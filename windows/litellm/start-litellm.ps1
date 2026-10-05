#!/usr/bin/env pwsh
# Start the ONE local LiteLLM proxy (InferHub; CKFF only when switched on) from
# this repository's shared/litellm folder. No litellm-ckff-ops checkout is needed.
# CKFF is OFF by default since 2026-10-04 (Alex: unstable, never use it). The
# switch is ckff_enabled in shared\litellm\config\providers.yaml, overridden by
# LITELLM_ENABLE_CKFF (1 on, 0 off). While it is off no ckff* name is loaded
# from any env file and none is passed to the proxy.
# The launcher passes the env files it chose: -DesktopEnvFile (the desktop
# configs .env; -CkffEnvFile is the old name) and -InferHubEnvFile
# (INFERHUB_API_KEY etc.). Values are never printed.
# An optional machine-local env file (-LocalEnvFile, default
# shared\litellm\.env.local, gitignored) is loaded last, for per-PC settings
# such as CCL_WEB_SEARCH_CHAIN and SEARXNG_API_BASE. A missing file is fine.
# Merges config/config.yaml + inferhub_top20.yaml + inferhub_aliases.yaml
# into config/runtime.yaml and serves that on 127.0.0.1 only.
# Keyless: no LITELLM_MASTER_KEY is required. If one is set in an env file it
# is passed through and LiteLLM enforces it.
# Keys (issue #64): outside packaged mode, the gitignored .env in the repository
# root is the one env file when it exists. It is used when no env file is passed,
# or when the launcher passes that same file as both -DesktopEnvFile and
# -InferHubEnvFile; the desktop configs .env is then not read at all. Only when it
# is missing do the old defaults apply. .env.local is still loaded last.
# Run with -ShowEnvSources to load the env files, print which files were read
# and which key NAMES are set (never values), and exit without starting anything.
# Run with -Background to start a detached background process.
# Run with -SkipSync to skip Top20 regeneration (still merges + applies seat).
# Writes the LiteLLM PID to shared/litellm/logs/litellm.pid; stop-litellm.ps1
# stops only that process.
# -CclHome <install folder> is the packaged mode used by windows\install.ps1
# (issue #61, docs/specs/windows-package.md): venv, logs and env files come from
# that folder, the desktop configs .env is never read, and CCL_INSTANCE_ID from
# install.json is passed to the proxy so /ccl/identity can name this install.

param(
    [switch]$Background,
    [switch]$SkipSync,
    [switch]$ForceInstall,
    [int]$Port = 4000,
    [Alias('CkffEnvFile')]
    [string]$DesktopEnvFile = '',
    [string]$InferHubEnvFile = '',
    [string]$LocalEnvFile = '',
    [string]$Top20Csv = '',
    [string]$CclHome = '',
    [switch]$ShowEnvSources
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LiteLLMRoot = Join-Path $RepoRoot 'shared\litellm'
$VenvPath = Join-Path $LiteLLMRoot '.litellm-venv'
$LogDir = Join-Path $LiteLLMRoot 'logs'
# A test proxy on another port gets its own PID and log files, so it never
# overwrites the live proxy's litellm.pid (stop-litellm.ps1 reads that file).
$LogTag = if ($Port -eq 4000) { 'litellm' } else { "litellm-$Port" }
$CclInstall = $null
$TinyFishEnvFile = ''
if ($CclHome) {
    $CclHome = [IO.Path]::GetFullPath($CclHome)
    $installJson = Join-Path $CclHome 'install.json'
    if (-not (Test-Path -LiteralPath $installJson)) { throw "No install.json in $CclHome" }
    $CclInstall = Get-Content -LiteralPath $installJson -Raw | ConvertFrom-Json
    $VenvPath = Join-Path $CclHome 'venv'
    $LogDir = Join-Path $CclHome 'logs'
    # One proxy per install, so the PID file name never depends on the port.
    $LogTag = 'litellm'
    $InferHubEnvFile = Join-Path $CclHome 'secrets\inferhub.env'
    # Optional: the free TinyFish Search key (TINYFISH_API_KEY), which puts tinyfish
    # first in the default web search chain.
    $TinyFishEnvFile = Join-Path $CclHome 'secrets\tinyfish.env'
    $LocalEnvFile = Join-Path $CclHome 'state\local.env'
    $env:CCL_INSTANCE_ID = [string]$CclInstall.instance_id
    # Self-contained install (install.json v2): the folder's tools and caches.
    if ($CclInstall.claude_config_dir) {
        $cclLib = Join-Path $RepoRoot 'windows\install.ps1'
        if (Test-Path -LiteralPath $cclLib) {
            $env:CCL_INSTALL_LIBRARY_ONLY = '1'
            . $cclLib
            Remove-Item Env:CCL_INSTALL_LIBRARY_ONLY -ErrorAction SilentlyContinue
            $ErrorActionPreference = 'Stop'
            $null = Use-CclToolEnv -Vars (Get-CclToolEnv -InstallDir $CclHome -State $CclInstall)
        }
    }
}
$PidFile = Join-Path $LogDir "$LogTag.pid"
$StdoutLog = Join-Path $LogDir "$LogTag.out.log"
$StderrLog = Join-Path $LogDir "$LogTag.err.log"
$PythonScripts = Join-Path $LiteLLMRoot 'scripts'
$Requirements = Join-Path $LiteLLMRoot 'requirements.txt'
$Overrides = Join-Path $LiteLLMRoot 'requirements-overrides.txt'
# The launcher-folder .env (issue #64): the only env file when it exists and the
# caller passed no other file.
$LauncherEnvFile = Join-Path $RepoRoot '.env'
function Test-SameEnvPath([string]$a, [string]$b) {
    if (-not $a -or -not $b) { return $false }
    return ([IO.Path]::GetFullPath($a) -eq [IO.Path]::GetFullPath($b))
}
$LauncherOnly = (-not $CclHome) -and (Test-Path -LiteralPath $LauncherEnvFile) -and
    ((-not $DesktopEnvFile) -or (Test-SameEnvPath $DesktopEnvFile $LauncherEnvFile)) -and
    ((-not $InferHubEnvFile) -or (Test-SameEnvPath $InferHubEnvFile $LauncherEnvFile))
if ($LauncherOnly) {
    $DesktopEnvFile = $LauncherEnvFile
    $InferHubEnvFile = $LauncherEnvFile
}
if (-not $InferHubEnvFile) { $InferHubEnvFile = Join-Path $RepoRoot '.env' }
if (-not $LocalEnvFile) { $LocalEnvFile = Join-Path $LiteLLMRoot '.env.local' }
if (-not $DesktopEnvFile -and -not $CclHome) {
    # Default to the real Desktop known folder; no user name is hardcoded.
    $DesktopDir = [Environment]::GetFolderPath('Desktop')
    if (-not $DesktopDir) { $DesktopDir = Join-Path $env:USERPROFILE 'Desktop' }
    $DesktopEnvFile = Join-Path $DesktopDir 'configs\.env'
}

# --- CKFF switch: env LITELLM_ENABLE_CKFF wins, else config\providers.yaml, else off ---
function Get-CkffEnabled {
    $raw = [Environment]::GetEnvironmentVariable('LITELLM_ENABLE_CKFF', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $v = $raw.Trim().Trim('"', "'").ToLowerInvariant()
        if (@('1', 'true', 'yes', 'on') -contains $v) { return $true }
        if (@('0', 'false', 'no', 'off') -contains $v) { return $false }
    }
    $providers = Join-Path $LiteLLMRoot 'config\providers.yaml'
    if (Test-Path -LiteralPath $providers) {
        foreach ($line in Get-Content -LiteralPath $providers) {
            if ($line -match '^\s*ckff_enabled\s*:\s*([^#\s]+)') {
                return (@('1', 'true', 'yes', 'on') -contains $Matches[1].Trim('"', "'").ToLowerInvariant())
            }
        }
    }
    return $false
}
$CkffEnabled = Get-CkffEnabled

function Import-DotEnvFile {
    # -SkipCkff: leave out every ckff*/CKFF* name (ckff-*, ckff_*, CKFF_*, ckff_astra).
    param([string]$Path, [string]$Label, [switch]$SkipCkff)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "note: $Label env not found at $Path"
        return
    }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*([A-Za-z0-9_.-]+)\s*=\s*(.*?)\s*$') {
            $key = $Matches[1]
            $val = $Matches[2]
            if ($SkipCkff -and $key -match '^ckff') { continue }
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
# The desktop env is still read with CKFF off: it holds other keys, e.g. the
# web search ones CCL_ENV_ALIASES points at. Its ckff* names are skipped.
$skip = -not $CkffEnabled
if ($CkffEnabled) {
    Write-Host 'CKFF provider group: ON (LITELLM_ENABLE_CKFF or config\providers.yaml)'
} else {
    Write-Host 'CKFF provider group: OFF (default since 2026-10-04). ckff* keys are not loaded.'
    # Nothing CKFF inherited from the user/machine environment reaches the proxy either.
    foreach ($item in @(Get-ChildItem Env: | Where-Object { $_.Name -match '^ckff' })) {
        [Environment]::SetEnvironmentVariable($item.Name, $null, 'Process')
    }
}
if ($LauncherOnly) {
    Write-Host 'env source: the .env in the launcher folder only (desktop configs .env and IRE .env not read)'
    Import-DotEnvFile -Path $LauncherEnvFile -Label 'launcher' -SkipCkff:$skip
} else {
    if ($DesktopEnvFile) {
        Import-DotEnvFile -Path $DesktopEnvFile -Label 'desktop-configs' -SkipCkff:$skip
    }
    if ($InferHubEnvFile -ne $DesktopEnvFile) {
        Import-DotEnvFile -Path $InferHubEnvFile -Label 'inferhub' -SkipCkff:$skip
    }
}
if ($TinyFishEnvFile -and (Test-Path -LiteralPath $TinyFishEnvFile)) {
    Import-DotEnvFile -Path $TinyFishEnvFile -Label 'tinyfish' -SkipCkff:$skip
}
# Per-PC settings (e.g. the web search chain). Optional, so no note when absent.
if (Test-Path -LiteralPath $LocalEnvFile) {
    Import-DotEnvFile -Path $LocalEnvFile -Label 'local' -SkipCkff:$skip
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

if ($ShowEnvSources) {
    # Names only, never values.
    foreach ($name in @('INFERHUB_API_KEY', 'INFERHUB_API_URL', 'LITELLM_MASTER_KEY', 'TINYFISH_API_KEY',
                        'TAVILY_API_KEY', 'EXA_API_KEY', 'BRAVE_API_KEY', 'SERPER_API_KEY', 'YOUCOM_API_KEY')) {
        $state = if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name, 'Process'))) { 'missing' } else { 'set' }
        Write-Host "${name}: $state"
    }
    exit 0
}

# Map CKFF secrets to the names LiteLLM expects (only used when CKFF is on)
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

if ($CkffEnabled) {
    foreach ($secretName in $envMap.Keys) {
        $envKey = $envMap[$secretName]
        $value = [Environment]::GetEnvironmentVariable($envKey, 'Process')
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Missing value for $envKey ($secretName)"
        }
        [Environment]::SetEnvironmentVariable($secretName, $value, 'Process')
    }
}
# The Python helpers (seat, merge) read the same switch; pass the resolved value on.
$env:LITELLM_ENABLE_CKFF = if ($CkffEnabled) { '1' } else { '0' }

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
    $VenvPython = $(if ($CclInstall -and $CclInstall.tools -and $CclInstall.tools.python -and $CclInstall.tools.python.path) { [string]$CclInstall.tools.python.path } else { '3.12' })
    if ($Uv) { & $Uv.Source venv --python $VenvPython $VenvPath } else { python -m venv $VenvPath }
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
    # No slots yet: apply_inferhub_seat.py uses the default chains in inferhub_fallbacks.yaml.
    $defaultSeat = @{
        version = 2
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

Write-Host 'Writing the Claude Code slot chains ...'
& $Python (Join-Path $PythonScripts 'apply_inferhub_seat.py') --api-base $ihUrl --no-reload
if ($LASTEXITCODE -ne 0) { throw "apply_inferhub_seat.py failed: $LASTEXITCODE" }

Write-Host 'Merging InferHub (and CKFF only when on) into config/runtime.yaml ...'
& $Python (Join-Path $PythonScripts 'merge_litellm_config.py') --no-reload
if ($LASTEXITCODE -ne 0) { throw "merge_litellm_config.py failed: $LASTEXITCODE" }

$ConfigPath = Join-Path $LiteLLMRoot 'config\runtime.yaml'
$groups = if ($CkffEnabled) { 'CKFF + InferHub' } else { 'InferHub only; CKFF off' }
Write-Host "Starting unified LiteLLM proxy on http://127.0.0.1:$Port ($groups)"

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
    $fwd = if ($CclHome) {
        " -SkipSync -CclHome `"$CclHome`""
    } else {
        " -SkipSync -DesktopEnvFile `"$DesktopEnvFile`" -InferHubEnvFile `"$InferHubEnvFile`" -LocalEnvFile `"$LocalEnvFile`""
    }
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
