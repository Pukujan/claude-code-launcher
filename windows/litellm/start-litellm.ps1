#!/usr/bin/env pwsh
# Start the ONE local LiteLLM proxy (CKFF + InferHub model groups) from this
# repository's shared/litellm folder. No litellm-ckff-ops checkout is needed.
# The launcher passes the env files it chose: -CkffEnvFile (CKFF keys) and
# -InferHubEnvFile (INFERHUB_API_KEY etc.). Values are never printed.
# An optional machine-local env file (-LocalEnvFile, default
# shared\litellm\.env.local, gitignored) is loaded last, for per-PC settings
# such as CCL_WEB_SEARCH_CHAIN and SEARXNG_API_BASE. A missing file is fine.
# Merges config/config.yaml + inferhub_top20.yaml + inferhub_aliases.yaml
# into config/runtime.yaml and serves that on 127.0.0.1 only.
# Keyless: no LITELLM_MASTER_KEY is required. If one is set in an env file it
# is passed through and LiteLLM enforces it.
# Run with -Background to start a detached background process.
# Run with -SkipSync to skip Top20 regeneration (still merges + applies seat).
# Writes the LiteLLM PID to shared/litellm/logs/litellm.pid; stop-litellm.ps1
# stops only that process.

param(
    [switch]$Background,
    [switch]$SkipSync,
    [switch]$ForceInstall,
    [int]$Port = 4000,
    [string]$CkffEnvFile = '',
    [string]$InferHubEnvFile = '',
    [string]$LocalEnvFile = '',
    [string]$Top20Csv = ''
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LiteLLMRoot = Join-Path $RepoRoot 'shared\litellm'
$VenvPath = Join-Path $LiteLLMRoot '.litellm-venv'
$LogDir = Join-Path $LiteLLMRoot 'logs'
# A test proxy on another port gets its own PID and log files, so it never
# overwrites the live proxy's litellm.pid (stop-litellm.ps1 reads that file).
$LogTag = if ($Port -eq 4000) { 'litellm' } else { "litellm-$Port" }
$PidFile = Join-Path $LogDir "$LogTag.pid"
$StdoutLog = Join-Path $LogDir "$LogTag.out.log"
$StderrLog = Join-Path $LogDir "$LogTag.err.log"
$PythonScripts = Join-Path $LiteLLMRoot 'scripts'
$Requirements = Join-Path $LiteLLMRoot 'requirements.txt'
$Overrides = Join-Path $LiteLLMRoot 'requirements-overrides.txt'
if (-not $InferHubEnvFile) { $InferHubEnvFile = Join-Path $RepoRoot '.env' }
if (-not $LocalEnvFile) { $LocalEnvFile = Join-Path $LiteLLMRoot '.env.local' }
if (-not $CkffEnvFile) {
    # Default to the real Desktop known folder; no user name is hardcoded.
    $DesktopDir = [Environment]::GetFolderPath('Desktop')
    if (-not $DesktopDir) { $DesktopDir = Join-Path $env:USERPROFILE 'Desktop' }
    $CkffEnvFile = Join-Path $DesktopDir 'configs\.env'
}

function Import-DotEnvFile {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "note: $Label env not found at $Path"
        return
    }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*([A-Za-z0-9_.-]+)\s*=\s*(.*?)\s*$') {
            $key = $Matches[1]
            $val = $Matches[2]
            if ($val.StartsWith('"') -and $val.EndsWith('"') -and $val.Length -ge 2) {
                $val = $val.Substring(1, $val.Length - 2)
            } elseif ($val.StartsWith("'") -and $val.EndsWith("'") -and $val.Length -ge 2) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            [Environment]::SetEnvironmentVariable($key, $val, 'Process')
        }
    }
    Write-Host "loaded env names from $Label ($Path) [values not printed]"
}

# --- Load secrets (names only ever logged) ---
# A missing desktop env is not fatal: Import-DotEnvFile prints a note and the
# InferHub env (or the shell environment) can still supply the keys.
Import-DotEnvFile -Path $CkffEnvFile -Label 'desktop-configs'
if ($InferHubEnvFile -ne $CkffEnvFile) {
    Import-DotEnvFile -Path $InferHubEnvFile -Label 'inferhub'
}
# Per-PC settings (e.g. the web search chain). Optional, so no note when absent.
if (Test-Path -LiteralPath $LocalEnvFile) {
    Import-DotEnvFile -Path $LocalEnvFile -Label 'local'
}
# CCL_ENV_ALIASES=TARGET=source,... (usually set in the local env file) copies an
# already-loaded value to the name LiteLLM reads, e.g.
# TAVILY_API_KEY=my_tavily_key, so a key kept under another name in the
# desktop env needs no second copy. A target that is already set wins.
$aliasSpec = [Environment]::GetEnvironmentVariable('CCL_ENV_ALIASES', 'Process')
if (-not [string]::IsNullOrWhiteSpace($aliasSpec)) {
    foreach ($pair in ($aliasSpec -split ',')) {
        $parts = $pair -split '=', 2
        if ($parts.Count -ne 2) { continue }
        $target = $parts[0].Trim()
        $source = $parts[1].Trim()
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($target, 'Process'))) { continue }
        $value = [Environment]::GetEnvironmentVariable($source, 'Process')
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host "note: env alias $target <- $source skipped, $source is not set"
            continue
        }
        [Environment]::SetEnvironmentVariable($target, $value, 'Process')
        Write-Host "env alias: $target <- $source [value not printed]"
    }
}

# Map CKFF secrets to the names LiteLLM expects
$envMap = @{
    'CKFF_DEFAULT_KEY'      = 'ckff-cortex-default'
    'CKFF_GROK_KEY'         = 'ckff-cortex-grok'
    'CKFF_KIRO_KEY'         = 'ckff-kiro-pro'
    'CKFF_KIMI_KEY'         = 'ckff_cortex_kimi_token_'
    'CKFF_GEMINI_CLI_KEY'   = 'ckff-cortex-gemini_cli'
    'CKFF_CODEX_CC_KEY'     = 'ckff-cortex-codex-CC'
    'CKFF_CODEX_PLUS_KEY'   = 'ckff-cortex-codex-plus'
    'CKFF_CODEX_PRO_KEY'    = 'ckff-cortex-codex-pro'
    'CKFF_IMAGEGEN_KEY'     = 'ckff-cortex-image-generation'
    'CKFF_EMBED_KEY'        = 'ckff_cortex_embedder_rerank'
}
# LITELLM_MASTER_KEY is optional (keyless proxy). If an env file set it, it is
# already in this process and LiteLLM picks it up from os.environ.
# Without a key, newer LiteLLM (1.104+) refuses to start unless this flag is set.
# The pinned 1.103.0 starts keyless without it; the flag is set anyway, only in
# this process (and so only for the proxy it starts), never machine-wide.
if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('LITELLM_MASTER_KEY', 'Process'))) {
    [Environment]::SetEnvironmentVariable('LITELLM_DANGEROUSLY_PERMIT_WEAK_OR_UNSET_MASTER_KEY', 'true', 'Process')
}

foreach ($secretName in $envMap.Keys) {
    $envKey = $envMap[$secretName]
    $value = [Environment]::GetEnvironmentVariable($envKey, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Missing value for $envKey ($secretName)"
    }
    [Environment]::SetEnvironmentVariable($secretName, $value, 'Process')
}

if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('INFERHUB_API_KEY', 'Process'))) {
    throw 'INFERHUB_API_KEY missing after loading env files'
}

# Prefer InferHub URL from env when present
$ihUrl = [Environment]::GetEnvironmentVariable('INFERHUB_API_URL', 'Process')
if ([string]::IsNullOrWhiteSpace($ihUrl)) {
    $ihUrl = 'https://api.inferhub.dev/v1'
}
$ihUrl = $ihUrl.TrimEnd('/')
if ($ihUrl -notmatch '/v1$') { $ihUrl = $ihUrl + '/v1' }

# --- Ensure virtual environment exists ---
# uv makes the venv and installs into it. Plain python -m venv + pip is only
# the fallback for a machine without uv. Same venv path either way.
$Uv = Get-Command uv -ErrorAction SilentlyContinue | Select-Object -First 1
$Python = Join-Path $VenvPath 'Scripts\python.exe'
$Pip = Join-Path $VenvPath 'Scripts\pip.exe'
if (-not (Test-Path -LiteralPath $VenvPath)) {
    Write-Host "Creating virtual environment at $VenvPath ..."
    # uv reports progress on stderr; under PS 5.1 + Stop that must not be fatal.
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    if ($Uv) { & $Uv.Source venv $VenvPath } else { python -m venv $VenvPath }
    $venvExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($venvExit -ne 0) { throw "creating the venv failed: $venvExit" }
}

$LiteLLM = Join-Path $VenvPath 'Scripts\litellm.exe'
# Use the bundled model cost map: avoids a network fetch (and a stderr WARNING) at import/startup.
$env:LITELLM_LOCAL_MODEL_COST_MAP = 'True'
$needInstall = [bool]$ForceInstall
if (-not $needInstall) {
    # PS 5.1 + $ErrorActionPreference=Stop turns any native stderr into a terminating error; judge by exit code only.
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $Python -c "import litellm, yaml, ddgs" 2>$null
    $importOk = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEap
    if (-not $importOk) { $needInstall = $true }
}
if ($needInstall) {
    Write-Host 'Installing pinned LiteLLM + PyYAML into venv...'
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    if ($Uv) {
        # LiteLLM 1.103.0 declares starlette>=1.0.1; the working venv runs the
        # older pins in the overrides file, which uv applies with --override.
        & $Uv.Source pip install --python $Python -r $Requirements --override $Overrides
        $installExit = $LASTEXITCODE
    } else {
        Write-Host 'uv not found; falling back to pip'
        # A venv made by uv has no pip, so bootstrap it first.
        if (-not (Test-Path -LiteralPath $Pip)) { & $Python -m ensurepip --upgrade }
        & $Python -m pip install -r $Requirements
        $installExit = $LASTEXITCODE
        # Same override pins on top (pip warns about the conflict).
        if ($installExit -eq 0) { & $Python -m pip install -r $Overrides; $installExit = $LASTEXITCODE }
    }
    $ErrorActionPreference = $prevEap
    if ($installExit -ne 0) { throw "installing LiteLLM into the venv failed: $installExit" }
} else {
    Write-Host 'LiteLLM already importable; skipping install (use -ForceInstall to refresh)'
}

# --- Build InferHub fragments + merge runtime config ---
$SeatPath = Join-Path $LiteLLMRoot 'config\inferhub_seat.json'
if (-not (Test-Path -LiteralPath $SeatPath)) {
    $defaultSeat = @{
        main_inferhub_id = 'cb/deepseek-v4.1-flash'
        advisor_inferhub_id = $null
        updated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    } | ConvertTo-Json
    # UTF-8 without a BOM: PS 5.1's -Encoding UTF8 adds one and json.loads rejects it.
    [System.IO.File]::WriteAllText($SeatPath, $defaultSeat, [System.Text.UTF8Encoding]::new($false))
    Write-Host "created default seat at $SeatPath"
}

# HOOK(ire): the Top 20 CSV. -Top20Csv wins, then config\top20.csv (written by
# an IRE fetch when one exists), then config\top20-builtin.csv (the launcher
# table). -SkipSync only skips regeneration when inferhub_top20.yaml exists.
$Top20Yaml = Join-Path $LiteLLMRoot 'config\inferhub_top20.yaml'
if (-not $Top20Csv) {
    $fetched = Join-Path $LiteLLMRoot 'config\top20.csv'
    $Top20Csv = if (Test-Path -LiteralPath $fetched) { $fetched } else { Join-Path $LiteLLMRoot 'config\top20-builtin.csv' }
}
if (-not $SkipSync -or -not (Test-Path -LiteralPath $Top20Yaml)) {
    Write-Host "Writing InferHub Top 20 deployments from $(Split-Path -Leaf $Top20Csv) ..."
    & $Python (Join-Path $PythonScripts 'sync_inferhub_top20.py') --csv $Top20Csv --api-base $ihUrl
    if ($LASTEXITCODE -ne 0) { throw "sync_inferhub_top20.py failed: $LASTEXITCODE" }
}

Write-Host 'Applying InferHub Claude seat aliases ...'
& $Python (Join-Path $PythonScripts 'apply_inferhub_seat.py') --api-base $ihUrl --no-reload
if ($LASTEXITCODE -ne 0) { throw "apply_inferhub_seat.py failed: $LASTEXITCODE" }

Write-Host 'Merging CKFF + InferHub into config/runtime.yaml ...'
& $Python (Join-Path $PythonScripts 'merge_litellm_config.py') --no-reload
if ($LASTEXITCODE -ne 0) { throw "merge_litellm_config.py failed: $LASTEXITCODE" }

$ConfigPath = Join-Path $LiteLLMRoot 'config\runtime.yaml'
Write-Host "Starting unified LiteLLM proxy on http://127.0.0.1:$Port (CKFF + InferHub)"

# Never take over a port someone else holds (port 4000 is the live proxy).
$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    throw "Port $Port is already in use (PID $(@($listener)[0].OwningProcess)). Not touching it."
}

if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

$env:PYTHONUTF8 = '1'
# Load shared/litellm/sitecustomize.py (latin-1 guard + /workbench/reload_runtime)
$env:PYTHONPATH = if ($env:PYTHONPATH) { "$LiteLLMRoot;$env:PYTHONPATH" } else { "$LiteLLMRoot" }


if ($Background) {
    # Win32_Process.Create does not run a shell, so wrap in cmd.exe /c for the log redirection to work.
    # The child reruns this script in the foreground; -SkipSync is safe because
    # inferhub_top20.yaml was just written above.
    $fwd = " -SkipSync -CkffEnvFile `"$CkffEnvFile`" -InferHubEnvFile `"$InferHubEnvFile`" -LocalEnvFile `"$LocalEnvFile`""
    $cmd = "cmd.exe /c powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Port $Port$fwd 1> `"$StdoutLog`" 2> `"$StderrLog`""
    $proc = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
    if ($proc.ReturnValue -ne 0) {
        throw "Failed to start background process (return code $($proc.ReturnValue))"
    }
    Write-Host "LiteLLM starting in background (wrapper PID $($proc.ProcessId); LiteLLM PID goes to $PidFile)"
    Write-Host "Logs: $StdoutLog and $StderrLog"
} else {
    # Bind 127.0.0.1 only, never 0.0.0.0.
    $litellmArgs = @('--config', "`"$ConfigPath`"", '--host', '127.0.0.1', '--port', "$Port")
    $p = Start-Process -FilePath $LiteLLM -ArgumentList $litellmArgs -NoNewWindow -PassThru
    Set-Content -LiteralPath $PidFile -Value $p.Id -Encoding ASCII
    Write-Host "LiteLLM PID $($p.Id) (recorded in $PidFile)"
    $p.WaitForExit()
    $recorded = (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ("$recorded".Trim() -eq "$($p.Id)") { Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue }
    exit $p.ExitCode
}
