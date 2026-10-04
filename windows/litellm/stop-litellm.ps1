#!/usr/bin/env pwsh
# Stop the LiteLLM proxy that start-litellm.ps1 started from this repository,
# and nothing else. It reads the PID from shared/litellm/logs/litellm.pid,
# checks that the process is this repository's venv litellm, and stops that
# process and its children. It never looks up or kills whatever owns a port,
# so the live proxy on 127.0.0.1:4000 started some other way is left alone.

param([switch]$WhatIf, [int]$Port = 4000)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LiteLLMRoot = Join-Path $RepoRoot 'shared\litellm'
$VenvScripts = Join-Path $LiteLLMRoot '.litellm-venv\Scripts'
# -Port picks a test proxy's own PID file (start-litellm.ps1 -Port N writes litellm-N.pid).
$PidFile = Join-Path $LiteLLMRoot $(if ($Port -eq 4000) { 'logs\litellm.pid' } else { "logs\litellm-$Port.pid" })

if (-not (Test-Path -LiteralPath $PidFile)) {
    Write-Host "No PID file at $PidFile; nothing started by this repo is recorded. Not stopping anything."
    exit 0
}

$raw = (Get-Content -LiteralPath $PidFile | Select-Object -First 1)
$procId = 0
if (-not [int]::TryParse("$raw".Trim(), [ref]$procId) -or $procId -le 0) {
    Write-Host "PID file $PidFile does not hold a PID; leaving it for you to check."
    exit 1
}

$proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
if (-not $proc) {
    Write-Host "PID $procId is not running. Removing the stale PID file."
    Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
    exit 0
}

# PIDs get reused: only stop it if it is this repository's venv litellm.
$exe = $proc.Path
if (-not $exe -or -not $exe.StartsWith($VenvScripts, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "PID $procId is $($proc.ProcessName) at '$exe', not this repo's LiteLLM. Not stopping it."
    exit 1
}

function Get-ChildProcessId {
    param([int]$ParentId)
    $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ParentId" -ErrorAction SilentlyContinue)
    foreach ($k in $kids) {
        Get-ChildProcessId -ParentId ([int]$k.ProcessId)
        [int]$k.ProcessId
    }
}

# Children first (the litellm.exe launcher runs python.exe as a child).
$targets = @(Get-ChildProcessId -ParentId $procId) + @($procId)
foreach ($t in $targets) {
    if ($WhatIf) {
        Write-Host "Would stop PID $t"
        continue
    }
    Stop-Process -Id $t -Force -ErrorAction SilentlyContinue
    Write-Host "Stopped PID $t"
}
if (-not $WhatIf) { Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue }
