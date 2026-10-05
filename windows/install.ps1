# claude-code-launcher: one-command Windows installer (issue #61).
#
# Sets up Claude Code with InferHub models through a local LiteLLM proxy. You need an
# InferHub API key, and a free TinyFish Search key is recommended for web search
# (https://agent.tinyfish.ai/api-keys). Run it in PowerShell:
#
#   irm https://github.com/Pukujan/claude-code-launcher/releases/latest/download/install.ps1 | iex
#
# or, to pass options, download it first and run
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 [-InferHubKey <key>] [-TinyFishKey <key>] [-Uninstall] ...
#
# What it does: asks for ONE install folder (default %USERPROFILE%\claude-code-launcher)
# and puts everything in it: the launcher files for its own version, the keys, the
# LiteLLM venv, logs, Claude Code's config for launcher sessions (CLAUDE_CONFIG_DIR),
# and private copies of the tools the PC doesn't already have (uv, Python, Node, pnpm;
# git and Claude Code always, unless -UseSystemTools). Every download is checked against
# a pinned SHA-256; no winget, no global installers. It picks a free port from 4000 up
# (it never takes a port another program holds), runs the proxy from a hidden logon
# task and leaves a `claude-inferhub` command. Outside the folder it only writes the
# logon task and (unless -NoPath) the bin\ entry in the user PATH.
# The spec is docs/specs/windows-package.md in the repository.
#
# The keys are never printed or logged. Tools that were already on the PC are never removed.

[CmdletBinding()]
param(
    [string]$InferHubKey = '',
    [string]$InstallDir = '',
    [string]$Ref = 'v1.0.1-windows',
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
    [switch]$PortableOnly,
    [switch]$UseSystemTools,
    [string]$ClaudeConfigDir = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:CclVersion = '1.0.1-windows'
$script:CclDefaultRef = $Ref
$script:CclRepo = 'Pukujan/claude-code-launcher'
$script:CclTaskName = 'claude-code-launcher-proxy'
$script:CclSchema = 'claude-code-launcher.install.v2'
$script:CclApp = 'claude-code-launcher'
$script:CclOnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or [bool]$IsWindows
$script:CclLogFile = $null
$script:CclPythonHint = $null
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
        claude_config_dir = $(if ($State.claude_config_dir) { [string]$State.claude_config_dir } else { '' })
        tools = $(if ($null -ne $State.tools) { $State.tools } else { [ordered]@{} })
    }
    Write-CclUtf8 -Path (Join-Path $InstallDir 'install.json') -Text (($doc | ConvertTo-Json -Depth 6) + "`n")
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
    # Ports are 1..65535; a saved port outside that is ignored.
    param([int]$Start, [int]$Saved = 0, [scriptblock]$Probe, [int]$Count = 100)
    if ($Start -lt 1 -or $Start -gt 65535) { throw "CCL_BAD_PORT: $Start is not a port (1..65535)" }
    if ($Saved -lt 1 -or $Saved -gt 65535) { $Saved = 0 }
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
    # Pure ASCII and no path inside: the shim finds its install from its own folder
    # (%~dp0 is bin\), so non-ASCII profile folders survive cmd.exe's OEM code page.
    # -InstallDir is accepted for old callers and ignored.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'InstallDir', Justification = 'Kept for callers; the shim no longer holds a path.')]
    param([string]$InstallDir)
    $ps = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File'
    return @(
        '@echo off'
        'rem claude-inferhub: runs the claude-code-launcher install in this folder (made by install.ps1).'
        'setlocal'
        'for %%I in ("%~dp0..") do set "CCL_HOME=%%~fI"'
        ('if /i "%~1"=="--set-key" ( ' + $ps + ' "%CCL_HOME%\app\windows\install.ps1" -InstallDir "%CCL_HOME%" -ChangeKey & exit /b )')
        ('if /i "%~1"=="--set-tinyfish-key" ( ' + $ps + ' "%CCL_HOME%\app\windows\install.ps1" -InstallDir "%CCL_HOME%" -ChangeTinyFishKey & exit /b )')
        # Uninstall deletes this file: "(goto) 2>nul" leaves the batch first, so cmd.exe never
        # goes back to read a file that is gone; the rest of the line still runs.
        ('if /i "%~1"=="--uninstall" ( (goto) 2>nul & ' + $ps + ' "%CCL_HOME%\app\windows\install.ps1" -InstallDir "%CCL_HOME%" -Uninstall )')
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

function Remove-CclTree {
    # Deletes a folder, retrying while files in it come and go (the proxy that was just stopped
    # can still remove its own PID file mid-walk). Throws when the folder is still there.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal helper of a non-interactive installer; -WhatIf is not offered.')]
    param([string]$Path, [int]$Tries = 5)
    for ($i = 1; $i -le $Tries; $i++) {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return }
        catch { if ($i -eq $Tries -and (Test-Path -LiteralPath $Path)) { throw } ; Start-Sleep -Milliseconds 500 }
    }
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

# ---------------------------------------------------------------- prerequisites

function Get-CclPrereqPlan {
    param([System.Collections.IDictionary]$Have)
    return @(foreach ($t in 'uv', 'git', 'node', 'pnpm', 'claude') { if (-not $Have[$t]) { $t } })
}

function Test-CclTool { param([string]$Name) return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# ---------------------------------------------------------------- self-contained tools (v1.0.1)
# Each tool is either reused from the PC (Python 3.10-3.13, Node 18+, any uv or pnpm; git
# and Claude Code only with -UseSystemTools) or a private copy under <InstallDir>\tools.
# Every download is pinned by SHA-256 (Claude Code: the SHA-256 in its release manifest).

$script:CclToolOrder = @('uv', 'python', 'node', 'pnpm', 'git', 'claude', 'poppler')
# Tools the install goes on without: a failure only warns (Claude Code's Read then can't
# render PDF pages, nothing else breaks).
$script:CclOptionalTools = @('poppler')
$script:CclToolSpecs = @{
    uv = @{ version = '0.12.23'; kind = 'zip'; exe = 'uv.exe'
        url = 'https://github.com/astral-sh/uv/releases/download/0.12.23/uv-x86_64-pc-windows-msvc.zip'
        sha256 = '75d05de6762778c31ee183398de7dd15093fad0ed90b1f236d8205ea5ec00c90' }
    node = @{ version = '24.21.0'; kind = 'zip'; exe = 'node.exe'; strip = 'node-v24.21.0-win-x64'
        url = 'https://nodejs.org/dist/v24.21.0/node-v24.21.0-win-x64.zip'
        sha256 = '158f7685b44de51f6c0df1d153526cbcd3e1bc739a8dfc607721cef75de9e541' }
    pnpm = @{ version = '12.9.1'; kind = 'zip'; exe = 'pnpm.exe'
        url = 'https://github.com/pnpm/pnpm/releases/download/v12.9.1/pnpm-win32-x64.zip'
        sha256 = '2b30f6bc53228187881aeae604cc6cedf092641df30d3be1cf4cd3d17bf630f5' }
    # PortableGit, not MinGit: Claude Code's Bash tool needs bash.exe, which MinGit leaves out.
    git = @{ version = '2.56.0'; kind = 'sfx'; exe = 'cmd\git.exe'; bash = 'bin\bash.exe'
        url = 'https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.1/PortableGit-2.56.0-64-bit.7z.exe'
        sha256 = 'eceb5e061aa90df2f69ddd3e90f0030e1b8037a7829934bc40e4be1caa1accc1' }
    claude = @{ version = 'stable'; kind = 'claude-manifest'; exe = 'claude.exe'
        url = 'https://downloads.claude.ai/claude-code-releases' }
    python = @{ version = '3.12'; kind = 'uv-python' }
    # pdftoppm for Claude Code's Read on PDF pages. The official Windows build of poppler.
    poppler = @{ version = '26.09.0-0'; kind = 'zip'; exe = 'Library\bin\pdftoppm.exe'; strip = 'poppler-26.09.0'
        url = 'https://github.com/oschwartz10612/poppler-windows/releases/download/v26.09.0-0/Release-26.09.0-0.zip'
        sha256 = '7a6f256a0ddf7536182246a5733331bf4677cbcc34f4663774947ad34556c8d0' }
}

function Test-CclPythonVersion {
    param([string]$Version)
    if ($Version -notmatch '(\d+)\.(\d+)') { return $false }
    return ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 10 -and [int]$Matches[2] -le 13)
}

function Test-CclNodeVersion {
    param([string]$Version)
    if ($Version -notmatch '^\s*v?(\d+)\.') { return $false }
    return ([int]$Matches[1] -ge 18)
}

function Get-CclToolPlan {
    # 'reuse' or 'bundle' per tool (spec: Self-contained install).
    param([System.Collections.IDictionary]$Found, [switch]$PortableOnly, [switch]$UseSystemTools)
    if ($null -eq $Found) { $Found = @{} }
    $plan = [ordered]@{}
    foreach ($n in 'python', 'node', 'uv', 'pnpm', 'git', 'claude', 'poppler') {
        $f = $Found[$n]
        $ok = [bool]($f -and $f.path)
        if ($ok -and $n -eq 'python') { $ok = Test-CclPythonVersion -Version ([string]$f.version) }
        if ($ok -and $n -eq 'node') { $ok = Test-CclNodeVersion -Version ([string]$f.version) }
        if ($ok -and ($n -eq 'git' -or $n -eq 'claude')) { $ok = [bool]$UseSystemTools }
        if ($PortableOnly) { $ok = $false }
        $plan[$n] = $(if ($ok) { 'reuse' } else { 'bundle' })
    }
    return $plan
}

function Get-CclToolEnv {
    # The variables that keep every tool's data in the folder (spec table). PATH is the
    # list of folders to put in front of the process PATH.
    param([string]$InstallDir, $State = $null, [string]$ClaudeConfigDir = '')
    $t = Join-Path $InstallDir 'tools'
    $c = Join-Path $InstallDir 'cache'
    $cfg = $(if ($ClaudeConfigDir) { $ClaudeConfigDir } elseif ($State -and $State.claude_config_dir) { [string]$State.claude_config_dir } else { Join-Path $InstallDir 'claude-config' })
    $e = [ordered]@{
        UV_CACHE_DIR = Join-Path $c 'uv'
        UV_PYTHON_INSTALL_DIR = Join-Path $t 'python'
        UV_PYTHON_BIN_DIR = Join-Path $t 'bin'
        UV_TOOL_BIN_DIR = Join-Path $t 'bin'
        UV_TOOL_DIR = Join-Path $t 'uv-tools'
        UV_INSTALL_DIR = Join-Path $t 'uv'
        PNPM_HOME = Join-Path $t 'pnpm'
        npm_config_store_dir = Join-Path $c 'pnpm-store'
        npm_config_cache_dir = Join-Path $c 'pnpm'
        npm_config_state_dir = Join-Path $c 'pnpm'
        npm_config_cache = Join-Path $c 'npm'
        CLAUDE_CONFIG_DIR = $cfg
        DISABLE_AUTOUPDATER = '1'
    }
    $tools = $(if ($State) { $State.tools } else { $null })
    if ($tools -and $tools.git -and $tools.git.source -eq 'bundled') {
        $e.CLAUDE_CODE_GIT_BASH_PATH = Join-Path (Join-Path (Join-Path $t 'git') 'bin') 'bash.exe'
    }
    $path = @((Join-Path $t 'claude'), (Join-Path $t 'node'), (Join-Path $t 'pnpm'), (Join-Path $t 'uv'),
        (Join-Path (Join-Path $t 'git') 'cmd'), (Join-Path $t 'bin'), (Join-Path (Join-Path (Join-Path $t 'poppler') 'Library') 'bin'))
    if ($tools) {
        foreach ($n in 'python', 'node', 'uv', 'pnpm', 'git', 'claude', 'poppler') {
            $rec = $tools.$n
            if ($rec -and $rec.path) {
                $d = Split-Path -Parent ([string]$rec.path)
                if ($d -and $path -notcontains $d) { $path += $d }
            }
        }
    }
    $e.PATH = $path
    return $e
}

function Use-CclToolEnv {
    # Sets the variables for this process and returns what was there before (for Restore-CclToolEnv).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Process environment only; restored by Restore-CclToolEnv.')]
    param([System.Collections.IDictionary]$Vars)
    $saved = @{}
    foreach ($k in $Vars.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        if ($k -eq 'PATH') {
            $front = @($Vars.PATH | Where-Object { $_ })
            $rest = @(([string]$saved[$k]).Split([IO.Path]::PathSeparator) | Where-Object { $_ -and $front -notcontains $_ })
            [Environment]::SetEnvironmentVariable('PATH', (($front + $rest) -join [IO.Path]::PathSeparator))
        } else {
            [Environment]::SetEnvironmentVariable($k, [string]$Vars[$k])
        }
    }
    return $saved
}

function Restore-CclToolEnv {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Process environment only.')]
    param([System.Collections.IDictionary]$Saved)
    if (-not $Saved) { return }
    foreach ($k in $Saved.Keys) { [Environment]::SetEnvironmentVariable($k, $Saved[$k]) }
}

function Invoke-CclToolOutput {
    # Runs a tool and returns its trimmed output lines, or $null when it can't run.
    param([string]$Exe, [string[]]$ToolArgs)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @ToolArgs 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    } catch { return $null } finally { $ErrorActionPreference = $prev }
}

function Find-CclSystemTools {
    # What the PC already has: @{ name = @{ path; version } } for the tools found.
    $found = @{}
    # No double quotes: Windows PowerShell 5.1 drops them from native arguments.
    $pyCode = 'import sys; print(sys.executable); print(''%d.%d.%d'' % sys.version_info[:3])'
    $candidates = @()
    if ($script:CclOnWindows -and (Test-CclTool 'py')) {
        foreach ($v in '3.13', '3.12', '3.11', '3.10') { $candidates += , @((Get-Command py).Source, "-$v") }
    }
    foreach ($n in 'python', 'python3') {
        foreach ($c in @(Get-Command $n -CommandType Application -ErrorAction SilentlyContinue)) {
            if ($c.Source -notlike '*\WindowsApps\*') { $candidates += , @($c.Source) }
        }
    }
    foreach ($cand in $candidates) {
        $exe = $cand[0]; $pre = @($cand | Select-Object -Skip 1)
        $out = @(Invoke-CclToolOutput -Exe $exe -ToolArgs ($pre + @('-c', $pyCode)))
        if ($out.Count -ge 2) {
            $rec = @{ path = $out[0]; version = $out[1] }
            if (Test-CclPythonVersion -Version $rec.version) { $found.python = $rec; break }
            if (-not $found.python) { $found.python = $rec }
        }
    }
    foreach ($n in 'node', 'uv', 'pnpm', 'git', 'claude') {
        $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $c) { continue }
        $out = @(Invoke-CclToolOutput -Exe $c.Source -ToolArgs @('--version'))
        if ($out.Count -gt 0) { $found[$n] = @{ path = $c.Source; version = ($out[0] -replace '^(uv|git version)\s+', '') } }
    }
    # pdftoppm prints its version to stderr; being on PATH and running is enough.
    $pp = Get-Command pdftoppm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pp) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $txt = (& $pp.Source -v 2>&1 | Out-String) } catch { $txt = '' } finally { $ErrorActionPreference = $prev }
        if ($txt -match 'pdftoppm version\s+(\S+)') { $found.poppler = @{ path = $pp.Source; version = $Matches[1] } }
    }
    return $found
}

function Save-CclDownload {
    # A URL (or, for tests, a local file) into OutFile.
    param([string]$Url, [string]$OutFile)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
    if ($Url -notmatch '^[a-z][a-z0-9+.-]*://') {
        if (-not (Test-Path -LiteralPath $Url)) { throw "missing download source $Url" }
        Copy-Item -LiteralPath $Url -Destination $OutFile -Force
        return
    }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile
}

function Expand-CclZip {
    param([string]$Zip, [string]$To)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $To)
}

function Install-CclPortableTool {
    # One private tool into <InstallDir>\tools\<Name>; returns @{ path; version }. A tool
    # already there for the same spec version is kept (no download). Nothing half-made is
    # left behind on failure.
    param([string]$InstallDir, [string]$Name, [System.Collections.IDictionary]$Spec)
    $tools = Join-Path $InstallDir 'tools'
    $dest = Join-Path $tools $Name
    $stampPath = Join-Path $dest '.ccl-tool.json'
    $exe = Join-Path $dest $Spec.exe
    if ((Test-Path -LiteralPath $stampPath) -and (Test-Path -LiteralPath $exe)) {
        try {
            $stamp = Get-Content -LiteralPath $stampPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$stamp.spec_version -eq [string]$Spec.version) { return @{ path = $exe; version = [string]$stamp.version } }
        } catch { }
    }
    $url = [string]$Spec.url; $sha = [string]$Spec.sha256; $kind = [string]$Spec.kind; $version = [string]$Spec.version
    if ($kind -eq 'claude-manifest') {
        $platform = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win32-arm64' } else { 'win32-x64' })
        $channel = $(if ($version -match '^\d') { $null } else { $version })
        $v = $(if ($channel) { ([string](Invoke-RestMethod -UseBasicParsing -Uri "$url/$channel")).Trim() } else { $version })
        if ($v -notmatch '^\d+\.\d+\.\d+') { throw "Claude Code: no version from $url/$channel" }
        $manifest = Invoke-RestMethod -UseBasicParsing -Uri "$url/$v/manifest.json"
        $sha = [string]$manifest.platforms.$platform.checksum
        if (-not $sha) { throw "Claude Code: no checksum for $platform in the $v manifest" }
        $url = "$url/$v/$platform/claude.exe"; $kind = 'file'; $version = $v
    }
    $dl = Join-Path (Join-Path (Join-Path $InstallDir 'cache') 'downloads') ($Name + '-' + [guid]::NewGuid().ToString('N') + '-' + (Split-Path -Leaf $url))
    $stage = $dest + '.new'
    try {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        Save-CclDownload -Url $url -OutFile $dl
        $got = (Get-FileHash -LiteralPath $dl -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($got -ne $sha.ToLowerInvariant()) { throw "$Name download failed its SHA-256 check" }
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        switch ($kind) {
            'zip' {
                Expand-CclZip -Zip $dl -To $stage
                if ($Spec.strip) {
                    $inner = Join-Path $stage $Spec.strip
                    $flat = $stage + '.flat'
                    Move-Item -LiteralPath $inner -Destination $flat
                    Remove-Item -LiteralPath $stage -Recurse -Force
                    Move-Item -LiteralPath $flat -Destination $stage
                }
            }
            'file' { Copy-Item -LiteralPath $dl -Destination (Join-Path $stage $Spec.exe) }
            'sfx' {
                $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                try { & $dl ('-o' + $stage) '-y' 2>&1 | Out-Null; $rc = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
                if ($rc -ne 0) { throw "$Name self-extractor exited $rc" }
            }
            default { throw "unknown tool kind $kind" }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $stage $Spec.exe))) { throw "$Name has no $($Spec.exe) after unpacking" }
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Move-Item -LiteralPath $stage -Destination $dest
        $stampText = ([ordered]@{ spec_version = [string]$Spec.version; version = $version; sha256 = $sha.ToLowerInvariant() } | ConvertTo-Json)
        Write-CclUtf8 -Path $stampPath -Text ($stampText + "`n")
        return @{ path = $exe; version = $version }
    } finally {
        Remove-Item -LiteralPath $dl -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Install-CclManagedPython {
    # uv-managed CPython in tools\python (UV_PYTHON_INSTALL_DIR is set by the caller).
    param([string]$Uv, [string]$Version)
    $prevPref = $env:UV_PYTHON_PREFERENCE
    $env:UV_PYTHON_PREFERENCE = 'only-managed'
    try {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            & $Uv python install $Version --quiet 2>&1 | ForEach-Object { Write-CclLog ('  ' + $_) }
            $rc = $LASTEXITCODE
        } finally { $ErrorActionPreference = $prev }
        if ($rc -ne 0) { throw "uv python install $Version exited $rc" }
        $out = @(Invoke-CclToolOutput -Exe $Uv -ToolArgs @('python', 'find', $Version))
        if ($out.Count -eq 0) { throw "uv python find $Version found nothing" }
        $py = $out[-1]
        if (-not (Test-Path -LiteralPath $py)) { throw "uv python find returned $py, which doesn't exist" }
        return @{ path = $py; version = $Version }
    } finally {
        if ($null -eq $prevPref) { Remove-Item Env:UV_PYTHON_PREFERENCE -ErrorAction SilentlyContinue } else { $env:UV_PYTHON_PREFERENCE = $prevPref }
    }
}

function Install-CclTools {
    # Reuses or fetches each tool per the plan; returns the install.json `tools` record.
    param([string]$InstallDir, [System.Collections.IDictionary]$Plan, [System.Collections.IDictionary]$Found, [System.Collections.IDictionary]$Specs)
    $rec = [ordered]@{}
    foreach ($n in $script:CclToolOrder) {
        if ($Plan[$n] -eq 'reuse') {
            $rec[$n] = [ordered]@{ source = 'reused'; path = [string]$Found[$n].path; version = [string]$Found[$n].version }
            Write-CclLog "Using the $n already on this PC ($($Found[$n].path))."
            continue
        }
        $spec = $Specs[$n]
        $optional = $script:CclOptionalTools -contains $n
        if (-not $spec) {
            if ($optional) { continue }
            throw "no download known for $n"
        }
        Write-CclLog "Setting up a private $n in the install folder ..."
        try {
            if ($spec.kind -eq 'uv-python') {
                $r = Install-CclManagedPython -Uv $rec.uv.path -Version ([string]$spec.version)
            } else {
                $r = Install-CclPortableTool -InstallDir $InstallDir -Name $n -Spec $spec
            }
        } catch {
            if (-not $optional) { throw }
            Write-CclLog ("Could not set up $n (" + $_.Exception.Message + "); Claude Code can't read PDF pages until pdftoppm is on PATH. Run the installer again to retry.") 'warn'
            continue
        }
        $rec[$n] = [ordered]@{ source = 'bundled'; path = [string]$r.path; version = [string]$r.version }
    }
    return $rec
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
    # @{ Exe; Args } for running the standard-library helpers: the venv, then the Python
    # this install recorded, then a working python on PATH, then uv's managed Python.
    param([string]$InstallDir)
    $v = Get-CclVenvPython -InstallDir $InstallDir
    if ($v) { return @{ Exe = $v; Args = @() } }
    $hint = $script:CclPythonHint
    if (-not $hint) {
        $st = Read-CclInstallState -InstallDir $InstallDir
        if ($st -and $st.tools -and $st.tools.python) { $hint = [string]$st.tools.python.path }
    }
    if ($hint -and (Test-Path -LiteralPath $hint)) { return @{ Exe = $hint; Args = @() } }
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
    # UTF-8 both ways, so a non-ASCII install folder in the helper's output neither crashes
    # Python's console encoding nor turns into mojibake in the log.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $prevIo = $env:PYTHONIOENCODING; $env:PYTHONIOENCODING = 'utf-8'
    $prevEnc = $null
    try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { $prevEnc = $null }
    try {
        $out = & $py.Exe @($py.Args) $Script @HelperArgs 2>&1
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
        if ($null -eq $prevIo) { Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue } else { $env:PYTHONIOENCODING = $prevIo }
        if ($prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { } }
    }
    foreach ($line in @($out)) { if ("$line".Trim()) { Write-CclLog ("  " + "$line".Trim()) } }
    return $rc
}

function Get-CclClaudeDir {
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return (Join-Path $HOME '.claude')
}

function Build-CclVenv {
    # uv venv on the recorded Python (or uv's 3.12), then the pinned requirements. The uv
    # cache and any managed Python go to the folder through the variables set by the caller.
    param([string]$InstallDir, [string]$Uv = '', [string]$Python = '')
    $uvExe = $(if ($Uv) { $Uv } else { (Get-Command uv -ErrorAction SilentlyContinue | Select-Object -First 1).Source })
    if (-not $uvExe) { throw 'uv is not installed' }
    $pyArg = $(if ($Python) { $Python } else { '3.12' })
    $venv = Join-Path $InstallDir 'venv'
    $req = Join-Path $InstallDir 'app\shared\litellm\requirements.txt'
    $ovr = Join-Path $InstallDir 'app\shared\litellm\requirements-overrides.txt'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        if (-not (Get-CclVenvPython -InstallDir $InstallDir)) {
            Write-CclLog "Creating the LiteLLM venv (Python $pyArg) ..."
            & $uvExe venv --python $pyArg --quiet $venv 2>&1 | ForEach-Object { Write-CclLog ("  " + $_) }
            if ($LASTEXITCODE -ne 0) { throw "uv venv exited $LASTEXITCODE" }
        }
        $py = Get-CclVenvPython -InstallDir $InstallDir
        Write-CclLog 'Installing the pinned LiteLLM (this takes a minute the first time) ...'
        # uv splits --override values on spaces, so run next to the file and pass its bare name.
        $ovrName = Split-Path -Leaf $ovr
        Push-Location -LiteralPath (Split-Path -Parent $ovr)
        try {
            & $uvExe pip install --quiet --python $py -r $req --override $ovrName 2>&1 | ForEach-Object { Write-CclLog ("  " + $_) }
            $rc = $LASTEXITCODE
        } finally { Pop-Location }
        if ($rc -ne 0) { throw "uv pip install exited $rc" }
    } finally { $ErrorActionPreference = $prev }
}

# ---------------------------------------------------------------- flows

function Get-CclLegacyInstallDir {
    # Where v1.0.0 installed.
    $base = $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData/Local' })
    return (Join-Path $base 'claude-code-launcher')
}

function Get-CclSuggestedInstallDir {
    # An existing v1.0.0 install, else %USERPROFILE%\claude-code-launcher.
    $legacy = Get-CclLegacyInstallDir
    if (Test-Path -LiteralPath (Join-Path $legacy 'install.json')) { return $legacy }
    $prof = $(if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME })
    return (Join-Path $prof 'claude-code-launcher')
}

function Get-CclTaskInstallDir {
    # The folder the logon task points at (-CclHome "<folder>"), if there is a task.
    if (-not (Test-CclTaskRegistered)) { return $null }
    $t = Get-ScheduledTask -TaskName $script:CclTaskName -ErrorAction SilentlyContinue
    foreach ($a in @($t.Actions)) { if ([string]$a.Arguments -match '-CclHome "([^"]+)"') { return $Matches[1] } }
    return $null
}

function Resolve-CclInstallDir {
    # For uninstall and the key changes (never asks): -InstallDir, CCL_INSTALL_DIR, the
    # task's folder, a v1.0.0 install, else the suggestion.
    param([string]$InstallDir)
    if ($InstallDir) { return [IO.Path]::GetFullPath($InstallDir) }
    if ($env:CCL_INSTALL_DIR) { return [IO.Path]::GetFullPath($env:CCL_INSTALL_DIR) }
    $fromTask = Get-CclTaskInstallDir
    if ($fromTask) { return $fromTask }
    return (Get-CclSuggestedInstallDir)
}

function Test-CclInstallTarget {
    # True when the folder may be installed into: missing, empty, or an earlier install.
    param([string]$InstallDir)
    if (-not (Test-Path -LiteralPath $InstallDir)) { return $true }
    if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) { return $false }
    if (@(Get-ChildItem -LiteralPath $InstallDir -Force).Count -eq 0) { return $true }
    if (Test-Path -LiteralPath (Join-Path $InstallDir 'install.json')) { return $true }
    return (Test-Path -LiteralPath (Join-Path $InstallDir 'app/windows/install.ps1'))
}

function Read-CclLocationFromPrompt {
    param([string]$Default)
    return (Read-Host "Install folder [$Default]")
}

function Select-CclInstallTarget {
    # The install folder for an install: -InstallDir or CCL_INSTALL_DIR as given, else asked
    # (the suggestion with -NonInteractive). Returns $null when it can't be used.
    param([string]$InstallDir, [scriptblock]$LocationPrompt, [switch]$NonInteractive)
    $given = $(if ($InstallDir) { $InstallDir } elseif ($env:CCL_INSTALL_DIR) { $env:CCL_INSTALL_DIR } else { '' })
    if ($given -or $NonInteractive) {
        $dir = [IO.Path]::GetFullPath($(if ($given) { $given } else { Get-CclSuggestedInstallDir }))
        if (Test-CclInstallTarget -InstallDir $dir) { return $dir }
        Write-CclLog "$dir already holds other files; pick an empty or new folder (or an earlier claude-inferhub install)." 'warn'
        return $null
    }
    $suggest = Get-CclSuggestedInstallDir
    for ($i = 0; $i -lt 3; $i++) {
        $ans = [string](& $LocationPrompt $suggest)
        $ans = $ans.Trim().Trim('"')
        $dir = $(if ($ans) { $ans } else { $suggest })
        try { $dir = [IO.Path]::GetFullPath($dir) } catch { Write-CclLog "'$ans' isn't a usable folder path." 'warn'; continue }
        if (Test-CclInstallTarget -InstallDir $dir) { return $dir }
        Write-CclLog "$dir already holds other files; pick an empty or new folder (or an earlier claude-inferhub install)." 'warn'
    }
    return $null
}

function Get-CclKeyErrorCode {
    param($ErrorRecord)
    $m = $ErrorRecord.Exception.Message
    if ($m -like 'CCL_NO_KEY*') { return 4 }
    if ($m -like 'CCL_BAD_KEY*') { return 2 }
    return 2
}

function Invoke-CclPartialUninstall {
    # install.json is missing, so the folder can't be proven ours: undo what is ours
    # outside it (settings, planner, PATH, a task pointing here) and our own secrets and
    # shim inside it, then keep the folder.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal helper of a non-interactive installer; -WhatIf is not offered.')]
    param([string]$InstallDir)
    Write-CclLog "$InstallDir has no install.json, so it can't be proven this installer made it. Removing only our settings, planner, secrets and shim; the folder stays." 'warn'
    if ($script:CclOnWindows -and (Test-CclTaskRegistered)) {
        $t = Get-ScheduledTask -TaskName $script:CclTaskName -ErrorAction SilentlyContinue
        $args0 = (@($t.Actions) | ForEach-Object { $_.Arguments }) -join ' '
        $d = $InstallDir.TrimEnd('\', '/')
        if ($args0 -and $args0.ToLowerInvariant().Contains(('-CclHome "' + $d + '"').ToLowerInvariant())) {
            Stop-ScheduledTask -TaskName $script:CclTaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $script:CclTaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    $app = Join-Path $InstallDir 'app'
    $sync = Join-Path $app 'shared/claude/settings_sync.py'
    $planner = Join-Path $app 'shared/claude/install_planner.py'
    $settings = Join-Path (Get-CclClaudeDir) 'settings.json'
    if (Test-Path -LiteralPath $sync) {
        if (Test-Path -LiteralPath $settings) {
            $rc = Invoke-CclHelper -InstallDir $InstallDir -Script $sync -HelperArgs @('unsync', '--settings', $settings)
            if ($rc -eq 3) { Write-CclLog 'Claude Code settings.json is read-only, so it was left untouched.' 'warn' }
        }
    } else { Write-CclLog "No settings helper under $app; Claude Code settings.json was not changed." 'warn' }
    if (Test-Path -LiteralPath $planner) {
        $null = Invoke-CclHelper -InstallDir $InstallDir -Script $planner -HelperArgs @('uninstall', '--quiet')
    } else { Write-CclLog "No planner helper under $app; the planner sub-agent was not removed." 'warn' }
    $secrets = Join-Path $InstallDir 'secrets'
    foreach ($f in 'inferhub.env', 'tinyfish.env') {
        $p = Join-Path $secrets $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    if ((Test-Path -LiteralPath $secrets) -and @(Get-ChildItem -LiteralPath $secrets -Force).Count -eq 0) { Remove-Item -LiteralPath $secrets -Force }
    $shim = Join-Path $InstallDir 'bin/claude-inferhub.cmd'
    if (Test-Path -LiteralPath $shim) {
        $lines = @(Get-Content -LiteralPath $shim -TotalCount 2 -ErrorAction SilentlyContinue)
        if ($lines.Count -ge 2 -and $lines[1].StartsWith('rem claude-inferhub:')) { Remove-Item -LiteralPath $shim -Force }
    }
    Remove-CclUserPath -Dir (Join-Path $InstallDir 'bin')
    Write-CclLog "Left $InstallDir in place; delete it yourself if you no longer need it."
    return 0
}

function Invoke-CclUninstall {
    param([string]$InstallDir)
    $InstallDir = Resolve-CclInstallDir -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $InstallDir)) { Write-CclLog "Nothing installed at $InstallDir."; return 0 }
    $state = Read-CclInstallState -InstallDir $InstallDir
    if (-not $state -and @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) {
        return (Invoke-CclPartialUninstall -InstallDir $InstallDir)
    }
    Write-CclLog "Removing claude-inferhub from $InstallDir ..."
    Stop-CclProxy -InstallDir $InstallDir
    if (Test-CclTaskRegistered) { Unregister-ScheduledTask -TaskName $script:CclTaskName -Confirm:$false -ErrorAction SilentlyContinue }
    $app = Join-Path $InstallDir 'app'
    # A Claude config folder inside the install goes with it; one outside (a v1.0.0 install,
    # or -ClaudeConfigDir) gets our entries taken out.
    $claudeDir = $(if ($state -and $state.claude_config_dir) { [string]$state.claude_config_dir } else { Get-CclClaudeDir })
    $inside = ([IO.Path]::GetFullPath($claudeDir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar).StartsWith($InstallDir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar)
    $settings = Join-Path $claudeDir 'settings.json'
    if (-not $inside -and (Test-Path -LiteralPath (Join-Path $app 'shared/claude/settings_sync.py'))) {
        if (Test-Path -LiteralPath $settings) {
            $null = Invoke-CclHelper -InstallDir $InstallDir -Script (Join-Path $app 'shared/claude/settings_sync.py') -HelperArgs @('unsync', '--settings', $settings)
            if ($state -and $state.claude_settings_created) {
                try {
                    $doc = Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
                    if (@($doc.PSObject.Properties).Count -eq 0) { Remove-Item -LiteralPath $settings -Force }
                } catch { }
            }
        }
        $null = Invoke-CclHelper -InstallDir $InstallDir -Script (Join-Path $app 'shared/claude/install_planner.py') -HelperArgs @('uninstall', '--quiet', '--claude-dir', $claudeDir)
    }
    Remove-CclUserPath -Dir (Join-Path $InstallDir 'bin')
    $script:CclLogFile = $null
    if ((Get-Location).Path -like ($InstallDir + '*')) { Set-Location -LiteralPath ([IO.Path]::GetTempPath()) }
    Remove-CclTree -Path $InstallDir
    Write-CclLog 'Done. The private tools went with the folder; tools that were already on this PC are still installed.'
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
        [switch]$PortableOnly,
        [switch]$UseSystemTools,
        [string]$ClaudeConfigDir = '',
        [System.Collections.IDictionary]$Environment = $null,
        [scriptblock]$KeyPrompt = { Read-CclKeyFromPrompt },
        [scriptblock]$TinyFishPrompt = { Read-CclTinyFishKeyFromPrompt },
        [scriptblock]$LocationPrompt = { param($s) Read-CclLocationFromPrompt -Default $s },
        [scriptblock]$ToolProbe = $null,
        [System.Collections.IDictionary]$ToolSpecs = $null
    )
    if ($null -eq $Environment) {
        $Environment = @{
            CCL_INFERHUB_KEY = $env:CCL_INFERHUB_KEY; INFERHUB_API_KEY = $env:INFERHUB_API_KEY
            CCL_TINYFISH_KEY = $env:CCL_TINYFISH_KEY; TINYFISH_API_KEY = $env:TINYFISH_API_KEY
        }
    }
    $script:CclLogFile = $null
    $script:CclPythonHint = $null
    if ($Uninstall -or $ChangeKey -or $ChangeTinyFishKey) { $InstallDir = Resolve-CclInstallDir -InstallDir $InstallDir }
    if ($Uninstall) { return (Invoke-CclUninstall -InstallDir $InstallDir) }
    if ($ChangeKey) {
        return (Invoke-CclChangeKey -InstallDir $InstallDir -InferHubKey $InferHubKey -Environment $Environment -KeyPrompt $KeyPrompt -NonInteractive:$NonInteractive)
    }
    if ($ChangeTinyFishKey) {
        return (Invoke-CclChangeTinyFishKey -InstallDir $InstallDir -TinyFishKey $TinyFishKey -Environment $Environment -TinyFishPrompt $TinyFishPrompt -NonInteractive:$NonInteractive)
    }
    if ($StartPort -lt 1 -or $StartPort -gt 65535) { Write-CclLog "StartPort must be a port between 1 and 65535 (got $StartPort)." 'warn'; return 2 }

    # 0. The one folder everything goes into.
    $InstallDir = Select-CclInstallTarget -InstallDir $InstallDir -LocationPrompt $LocationPrompt -NonInteractive:$NonInteractive
    if (-not $InstallDir) { return 2 }
    $claudeDir = $(if ($ClaudeConfigDir) { [IO.Path]::GetFullPath($ClaudeConfigDir) } else { Join-Path $InstallDir 'claude-config' })
    $legacyClaudeDir = Get-CclClaudeDir

    # 1. The keys, before anything changes on disk.
    $secretPath = Join-Path $InstallDir 'secrets\inferhub.env'
    $tinyFishPath = Join-Path $InstallDir 'secrets\tinyfish.env'
    try {
        $key = Resolve-CclInferHubKey -Flag $InferHubKey -Environment $Environment -StoredPath $secretPath -Prompt $KeyPrompt -NonInteractive:$NonInteractive
        $tinyFish = Resolve-CclTinyFishKey -Flag $TinyFishKey -Environment $Environment -StoredPath $tinyFishPath -Prompt $TinyFishPrompt -NonInteractive:$NonInteractive -Skip:$SkipTinyFish
    } catch { Write-CclLog $_.Exception.Message 'warn'; return (Get-CclKeyErrorCode $_) }

    # 2. Tools: reused from the PC or private copies in the folder. Every tool's data goes
    # to the folder through these variables, for this process only.
    $savedEnv = Use-CclToolEnv -Vars (Get-CclToolEnv -InstallDir $InstallDir -ClaudeConfigDir $claudeDir)
    try {
        return (Invoke-CclInstallSteps -InstallDir $InstallDir -ClaudeDir $claudeDir -LegacyClaudeDir $legacyClaudeDir -Key $key -TinyFish $tinyFish `
            -Ref $Ref -Source $Source -StartPort $StartPort -SkipPrereqs:$SkipPrereqs -SkipVenv:$SkipVenv -NoTask:$NoTask -NoPath:$NoPath `
            -NoStart:$NoStart -PortableOnly:$PortableOnly -UseSystemTools:$UseSystemTools -ToolProbe $ToolProbe -ToolSpecs $ToolSpecs)
    } finally {
        Restore-CclToolEnv -Saved $savedEnv
        $script:CclPythonHint = $null
    }
}

function Invoke-CclInstallSteps {
    # Steps 2 to 8 of the install (spec: Install), with the tool variables already set.
    param([string]$InstallDir, [string]$ClaudeDir, [string]$LegacyClaudeDir, [string]$Key, [string]$TinyFish, [string]$Ref,
        [string]$Source, [int]$StartPort, [switch]$SkipPrereqs, [switch]$SkipVenv, [switch]$NoTask, [switch]$NoPath,
        [switch]$NoStart, [switch]$PortableOnly, [switch]$UseSystemTools, [scriptblock]$ToolProbe, [System.Collections.IDictionary]$ToolSpecs)
    $secretPath = Join-Path $InstallDir 'secrets\inferhub.env'
    $tinyFishPath = Join-Path $InstallDir 'secrets\tinyfish.env'
    New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'logs') | Out-Null
    $script:CclLogFile = Join-Path $InstallDir 'logs/install.log'
    Write-CclLog "Installing claude-inferhub $($script:CclVersion) into $InstallDir"
    $tools = [ordered]@{}
    if (-not $SkipPrereqs) {
        $specs = $(if ($ToolSpecs) { $ToolSpecs } else { $script:CclToolSpecs })
        $found = $(if ($ToolProbe) { & $ToolProbe } else { Find-CclSystemTools })
        $plan = Get-CclToolPlan -Found $found -PortableOnly:$PortableOnly -UseSystemTools:$UseSystemTools
        try { $tools = Install-CclTools -InstallDir $InstallDir -Plan $plan -Found $found -Specs $specs }
        catch { Write-CclLog ('Could not set up the tools: ' + $_.Exception.Message + '. Check the network and run this again.') 'warn'; return 3 }
        $null = Use-CclToolEnv -Vars @{ PATH = (Get-CclToolEnv -InstallDir $InstallDir -State @{ tools = $tools; claude_config_dir = $ClaudeDir }).PATH }
        if ($tools.git -and $tools.git.source -eq 'bundled') { $env:CLAUDE_CODE_GIT_BASH_PATH = Join-Path $InstallDir 'tools\git\bin\bash.exe' }
        $script:CclPythonHint = [string]$tools.python.path
    }

    # 3. Launcher files, then the key.
    foreach ($d in 'state', 'logs', 'bin', 'secrets') { New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir $d) | Out-Null }
    try { Install-CclAppFiles -InstallDir $InstallDir -Source $Source -Ref $Ref }
    catch { Write-CclLog $_.Exception.Message 'warn'; return 5 }
    Write-CclSecret -Path $secretPath -Key $Key
    Write-CclLog 'InferHub key saved for this user.'
    if ($TinyFish) {
        Write-CclSecret -Path $tinyFishPath -Key $TinyFish -Name 'TINYFISH_API_KEY'
        Write-CclLog 'TinyFish key saved for this user.'
    } else {
        Write-CclNoTinyFishWarning
    }

    # 4. The LiteLLM venv.
    if (-not $SkipVenv) {
        $uvExe = $(if ($tools.uv) { [string]$tools.uv.path } else { '' })
        $pyExe = $(if ($tools.python) { [string]$tools.python.path } else { '' })
        try { Build-CclVenv -InstallDir $InstallDir -Uv $uvExe -Python $pyExe } catch { Write-CclLog ('Building the venv failed: ' + $_.Exception.Message) 'warn'; return 6 }
    }

    # 5. Port and install.json.
    $old = Read-CclInstallState -InstallDir $InstallDir
    $instance = $(if ($old -and $old.instance_id -match '^[0-9a-f]{32}$') { [string]$old.instance_id } else { New-CclInstanceId })
    $saved = $(if ($old -and $old.port) { [int]$old.port } else { 0 })
    $probe = { param($p) Get-CclPortState -Port $p -InstanceId $instance }   # $instance: dynamic scope
    $port = Select-CclPort -Start $StartPort -Saved $saved -Probe $probe
    if ($saved -and $port -ne $saved) { Write-CclLog "Port $saved is taken by another program; using $port." }
    $app = Join-Path $InstallDir 'app'
    $settingsPath = Join-Path $ClaudeDir 'settings.json'
    # Upgrading v1.0.0 (no claude_config_dir): take out what it put into the profile's Claude config.
    if ($old -and -not $old.claude_config_dir -and $LegacyClaudeDir -and ([IO.Path]::GetFullPath($LegacyClaudeDir) -ne [IO.Path]::GetFullPath($ClaudeDir))) {
        Write-CclLog "Moving Claude Code's launcher settings out of $LegacyClaudeDir into the install folder ..."
        $legacySettings = Join-Path $LegacyClaudeDir 'settings.json'
        if (Test-Path -LiteralPath $legacySettings) {
            $rcU = Invoke-CclHelper -InstallDir $InstallDir -Script (Join-Path $app 'shared/claude/settings_sync.py') -HelperArgs @('unsync', '--settings', $legacySettings)
            if ($rcU -eq 0 -and $old.claude_settings_created) {
                try {
                    $doc = Get-Content -LiteralPath $legacySettings -Raw -Encoding UTF8 | ConvertFrom-Json
                    if (@($doc.PSObject.Properties).Count -eq 0) { Remove-Item -LiteralPath $legacySettings -Force }
                } catch { }
            }
        }
        $null = Invoke-CclHelper -InstallDir $InstallDir -Script (Join-Path $app 'shared/claude/install_planner.py') -HelperArgs @('uninstall', '--quiet', '--claude-dir', $LegacyClaudeDir)
        $old = $null
    }
    $created = $(if ($old) { [bool]$old.claude_settings_created } else { -not (Test-Path -LiteralPath $settingsPath) })
    Write-CclInstallState -InstallDir $InstallDir -State @{ ref = $Ref; port = $port; instance_id = $instance; claude_settings_created = $created
        claude_config_dir = $ClaudeDir; tools = $tools }
    Write-CclLog "Proxy port: $port"

    # 6. The claude-inferhub command.
    $bin = Join-Path $InstallDir 'bin'
    Write-CclUtf8 -Path (Join-Path $bin 'claude-inferhub.cmd') -Text ((Get-CclShimText -InstallDir $InstallDir) + "`r`n")
    if (-not $NoPath) { Add-CclUserPath -Dir $bin }

    # 7. Claude Code settings and the planner sub-agent, in the folder's Claude config.
    $rc = Invoke-CclHelper -InstallDir $InstallDir -Script (Join-Path $app 'shared/claude/settings_sync.py') -HelperArgs @('sync', '--settings', $settingsPath)
    if ($rc -eq 3) { Write-CclLog "Claude Code settings.json is read-only, so it was left untouched; clear the read-only flag and run this again to get the model picker." 'warn' }
    elseif ($rc -ne 0) { Write-CclLog 'Could not update Claude Code settings.json (left as it was).' 'warn' }
    $null = Invoke-CclHelper -InstallDir $InstallDir -Script (Join-Path $app 'shared/claude/install_planner.py') -HelperArgs @('install', '--quiet', '--claude-dir', $ClaudeDir)
    # settings_sync.py also gave Claude Code 120 s for ripgrep (issue #69); check its search
    # works, with the Claude Code this install uses and the folder's config (tool env is on).
    if (-not $SkipPrereqs) {
        $claudeExe = $(if ($tools -and $tools.claude -and $tools.claude.path) { [string]$tools.claude.path } else { 'claude' })
        $null = Test-CclClaudeSearch -Claude $claudeExe
    }

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
    param([string]$Claude = 'claude', [int]$TimeoutSec = 90)
    $out = ''
    # In a job with a time limit: doctor is a TUI and must never hang the install.
    $job = $null
    try {
        $job = Start-Job -ScriptBlock { & $args[0] doctor 2>&1 | Out-String } -ArgumentList $Claude
        if (Wait-Job -Job $job -Timeout $TimeoutSec) { $out = [string](Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-String) }
        else { Stop-Job -Job $job -ErrorAction SilentlyContinue; Write-CclLog "claude doctor did not finish in $TimeoutSec s." 'warn' }
    } catch { $out = '' }
    finally { if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } }
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
    PortableOnly = $PortableOnly; UseSystemTools = $UseSystemTools; ClaudeConfigDir = $ClaudeConfigDir
}
$cclCode = Invoke-CclInstall @cclArgs
if ($PSCommandPath) { exit $cclCode }
if ($cclCode -ne 0) { Write-Error "claude-inferhub install stopped (code $cclCode)." -ErrorAction Continue }
