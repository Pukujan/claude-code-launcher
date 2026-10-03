#!/usr/bin/env pwsh
# Stop the locally-running LiteLLM proxy (D:\claude\litellm workbench).

$ErrorActionPreference = 'SilentlyContinue'

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$VenvPython = Join-Path $RepoRoot '.litellm-venv\Scripts\python.exe'

$procs = Get-Process python, litellm -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -like ('*' + $RepoRoot + '*') -or
    $_.Path -like '*\litellm*' -or
    ($VenvPython -and $_.Path -eq $VenvPython) -or
    $_.Path -like '*litellm-ckff-ops*' -or
    $_.Path -like '*\.litellm-venv\*'
}

# Also kill whatever owns port 4000 if it looks like our proxy
$portOwners = @()
Get-NetTCPConnection -LocalPort 4000 -ErrorAction SilentlyContinue | ForEach-Object {
    $portOwners += $_.OwningProcess
}
$portOwners = $portOwners | Select-Object -Unique

if ($procs) {
    $procs | Stop-Process -Force
    Write-Host "Stopped LiteLLM-related processes."
} else {
    Write-Host "No LiteLLM python processes matched by path."
}

foreach ($procId in $portOwners) {
    try {
        $p = Get-Process -Id $procId -ErrorAction Stop
        Write-Host ("Stopping port-4000 owner PID {0} ({1})" -f $procId, $p.ProcessName)
        Stop-Process -Id $procId -Force
    } catch {
        Write-Host ("Port 4000 PID {0} already gone" -f $pid)
    }
}

Start-Sleep -Seconds 1
$left = Get-NetTCPConnection -LocalPort 4000 -ErrorAction SilentlyContinue
if ($left) {
    $left | ForEach-Object { Write-Host ("Port 4000 still bound by PID {0}" -f $_.OwningProcess) }
} else {
    Write-Host "Port 4000 is free."
}
