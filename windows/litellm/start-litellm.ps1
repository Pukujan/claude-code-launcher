#!/usr/bin/env pwsh
# Start the ONE local LiteLLM proxy (CKFF + InferHub model groups).
# CKFF secrets: C:\Users\pujan\OneDrive\Desktop\configs\.env
# InferHub secrets: D:\claude\inferhub\.env (preferred) or same desktop .env
# Merges config/config.yaml + inferhub_top20.yaml + inferhub_aliases.yaml
# into config/runtime.yaml and serves that. Local-only (no Railway/Vercel).
# Run with -Background to start a detached background process.
# Run with -SkipSync to skip Top20 regeneration (still merges + applies seat).

param(
    [switch]$Background,
    [switch]$SkipSync,
    [switch]$ForceInstall,
    [int]$Port = 4000
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$VenvPath = Join-Path $RepoRoot '.litellm-venv'
$CkffEnvFile = 'C:\Users\pujan\OneDrive\Desktop\configs\.env'
$InferHubEnvFile = 'D:\claude\inferhub\.env'
$LogDir = Join-Path $RepoRoot 'logs'
$StdoutLog = Join-Path $LogDir 'litellm.out.log'
$StderrLog = Join-Path $LogDir 'litellm.err.log'
$PythonScripts = Join-Path $RepoRoot 'scripts'

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
if (-not (Test-Path -LiteralPath $CkffEnvFile)) {
    throw "CKFF/desktop env file not found: $CkffEnvFile"
}
Import-DotEnvFile -Path $CkffEnvFile -Label 'desktop-configs'
Import-DotEnvFile -Path $InferHubEnvFile -Label 'inferhub'

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
    'LITELLM_MASTER_KEY'    = 'LITELLM_MASTER_KEY'
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
if (-not (Test-Path -LiteralPath $VenvPath)) {
    Write-Host "Creating virtual environment at $VenvPath ..."
    python -m venv $VenvPath
}

$Python = Join-Path $VenvPath 'Scripts\python.exe'
$Pip = Join-Path $VenvPath 'Scripts\pip.exe'

$LiteLLM = Join-Path $VenvPath 'Scripts\litellm.exe'
# Use the bundled model cost map: avoids a network fetch (and a stderr WARNING) at import/startup.
$env:LITELLM_LOCAL_MODEL_COST_MAP = 'True'
$needInstall = [bool]$ForceInstall
if (-not $needInstall) {
    # PS 5.1 + $ErrorActionPreference=Stop turns any native stderr into a terminating error; judge by exit code only.
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $Python -c "import litellm, yaml" 2>$null
    $importOk = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEap
    if (-not $importOk) { $needInstall = $true }
}
if ($needInstall) {
    Write-Host 'Installing LiteLLM + PyYAML into venv...'
    & $Pip install --upgrade 'litellm[proxy]' 'pyyaml'
    if ($LASTEXITCODE -ne 0) { throw "pip install litellm failed: $LASTEXITCODE" }
    & $Pip install --upgrade 'fastapi>=0.115.0,<0.116.0' 'starlette>=0.40.0,<0.42.0' 'sse-starlette>=2.1.0,<2.2.0'
} else {
    Write-Host 'LiteLLM already importable; skipping pip (use -ForceInstall to refresh)'
}

# --- Build InferHub fragments + merge runtime config ---
$SeatPath = Join-Path $RepoRoot 'config\inferhub_seat.json'
if (-not (Test-Path -LiteralPath $SeatPath)) {
    $defaultSeat = @{
        main_inferhub_id = 'cb/deepseek-v4.1-flash'
        advisor_inferhub_id = $null
        updated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    } | ConvertTo-Json
    Set-Content -LiteralPath $SeatPath -Value $defaultSeat -Encoding UTF8
    Write-Host "created default seat at $SeatPath"
}

if (-not $SkipSync) {
    Write-Host 'Syncing InferHub Top 20 from IRE CSV ...'
    & $Python (Join-Path $PythonScripts 'sync_inferhub_top20.py') --api-base $ihUrl
    if ($LASTEXITCODE -ne 0) { throw "sync_inferhub_top20.py failed: $LASTEXITCODE" }
}

Write-Host 'Applying InferHub Claude seat aliases ...'
& $Python (Join-Path $PythonScripts 'apply_inferhub_seat.py') --api-base $ihUrl --no-reload
if ($LASTEXITCODE -ne 0) { throw "apply_inferhub_seat.py failed: $LASTEXITCODE" }

Write-Host 'Merging CKFF + InferHub into config/runtime.yaml ...'
& $Python (Join-Path $PythonScripts 'merge_litellm_config.py') --no-reload
if ($LASTEXITCODE -ne 0) { throw "merge_litellm_config.py failed: $LASTEXITCODE" }

$ConfigPath = Join-Path $RepoRoot 'config\runtime.yaml'
Write-Host "Starting unified LiteLLM proxy on http://127.0.0.1:$Port (CKFF + InferHub)"

if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

$env:PYTHONUTF8 = '1'
# Load repo-root sitecustomize.py (latin-1 guard + /workbench/reload_runtime)
$env:PYTHONPATH = if ($env:PYTHONPATH) { "$RepoRoot;$env:PYTHONPATH" } else { "$RepoRoot" }


if ($Background) {
    # Win32_Process.Create does not run a shell, so wrap in cmd.exe /c for the log redirection to work.
    $skip = if ($SkipSync) { ' -SkipSync' } else { '' }
    $cmd = "cmd.exe /c powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Port $Port$skip 1> `"$StdoutLog`" 2> `"$StderrLog`""
    $proc = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
    if ($proc.ReturnValue -ne 0) {
        throw "Failed to start background process (return code $($proc.ReturnValue))"
    }
    Write-Host "LiteLLM started in background. PID: $($proc.ProcessId)"
    Write-Host "Logs: $StdoutLog and $StderrLog"
} else {
    & $LiteLLM --config $ConfigPath --port $Port
}
