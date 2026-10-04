# Starts the fault server (4019) and a keyless, loopback-only test proxy
# (default 4012) with shared/litellm on PYTHONPATH so its sitecustomize
# (and the /workbench/reload_runtime ladder scope) loads.
# INFERHUB_API_KEY is read from the IRE .env into this process only; its value
# is never printed. LITELLM_MASTER_KEY is removed. Refuses port 4000.
param(
  [int]$Port = 4012,
  [string]$EnvFile = "D:\development\inference-recommendation-engine\.env",
  # Default: this repository's proxy venv (made by windows\litellm\start-litellm.ps1).
  [string]$LiteLLM = "",
  [string]$Python = "python"
)
$ErrorActionPreference = "Stop"
if ($Port -eq 4000) { throw "Port 4000 is the live proxy. Use another port." }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here "..\..")).Path
if (-not $LiteLLM) { $LiteLLM = Join-Path $repo "shared\litellm\.litellm-venv\Scripts\litellm.exe" }
if (-not (Test-Path -LiteralPath $LiteLLM)) { throw "litellm not found at $LiteLLM; pass -LiteLLM <path to litellm.exe>" }
$line = Get-Content -LiteralPath $EnvFile | Where-Object { $_ -match '^\s*INFERHUB_API_KEY\s*=' } | Select-Object -First 1
if (-not $line) { throw "INFERHUB_API_KEY not found in $EnvFile" }
$env:INFERHUB_API_KEY = ($line -replace '^\s*INFERHUB_API_KEY\s*=\s*', '').Trim().Trim('"').Trim("'")
Remove-Item Env:LITELLM_MASTER_KEY -ErrorAction SilentlyContinue
$env:PYTHONPATH = Join-Path $repo "shared\litellm"
$env:PYTHONIOENCODING = "utf-8"
$logs = Join-Path $env:TEMP "ccl-t46-logs"; New-Item -ItemType Directory -Force $logs | Out-Null
$f = Start-Process $Python -ArgumentList "`"$here\fault_server.py`" 4019" -WindowStyle Hidden -PassThru `
  -RedirectStandardError "$logs\fault.err" -RedirectStandardOutput "$logs\fault.out"
$p = Start-Process $LiteLLM -ArgumentList "--config `"$here\test-proxy.yaml`" --host 127.0.0.1 --port $Port" `
  -WindowStyle Hidden -PassThru -RedirectStandardError "$logs\proxy.err" -RedirectStandardOutput "$logs\proxy.out"
"fault_pid=$($f.Id) proxy_pid=$($p.Id) logs=$logs"
