# claude-code-launcher: one-command Windows installer (issue #61).
#
# Sets up Claude Code with InferHub models through a local LiteLLM proxy. You need an
# InferHub API key, and a free TinyFish Search key is recommended for web search
# (https://agent.tinyfish.ai/api-keys). Run it in PowerShell:
#
#   irm https://github.com/Pukujan/claude-code-launcher/releases/download/v1.0.0-windows/install.ps1 | iex
#
# or, to pass options, download it first and run
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 [-InferHubKey <key>] [-TinyFishKey <key>] [-Uninstall] ...
#
# What it does: installs uv, git, Node with pnpm and Claude Code when they are
# missing (official installers and winget), fetches the launcher files for its own
# version into %LOCALAPPDATA%\claude-code-launcher\app, stores the key per user,
# builds the LiteLLM venv with uv on Python 3.12, picks a free port from 4000 up
# (it never takes a port another program holds), runs the proxy from a hidden
# logon task, writes Claude Code's settings and leaves a `claude-inferhub` command.
# The spec is docs/specs/windows-package.md in the repository.
#
# The keys are never printed or logged. Prerequisites are never uninstalled.

[CmdletBinding()]
param(
    [string]$InferHubKey = '',
    [string]$InstallDir = '',
    [string]$Ref = 'v1.0.0-windows',
    [string]$Source = '',
    [int]$StartPort = 4000,
    [switch]$Uninstall,
    [switch]$ChangeKey,
    [string]$TinyFishKey = '',
    [switch]$SkipTinyFish,
    [switch]$ChangeTinyFishKey,
    [switch]$SkipPrereqs,
    [switch]$SkipVenv,
    [switch]$NoTask,
    [switch]$NoPath,
    [switch]$NoStart,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:CclVersion = '1.0.0-windows'
$script:CclDefaultRef = $Ref
$script:CclRepo = 'Pukujan/claude-code-launcher'
$script:CclTaskName = 'claude-code-launcher-proxy'
$script:CclSchema = 'claude-code-launcher.install.v1'
$script:CclApp = 'claude-code-launcher'
$script:CclOnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or [bool]$IsWindows
$script:CclLogFile = $null
# Copying the launcher files skips these names at any depth...
$script:CclSkipAnywhere = @('.git', 'node_modules', '__pycache__', '.litellm-venv', '.venv', 'logs', '.pytest_cache',
    '.ruff_cache', '.hypothesis', 'last-picks.json', '.env.local')
# ...and these at the top level only.
$script:CclSkipTop = @('pcm', 'tests', 'history', '.github', '.coord', '.continuity', '.oio', '.content-system', 'checkpoints', 'tasks')

# ---------------------------------------------------------------- output

function Write-CclLog {
    # One line to the console and, once the install folder exists, to logs\install.log.
    # Callers never pass the key.
    param([string]$Message, [string]$Level = 'info')
    $line = '[claude-inferhub] ' + $Message
    if ($Level -eq 'warn') { Write-Warning $Message } else { Write-Information $line -InformationAction Continue }
    if ($script:CclLogFile) {
        try { Add-Content -LiteralPath $script:CclLogFile -Value ((Get-Date -Format s) + ' ' + $Level + ' ' + $Message) -Encoding UTF8 } catch { }
    }
}

function Write-CclUtf8 {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------- key

function Test-CclKeyShape {
    param([AllowNull()][AllowEmptyString()][string]$Key)
    if ($null -eq $Key) { return $false }
    $t = $Key.Trim()
    if ($t.Length -eq 0 -or $t.Length -gt 4096) { return $false }
    return ($Key -notmatch "[`r`n`0`"]")
}

function Read-CclSecret {
    param([string]$Path, [string]$Name = 'INFERHUB_API_KEY')
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line.StartsWith($Name + '=')) { return $line.Substring($Name.Length + 1) }
    }
    return $null
}

function Write-CclSecret {
    # secrets\inferhub.env or secrets\tinyfish.env: one NAME=key line, UTF-8 without BOM.
    # On Windows the folder is limited to the current user.
    param([string]$Path, [string]$Key, [string]$Name = 'INFERHUB_API_KEY')
    Write-CclUtf8 -Path $Path -Text ($Name + '=' + $Key + "`n")
    if ($script:CclOnWindows) {
        $dir = Split-Path -Parent $Path
        try { & icacls.exe $dir /inheritance:r /grant:r ("{0}:(OI)(CI)F" -f $env:USERNAME) 2>&1 | Out-Null } catch { }
    }
}

function Read-CclKeyFromPrompt {
    $secure = Read-Host -AsSecureString 'InferHub API key (typing is hidden)'
    return [Net.NetworkCredential]::new('', $secure).Password
}

function Read-CclTinyFishKeyFromPrompt {
    Write-Information '' -InformationAction Continue
    Write-Information 'Web search works best with a TinyFish Search key. It is free, no card needed:' -InformationAction Continue
    Write-Information '  sign up at https://agent.tinyfish.ai/sign-up, then create a key at https://agent.tinyfish.ai/api-keys' -InformationAction Continue
    $secure = Read-Host -AsSecureString 'TinyFish API key (typing is hidden; press Enter to skip)'
    return [Net.NetworkCredential]::new('', $secure).Password
}

function Resolve-CclTinyFishKey {
    # -TinyFishKey, then CCL_TINYFISH_KEY, then TINYFISH_API_KEY, then the stored key, then
    # the prompt (not with -Skip or -NonInteractive). $null means skipped; never an error.
    param(
        [string]$Flag,
        [System.Collections.IDictionary]$Environment = @{},
        [string]$StoredPath,
        [scriptblock]$Prompt = { Read-CclTinyFishKeyFromPrompt },
        [switch]$NonInteractive,
        [switch]$Skip
    )
    if ($null -eq $Environment) { $Environment = @{} }
    $found = $null
    foreach ($c in @($Flag, $Environment['CCL_TINYFISH_KEY'], $Environment['TINYFISH_API_KEY'])) {
        if (-not [string]::IsNullOrWhiteSpace([string]$c)) { $found = [string]$c; break }
    }
    if ($null -eq $found) {
        $stored = Read-CclSecret -Path $StoredPath -Name 'TINYFISH_API_KEY'
        if (-not [string]::IsNullOrWhiteSpace($stored)) { $found = $stored }
    }
    if ($null -eq $found) {
        if ($NonInteractive -or $Skip) { return $null }
        $found = [string](& $Prompt)
        if ([string]::IsNullOrWhiteSpace($found)) { return $null }
    }
    if (-not (Test-CclKeyShape -Key $found)) {
        throw 'CCL_BAD_KEY: that TinyFish key has a line break, quote or NUL in it, or is too long.'
    }
    return $found.Trim()
}

function Write-CclNoTinyFishWarning {
    Write-CclLog ('No TinyFish key, so web search uses only DuckDuckGo and You.com, which can be unreliable. ' +
        'Get a free key at https://agent.tinyfish.ai/api-keys and add it with: claude-inferhub --set-tinyfish-key') 'warn'
}

function Resolve-CclInferHubKey {
    # -InferHubKey, then CCL_INFERHUB_KEY, then INFERHUB_API_KEY, then the stored key,
    # then the prompt. Errors never contain the key.
    param(
        [string]$Flag,
        [System.Collections.IDictionary]$Environment = @{},
        [string]$StoredPath,
        [scriptblock]$Prompt = { Read-CclKeyFromPrompt },
        [switch]$NonInteractive
    )
    if ($null -eq $Environment) { $Environment = @{} }
    $found = $null
    foreach ($c in @($Flag, $Environment['CCL_INFERHUB_KEY'], $Environment['INFERHUB_API_KEY'])) {
        if (-not [string]::IsNullOrWhiteSpace([string]$c)) { $found = [string]$c; break }
    }
    if ($null -eq $found) {
        $stored = Read-CclSecret -Path $StoredPath
        if (-not [string]::IsNullOrWhiteSpace($stored)) { $found = $stored }
    }
    if ($null -eq $found) {
        if ($NonInteractive) { throw 'CCL_NO_KEY: no InferHub key. Pass -InferHubKey or set CCL_INFERHUB_KEY.' }
        $found = [string](& $Prompt)
        if ([string]::IsNullOrWhiteSpace($found)) { throw 'CCL_NO_KEY: no InferHub key was entered.' }
    }
    if (-not (Test-CclKeyShape -Key $found)) {
        throw 'CCL_BAD_KEY: that InferHub key has a line break, quote or NUL in it, or is too long.'
    }
    return $found.Trim()
}

# ---------------------------------------------------------------- state

function New-CclInstanceId {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only returns a new random id; changes nothing.')]
    param()
    return [guid]::NewGuid().ToString('N')
}

function Read-CclInstallState {
    param([string]$InstallDir)
    $p = Join-Path $InstallDir 'install.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Write-CclInstallState {
    param([string]$InstallDir, [System.Collections.IDictionary]$State)
    $ref = $(if ($State.ref) { [string]$State.ref } else { $script:CclDefaultRef })
    $doc = [ordered]@{
        schema = $script:CclSchema
        version = $script:CclVersion
        ref = $ref
        port = [int]$State.port
        instance_id = [string]$State.instance_id
        task_name = $script:CclTaskName
        claude_settings_created = [bool]$State.claude_settings_created
    }
    Write-CclUtf8 -Path (Join-Path $InstallDir 'install.json') -Text (($doc | ConvertTo-Json) + "`n")
}

# ---------------------------------------------------------------- ports

function Get-CclIdentity {
    # GET /ccl/identity on loopback, no proxy, short timeout. $null when it doesn't answer JSON.
    param([int]$Port)
    try {
        $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/ccl/identity")
        $req.Proxy = $null
        $req.Timeout = 3000
        $req.ReadWriteTimeout = 3000
        $resp = $req.GetResponse()
        try {
            $reader = [IO.StreamReader]::new($resp.GetResponseStream())
            return ($reader.ReadToEnd() | ConvertFrom-Json)
        } finally { $resp.Close() }
    } catch { return $null }
}

function Test-CclPortListening {
    param([int]$Port)
    $c = [Net.Sockets.TcpClient]::new()
    try {
        $ar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(500)) { return $false }
        $c.EndConnect($ar)
        return $true
    } catch { return $false } finally { $c.Close() }
}

function Get-CclPortState {
    # free: nothing answers and 127.0.0.1:<port> can be bound. ours: /ccl/identity names
    # this install. foreign: anything else.
    param([int]$Port, [string]$InstanceId)
    if (-not (Test-CclPortListening -Port $Port)) {
        $l = $null
        try {
            $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
            $l.Start()
            return 'free'
        } catch { return 'foreign' } finally { if ($l) { $l.Stop() } }
    }
    $id = Get-CclIdentity -Port $Port
    if ($id -and $id.app -eq $script:CclApp -and [string]$id.instance -eq [string]$InstanceId -and $InstanceId) { return 'ours' }
    return 'foreign'
}

function Select-CclPort {
    # The saved port when it is free or ours, else the lowest free-or-ours port from
    # Start. Never a foreign port.
    param([int]$Start, [int]$Saved = 0, [scriptblock]$Probe, [int]$Count = 100)
    if ($Saved -gt 0) {
        $s = & $Probe $Saved
        if ($s -eq 'free' -or $s -eq 'ours') { return $Saved }
    }
    $end = [Math]::Min($Start + $Count - 1, 65535)
    for ($p = $Start; $p -le $end; $p++) {
        if ($p -eq $Saved) { continue }
        $s = & $Probe $p
        if ($s -eq 'free' -or $s -eq 'ours') { return $p }
    }
    throw "CCL_NO_PORT: no free port in $Start..$end"
}

# ---------------------------------------------------------------- shim and task

function Get-CclShimText {
    param([string]$InstallDir)
    $d = $InstallDir.TrimEnd('\', '/')
    $ps = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File'
    return @(
        '@echo off'
        'rem claude-inferhub: runs the claude-code-launcher install in this folder (made by install.ps1).'
        'setlocal'
        ('set "CCL_HOME=' + $d + '"')
        ('if /i "%~1"=="--set-key" ( ' + $ps + ' "%CCL_HOME%\app\windows\install.ps1" -InstallDir "%CCL_HOME%" -ChangeKey & exit /b )')
        ('if /i "%~1"=="--set-tinyfish-key" ( ' + $ps + ' "%CCL_HOME%\app\windows\install.ps1" -InstallDir "%CCL_HOME%" -ChangeTinyFishKey & exit /b )')
        ('if /i "%~1"=="--uninstall" ( ' + $ps + ' "%CCL_HOME%\app\windows\install.ps1" -InstallDir "%CCL_HOME%" -Uninstall & exit /b )')
        ($ps + ' "%CCL_HOME%\app\windows\launch-claude-inferhub.ps1" %* & exit /b')
    ) -join "`r`n"
}

function Get-CclTaskArguments {
    param([string]$InstallDir, [int]$Port)
    $d = $InstallDir.TrimEnd('\', '/')
    return ('--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
        $d + '\app\windows\litellm\start-litellm.ps1" -CclHome "' + $d + '" -Port ' + $Port)
}

function Register-CclProxyTask {
    param([string]$InstallDir, [int]$Port)
    if (-not $script:CclOnWindows) { return $false }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" -Argument (Get-CclTaskArguments -InstallDir $InstallDir -Port $Port)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $script:CclTaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description "LiteLLM proxy for claude-inferhub on 127.0.0.1:$Port" -Force | Out-Null
    return $true
}

function Test-CclTaskRegistered {
    if (-not $script:CclOnWindows) { return $false }
    return [bool](Get-ScheduledTask -TaskName $script:CclTaskName -ErrorAction SilentlyContinue)
}

function Stop-CclProxy {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal helper of a non-interactive installer; -WhatIf is not offered.')]
    # Stops only our proxy: the task, then the PID in logs\litellm.pid (with its children).
    # Never kills by port.
    param([string]$InstallDir)
    if (Test-CclTaskRegistered) { Stop-ScheduledTask -TaskName $script:CclTaskName -ErrorAction SilentlyContinue }
    $pidFile = Join-Path $InstallDir 'logs\litellm.pid'
    if (-not (Test-Path -LiteralPath $pidFile)) { $pidFile = Join-Path $InstallDir 'logs/litellm.pid' }
    if (Test-Path -LiteralPath $pidFile) {
        $procId = 0
        if ([int]::TryParse(((Get-Content -LiteralPath $pidFile -TotalCount 1) -as [string]).Trim(), [ref]$procId) -and $procId -gt 0) {
            if ($script:CclOnWindows) { & taskkill.exe /PID $procId /T /F 2>&1 | Out-Null }
            else { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
        }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
}

function Start-CclProxy {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal helper of a non-interactive installer; -WhatIf is not offered.')]
    # Starts the proxy (the task when there is one, else a hidden direct start) and waits
    # until the port answers as ours. Returns $true when it does.
    param([string]$InstallDir, [int]$Port, [string]$InstanceId, [int]$TimeoutSec = 300)
    if ((Get-CclPortState -Port $Port -InstanceId $InstanceId) -eq 'ours') { return $true }
    $starter = Join-Path $InstallDir 'app\windows\litellm\start-litellm.ps1'
    $direct = $false
    if (Test-CclTaskRegistered) {
        Start-ScheduledTask -TaskName $script:CclTaskName
    } else {
        $direct = $true
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $fallbackAt = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        if ($direct) {
            $direct = $false
            $fallbackAt = $deadline
            Write-CclLog 'Starting the proxy directly (hidden).'
            $argList = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $starter + '" -CclHome "' + $InstallDir + '" -Port ' + $Port + ' -Background'
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden | Out-Null
        }
        Start-Sleep -Seconds 2
        $st = Get-CclPortState -Port $Port -InstanceId $InstanceId
        if ($st -eq 'ours') { return $true }
        if ((Get-Date) -gt $fallbackAt -and $st -eq 'free') {
            Write-CclLog 'The logon task did not bring the proxy up; falling back to a direct start.' 'warn'
            $direct = $true
        }
    }
    return $false
}

# ---------------------------------------------------------------- PATH

function Add-CclUserPath {
    param([string]$Dir)
    if (-not $script:CclOnWindows) { return }
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @(($cur -split ';') | Where-Object { $_ })
    if ($parts -notcontains $Dir) {
        [Environment]::SetEnvironmentVariable('Path', (@($parts) + $Dir) -join ';', 'User')
    }
    if ((($env:Path -split ';') -notcontains $Dir)) { $env:Path = $env:Path + ';' + $Dir }
}

function Remove-CclUserPath {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal helper of a non-interactive installer; -WhatIf is not offered.')]
    param([string]$Dir)
    if (-not $script:CclOnWindows) { return }
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $cur) { return }
    $parts = @(($cur -split ';') | Where-Object { $_ -and ($_.TrimEnd('\') -ne $Dir.TrimEnd('\')) })
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
}

function Update-CclSessionPath {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal helper of a non-interactive installer; -WhatIf is not offered.')]
    param()
    if (-not $script:CclOnWindows) { return }
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $extra = @((Join-Path $env:USERPROFILE '.local\bin'), (Join-Path $env:LOCALAPPDATA 'pnpm'))
    # Keep what this session already had (a tool the caller put on PATH) and add what
    # the installers just wrote to the registry, without duplicates.
    $seen = @{}
    $parts = foreach ($p in (@($env:Path, $m, $u) -join ';').Split(';') + $extra) {
        if ($p -and -not $seen.ContainsKey($p.TrimEnd('\').ToLowerInvariant())) { $seen[$p.TrimEnd('\').ToLowerInvariant()] = $true; $p }
    }
    $env:Path = @($parts) -join ';'
}

# ---------------------------------------------------------------- prerequisites

function Get-CclPrereqPlan {
    param([System.Collections.IDictionary]$Have)
    return @(foreach ($t in 'uv', 'git', 'node', 'pnpm', 'claude') { if (-not $Have[$t]) { $t } })
}

function Test-CclTool { param([string]$Name) return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Invoke-CclDownloadedScript {
    # Official installers are downloaded to a temp file and run with powershell -File.
    param([string]$Url, [string]$What)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ccl-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $tmp
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp
        if ($LASTEXITCODE -ne 0) { throw "$What installer exited $LASTEXITCODE" }
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Invoke-CclWinget {
    param([string]$Id)
    if (-not (Test-CclTool 'winget')) { throw "winget is not available to install $Id" }
    & winget install --id $Id -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) { throw "winget install $Id exited $LASTEXITCODE" }
}

function Install-CclPrereq {
    param([string]$Name)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        switch ($Name) {
            'uv' { Invoke-CclDownloadedScript -Url 'https://astral.sh/uv/install.ps1' -What 'uv' }
            'git' { Invoke-CclWinget -Id 'Git.Git' }
            'node' { Invoke-CclWinget -Id 'OpenJS.NodeJS.LTS' }
            'pnpm' {
                $done = $false
                if (Test-CclTool 'corepack') { & corepack enable pnpm 2>&1 | Out-Null; Update-CclSessionPath; $done = Test-CclTool 'pnpm' }
                if (-not $done) { Invoke-CclDownloadedScript -Url 'https://get.pnpm.io/install.ps1' -What 'pnpm' }
            }
            'claude' { Invoke-CclDownloadedScript -Url 'https://claude.ai/install.ps1' -What 'Claude Code' }
        }
    } finally { $ErrorActionPreference = $prev }
    Update-CclSessionPath
}

function Install-CclPrereqs {
    # Returns the tools still missing afterwards.
    param([switch]$CheckOnly)
    Update-CclSessionPath
    $have = @{}
    foreach ($t in 'uv', 'git', 'node', 'pnpm', 'claude') { $have[$t] = Test-CclTool $t }
    $plan = @(Get-CclPrereqPlan -Have $have)
    if ($plan.Count -eq 0) { Write-CclLog 'uv, git, Node, pnpm and Claude Code are all here.'; return @() }
    if ($CheckOnly) {
        Write-CclLog ('Missing (not installing, -SkipPrereqs): ' + ($plan -join ', ')) 'warn'
        return @()
    }
    foreach ($t in $plan) {
        Write-CclLog "Installing $t ..."
        try { Install-CclPrereq -Name $t } catch { Write-CclLog ("$t install failed: " + $_.Exception.Message) 'warn' }
    }
    return @(foreach ($t in $plan) { if (-not (Test-CclTool $t)) { $t } })
}

# ---------------------------------------------------------------- launcher files

function Copy-CclTree {
    param([string]$From, [string]$To, [int]$Depth = 0)
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $From -Force) {
        $n = $item.Name
        if ($script:CclSkipAnywhere -contains $n) { continue }
        if ($Depth -eq 0 -and $script:CclSkipTop -contains $n) { continue }
        if (-not $item.PSIsContainer -and ($n -eq '.env' -or ($n -like '.env.*' -and $n -ne '.env.example') -or $n -like '*.key' -or $n -like '*.pem' -or $n -like '*.pyc')) { continue }
        $dest = Join-Path $To $n
        if ($item.PSIsContainer) { Copy-CclTree -From $item.FullName -To $dest -Depth ($Depth + 1) }
        else { Copy-Item -LiteralPath $item.FullName -Destination $dest -Force }
    }
}

function Get-CclSourceTree {
    # Returns a folder holding the launcher files for -Ref (and a temp folder to clean up).
    param([string]$Source, [string]$Ref)
    if ($Source) {
        if (-not (Test-Path -LiteralPath (Join-Path $Source 'windows/launch-claude-inferhub.ps1'))) { throw "no launcher files in $Source" }
        return @{ Path = (Resolve-Path -LiteralPath $Source).Path; Temp = $null }
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ccl-src-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $errors = @()
    # 1. Public tarball.
    try {
        $tgz = Join-Path $tmp 'src.tar.gz'
        Invoke-WebRequest -UseBasicParsing -Uri ("https://codeload.github.com/$($script:CclRepo)/tar.gz/$Ref") -OutFile $tgz
        $x = Join-Path $tmp 'x'
        New-Item -ItemType Directory -Force -Path $x | Out-Null
        & tar.exe -xzf $tgz -C $x
        if ($LASTEXITCODE -ne 0) { & tar -xzf $tgz -C $x }
        $top = Get-ChildItem -LiteralPath $x -Directory | Select-Object -First 1
        if ($top -and (Test-Path -LiteralPath (Join-Path $top.FullName 'windows/launch-claude-inferhub.ps1'))) { return @{ Path = $top.FullName; Temp = $tmp } }
        $errors += 'tarball had no launcher files'
    } catch { $errors += ('tarball: ' + $_.Exception.Message) }
    # 2. gh, when it is logged in (private repo access).
    if (Test-CclTool 'gh') {
        $dst = Join-Path $tmp 'gh'
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & gh repo clone $script:CclRepo $dst -- --depth 1 --branch $Ref --quiet 2>&1 | Out-Null
        $ErrorActionPreference = $prev
        if (Test-Path -LiteralPath (Join-Path $dst 'windows/launch-claude-inferhub.ps1')) { return @{ Path = $dst; Temp = $tmp } }
        $errors += 'gh repo clone failed'
    }
    # 3. git.
    if (Test-CclTool 'git') {
        $dst = Join-Path $tmp 'git'
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & git clone --quiet --depth 1 --branch $Ref ("https://github.com/$($script:CclRepo).git") $dst 2>&1 | Out-Null
        $ErrorActionPreference = $prev
        if (Test-Path -LiteralPath (Join-Path $dst 'windows/launch-claude-inferhub.ps1')) { return @{ Path = $dst; Temp = $tmp } }
        $errors += 'git clone failed'
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    throw ('could not fetch the launcher files for ' + $Ref + ': ' + ($errors -join '; '))
}

function Install-CclAppFiles {
    param([string]$InstallDir, [string]$Source, [string]$Ref)
    $src = Get-CclSourceTree -Source $Source -Ref $Ref
    try {
        $stage = Join-Path $InstallDir 'app.new'
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        Copy-CclTree -From $src.Path -To $stage
        $app = Join-Path $InstallDir 'app'
        if (Test-Path -LiteralPath $app) { Remove-Item -LiteralPath $app -Recurse -Force }
        Move-Item -LiteralPath $stage -Destination $app
    } finally {
        if ($src.Temp) { Remove-Item -LiteralPath $src.Temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------- Python helpers

function Get-CclVenvPython {
    param([string]$InstallDir)
    foreach ($rel in 'venv\Scripts\python.exe', 'venv/bin/python') {
        $p = Join-Path $InstallDir $rel
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-CclPython {
    # @{ Exe; Args } for running the standard-library helpers: the venv, then a working
    # python on PATH, then uv's managed Python.
    param([string]$InstallDir)
    $v = Get-CclVenvPython -InstallDir $InstallDir
    if ($v) { return @{ Exe = $v; Args = @() } }
    foreach ($n in 'python3', 'python') {
        $c = Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) {
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            & $c.Source -c 'import sys' 2>&1 | Out-Null
            $ok = ($LASTEXITCODE -eq 0)
            $ErrorActionPreference = $prev
            if ($ok) { return @{ Exe = $c.Source; Args = @() } }
        }
    }
    $uv = Get-Command uv -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($uv) { return @{ Exe = $uv.Source; Args = @('run', '--no-project', '--python', '3.12', 'python') } }
    return $null
}

function Invoke-CclHelper {
    # Runs a helper script; its output goes to the log, never to stdout. Returns the exit code.
    param([string]$InstallDir, [string]$Script, [string[]]$HelperArgs)
    $py = Get-CclPython -InstallDir $InstallDir
    if (-not $py) { Write-CclLog "No Python found to run $(Split-Path -Leaf $Script)" 'warn'; return 1 }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & $py.Exe @($py.Args) $Script @HelperArgs 2>&1
        $rc = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    foreach ($line in @($out)) { if ("$line".Trim()) { Write-CclLog ("  " + "$line".Trim()) } }
    return $rc
}

function Get-CclClaudeDir {
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return (Join-Path $HOME '.claude')
}

function Build-CclVenv {
    param([string]$InstallDir)
    $uv = Get-Command uv -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $uv) { throw 'uv is not installed' }
    $venv = Join-Path $InstallDir 'venv'
    $req = Join-Path $InstallDir 'app\shared\litellm\requirements.txt'
    $ovr = Join-Path $InstallDir 'app\shared\litellm\requirements-overrides.txt'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        if (-not (Get-CclVenvPython -InstallDir $InstallDir)) {
            Write-CclLog 'Creating the LiteLLM venv (Python 3.12) ...'
            & $uv.Source venv --python 3.12 --quiet $venv 2>&1 | ForEach-Object { Write-CclLog ("  " + $_) }
            if ($LASTEXITCODE -ne 0) { throw "uv venv exited $LASTEXITCODE" }
        }
        $py = Get-CclVenvPython -InstallDir $InstallDir
        Write-CclLog 'Installing the pinned LiteLLM (this takes a minute the first time) ...'
        & $uv.Source pip install --quiet --python $py -r $req --override $ovr 2>&1 | ForEach-Object { Write-CclLog ("  " + $_) }
        if ($LASTEXITCODE -ne 0) { throw "uv pip install exited $LASTEXITCODE" }
    } finally { $ErrorActionPreference = $prev }
}

# ---------------------------------------------------------------- flows

function Resolve-CclInstallDir {
    param([string]$InstallDir)
    if ($InstallDir) { return [IO.Path]::GetFullPath($InstallDir) }
    if ($env:CCL_INSTALL_DIR) { return [IO.Path]::GetFullPath($env:CCL_INSTALL_DIR) }
    $base = $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData/Local' })
    return (Join-Path $base 'claude-code-launcher')
}

function Get-CclKeyErrorCode {
    param($ErrorRecord)
    $m = $ErrorRecord.Exception.Message
    if ($m -like 'CCL_NO_KEY*') { return 4 }
    if ($m -like 'CCL_BAD_KEY*') { return 2 }
    return 2
}

function Invoke-CclUninstall {
    param([string]$InstallDir)
    $InstallDir = Resolve-CclInstallDir -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $InstallDir)) { Write-CclLog "Nothing installed at $InstallDir."; return 0 }
    $state = Read-CclInstallState -InstallDir $InstallDir
    if (-not $state -and @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) {
        Write-CclLog "$InstallDir has no install.json; not deleting a folder this installer didn't make." 'warn'
        return 2
    }
    Write-CclLog "Removing claude-inferhub from $InstallDir ..."
    Stop-CclProxy -InstallDir $InstallDir
    if (Test-CclTaskRegistered) { Unregister-ScheduledTask -TaskName $script:CclTaskName -Confirm:$false -ErrorAction SilentlyContinue }
    $app = Join-Path $InstallDir 'app'
    $claudeDir = Get-CclClaudeDir
    $settings = Join-Path $claudeDir 'settings.json'
    if (Test-Path -LiteralPath (Join-Path $app 'shared/claude/settings_sync.py')) {
        if (Test-Path -LiteralPath $settings) {
            $null = Invoke-CclHelper -InstallDir $InstallDir -Script (Join-Path $app 'shared/claude/settings_sync.py') -HelperArgs @('unsync', '--settings', $settings)
            if ($state -and $state.claude_settings_created) {
                try {
                    $doc = Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
                    if (@($doc.PSObject.Properties).Count -eq 0) { Remove-Item -LiteralPath $settings -Force }
                } catch { }
            }
        }
        $null = Invoke-CclHelper -InstallDir $InstallDir -Script (Join-Path $app 'shared/claude/install_planner.py') -HelperArgs @('uninstall', '--quiet')
    }
    Remove-CclUserPath -Dir (Join-Path $InstallDir 'bin')
    $script:CclLogFile = $null
    if ((Get-Location).Path -like ($InstallDir + '*')) { Set-Location -LiteralPath ([IO.Path]::GetTempPath()) }
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-CclLog 'Done. uv, git, Node, pnpm and Claude Code are still installed.'
    return 0
}

function Invoke-CclChangeKey {
    param([string]$InstallDir, [string]$InferHubKey, [System.Collections.IDictionary]$Environment, [scriptblock]$KeyPrompt, [switch]$NonInteractive)
    $state = Read-CclInstallState -InstallDir $InstallDir
    if (-not $state) { Write-CclLog "No install at $InstallDir; run the installer first." 'warn'; return 2 }
    try {
        $key = Resolve-CclInferHubKey -Flag $InferHubKey -Environment $Environment -StoredPath '' -Prompt $KeyPrompt -NonInteractive:$NonInteractive
    } catch { Write-CclLog $_.Exception.Message 'warn'; return (Get-CclKeyErrorCode $_) }
    Write-CclSecret -Path (Join-Path $InstallDir 'secrets\inferhub.env') -Key $key
    Write-CclLog 'Saved the new InferHub key.'
    Restart-CclProxyIfOurs -InstallDir $InstallDir -State $state
    return 0
}

function Restart-CclProxyIfOurs {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal helper of a non-interactive installer; -WhatIf is not offered.')]
    param([string]$InstallDir, $State)
    if ((Get-CclPortState -Port ([int]$State.port) -InstanceId $State.instance_id) -eq 'ours') {
        Write-CclLog 'Restarting the proxy so it picks the new key up ...'
        Stop-CclProxy -InstallDir $InstallDir
        Start-Sleep -Seconds 2
        if (-not (Start-CclProxy -InstallDir $InstallDir -Port ([int]$State.port) -InstanceId $State.instance_id)) {
            Write-CclLog "The proxy didn't come back; claude-inferhub will start it." 'warn'
        }
    }
}

function Invoke-CclChangeTinyFishKey {
    # Replace the stored TinyFish key; an empty answer removes it. The stored key is not
    # offered back, so the prompt always asks.
    param([string]$InstallDir, [string]$TinyFishKey, [System.Collections.IDictionary]$Environment, [scriptblock]$TinyFishPrompt, [switch]$NonInteractive)
    $state = Read-CclInstallState -InstallDir $InstallDir
    if (-not $state) { Write-CclLog "No install at $InstallDir; run the installer first." 'warn'; return 2 }
    try {
        $key = Resolve-CclTinyFishKey -Flag $TinyFishKey -Environment $Environment -StoredPath '' -Prompt $TinyFishPrompt -NonInteractive:$NonInteractive
    } catch { Write-CclLog $_.Exception.Message 'warn'; return 2 }
    $path = Join-Path $InstallDir 'secrets\tinyfish.env'
    if ($key) {
        Write-CclSecret -Path $path -Key $key -Name 'TINYFISH_API_KEY'
        Write-CclLog 'Saved the new TinyFish key.'
    } elseif ($NonInteractive) {
        Write-CclLog 'No TinyFish key given; the stored one (if any) is unchanged.' 'warn'
        return 4
    } else {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; Write-CclLog 'Removed the TinyFish key.' }
        Write-CclNoTinyFishWarning
    }
    Restart-CclProxyIfOurs -InstallDir $InstallDir -State $state
    return 0
}

function Invoke-CclInstall {
    param(
        [string]$InferHubKey = '',
        [string]$InstallDir = '',
        [string]$Ref = $script:CclDefaultRef,
        [string]$Source = '',
        [int]$StartPort = 4000,
        [switch]$Uninstall,
        [switch]$ChangeKey,
        [string]$TinyFishKey = '',
        [switch]$SkipTinyFish,
        [switch]$ChangeTinyFishKey,
        [switch]$SkipPrereqs,
        [switch]$SkipVenv,
        [switch]$NoTask,
        [switch]$NoPath,
        [switch]$NoStart,
        [switch]$NonInteractive,
        [System.Collections.IDictionary]$Environment = $null,
        [scriptblock]$KeyPrompt = { Read-CclKeyFromPrompt },
        [scriptblock]$TinyFishPrompt = { Read-CclTinyFishKeyFromPrompt }
    )
    if ($null -eq $Environment) {
        $Environment = @{
            CCL_INFERHUB_KEY = $env:CCL_INFERHUB_KEY; INFERHUB_API_KEY = $env:INFERHUB_API_KEY
            CCL_TINYFISH_KEY = $env:CCL_TINYFISH_KEY; TINYFISH_API_KEY = $env:TINYFISH_API_KEY
        }
    }
    $InstallDir = Resolve-CclInstallDir -InstallDir $InstallDir
    $script:CclLogFile = $null
    if ($Uninstall) { return (Invoke-CclUninstall -InstallDir $InstallDir) }
    if ($ChangeKey) {
        return (Invoke-CclChangeKey -InstallDir $InstallDir -InferHubKey $InferHubKey -Environment $Environment -KeyPrompt $KeyPrompt -NonInteractive:$NonInteractive)
    }
    if ($ChangeTinyFishKey) {
        return (Invoke-CclChangeTinyFishKey -InstallDir $InstallDir -TinyFishKey $TinyFishKey -Environment $Environment -TinyFishPrompt $TinyFishPrompt -NonInteractive:$NonInteractive)
    }
    if ($StartPort -lt 1024 -or $StartPort -gt 65000) { Write-CclLog 'StartPort must be between 1024 and 65000.' 'warn'; return 2 }

    # 1. The keys, before anything changes on disk.
    $secretPath = Join-Path $InstallDir 'secrets\inferhub.env'
    $tinyFishPath = Join-Path $InstallDir 'secrets\tinyfish.env'
    try {
        $key = Resolve-CclInferHubKey -Flag $InferHubKey -Environment $Environment -StoredPath $secretPath -Prompt $KeyPrompt -NonInteractive:$NonInteractive
        $tinyFish = Resolve-CclTinyFishKey -Flag $TinyFishKey -Environment $Environment -StoredPath $tinyFishPath -Prompt $TinyFishPrompt -NonInteractive:$NonInteractive -Skip:$SkipTinyFish
    } catch { Write-CclLog $_.Exception.Message 'warn'; return (Get-CclKeyErrorCode $_) }

    # 2. Prerequisites.
    $missing = @(Install-CclPrereqs -CheckOnly:$SkipPrereqs)
    if ($missing.Count -gt 0) {
        Write-CclLog ('Could not install: ' + ($missing -join ', ') + '. Install them by hand and run this again.') 'warn'
        return 3
    }

    # 3. Launcher files, then the key.
    foreach ($d in 'state', 'logs', 'bin', 'secrets') { New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir $d) | Out-Null }
    $script:CclLogFile = Join-Path $InstallDir 'logs/install.log'
    Write-CclLog "Installing claude-inferhub $($script:CclVersion) into $InstallDir"
    try { Install-CclAppFiles -InstallDir $InstallDir -Source $Source -Ref $Ref }
    catch { Write-CclLog $_.Exception.Message 'warn'; return 5 }
    Write-CclSecret -Path $secretPath -Key $key
    Write-CclLog 'InferHub key saved for this user.'
    if ($tinyFish) {
        Write-CclSecret -Path $tinyFishPath -Key $tinyFish -Name 'TINYFISH_API_KEY'
        Write-CclLog 'TinyFish key saved for this user.'
    } else {
        Write-CclNoTinyFishWarning
    }

    # 4. The LiteLLM venv.
    if (-not $SkipVenv) {
        try { Build-CclVenv -InstallDir $InstallDir } catch { Write-CclLog ('Building the venv failed: ' + $_.Exception.Message) 'warn'; return 6 }
    }

    # 5. Port and install.json.
    $old = Read-CclInstallState -InstallDir $InstallDir
    $instance = $(if ($old -and $old.instance_id -match '^[0-9a-f]{32}$') { [string]$old.instance_id } else { New-CclInstanceId })
    $saved = $(if ($old -and $old.port) { [int]$old.port } else { 0 })
    $probe = { param($p) Get-CclPortState -Port $p -InstanceId $instance }   # $instance: dynamic scope
    $port = Select-CclPort -Start $StartPort -Saved $saved -Probe $probe
    if ($saved -and $port -ne $saved) { Write-CclLog "Port $saved is taken by another program; using $port." }
    $settingsPath = Join-Path (Get-CclClaudeDir) 'settings.json'
    $created = $(if ($old) { [bool]$old.claude_settings_created } else { -not (Test-Path -LiteralPath $settingsPath) })
    Write-CclInstallState -InstallDir $InstallDir -State @{ ref = $Ref; port = $port; instance_id = $instance; claude_settings_created = $created }
    Write-CclLog "Proxy port: $port"

    # 6. The claude-inferhub command.
    $bin = Join-Path $InstallDir 'bin'
    Write-CclUtf8 -Path (Join-Path $bin 'claude-inferhub.cmd') -Text ((Get-CclShimText -InstallDir $InstallDir) + "`r`n")
    if (-not $NoPath) { Add-CclUserPath -Dir $bin }

    # 7. Claude Code settings and the planner sub-agent.
    $app = Join-Path $InstallDir 'app'
    $rc = Invoke-CclHelper -InstallDir $InstallDir -Script (Join-Path $app 'shared/claude/settings_sync.py') -HelperArgs @('sync', '--settings', $settingsPath)
    if ($rc -ne 0) { Write-CclLog 'Could not update Claude Code settings.json (left as it was).' 'warn' }
    $null = Invoke-CclHelper -InstallDir $InstallDir -Script (Join-Path $app 'shared/claude/install_planner.py') -HelperArgs @('install', '--quiet')
    # settings_sync.py also gave Claude Code 120 s for ripgrep (issue #69); check its search works.
    if (-not $SkipPrereqs) { $null = Test-CclClaudeSearch }

    # 8. Logon task and the proxy.
    if (-not $NoTask) {
        if (Register-CclProxyTask -InstallDir $InstallDir -Port $port) { Write-CclLog "Registered the hidden logon task '$($script:CclTaskName)'." }
    }
    if (-not $NoStart) {
        Stop-CclProxy -InstallDir $InstallDir
        if (Start-CclProxy -InstallDir $InstallDir -Port $port -InstanceId $instance) { Write-CclLog "The proxy is up on 127.0.0.1:$port." }
        else { Write-CclLog "The proxy didn't answer yet; claude-inferhub will start it. Logs: $InstallDir\logs" 'warn' }
    }
    Write-CclLog 'All set. Open a new terminal and run: claude-inferhub'
    return 0
}

function Test-CclClaudeSearch {
    # True when `claude doctor` reports "Search: OK", Claude Code's check of its ripgrep
    # (issue #69). Otherwise warns with the line it printed and returns $false. Never throws.
    [CmdletBinding()]
    param([string]$Claude = 'claude')
    $out = ''
    try { $out = (& $Claude doctor 2>&1 | Out-String) } catch { $out = '' }
    if ($out -match '(?m)^\s*Search:\s*OK\b') { return $true }
    $line = ([regex]::Match($out, '(?m)^\s*Search:.*$')).Value.Trim()
    $detail = $(if ($line) { " ($line)" } else { ' (no Search line; is Claude Code installed?)' })
    Write-CclLog ("Claude Code's search check did not pass" + $detail + ". Grep and Glob need it; run 'claude doctor' to see why.") 'warn'
    return $false
}

# ---------------------------------------------------------------- main

if ($env:CCL_INSTALL_LIBRARY_ONLY -eq '1') { return }
$cclArgs = @{
    InferHubKey = $InferHubKey; InstallDir = $InstallDir; Ref = $Ref; Source = $Source; StartPort = $StartPort
    Uninstall = $Uninstall; ChangeKey = $ChangeKey; TinyFishKey = $TinyFishKey; SkipTinyFish = $SkipTinyFish
    ChangeTinyFishKey = $ChangeTinyFishKey; SkipPrereqs = $SkipPrereqs; SkipVenv = $SkipVenv; NoTask = $NoTask
    NoPath = $NoPath; NoStart = $NoStart; NonInteractive = $NonInteractive
}
$cclCode = Invoke-CclInstall @cclArgs
if ($PSCommandPath) { exit $cclCode }
if ($cclCode -ne 0) { Write-Error "claude-inferhub install stopped (code $cclCode)." -ErrorAction Continue }
