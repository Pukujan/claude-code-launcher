#!/usr/bin/env pwsh
# Install or update SlopSearX (https://github.com/magnus919/SlopSearX), a
# SearXNG-compatible meta search service, and run it on 127.0.0.1 so the
# LiteLLM proxy's WebSearch hook can use it as its first search source.
#
# Windows native: git + uv only (no pip, no Docker, no Valkey). It
#   1. clones or fast-forwards SlopSearX into -InstallDir (default: a
#      SlopSearX folder next to this checkout) and builds .venv with uv,
#   2. writes a hidden start script to %USERPROFILE%\.slopsearx and registers
#      a logon scheduled task (conhost --headless, no window) that runs it,
#   3. starts the task and waits for the JSON search API to answer,
#   4. writes CCL_WEB_SEARCH_CHAIN and SEARXNG_API_BASE to the proxy's
#      machine-local env file (shared\litellm\.env.local, gitignored).
# The proxy picks the new chain up on its next start; this script never
# touches a running proxy.
#
# -Uninstall stops and removes the task and its SlopSearX process. The checkout,
# logs and the env file stay.

param(
    [int]$Port = 18080,
    [string]$InstallDir = '',
    [string]$Ref = 'main',
    [string]$TaskName = 'SlopSearX',
    [string]$PythonVersion = '3.12',
    [string]$Chain = 'searxng,ddgs',
    # Optional CCL_ENV_ALIASES for the env file, e.g. paid fallbacks kept in the
    # desktop env under other names: 'TAVILY_API_KEY=my_tavily,EXA_API_KEY=my_exa'
    # (names only; the proxy start copies the values). Empty leaves it alone.
    [string]$EnvAliases = '',
    [switch]$NoTask,
    [switch]$NoEnv,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $InstallDir) { $InstallDir = Join-Path (Split-Path -Parent $RepoRoot) 'SlopSearX' }
$RunDir = Join-Path $env:USERPROFILE '.slopsearx'
$StartScript = Join-Path $RunDir 'start-slopsearx.ps1'
$LocalEnv = Join-Path $RepoRoot 'shared\litellm\.env.local'
$BaseUrl = "http://127.0.0.1:$Port"

# Native tools write progress to stderr; under 'Stop' Windows PowerShell 5.1
# would turn that into an error, so run them with 'Continue' and check the code.
function Invoke-Native([string]$What, [scriptblock]$Block, [switch]$AllowFail) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Block 2>&1 | ForEach-Object { Write-Host "  $_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($code -ne 0 -and -not $AllowFail) { throw "$What failed (exit $code)" }
}

function Get-SlopSearXProcess {
    # The venv's python.exe is a launcher that starts the base interpreter as a
    # child, so match the uvicorn arguments, not the venv path.
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
        Where-Object { $_.CommandLine -match 'slopsearx\.server:app' -and $_.CommandLine -match "--port $Port(\s|$)" }
}

function Close-SlopSearX {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    # Stopping the task ends the start script; the uvicorn child can outlive it.
    $starter = [regex]::Escape($StartScript)
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match $starter } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-SlopSearXProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Uninstall) {
    Close-SlopSearX
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    Write-Host "Removed task '$TaskName'. Left in place: $InstallDir, $RunDir, $LocalEnv"
    return
}

foreach ($tool in 'git', 'uv') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is not on PATH" }
}

# --- 1. Checkout + venv ---
if (-not (Test-Path -LiteralPath (Join-Path $InstallDir '.git'))) {
    Invoke-Native 'git clone' { git clone --quiet https://github.com/magnus919/SlopSearX.git "$InstallDir" }
}
# uv sync rewrites upstream's uv.lock when it is out of date; drop that local
# change so the checkout stays clean and fast-forwardable.
Invoke-Native 'git restore uv.lock' { git -C "$InstallDir" checkout --quiet -- uv.lock } -AllowFail
Invoke-Native 'git fetch' { git -C "$InstallDir" fetch --quiet origin }
Invoke-Native "git checkout $Ref" { git -C "$InstallDir" checkout --quiet $Ref }
Invoke-Native 'git fast-forward' { git -C "$InstallDir" merge --quiet --ff-only "origin/$Ref" } -AllowFail
$commit = (git -C "$InstallDir" rev-parse --short HEAD).Trim()
Write-Host "SlopSearX $commit in $InstallDir"

Push-Location $InstallDir
try {
    # Not --frozen: upstream's lock has lagged pyproject.toml (it once lacked structlog).
    Invoke-Native 'uv sync' { uv sync --no-dev --python $PythonVersion }
} finally {
    Pop-Location
}
Invoke-Native 'git restore uv.lock' { git -C "$InstallDir" checkout --quiet -- uv.lock } -AllowFail
$Python = Join-Path $InstallDir '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $Python)) { throw "no venv python at $Python" }

# --- 2. Start script + logon task ---
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
$start = @"
# Generated by claude-code-launcher windows\slopsearx\setup-slopsearx.ps1.
# Runs SlopSearX on 127.0.0.1:$Port with no window and restarts it if it exits.
`$ErrorActionPreference = 'Continue'
`$env:PYTHONUTF8 = '1'
`$log = Join-Path '$RunDir' 'autostart.log'
`$console = Join-Path '$RunDir' 'slopsearx.log'
Set-Location -LiteralPath '$InstallDir'
while (`$true) {
    if ((Test-Path `$console) -and (Get-Item `$console).Length -gt 20MB) {
        Move-Item -Force `$console "`$console.1"
    }
    Add-Content -Path `$log -Value "`$(Get-Date -Format s) starting slopsearx on 127.0.0.1:$Port"
    & cmd.exe /c "`"$Python`" -m uvicorn slopsearx.server:app --host 127.0.0.1 --port $Port --no-access-log >> `"`$console`" 2>&1"
    Add-Content -Path `$log -Value "`$(Get-Date -Format s) slopsearx exited with `$LASTEXITCODE; restarting in 10 s"
    Start-Sleep -Seconds 10
}
"@
Set-Content -LiteralPath $StartScript -Value $start -Encoding UTF8

if (-not $NoTask) {
    Close-SlopSearX
    $busy = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if ($busy) { throw "port $Port is already in use (PID $($busy[0].OwningProcess)); pick another -Port" }
    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" `
        -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$StartScript`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $trigger.Delay = 'PT20S'
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description "SlopSearX search API on 127.0.0.1:$Port (claude-code-launcher)" -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    # --- 3. Wait for the API ---
    $ok = $false
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-RestMethod "$BaseUrl/config" -TimeoutSec 5 | Out-Null
            $ok = $true
            break
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    if (-not $ok) { throw "SlopSearX did not answer on $BaseUrl within 90 s; see $RunDir\slopsearx.log" }
    $r = Invoke-RestMethod "$BaseUrl/search?format=json&q=python+asyncio" -TimeoutSec 60
    Write-Host "SlopSearX is up on $BaseUrl ($(@($r.results).Count) results for a test query)"
}

# --- 4. Proxy env ---
if (-not $NoEnv) {
    $want = [ordered]@{ 'CCL_WEB_SEARCH_CHAIN' = $Chain; 'SEARXNG_API_BASE' = $BaseUrl }
    if ($EnvAliases) { $want['CCL_ENV_ALIASES'] = $EnvAliases }
    $lines = @()
    if (Test-Path -LiteralPath $LocalEnv) { $lines = @(Get-Content -LiteralPath $LocalEnv) }
    foreach ($k in $want.Keys) {
        $line = "$k=$($want[$k])"
        $i = [array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -match "^\s*$k\s*=" })
        if ($i -ge 0) { $lines[$i] = $line } else { $lines += $line }
    }
    # No BOM: start-litellm.ps1 matches each line from its first character.
    [IO.File]::WriteAllLines($LocalEnv, [string[]]$lines, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Wrote $($want.Keys -join ', ') to $LocalEnv"
    Write-Host 'The proxy reads it on its next start (start-litellm.ps1).'
}
