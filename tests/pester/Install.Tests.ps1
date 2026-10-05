# Pester 5 tests for windows/install.ps1 (docs/specs/windows-package.md).
# Tags: Spec (examples), Property (table invariants), Metamorphic (relations between runs).
# Runs on Linux and Windows pwsh. Never installs prerequisites, never registers a task,
# never touches the real PATH or ~/.claude, never binds port 4000.

BeforeDiscovery { $script:PosixHost = -not (($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows) }

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Installer = Join-Path $Repo 'windows/install.ps1'
    $env:CCL_INSTALL_LIBRARY_ONLY = '1'
    . $Installer
    Remove-Item Env:CCL_INSTALL_LIBRARY_ONLY

    function New-Sandbox {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccl-pester-' + [guid]::NewGuid().ToString('N'))
        $s = @{
            Root = $root
            InstallDir = Join-Path $root 'install'
            ClaudeDir = Join-Path $root 'home/.claude'
        }
        New-Item -ItemType Directory -Force -Path $s.Root, (Split-Path $s.ClaudeDir) | Out-Null
        return $s
    }

    function Invoke-SandboxInstall {
        param($Sandbox, [hashtable]$Extra = @{}, [scriptblock]$KeyPrompt = $null, [hashtable]$Environment = $null,
            [scriptblock]$TinyFishPrompt = $null)
        $env:CLAUDE_CONFIG_DIR = $Sandbox.ClaudeDir
        $p = @{
            InstallDir = $Sandbox.InstallDir; Source = $script:Repo; SkipPrereqs = $true; SkipVenv = $true
            NoTask = $true; NoPath = $true; NoStart = $true; NonInteractive = ($null -eq $KeyPrompt)
            StartPort = 47100
        }
        # Old tests keep Claude's config in the sandbox "profile"; the self-contained tests pass
        # ClaudeConfigDir = '' to get the default <InstallDir>\claude-config.
        $p.ClaudeConfigDir = $Sandbox.ClaudeDir
        foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
        foreach ($k in @($p.Keys)) { if ($null -eq $p[$k]) { $p.Remove($k) } }
        if ($KeyPrompt) { $p.KeyPrompt = $KeyPrompt }
        # Interactive runs never reach the real masked TinyFish prompt: default to skipping it.
        if ($TinyFishPrompt) { $p.TinyFishPrompt = $TinyFishPrompt; $p.NonInteractive = $false }
        elseif ($KeyPrompt) { $p.TinyFishPrompt = { '' } }
        if ($TinyFishPrompt -and -not $KeyPrompt -and -not $p.ContainsKey('InferHubKey')) { $p.InferHubKey = 'ih-default' }
        if ($Environment) { $p.Environment = $Environment } else { $p.Environment = @{} }
        return Invoke-CclInstall @p
    }

    function Get-InstallSnapshot {
        # Relative path -> SHA-256 for the install folder and the Claude config folder.
        # instance_id is normalised so two installs can be compared.
        param($Sandbox, [switch]$KeepInstance)
        $out = [ordered]@{}
        foreach ($base in @($Sandbox.InstallDir, $Sandbox.ClaudeDir)) {
            if (-not (Test-Path -LiteralPath $base)) { continue }
            foreach ($f in Get-ChildItem -LiteralPath $base -Recurse -File -Force | Sort-Object FullName) {
                $rel = $f.FullName.Substring($Sandbox.Root.Length).Replace('\', '/')
                if ($rel -match '/__pycache__/' -or $rel -like '/install/logs/*') { continue }   # logs are history, not state
                if ($f.Name -eq 'install.json' -and -not $KeepInstance) {
                    $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
                    $j.instance_id = '<id>'
                    if ($j.PSObject.Properties.Name -contains 'claude_config_dir') { $j.claude_config_dir = ([string]$j.claude_config_dir).Replace($Sandbox.Root, '<root>') }
                    $out[$rel] = ($j | ConvertTo-Json -Compress)
                } elseif ($f.Length -lt 1MB) {
                    # The sandbox root differs between sandboxes (the shim embeds it); normalise it.
                    $text = [IO.File]::ReadAllText($f.FullName).Replace($Sandbox.Root, '<root>')
                    $out[$rel] = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))
                } else {
                    $out[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
                }
            }
        }
        return $out
    }

    function Compare-Snapshot($a, $b) {
        $ka = @($a.Keys); $kb = @($b.Keys)
        if (Compare-Object $ka $kb) { return "files differ: " + ((Compare-Object $ka $kb | ForEach-Object { $_.InputObject }) -join ', ') }
        foreach ($k in $ka) { if ($a[$k] -ne $b[$k]) { return "content differs: $k" } }
        return ''
    }

    function Remove-Sandbox($s) {
        Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        if ($s -and (Test-Path -LiteralPath $s.Root)) { Remove-Item -LiteralPath $s.Root -Recurse -Force }
    }

    # Non-ASCII names built from code points, so Windows PowerShell 5.1 reading this BOM-less
    # file in the ANSI code page still gets the right characters.
    $script:Jose = 'Jos' + [char]0x00E9
    $script:Cjk = [string][char]0x6D4B + [char]0x8BD5
    $script:NonAsciiDirs = @(
        ('C:\Users\' + $Jose + '\AppData\Local\claude-code-launcher'),
        ('C:\Users\' + $Cjk + '\AppData\Local\claude-code-launcher'),
        ('D:\' + [char]0x00DC + 'ber ' + [char]0x00C5 + 'se\ccl'),
        ('C:\Users\M' + [char]0x00FC + 'ller (x86) & co\AppData\Local\claude-code-launcher'),
        'C:\Users\plain\AppData\Local\claude-code-launcher'
    )
    function New-NonAsciiSandbox {
        $s = New-Sandbox
        $old = $s.Root
        $root = Join-Path ([IO.Path]::GetTempPath()) ('ccl-pester-' + $script:Jose + '-' + $script:Cjk + '-' + [guid]::NewGuid().ToString('N'))
        Remove-Item -LiteralPath $old -Recurse -Force
        $s = @{ Root = $root; InstallDir = Join-Path $root 'install'; ClaudeDir = Join-Path $root 'home/.claude' }
        New-Item -ItemType Directory -Force -Path $s.Root, (Split-Path $s.ClaudeDir) | Out-Null
        return $s
    }
    function Get-TreeSnapshot {
        # Relative path -> length + SHA-256 for every file and folder under $Dir.
        param([string]$Dir)
        $out = [ordered]@{}
        if (-not (Test-Path -LiteralPath $Dir)) { return $out }
        foreach ($i in Get-ChildItem -LiteralPath $Dir -Recurse -Force | Sort-Object FullName) {
            $rel = $i.FullName.Substring($Dir.Length)
            $out[$rel] = $(if ($i.PSIsContainer) { 'dir' } else { (Get-FileHash -LiteralPath $i.FullName -Algorithm SHA256).Hash })
        }
        return $out
    }

    function New-FakeToolSpecs {
        # Zips holding tiny stand-in tools (sh scripts, so POSIX hosts only) and a spec table
        # pointing at them with their real SHA-256. The fake uv "installs" Python by linking
        # the host python3 into UV_PYTHON_INSTALL_DIR.
        param([string]$Dir, [switch]$BadHash)
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        $py = (Get-Command python3 -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        $uv = @'
#!/bin/sh
d="$UV_PYTHON_INSTALL_DIR/cpython-3.12-fake/bin"
case "$1 $2" in
  "python install") mkdir -p "$d" && ln -sf "@PY@" "$d/python.exe" ;;
  "python find") echo "$d/python.exe" ;;
  *) echo "uv 0.0.0-fake" ;;
esac
'@.Replace('@PY@', $py)
        $files = [ordered]@{
            uv = [ordered]@{ 'uv.exe' = $uv }
            node = [ordered]@{ 'node-v0-fake/node.exe' = "#!/bin/sh`necho v24.21.0`n" }
            pnpm = [ordered]@{ 'pnpm.exe' = "#!/bin/sh`necho 12.9.1`n" }
            git = [ordered]@{ 'cmd/git.exe' = "#!/bin/sh`necho git version 2.56.0`n"; 'bin/bash.exe' = "#!/bin/sh`nexit 0`n" }
            poppler = [ordered]@{ 'poppler-0-fake/Library/bin/pdftoppm.exe' = "#!/bin/sh`necho 'pdftoppm version 26.09.0' >&2`n" }
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $specs = @{}
        foreach ($name in $files.Keys) {
            $src = Join-Path $Dir "src-$name"
            foreach ($rel in $files[$name].Keys) {
                $f = Join-Path $src $rel
                New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
                [IO.File]::WriteAllText($f, $files[$name][$rel])
                & chmod +x $f
            }
            $zip = Join-Path $Dir "$name.zip"
            if (Test-Path $zip) { Remove-Item $zip }
            [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
            $specs[$name] = @{ version = '0-fake'; url = $zip; sha256 = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower(); kind = 'zip' }
        }
        $specs.uv.exe = 'uv.exe'
        $specs.node.exe = 'node.exe'; $specs.node.strip = 'node-v0-fake'
        $specs.pnpm.exe = 'pnpm.exe'
        $specs.git.exe = 'cmd/git.exe'; $specs.git.bash = 'bin/bash.exe'
        $specs.poppler.exe = 'Library/bin/pdftoppm.exe'; $specs.poppler.strip = 'poppler-0-fake'
        $claude = Join-Path $Dir 'claude.exe'
        [IO.File]::WriteAllText($claude, "#!/bin/sh`necho '2.1.285 (Claude Code)'`n")
        & chmod +x $claude
        $specs.claude = @{ version = '2.1.285'; url = $claude; sha256 = (Get-FileHash $claude -Algorithm SHA256).Hash.ToLower(); kind = 'file'; exe = 'claude.exe' }
        $specs.python = @{ version = '3.12'; kind = 'uv-python' }
        if ($BadHash) { $specs.uv.sha256 = ('0' * 64) }
        return $specs
    }

    function Get-NoDownloadSpecs {
        # Every download points at a file that doesn't exist, so any use of it fails.
        $s = @{}
        foreach ($n in 'uv', 'node', 'pnpm', 'git', 'claude') {
            $s[$n] = @{ version = 'x'; url = (Join-Path ([IO.Path]::GetTempPath()) ('ccl-missing-' + [guid]::NewGuid().ToString('N'))); sha256 = ('0' * 64); kind = 'zip'; exe = "$n.exe" }
        }
        $s.claude.kind = 'file'
        $s.python = @{ version = '3.12'; kind = 'uv-python' }
        $s.poppler = @{ version = 'x'; url = (Join-Path ([IO.Path]::GetTempPath()) ('ccl-missing-' + [guid]::NewGuid().ToString('N'))); sha256 = ('0' * 64); kind = 'zip'; exe = 'Library/bin/pdftoppm.exe' }
        return $s
    }

    function Get-HostPythonFound {
        $py = (Get-Command python3 -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        $v = (& $py -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])').Trim()
        return @{ path = $py; version = $v }
    }

    $script:GoodKeys = @('ih-abc123', 'sk-' + ('x' * 60), 'key with spaces inside', 'k=v=w', "tab`tkey", 'ümlaut-ключ-鍵', ('a' * 4096))
    $script:BadKeys = @('', '   ', "line1`nline2", "cr`rkey", "nul`0key", 'quote"key', ('a' * 4097))
}

Describe 'Key shape and precedence' -Tag 'Spec' {
    It 'accepts <_>' -ForEach @('ih-abc123', 'key with spaces inside', 'k=v=w', ('a' * 4096)) {
        Test-CclKeyShape -Key $_ | Should -BeTrue
    }
    It 'rejects a bad key (case <_>)' -ForEach @(0, 1, 2, 3, 4, 5, 6) {
        Test-CclKeyShape -Key $script:BadKeys[$_] | Should -BeFalse
    }
    It 'trims surrounding whitespace' {
        $k = Resolve-CclInferHubKey -Flag '  ih-trim  ' -Environment @{} -StoredPath 'nope' -Prompt { throw 'no prompt' } -NonInteractive
        $k | Should -Be 'ih-trim'
    }
    It 'picks <Expected> from flag=<Flag> ccl=<Ccl> env=<Env> stored=<Stored>' -ForEach @(
        @{ Flag = 'F'; Ccl = 'C'; Env = 'E'; Stored = 'S'; Expected = 'F' }
        @{ Flag = '';  Ccl = 'C'; Env = 'E'; Stored = 'S'; Expected = 'C' }
        @{ Flag = '';  Ccl = '';  Env = 'E'; Stored = 'S'; Expected = 'E' }
        @{ Flag = '';  Ccl = '';  Env = '';  Stored = 'S'; Expected = 'S' }
        @{ Flag = '';  Ccl = '';  Env = '';  Stored = '';  Expected = 'P' }
    ) {
        $storedFile = Join-Path $TestDrive ("s-" + [guid]::NewGuid().ToString('N') + '.env')   # ($stored would shadow $Stored)
        if ($Stored) { Write-CclSecret -Path $storedFile -Key $Stored }
        $envs = @{}
        if ($Ccl) { $envs.CCL_INFERHUB_KEY = $Ccl }
        if ($Env) { $envs.INFERHUB_API_KEY = $Env }
        Resolve-CclInferHubKey -Flag $Flag -Environment $envs -StoredPath $storedFile -Prompt { 'P' } | Should -Be $Expected
    }
    It 'throws CCL_NO_KEY when non-interactive and nothing is found' {
        { Resolve-CclInferHubKey -Flag '' -Environment @{} -StoredPath 'nope' -Prompt { 'P' } -NonInteractive } | Should -Throw '*CCL_NO_KEY*'
    }
    It 'throws CCL_BAD_KEY without echoing the key' {
        $bad = "secret-part`nmore"
        try { Resolve-CclInferHubKey -Flag $bad -Environment @{} -StoredPath 'nope' -Prompt { 'P' } -NonInteractive; throw 'no error' }
        catch { $_.Exception.Message | Should -Match 'CCL_BAD_KEY'; $_.Exception.Message | Should -Not -Match 'secret-part' }
    }
}

Describe 'Secret file' -Tag 'Spec' {
    It 'writes exactly one INFERHUB_API_KEY line without a BOM' {
        $p = Join-Path $TestDrive 'secrets/inferhub.env'
        Write-CclSecret -Path $p -Key 'ih-123'
        $bytes = [IO.File]::ReadAllBytes($p)
        ($bytes[0] -eq 0xEF) | Should -BeFalse
        [Text.Encoding]::UTF8.GetString($bytes).TrimEnd("`r", "`n") | Should -Be 'INFERHUB_API_KEY=ih-123'
        Read-CclSecret -Path $p | Should -Be 'ih-123'
    }
    It 'returns null for a missing file' {
        Read-CclSecret -Path (Join-Path $TestDrive 'none.env') | Should -BeNullOrEmpty
    }
}

Describe 'Install state, shim and task' -Tag 'Spec' {
    It 'makes a 32-hex instance id' {
        New-CclInstanceId | Should -Match '^[0-9a-f]{32}$'
    }
    It 'writes install.json with exactly the schema keys' {
        $d = Join-Path $TestDrive 'st'
        Write-CclInstallState -InstallDir $d -State @{ port = 4001; instance_id = ('a' * 32); claude_settings_created = $true }
        $j = Get-Content (Join-Path $d 'install.json') -Raw | ConvertFrom-Json
        @($j.PSObject.Properties.Name | Sort-Object) | Should -Be @('claude_config_dir', 'claude_settings_created', 'instance_id', 'port', 'ref', 'schema', 'task_name', 'tools', 'version')
        $j.schema | Should -Be 'claude-code-launcher.install.v2'
        $j.task_name | Should -Be 'claude-code-launcher-proxy'
        (Read-CclInstallState -InstallDir $d).port | Should -Be 4001
    }
    It 'shim runs the launcher with CCL_HOME and handles --set-key and --uninstall' {
        $t = Get-CclShimText -InstallDir 'X:\inst'
        $t | Should -Match ([regex]::Escape('for %%I in ("%~dp0..") do set "CCL_HOME=%%~fI"'))
        $t | Should -Not -Match 'X:\\inst'
        $t | Should -Match 'launch-claude-inferhub\.ps1'
        $t | Should -Match '--set-key'
        $t | Should -Match '-ChangeKey'
        $t | Should -Match '--uninstall'
        $t | Should -Match '-Uninstall'
        # Uninstall deletes the shim itself, so the batch is left before it runs.
        $t | Should -Match ([regex]::Escape('"--uninstall" ( (goto) 2>nul & '))
    }
    It 'task runs start-litellm hidden with -CclHome and -Port' {
        $a = Get-CclTaskArguments -InstallDir 'X:\inst' -Port 4002
        $a | Should -Match '--headless'
        $a | Should -Match '-WindowStyle Hidden'
        $a | Should -Match 'start-litellm\.ps1'
        $a | Should -Match '-CclHome "X:\\inst"'
        $a | Should -Match '-Port 4002'
    }
    It 'plans only the missing prerequisites, in order' -ForEach @(
        @{ Have = @{ uv = $true; git = $true; node = $true; pnpm = $true; claude = $true }; Want = @() }
        @{ Have = @{ uv = $false; git = $true; node = $true; pnpm = $true; claude = $false }; Want = @('uv', 'claude') }
        @{ Have = @{ uv = $false; git = $false; node = $false; pnpm = $false; claude = $false }; Want = @('uv', 'git', 'node', 'pnpm', 'claude') }
        @{ Have = @{ uv = $true; git = $true; node = $false; pnpm = $true; claude = $true }; Want = @('node') }
    ) {
        @(Get-CclPrereqPlan -Have $Have) | Should -Be $Want
    }
}

Describe 'Port choice' -Tag 'Spec' {
    It 'keeps a saved port that is ours' {
        Select-CclPort -Start 4000 -Saved 4003 -Probe { param($p) if ($p -eq 4003) { 'ours' } else { 'free' } } | Should -Be 4003
    }
    It 'keeps a saved port that is free' {
        Select-CclPort -Start 4000 -Saved 4005 -Probe { param($p) 'free' } | Should -Be 4005
    }
    It 'skips a foreign 4000 and takes 4001' {
        Select-CclPort -Start 4000 -Saved 0 -Probe { param($p) if ($p -eq 4000) { 'foreign' } else { 'free' } } | Should -Be 4001
    }
    It 'moves off a saved port another program took' {
        Select-CclPort -Start 4000 -Saved 4000 -Probe { param($p) if ($p -le 4002) { 'foreign' } else { 'free' } } | Should -Be 4003
    }
    It 'throws when every port in range is foreign' {
        { Select-CclPort -Start 4000 -Saved 0 -Count 5 -Probe { param($p) 'foreign' } } | Should -Throw
    }
}

Describe 'Port state probe' -Tag 'Spec' {
    BeforeAll {
        $script:py = (Get-Command python3, python -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        $script:srv = Join-Path $TestDrive 'srv.py'
        Set-Content -LiteralPath $srv -Encoding ASCII -Value @'
import http.server, json, sys
inst = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/ccl/identity" and inst != "-":
            b = json.dumps({"app": "claude-code-launcher", "instance": inst}).encode()
            self.send_response(200); self.end_headers(); self.wfile.write(b); return
        self.send_response(200 if self.path.startswith("/health") else 404); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
'@
        function Start-FakeServer([string]$Instance) {
            $psi = [Diagnostics.ProcessStartInfo]::new($script:py)
            # ProcessStartInfo.ArgumentList is .NET Core only; Windows PowerShell 5.1 needs Arguments.
            $psi.Arguments = '"' + $script:srv + '" ' + $Instance
            $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
            $p = [Diagnostics.Process]::Start($psi)
            $port = [int]$p.StandardOutput.ReadLine()
            return @{ Process = $p; Port = $port }
        }
    }
    It 'reports a closed port as free' {
        $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
        Get-CclPortState -Port $port -InstanceId ('a' * 32) | Should -Be 'free'
    }
    It 'reports a raw TCP listener as foreign' {
        $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start()
        try { Get-CclPortState -Port $l.LocalEndpoint.Port -InstanceId ('a' * 32) | Should -Be 'foreign' } finally { $l.Stop() }
    }
    It 'reports a LiteLLM-like server without identity as foreign' {
        $s = Start-FakeServer '-'
        try { Get-CclPortState -Port $s.Port -InstanceId ('a' * 32) | Should -Be 'foreign' } finally { $s.Process.Kill() }
    }
    It 'reports another install as foreign and this install as ours' {
        $id = New-CclInstanceId
        $s = Start-FakeServer $id
        try {
            Get-CclPortState -Port $s.Port -InstanceId $id | Should -Be 'ours'
            Get-CclPortState -Port $s.Port -InstanceId (New-CclInstanceId) | Should -Be 'foreign'
        } finally { $s.Process.Kill() }
    }
}

Describe 'Install flow' -Tag 'Spec' {
    BeforeEach { $script:sb = New-Sandbox }
    AfterEach { Remove-Sandbox $script:sb }

    It 'creates the documented layout and settings.json with the fable advisor' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-layout' } | Should -Be 0
        foreach ($rel in 'app/windows/launch-claude-inferhub.ps1', 'install.json', 'secrets/inferhub.env', 'bin/claude-inferhub.cmd') {
            Test-Path -LiteralPath (Join-Path $sb.InstallDir $rel) | Should -BeTrue -Because $rel
        }
        foreach ($rel in 'state', 'logs') { Test-Path -LiteralPath (Join-Path $sb.InstallDir $rel) -PathType Container | Should -BeTrue }
        $s = Get-Content (Join-Path $sb.ClaudeDir 'settings.json') -Raw | ConvertFrom-Json
        $s.advisorModel | Should -Be 'fable'
        (Read-CclInstallState -InstallDir $sb.InstallDir).claude_settings_created | Should -BeTrue
        Test-Path (Join-Path $sb.ClaudeDir 'agents/planner.md') | Should -BeTrue
    }
    It 'exits 4 with no key in non-interactive mode' {
        Invoke-SandboxInstall $sb | Should -Be 4
    }
    It 'exits 2 for a bad key' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = "bad`nkey" } | Should -Be 2
    }
    It 'exits 5 when the source is missing' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; Source = (Join-Path $sb.Root 'nope') } | Should -Be 5
    }
    It 'keeps unrelated settings and records that it did not create the file' {
        New-Item -ItemType Directory -Force $sb.ClaudeDir | Out-Null
        '{"theme":"dark","advisorModel":"opus"}' | Set-Content (Join-Path $sb.ClaudeDir 'settings.json')
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x' } | Should -Be 0
        $s = Get-Content (Join-Path $sb.ClaudeDir 'settings.json') -Raw | ConvertFrom-Json
        $s.theme | Should -Be 'dark'; $s.advisorModel | Should -Be 'fable'
        (Read-CclInstallState -InstallDir $sb.InstallDir).claude_settings_created | Should -BeFalse
    }
    It 'ChangeKey replaces only the key' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-old' } | Should -Be 0
        $before = Get-InstallSnapshot $sb -KeepInstance
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-new'; ChangeKey = $true } | Should -Be 0
        Read-CclSecret -Path (Join-Path $sb.InstallDir 'secrets/inferhub.env') | Should -Be 'ih-new'
        $after = Get-InstallSnapshot $sb -KeepInstance
        @($after.Keys | Where-Object { $after[$_] -ne $before[$_] }) | Should -Be @('/install/secrets/inferhub.env')
    }
    It 'uninstall removes the folder, our settings and the planner, and keeps the user''s settings' {
        New-Item -ItemType Directory -Force $sb.ClaudeDir | Out-Null
        '{"theme":"dark"}' | Set-Content (Join-Path $sb.ClaudeDir 'settings.json')
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x' } | Should -Be 0
        Invoke-SandboxInstall $sb -Extra @{ Uninstall = $true } | Should -Be 0
        Test-Path $sb.InstallDir | Should -BeFalse
        $s = Get-Content (Join-Path $sb.ClaudeDir 'settings.json') -Raw | ConvertFrom-Json
        @($s.PSObject.Properties.Name) | Should -Be @('theme')
        Test-Path (Join-Path $sb.ClaudeDir 'agents/planner.md') | Should -BeFalse
    }
    It 'uninstall deletes settings.json when the installer created it' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x' } | Should -Be 0
        Invoke-SandboxInstall $sb -Extra @{ Uninstall = $true } | Should -Be 0
        Test-Path (Join-Path $sb.ClaudeDir 'settings.json') | Should -BeFalse
    }
    It 'install.ps1 has no Alex-specific bits in the installed launcher config' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x' } | Should -Be 0
        (Get-Content (Join-Path $sb.InstallDir 'install.json') -Raw) | Should -Not -Match 'pujan|D:\\\\|Desktop'
    }
}

Describe 'Invariants' -Tag 'Property' {
    It 'Select-CclPort never returns a foreign port (seeded random tables, seed <_>)' -ForEach (1..60) {
        $rng = [Random]::new($_)
        $start = 4000 + $rng.Next(0, 50)
        $states = @{}
        foreach ($p in $start..($start + 40)) { $states[$p] = @('free', 'ours', 'foreign')[$rng.Next(0, 3)] }
        $states[$start + 40] = 'free'                         # always at least one usable port
        $saved = @(0, ($start + $rng.Next(0, 41)))[$rng.Next(0, 2)]
        $probe = { param($p) if ($states.ContainsKey($p)) { $states[$p] } else { 'free' } }.GetNewClosure()
        $got = Select-CclPort -Start $start -Saved $saved -Probe $probe -Count 41
        $states[$got] | Should -Not -Be 'foreign'
        if ($saved -and $states[$saved] -ne 'foreign') { $got | Should -Be $saved }
        else {
            $got | Should -BeGreaterOrEqual $start
            if ($got -gt $start) { foreach ($q in $start..($got - 1)) { $states[$q] | Should -Be 'foreign' } }   # (a..b counts down when b < a)
        }
        Select-CclPort -Start $start -Saved $saved -Probe $probe -Count 41 | Should -Be $got   # deterministic
    }
    It 'Test-CclKeyShape agrees with the rules for random keys (seed <_>)' -ForEach (1..40) {
        $rng = [Random]::new($_)
        $len = $rng.Next(0, 60)
        $chars = for ($i = 0; $i -lt $len; $i++) { [char]$rng.Next(0, 128) }
        $k = -join $chars
        $expect = ($k.Trim().Length -gt 0) -and ($k.Trim().Length -le 4096) -and ($k -notmatch "[`r`n`0`"]")
        Test-CclKeyShape -Key $k | Should -Be $expect
    }
    It 'the key never appears in any output stream or file except the secret file (key <_>)' -ForEach (0..6) {
        $key = $script:GoodKeys[$_] + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $sb = New-Sandbox
        try {
            $env:CLAUDE_CONFIG_DIR = $sb.ClaudeDir
            $all = & { Invoke-SandboxInstall $sb -Extra @{ InferHubKey = $key } } *>&1 | Out-String
            $all | Should -Not -BeLike ('*' + $key.Trim() + '*')
            $secret = (Resolve-Path (Join-Path $sb.InstallDir 'secrets/inferhub.env')).Path
            foreach ($f in Get-ChildItem $sb.Root -Recurse -File -Force) {
                if ($f.FullName -eq $secret) { continue }
                if ($f.Length -gt 5MB) { continue }
                [IO.File]::ReadAllText($f.FullName).Contains($key.Trim()) | Should -BeFalse -Because $f.FullName
            }
            Read-CclSecret -Path $secret | Should -Be $key.Trim()
        } finally { Remove-Sandbox $sb }
    }
    It 'Get-CclTaskArguments never carries a key-like value and always names the port (port <_>)' -ForEach @(4000, 4001, 4100, 47123) {
        $a = Get-CclTaskArguments -InstallDir 'C:\Users\friend\AppData\Local\claude-code-launcher' -Port $_
        $a | Should -Match ("-Port $_" + '(\s|$)')
        $a | Should -Not -Match 'INFERHUB|KEY='
    }
    It 'Get-CclShimText never contains Alex-specific paths (dir <_>)' -ForEach @('C:\Users\a\AppData\Local\claude-code-launcher', 'E:\tools\ccl', '/tmp/x') {
        Get-CclShimText -InstallDir $_ | Should -Not -Match 'pujan|D:\\development|C:\\work|Desktop'
    }
}

Describe 'Relations between runs' -Tag 'Metamorphic' {
    It 'install twice leaves the same state as once' {
        $a = New-Sandbox; $b = New-Sandbox
        try {
            Invoke-SandboxInstall $a -Extra @{ InferHubKey = 'ih-m1' } | Should -Be 0
            Invoke-SandboxInstall $b -Extra @{ InferHubKey = 'ih-m1' } | Should -Be 0
            $idb = (Read-CclInstallState -InstallDir $b.InstallDir).instance_id
            Invoke-SandboxInstall $b -Extra @{ InferHubKey = 'ih-m1' } | Should -Be 0
            (Read-CclInstallState -InstallDir $b.InstallDir).instance_id | Should -Be $idb   # kept across reinstalls
            Compare-Snapshot (Get-InstallSnapshot $a) (Get-InstallSnapshot $b) | Should -Be ''
        } finally { Remove-Sandbox $a; Remove-Sandbox $b }
    }
    It 'install, uninstall, install equals a fresh install' {
        $a = New-Sandbox; $b = New-Sandbox
        try {
            Invoke-SandboxInstall $a -Extra @{ InferHubKey = 'ih-m2' } | Should -Be 0
            Invoke-SandboxInstall $b -Extra @{ InferHubKey = 'ih-m2' } | Should -Be 0
            Invoke-SandboxInstall $b -Extra @{ Uninstall = $true } | Should -Be 0
            Invoke-SandboxInstall $b -Extra @{ InferHubKey = 'ih-m2' } | Should -Be 0
            Compare-Snapshot (Get-InstallSnapshot $a) (Get-InstallSnapshot $b) | Should -Be ''
        } finally { Remove-Sandbox $a; Remove-Sandbox $b }
    }
    It 'key via flag, CCL_INFERHUB_KEY, INFERHUB_API_KEY or prompt gives identical stored config' {
        $boxes = 1..4 | ForEach-Object { New-Sandbox }
        try {
            Invoke-SandboxInstall $boxes[0] -Extra @{ InferHubKey = 'ih-same' } | Should -Be 0
            Invoke-SandboxInstall $boxes[1] -Environment @{ CCL_INFERHUB_KEY = 'ih-same' } | Should -Be 0
            Invoke-SandboxInstall $boxes[2] -Environment @{ INFERHUB_API_KEY = 'ih-same' } | Should -Be 0
            Invoke-SandboxInstall $boxes[3] -KeyPrompt { 'ih-same' } | Should -Be 0
            $ref = Get-InstallSnapshot $boxes[0]
            foreach ($i in 1..3) { Compare-Snapshot $ref (Get-InstallSnapshot $boxes[$i]) | Should -Be '' -Because "source $i" }
        } finally { $boxes | ForEach-Object { Remove-Sandbox $_ } }
    }
    It 'a different free start port gives the same install apart from the port' {
        $a = New-Sandbox; $b = New-Sandbox
        try {
            Invoke-SandboxInstall $a -Extra @{ InferHubKey = 'ih-p'; StartPort = 47200 } | Should -Be 0
            Invoke-SandboxInstall $b -Extra @{ InferHubKey = 'ih-p'; StartPort = 47300 } | Should -Be 0
            (Read-CclInstallState -InstallDir $a.InstallDir).port | Should -Be 47200
            (Read-CclInstallState -InstallDir $b.InstallDir).port | Should -Be 47300
            $sa = Get-InstallSnapshot $a; $sb2 = Get-InstallSnapshot $b
            $sa['/install/install.json'] = $sa['/install/install.json'] -replace '"port":\d+', '"port":0'
            $sb2['/install/install.json'] = $sb2['/install/install.json'] -replace '"port":\d+', '"port":0'
            Compare-Snapshot $sa $sb2 | Should -Be ''
        } finally { Remove-Sandbox $a; Remove-Sandbox $b }
    }
    It 'reordering the keys of an existing settings.json does not change the result' {
        $a = New-Sandbox; $b = New-Sandbox
        try {
            New-Item -ItemType Directory -Force $a.ClaudeDir, $b.ClaudeDir | Out-Null
            '{"theme":"dark","env":{"A":"1"},"advisorModel":"opus","z":[1,2]}' | Set-Content (Join-Path $a.ClaudeDir 'settings.json')
            '{"z":[1,2],"advisorModel":"opus","env":{"A":"1"},"theme":"dark"}' | Set-Content (Join-Path $b.ClaudeDir 'settings.json')
            Invoke-SandboxInstall $a -Extra @{ InferHubKey = 'ih-r' } | Should -Be 0
            Invoke-SandboxInstall $b -Extra @{ InferHubKey = 'ih-r' } | Should -Be 0
            # Compare key-order-independently (ConvertFrom-Json -AsHashtable is pwsh 7 only).
            $py = (Get-Command python3, python -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            # No double quotes in the code: Windows PowerShell 5.1 drops them when passing native arguments.
            $canon = "import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding='utf-8-sig')), sort_keys=True))"
            $ca = & $py -c $canon (Join-Path $a.ClaudeDir 'settings.json')
            $cb = & $py -c $canon (Join-Path $b.ClaudeDir 'settings.json')
            $ca | Should -Not -BeNullOrEmpty
            $ca | Should -Be $cb
        } finally { Remove-Sandbox $a; Remove-Sandbox $b }
    }
}

Describe 'TinyFish key' -Tag 'Spec' {
    BeforeEach { $script:sb = New-Sandbox }
    AfterEach { Remove-Sandbox $script:sb }

    It 'picks <Expected> from flag=<Flag> ccl=<Ccl> env=<Env> stored=<Stored>' -ForEach @(
        @{ Flag = 'F'; Ccl = 'C'; Env = 'E'; Stored = 'S'; Expected = 'F' }
        @{ Flag = '';  Ccl = 'C'; Env = 'E'; Stored = 'S'; Expected = 'C' }
        @{ Flag = '';  Ccl = '';  Env = 'E'; Stored = 'S'; Expected = 'E' }
        @{ Flag = '';  Ccl = '';  Env = '';  Stored = 'S'; Expected = 'S' }
        @{ Flag = '';  Ccl = '';  Env = '';  Stored = '';  Expected = 'P' }
    ) {
        $storedFile = Join-Path $TestDrive ('tf-' + [guid]::NewGuid().ToString('N') + '.env')
        if ($Stored) { Write-CclSecret -Path $storedFile -Key $Stored -Name 'TINYFISH_API_KEY' }
        $envs = @{}
        if ($Ccl) { $envs.CCL_TINYFISH_KEY = $Ccl }
        if ($Env) { $envs.TINYFISH_API_KEY = $Env }
        Resolve-CclTinyFishKey -Flag $Flag -Environment $envs -StoredPath $storedFile -Prompt { 'P' } | Should -Be $Expected
    }
    It 'the InferHub variables never count as a TinyFish key' {
        Resolve-CclTinyFishKey -Flag '' -Environment @{ CCL_INFERHUB_KEY = 'ih'; INFERHUB_API_KEY = 'ih' } -StoredPath 'nope' -Prompt { '' } | Should -BeNullOrEmpty
    }
    It 'returns null for an empty answer, -Skip or -NonInteractive, without calling the prompt for the last two' {
        Resolve-CclTinyFishKey -Flag '' -Environment @{} -StoredPath 'nope' -Prompt { '   ' } | Should -BeNullOrEmpty
        Resolve-CclTinyFishKey -Flag '' -Environment @{} -StoredPath 'nope' -Prompt { throw 'prompted' } -Skip | Should -BeNullOrEmpty
        Resolve-CclTinyFishKey -Flag '' -Environment @{} -StoredPath 'nope' -Prompt { throw 'prompted' } -NonInteractive | Should -BeNullOrEmpty
    }
    It '-Skip still keeps a stored key' {
        $storedFile = Join-Path $TestDrive 'kept.env'
        Write-CclSecret -Path $storedFile -Key 'tf-kept' -Name 'TINYFISH_API_KEY'
        Resolve-CclTinyFishKey -Flag '' -Environment @{} -StoredPath $storedFile -Prompt { throw 'prompted' } -Skip | Should -Be 'tf-kept'
    }
    It 'throws CCL_BAD_KEY for a bad key without echoing it' {
        try { Resolve-CclTinyFishKey -Flag "tf-secret`nx" -Environment @{} -StoredPath 'nope' -Prompt { '' }; throw 'no error' }
        catch { $_.Exception.Message | Should -Match 'CCL_BAD_KEY'; $_.Exception.Message | Should -Not -Match 'tf-secret' }
    }
    It 'writes secrets/tinyfish.env with exactly one TINYFISH_API_KEY line' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; TinyFishKey = 'tf-123' } | Should -Be 0
        $p = Join-Path $sb.InstallDir 'secrets/tinyfish.env'
        $bytes = [IO.File]::ReadAllBytes($p)
        ($bytes[0] -eq 0xEF) | Should -BeFalse
        [Text.Encoding]::UTF8.GetString($bytes) | Should -Be "TINYFISH_API_KEY=tf-123`n"
        Read-CclSecret -Path $p -Name 'TINYFISH_API_KEY' | Should -Be 'tf-123'
        Read-CclSecret -Path (Join-Path $sb.InstallDir 'secrets/inferhub.env') | Should -Be 'ih-x'
    }
    It 'installs without a TinyFish key in non-interactive mode, with a warning' {
        $out = & { Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x' } } 3>&1 | Out-String
        (Read-CclInstallState -InstallDir $sb.InstallDir) | Should -Not -BeNullOrEmpty
        Test-Path (Join-Path $sb.InstallDir 'secrets/tinyfish.env') | Should -BeFalse
        $out | Should -Match 'TinyFish'
        $out | Should -Match 'unreliable'
        $out | Should -Match '--set-tinyfish-key'
    }
    It 'an empty answer at the prompt skips it with the same warning and exit 0' {
        $out = & { Invoke-SandboxInstall $sb -TinyFishPrompt { '' } } 3>&1 | Out-String
        @($out -split "`n" | Where-Object { $_ -match 'unreliable' }).Count | Should -BeGreaterThan 0
        Test-Path (Join-Path $sb.InstallDir 'secrets/tinyfish.env') | Should -BeFalse
        Test-Path (Join-Path $sb.InstallDir 'install.json') | Should -BeTrue
    }
    It 'exits 2 for a bad TinyFish key and changes nothing on disk' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; TinyFishKey = "bad`"key" } | Should -Be 2
        Test-Path $sb.InstallDir | Should -BeFalse
    }
    It 'a reinstall keeps the stored TinyFish key' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; TinyFishKey = 'tf-keep' } | Should -Be 0
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x' } | Should -Be 0
        Read-CclSecret -Path (Join-Path $sb.InstallDir 'secrets/tinyfish.env') -Name 'TINYFISH_API_KEY' | Should -Be 'tf-keep'
    }
    It 'ChangeTinyFishKey replaces only that key' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; TinyFishKey = 'tf-old' } | Should -Be 0
        $before = Get-InstallSnapshot $sb -KeepInstance
        Invoke-SandboxInstall $sb -Extra @{ TinyFishKey = 'tf-new'; ChangeTinyFishKey = $true } | Should -Be 0
        Read-CclSecret -Path (Join-Path $sb.InstallDir 'secrets/tinyfish.env') -Name 'TINYFISH_API_KEY' | Should -Be 'tf-new'
        $after = Get-InstallSnapshot $sb -KeepInstance
        @($after.Keys | Where-Object { $after[$_] -ne $before[$_] }) | Should -Be @('/install/secrets/tinyfish.env')
    }
    It 'ChangeTinyFishKey adds a key to an install that skipped it' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x' } | Should -Be 0
        Invoke-SandboxInstall $sb -TinyFishPrompt { 'tf-later' } -Extra @{ ChangeTinyFishKey = $true } | Should -Be 0
        Read-CclSecret -Path (Join-Path $sb.InstallDir 'secrets/tinyfish.env') -Name 'TINYFISH_API_KEY' | Should -Be 'tf-later'
    }
    It 'ChangeTinyFishKey with an empty answer removes the key' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; TinyFishKey = 'tf-gone' } | Should -Be 0
        Invoke-SandboxInstall $sb -TinyFishPrompt { '' } -Extra @{ ChangeTinyFishKey = $true } | Should -Be 0
        Test-Path (Join-Path $sb.InstallDir 'secrets/tinyfish.env') | Should -BeFalse
        Read-CclSecret -Path (Join-Path $sb.InstallDir 'secrets/inferhub.env') | Should -Be 'ih-x'
    }
    It 'the shim handles --set-tinyfish-key' {
        $t = Get-CclShimText -InstallDir 'X:\inst'
        $t | Should -Match '--set-tinyfish-key'
        $t | Should -Match '-ChangeTinyFishKey'
    }
    It 'uninstall removes the TinyFish key with the folder' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; TinyFishKey = 'tf-u' } | Should -Be 0
        Invoke-SandboxInstall $sb -Extra @{ Uninstall = $true } | Should -Be 0
        Test-Path $sb.InstallDir | Should -BeFalse
    }
}

Describe 'TinyFish key invariants' -Tag 'Property' {
    It 'the TinyFish key never appears in any output stream or file except its secret file (key <_>)' -ForEach (0..6) {
        $key = 'tf-' + $script:GoodKeys[$_] + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $sb = New-Sandbox
        try {
            $all = & { Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-other'; TinyFishKey = $key } } *>&1 | Out-String
            $all | Should -Not -BeLike ('*' + $key.Trim() + '*')
            $secret = (Resolve-Path (Join-Path $sb.InstallDir 'secrets/tinyfish.env')).Path
            foreach ($f in Get-ChildItem $sb.Root -Recurse -File -Force) {
                if ($f.FullName -eq $secret -or $f.Length -gt 5MB) { continue }
                [IO.File]::ReadAllText($f.FullName).Contains($key.Trim()) | Should -BeFalse -Because $f.FullName
            }
            Read-CclSecret -Path $secret -Name 'TINYFISH_API_KEY' | Should -Be $key.Trim()
            $chg = & { Invoke-SandboxInstall $sb -Extra @{ TinyFishKey = ($key + 'b'); ChangeTinyFishKey = $true } } *>&1 | Out-String
            $chg | Should -Not -BeLike ('*' + $key.Trim() + '*')
        } finally { Remove-Sandbox $sb }
    }
    It 'Resolve-CclTinyFishKey returns a trimmed valid key or null, never anything else (seed <_>)' -ForEach (1..40) {
        $rng = [Random]::new(1000 + $_)
        $len = $rng.Next(0, 40)
        $k = -join $(for ($i = 0; $i -lt $len; $i++) { [char]$rng.Next(32, 127) })
        if (Test-CclKeyShape -Key $k) {
            Resolve-CclTinyFishKey -Flag $k -Environment @{} -StoredPath 'nope' -Prompt { throw 'prompted' } | Should -Be $k.Trim()
        } elseif ([string]::IsNullOrWhiteSpace($k)) {
            Resolve-CclTinyFishKey -Flag $k -Environment @{} -StoredPath 'nope' -Prompt { '' } | Should -BeNullOrEmpty
        } else {
            { Resolve-CclTinyFishKey -Flag $k -Environment @{} -StoredPath 'nope' -Prompt { '' } } | Should -Throw '*CCL_BAD_KEY*'
        }
    }
}

Describe 'TinyFish key relations' -Tag 'Metamorphic' {
    It 'key via prompt, flag, CCL_TINYFISH_KEY or TINYFISH_API_KEY gives identical stored config' {
        $boxes = 1..4 | ForEach-Object { New-Sandbox }
        try {
            Invoke-SandboxInstall $boxes[0] -Extra @{ InferHubKey = 'ih-same'; TinyFishKey = 'tf-same' } | Should -Be 0
            Invoke-SandboxInstall $boxes[1] -Extra @{ InferHubKey = 'ih-same' } -Environment @{ CCL_TINYFISH_KEY = 'tf-same' } | Should -Be 0
            Invoke-SandboxInstall $boxes[2] -Extra @{ InferHubKey = 'ih-same' } -Environment @{ TINYFISH_API_KEY = 'tf-same' } | Should -Be 0
            Invoke-SandboxInstall $boxes[3] -Extra @{ InferHubKey = 'ih-same' } -TinyFishPrompt { 'tf-same' } | Should -Be 0
            $ref = Get-InstallSnapshot $boxes[0]
            $ref.Contains('/install/secrets/tinyfish.env') | Should -BeTrue
            foreach ($i in 1..3) { Compare-Snapshot $ref (Get-InstallSnapshot $boxes[$i]) | Should -Be '' -Because "source $i" }
        } finally { $boxes | ForEach-Object { Remove-Sandbox $_ } }
    }
    It 'skipping TinyFish differs from a keyed install only by secrets/tinyfish.env' {
        $a = New-Sandbox; $b = New-Sandbox
        try {
            Invoke-SandboxInstall $a -Extra @{ InferHubKey = 'ih-s'; TinyFishKey = 'tf-s' } | Should -Be 0
            Invoke-SandboxInstall $b -Extra @{ InferHubKey = 'ih-s'; SkipTinyFish = $true } | Should -Be 0
            $sa = Get-InstallSnapshot $a; $sb2 = Get-InstallSnapshot $b
            $sa.Remove('/install/secrets/tinyfish.env')
            Compare-Snapshot $sa $sb2 | Should -Be ''
        } finally { Remove-Sandbox $a; Remove-Sandbox $b }
    }
    It 'adding the key later with ChangeTinyFishKey equals giving it at install' {
        $a = New-Sandbox; $b = New-Sandbox
        try {
            Invoke-SandboxInstall $a -Extra @{ InferHubKey = 'ih-l'; TinyFishKey = 'tf-l' } | Should -Be 0
            Invoke-SandboxInstall $b -Extra @{ InferHubKey = 'ih-l' } | Should -Be 0
            Invoke-SandboxInstall $b -Extra @{ TinyFishKey = 'tf-l'; ChangeTinyFishKey = $true } | Should -Be 0
            Compare-Snapshot (Get-InstallSnapshot $a) (Get-InstallSnapshot $b) | Should -Be ''
        } finally { Remove-Sandbox $a; Remove-Sandbox $b }
    }
}

# ---------------------------------------------------------------- v1.0.1 (issue #63)

Describe 'Shim works from any folder (v1.0.1 #1)' -Tag 'Spec' {
    It 'is pure ASCII and holds no path for <_>' -ForEach @(0, 1, 2, 3, 4) {
        $dir = $script:NonAsciiDirs[$_]
        $text = Get-CclShimText -InstallDir $dir
        foreach ($ch in $text.ToCharArray()) { [int]$ch | Should -BeLessThan 128 }
        $text.Contains($dir) | Should -BeFalse
        $text | Should -Match '%~dp0'
    }
    It 'installs a pure-ASCII shim into a non-ASCII folder and uninstalls cleanly' {
        $sb = New-NonAsciiSandbox
        try {
            Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-u' } | Should -Be 0
            $bytes = [IO.File]::ReadAllBytes((Join-Path $sb.InstallDir 'bin/claude-inferhub.cmd'))
            @($bytes | Where-Object { $_ -ge 0x80 }).Count | Should -Be 0
            ($bytes[0] -eq 0xEF) | Should -BeFalse
            Invoke-SandboxInstall $sb -Extra @{ Uninstall = $true } | Should -Be 0
            Test-Path -LiteralPath $sb.InstallDir | Should -BeFalse
        } finally { Remove-Sandbox $sb }
    }
}

Describe 'Shim invariants (v1.0.1 #1)' -Tag 'Property' {
    It 'is the same text for every install folder (seed <_>)' -ForEach (1..25) {
        $rng = [Random]::new(5000 + $_)
        $name = -join $(for ($i = 0; $i -lt $rng.Next(1, 20); $i++) { [char]$rng.Next(0x20, 0x3000) })
        $name = $name -replace '[\\/:*?"<>|]', '_'
        Get-CclShimText -InstallDir ('C:\Users\' + $name + '\AppData\Local\claude-code-launcher') | Should -BeExactly (Get-CclShimText -InstallDir 'C:\x')
    }
}

Describe 'Uninstall without install.json (v1.0.1 #2)' -Tag 'Spec' {
    BeforeEach { $script:sb = New-Sandbox }
    AfterEach { Remove-Sandbox $script:sb }

    It 'still unsyncs settings, removes the planner, the secrets and the shim, and keeps the folder' {
        New-Item -ItemType Directory -Force $sb.ClaudeDir | Out-Null
        '{"theme":"dark"}' | Set-Content (Join-Path $sb.ClaudeDir 'settings.json')
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; TinyFishKey = 'tf-x' } | Should -Be 0
        Remove-Item -LiteralPath (Join-Path $sb.InstallDir 'install.json')
        $out = & { Invoke-SandboxInstall $sb -Extra @{ Uninstall = $true } } 3>&1 | Out-String
        @($out -split "`n" | Where-Object { $_ -match '^\s*0\s*$' }).Count | Should -BeGreaterThan 0
        $out | Should -Match 'install\.json'
        $s = Get-Content (Join-Path $sb.ClaudeDir 'settings.json') -Raw | ConvertFrom-Json
        @($s.PSObject.Properties.Name) | Should -Be @('theme')
        Test-Path (Join-Path $sb.ClaudeDir 'agents/planner.md') | Should -BeFalse
        Test-Path (Join-Path $sb.InstallDir 'secrets/inferhub.env') | Should -BeFalse
        Test-Path (Join-Path $sb.InstallDir 'secrets/tinyfish.env') | Should -BeFalse
        Test-Path (Join-Path $sb.InstallDir 'bin/claude-inferhub.cmd') | Should -BeFalse
        Test-Path -LiteralPath $sb.InstallDir | Should -BeTrue
        Test-Path (Join-Path $sb.InstallDir 'app/windows/install.ps1') | Should -BeTrue
    }
    It 'never deletes settings.json it cannot prove it created' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x' } | Should -Be 0
        Remove-Item -LiteralPath (Join-Path $sb.InstallDir 'install.json')
        Invoke-SandboxInstall $sb -Extra @{ Uninstall = $true } | Should -Be 0
        $p = Join-Path $sb.ClaudeDir 'settings.json'
        Test-Path $p | Should -BeTrue
        $s = Get-Content $p -Raw | ConvertFrom-Json
        $s.advisorModel | Should -BeNullOrEmpty
        $s.modelPicker | Should -BeNullOrEmpty
    }
    It 'leaves a folder with none of our files exactly as it was' {
        New-Item -ItemType Directory -Force (Join-Path $sb.InstallDir 'bin'), (Join-Path $sb.InstallDir 'secrets') | Out-Null
        'mine' | Set-Content (Join-Path $sb.InstallDir 'notes.txt')
        '@echo off' | Set-Content (Join-Path $sb.InstallDir 'bin/claude-inferhub.cmd')
        'OTHER=1' | Set-Content (Join-Path $sb.InstallDir 'secrets/other.env')
        $before = Get-InstallSnapshot $sb
        Invoke-SandboxInstall $sb -Extra @{ Uninstall = $true } | Should -Be 0
        Compare-Snapshot $before (Get-InstallSnapshot $sb) | Should -Be ''
    }
    It 'still deletes an empty folder' {
        New-Item -ItemType Directory -Force $sb.InstallDir | Out-Null
        Invoke-SandboxInstall $sb -Extra @{ Uninstall = $true } | Should -Be 0
        Test-Path -LiteralPath $sb.InstallDir | Should -BeFalse
    }
}

Describe 'Uninstall relations (v1.0.1 #2)' -Tag 'Metamorphic' {
    It 'with or without install.json, the user''s settings.json ends up the same' {
        $a = New-Sandbox; $b = New-Sandbox
        try {
            foreach ($s in $a, $b) {
                New-Item -ItemType Directory -Force $s.ClaudeDir | Out-Null
                '{"theme":"dark","env":{"A":"1"}}' | Set-Content (Join-Path $s.ClaudeDir 'settings.json')
                Invoke-SandboxInstall $s -Extra @{ InferHubKey = 'ih-m' } | Should -Be 0
            }
            Remove-Item -LiteralPath (Join-Path $b.InstallDir 'install.json')
            Invoke-SandboxInstall $a -Extra @{ Uninstall = $true } | Should -Be 0
            Invoke-SandboxInstall $b -Extra @{ Uninstall = $true } | Should -Be 0
            (Get-Content (Join-Path $a.ClaudeDir 'settings.json') -Raw) | Should -Be (Get-Content (Join-Path $b.ClaudeDir 'settings.json') -Raw)
            Test-Path (Join-Path $b.ClaudeDir 'agents/planner.md') | Should -Be (Test-Path (Join-Path $a.ClaudeDir 'agents/planner.md'))
        } finally { Remove-Sandbox $a; Remove-Sandbox $b }
    }
}

Describe 'Port range (v1.0.1 #3)' -Tag 'Spec' {
    BeforeEach { $script:sb = New-Sandbox }
    AfterEach { Remove-Sandbox $script:sb }

    It 'rejects -StartPort <_> with exit 2' -ForEach @(0, -1, 65536, 70000) {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; StartPort = $_ } | Should -Be 2
        Test-Path -LiteralPath $sb.InstallDir | Should -BeFalse
    }
    It 'accepts -StartPort 65535' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; StartPort = 65535 } | Should -Be 0
        (Read-CclInstallState -InstallDir $sb.InstallDir).port | Should -Be 65535
    }
    It 'Select-CclPort accepts low ports such as <_>' -ForEach @(1, 80, 1023) {
        Select-CclPort -Start $_ -Saved 0 -Probe { param($p) 'free' } | Should -Be $_
    }
    It 'Select-CclPort throws CCL_BAD_PORT for start <_>' -ForEach @(0, -5, 65536) {
        { Select-CclPort -Start $_ -Saved 0 -Probe { param($p) 'free' } } | Should -Throw '*CCL_BAD_PORT*'
    }
    It 'Select-CclPort never probes past 65535' {
        $script:probed = [Collections.Generic.List[int]]::new()
        { Select-CclPort -Start 65530 -Saved 0 -Count 100 -Probe { param($p) $script:probed.Add($p); 'foreign' } } | Should -Throw '*CCL_NO_PORT*'
        ($script:probed | Measure-Object -Maximum).Maximum | Should -Be 65535
    }
    It 'Select-CclPort ignores a saved port outside the range (<_>)' -ForEach @(70000, -3) {
        $script:probed = [Collections.Generic.List[int]]::new()
        Select-CclPort -Start 4000 -Saved $_ -Probe { param($p) $script:probed.Add($p); 'free' } | Should -Be 4000
        $script:probed | Should -Not -Contain $_
    }
}

Describe 'Port range invariants (v1.0.1 #3)' -Tag 'Property' {
    It 'always returns a port in 1..65535 that is not foreign (seed <_>)' -ForEach (1..40) {
        $rng = [Random]::new(9000 + $_)
        $start = @(1, 2, 1023, 1024, 65400, 65535, $rng.Next(1, 65536))[$rng.Next(0, 7)]
        $states = @{}
        $probe = { param($p) if (-not $states.ContainsKey($p)) { $states[$p] = @('free', 'foreign', 'foreign')[$rng.Next(0, 3)] }; $states[$p] }.GetNewClosure()
        try { $got = Select-CclPort -Start $start -Saved 0 -Count 50 -Probe $probe } catch { $_.Exception.Message | Should -Match 'CCL_NO_PORT'; return }
        $got | Should -BeGreaterOrEqual 1
        $got | Should -BeLessOrEqual 65535
        $states[$got] | Should -Not -Be 'foreign'
    }
}

Describe 'settings.json edge cases through the installer (v1.0.1 #4, #5)' -Tag 'Spec' {
    BeforeEach { $script:sb = New-Sandbox }
    AfterEach {
        $p = Join-Path $script:sb.ClaudeDir 'settings.json'
        if (Test-Path $p) { Set-ItemProperty -LiteralPath $p -Name IsReadOnly -Value $false }
        Remove-Sandbox $script:sb
    }

    It 'treats a <Name> settings.json as {}' -ForEach @(@{ Name = 'empty'; Text = '' }, @{ Name = 'whitespace-only'; Text = "  `r`n `t" }) {
        New-Item -ItemType Directory -Force $sb.ClaudeDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $sb.ClaudeDir 'settings.json'), $Text)
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x' } | Should -Be 0
        (Get-Content (Join-Path $sb.ClaudeDir 'settings.json') -Raw | ConvertFrom-Json).advisorModel | Should -Be 'fable'
    }
    It 'leaves a read-only settings.json untouched and warns' {
        New-Item -ItemType Directory -Force $sb.ClaudeDir | Out-Null
        $p = Join-Path $sb.ClaudeDir 'settings.json'
        [IO.File]::WriteAllText($p, '{"theme":"dark"}')
        Set-ItemProperty -LiteralPath $p -Name IsReadOnly -Value $true
        $out = & { Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x' } } 3>&1 6>&1 | Out-String
        [IO.File]::ReadAllText($p) | Should -Be '{"theme":"dark"}'
        (Get-Item -LiteralPath $p).IsReadOnly | Should -BeTrue
        $out | Should -Match 'read-only'
        Test-Path (Join-Path $sb.InstallDir 'install.json') | Should -BeTrue
    }
}

# ---------------------------------------------------------------- v1.0.1 #7: one self-contained folder

Describe 'Tool versions and plan (v1.0.1 #7)' -Tag 'Spec' {
    It 'Python <V> is usable: <Ok>' -ForEach @(
        @{ V = '3.9.18'; Ok = $false }, @{ V = '3.10.0'; Ok = $true }, @{ V = '3.12.10'; Ok = $true }, @{ V = '3.13.7'; Ok = $true },
        @{ V = '3.14.0'; Ok = $false }, @{ V = '2.7.18'; Ok = $false }, @{ V = 'Python 3.12.1'; Ok = $true }, @{ V = 'garbage'; Ok = $false }, @{ V = ''; Ok = $false }
    ) {
        Test-CclPythonVersion -Version $V | Should -Be $Ok
    }
    It 'Node <V> is usable: <Ok>' -ForEach @(
        @{ V = 'v16.20.2'; Ok = $false }, @{ V = 'v17.9.1'; Ok = $false }, @{ V = 'v18.0.0'; Ok = $true }, @{ V = '18.19.1'; Ok = $true },
        @{ V = 'v24.21.0'; Ok = $true }, @{ V = 'x'; Ok = $false }, @{ V = ''; Ok = $false }
    ) {
        Test-CclNodeVersion -Version $V | Should -Be $Ok
    }
    It 'reuses good Python, Node, uv and pnpm, and bundles git and Claude Code by default' {
        $found = @{ python = @{ path = 'p'; version = '3.12.1' }; node = @{ path = 'n'; version = 'v22.1.0' }; uv = @{ path = 'u'; version = '0.12' }
            pnpm = @{ path = 'pn'; version = '10' }; git = @{ path = 'g'; version = '2.50' }; claude = @{ path = 'c'; version = '2.1' } }
        $plan = Get-CclToolPlan -Found $found
        $plan.python | Should -Be 'reuse'; $plan.node | Should -Be 'reuse'; $plan.uv | Should -Be 'reuse'; $plan.pnpm | Should -Be 'reuse'
        $plan.git | Should -Be 'bundle'; $plan.claude | Should -Be 'bundle'
        $all = Get-CclToolPlan -Found $found -UseSystemTools
        foreach ($n in 'python', 'node', 'uv', 'pnpm', 'git', 'claude') { $all[$n] | Should -Be 'reuse' }
        $none = Get-CclToolPlan -Found $found -PortableOnly -UseSystemTools
        foreach ($n in 'python', 'node', 'uv', 'pnpm', 'git', 'claude') { $none[$n] | Should -Be 'bundle' }
    }
    It 'bundles a too-old Python or Node and anything missing' {
        $plan = Get-CclToolPlan -Found @{ python = @{ path = 'p'; version = '3.9.1' }; node = @{ path = 'n'; version = 'v16.0.0' } }
        foreach ($n in 'python', 'node', 'uv', 'pnpm', 'git', 'claude') { $plan[$n] | Should -Be 'bundle' }
    }
    It 'keeps every tool variable inside the folder for <_>' -ForEach @(0, 1, 2, 3, 4) {
        # The last part of each non-ASCII sample path, under the real temp folder (Linux pwsh has no C: drive).
        $names = @($script:Jose, $script:Cjk, ([string][char]0x00DC + 'ber ' + [char]0x00C5 + 'se'), ('M' + [char]0x00FC + 'ller (x86) & co'), 'plain')
        $dir = Join-Path ([IO.Path]::GetTempPath()) ($names[$_] + ' ccl')
        $e = Get-CclToolEnv -InstallDir $dir
        $e.CLAUDE_CONFIG_DIR | Should -Be (Join-Path $dir 'claude-config')
        $e.UV_CACHE_DIR | Should -Be (Join-Path (Join-Path $dir 'cache') 'uv')
        $e.UV_PYTHON_INSTALL_DIR | Should -Be (Join-Path (Join-Path $dir 'tools') 'python')
        $e.npm_config_store_dir | Should -Be (Join-Path (Join-Path $dir 'cache') 'pnpm-store')
        $e.PNPM_HOME | Should -Be (Join-Path (Join-Path $dir 'tools') 'pnpm')
        $e.DISABLE_AUTOUPDATER | Should -Be '1'
    }
    It 'accepts a missing, empty or earlier-install folder and refuses any other' {
        $d = Join-Path $TestDrive ('t-' + [guid]::NewGuid().ToString('N'))
        Test-CclInstallTarget -InstallDir $d | Should -BeTrue
        New-Item -ItemType Directory -Force $d | Out-Null
        Test-CclInstallTarget -InstallDir $d | Should -BeTrue
        'x' | Set-Content (Join-Path $d 'notes.txt')
        Test-CclInstallTarget -InstallDir $d | Should -BeFalse
        '{}' | Set-Content (Join-Path $d 'install.json')
        Test-CclInstallTarget -InstallDir $d | Should -BeTrue
        $e = Join-Path $TestDrive ('e-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force (Join-Path $e 'app/windows') | Out-Null
        'x' | Set-Content (Join-Path $e 'app/windows/install.ps1')
        Test-CclInstallTarget -InstallDir $e | Should -BeTrue
    }
}

Describe 'Tool plan invariants (v1.0.1 #7)' -Tag 'Property' {
    It 'never reuses what is missing or unsuitable, and -PortableOnly bundles all (seed <_>)' -ForEach (1..40) {
        $rng = [Random]::new(7100 + $_)
        $found = @{}
        foreach ($n in 'python', 'node', 'uv', 'pnpm', 'git', 'claude') {
            if ($rng.Next(0, 3) -gt 0) {
                $v = $(switch ($n) { 'python' { '3.' + $rng.Next(6, 16) + '.1' } 'node' { 'v' + $rng.Next(12, 26) + '.0.0' } default { '1.0' } })
                $found[$n] = @{ path = "/x/$n"; version = $v }
            }
        }
        $po = [bool]$rng.Next(0, 2); $us = [bool]$rng.Next(0, 2)
        $plan = Get-CclToolPlan -Found $found -PortableOnly:$po -UseSystemTools:$us
        foreach ($n in 'python', 'node', 'uv', 'pnpm', 'git', 'claude') {
            $plan[$n] | Should -BeIn @('reuse', 'bundle')
            if ($plan[$n] -eq 'reuse') {
                $found.ContainsKey($n) | Should -BeTrue
                $po | Should -BeFalse
                if ($n -eq 'python') { Test-CclPythonVersion $found.python.version | Should -BeTrue }
                if ($n -eq 'node') { Test-CclNodeVersion $found.node.version | Should -BeTrue }
                if ($n -in 'git', 'claude') { $us | Should -BeTrue }
            }
            # -UseSystemTools never turns a reuse into a bundle.
            if ((Get-CclToolPlan -Found $found -PortableOnly:$po)[$n] -eq 'reuse') { $plan[$n] | Should -Be 'reuse' }
        }
    }
    It 'every folder variable starts with the install folder (seed <_>)' -ForEach (1..20) {
        $rng = [Random]::new(7300 + $_)
        $name = (-join $(for ($i = 0; $i -lt $rng.Next(1, 16); $i++) { [char]$rng.Next(0x20, 0x3000) })) -replace '[\\/:*?"<>|]', '_'
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('ccl ' + $name)
        $e = Get-CclToolEnv -InstallDir $dir
        foreach ($k in $e.Keys) {
            if ($k -in 'DISABLE_AUTOUPDATER', 'PATH') { continue }
            ([string]$e[$k]).StartsWith($dir) | Should -BeTrue -Because $k
        }
        foreach ($p in @($e.PATH)) { ([string]$p).StartsWith($dir) | Should -BeTrue }
    }
}

Describe 'Choosing the install folder (v1.0.1 #7)' -Tag 'Spec' {
    BeforeEach {
        $script:sb = New-Sandbox
        $script:saved = @{ USERPROFILE = $env:USERPROFILE; LOCALAPPDATA = $env:LOCALAPPDATA; CCL_INSTALL_DIR = $env:CCL_INSTALL_DIR }
        $env:USERPROFILE = Join-Path $sb.Root 'home'
        $env:LOCALAPPDATA = Join-Path $sb.Root 'home/AppData/Local'
        Remove-Item Env:CCL_INSTALL_DIR -ErrorAction SilentlyContinue
    }
    AfterEach {
        foreach ($k in $script:saved.Keys) { if ($null -eq $script:saved[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue } else { Set-Item "Env:$k" $script:saved[$k] } }
        Remove-Sandbox $script:sb
    }

    It 'asks for the folder, suggests %USERPROFILE%\claude-code-launcher and installs where the answer says' {
        $target = Join-Path $sb.Root ('picked ' + $script:Jose)
        $script:suggested = $null
        $script:target = $target
        $rc = Invoke-SandboxInstall $sb -Extra @{ InstallDir = $null; InferHubKey = 'ih-x'; SkipTinyFish = $true; NonInteractive = $false
            LocationPrompt = { param($s) $script:suggested = $s; $script:target } }
        $rc | Should -Be 0
        $script:suggested | Should -Be (Join-Path $env:USERPROFILE 'claude-code-launcher')
        Test-Path -LiteralPath (Join-Path $target 'install.json') | Should -BeTrue
    }
    It 'takes the suggestion on an empty answer' {
        $rc = Invoke-SandboxInstall $sb -Extra @{ InstallDir = $null; InferHubKey = 'ih-x'; SkipTinyFish = $true; NonInteractive = $false; LocationPrompt = { param($s) '' } }
        $rc | Should -Be 0
        Test-Path -LiteralPath (Join-Path $env:USERPROFILE 'claude-code-launcher/install.json') | Should -BeTrue
    }
    It 'uses the suggestion without asking when non-interactive' {
        $rc = Invoke-SandboxInstall $sb -Extra @{ InstallDir = $null; InferHubKey = 'ih-x'; LocationPrompt = { throw 'asked' } }
        $rc | Should -Be 0
        Test-Path -LiteralPath (Join-Path $env:USERPROFILE 'claude-code-launcher/install.json') | Should -BeTrue
    }
    It 'suggests an existing v1.0.0 install folder' {
        $old = Join-Path $env:LOCALAPPDATA 'claude-code-launcher'
        New-Item -ItemType Directory -Force $old | Out-Null
        '{"schema":"claude-code-launcher.install.v1","port":4000,"instance_id":"' + ('b' * 32) + '"}' | Set-Content (Join-Path $old 'install.json')
        $script:suggested = $null
        $rc = Invoke-SandboxInstall $sb -Extra @{ InstallDir = $null; InferHubKey = 'ih-x'; SkipTinyFish = $true; NonInteractive = $false; LocationPrompt = { param($s) $script:suggested = $s; '' } }
        $rc | Should -Be 0
        $script:suggested | Should -Be $old
    }
    It 'asks again for a folder that holds other files, and installs into the next answer' {
        $bad = Join-Path $sb.Root 'Documents'
        New-Item -ItemType Directory -Force $bad | Out-Null
        'mine' | Set-Content (Join-Path $bad 'letter.txt')
        $good = Join-Path $sb.Root 'good'
        $script:answers = [Collections.Generic.Queue[string]]::new([string[]]@($bad, $good))
        $rc = Invoke-SandboxInstall $sb -Extra @{ InstallDir = $null; InferHubKey = 'ih-x'; SkipTinyFish = $true; NonInteractive = $false; LocationPrompt = { param($s) $script:answers.Dequeue() } }
        $rc | Should -Be 0
        @(Get-ChildItem -LiteralPath $bad -Force).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $good 'install.json') | Should -BeTrue
    }
    It 'gives up with exit 2 after three such answers' {
        $bad = Join-Path $sb.Root 'Documents'
        New-Item -ItemType Directory -Force $bad | Out-Null
        'mine' | Set-Content (Join-Path $bad 'letter.txt')
        $before = Get-TreeSnapshot $bad
        $rc = Invoke-SandboxInstall $sb -Extra @{ InstallDir = $null; InferHubKey = 'ih-x'; SkipTinyFish = $true; NonInteractive = $false; LocationPrompt = { param($s) $bad }.GetNewClosure() }
        $rc | Should -Be 2
        Compare-Snapshot $before (Get-TreeSnapshot $bad) | Should -Be ''
    }
    It 'refuses -InstallDir pointing at a folder with other files (exit 2, untouched)' {
        $bad = Join-Path $sb.Root 'Documents'
        New-Item -ItemType Directory -Force $bad | Out-Null
        'mine' | Set-Content (Join-Path $bad 'letter.txt')
        $before = Get-TreeSnapshot $bad
        Invoke-SandboxInstall $sb -Extra @{ InstallDir = $bad; InferHubKey = 'ih-x' } | Should -Be 2
        Compare-Snapshot $before (Get-TreeSnapshot $bad) | Should -Be ''
    }
}

Describe 'Self-contained install with private tools (v1.0.1 #7)' -Tag 'Spec' -Skip:(-not $script:PosixHost) {
    BeforeEach {
        $script:sb = New-Sandbox
        $script:home0 = Join-Path $sb.Root 'home'
        $script:fake = New-FakeToolSpecs -Dir (Join-Path $sb.Root 'dl')
        $script:envBefore = @{ PATH = $env:PATH; UV_CACHE_DIR = $env:UV_CACHE_DIR; PNPM_HOME = $env:PNPM_HOME }
    }
    AfterEach { Remove-Sandbox $script:sb }

    It 'puts every tool, cache and Claude config in the folder and nothing in the profile' {
        $before = Get-TreeSnapshot $home0
        $rc = Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; SkipPrereqs = $false; PortableOnly = $true; ClaudeConfigDir = $null
            ToolSpecs = $fake; ToolProbe = { @{} } }
        $rc | Should -Be 0
        Compare-Snapshot $before (Get-TreeSnapshot $home0) | Should -Be ''
        $st = Read-CclInstallState -InstallDir $sb.InstallDir
        $st.schema | Should -Be 'claude-code-launcher.install.v2'
        $st.claude_config_dir | Should -Be (Join-Path $sb.InstallDir 'claude-config')
        foreach ($n in 'python', 'node', 'uv', 'pnpm', 'git', 'claude', 'poppler') {
            $st.tools.$n.source | Should -Be 'bundled' -Because $n
            ([string]$st.tools.$n.path).StartsWith($sb.InstallDir) | Should -BeTrue -Because $n
            Test-Path -LiteralPath $st.tools.$n.path | Should -BeTrue -Because $n
        }
        (Get-Content (Join-Path $sb.InstallDir 'claude-config/settings.json') -Raw | ConvertFrom-Json).advisorModel | Should -Be 'fable'
        Test-Path (Join-Path $sb.InstallDir 'claude-config/agents/planner.md') | Should -BeTrue
    }
    It 'leaves the caller''s environment as it was' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; SkipPrereqs = $false; PortableOnly = $true; ClaudeConfigDir = $null; ToolSpecs = $fake; ToolProbe = { @{} } } | Should -Be 0
        $env:PATH | Should -Be $envBefore.PATH
        $env:UV_CACHE_DIR | Should -Be $envBefore.UV_CACHE_DIR
        $env:PNPM_HOME | Should -Be $envBefore.PNPM_HOME
        $env:CLAUDE_CONFIG_DIR | Should -Be $sb.ClaudeDir
    }
    It 'stops with exit 3 on a checksum mismatch and leaves no half tool' {
        $bad = New-FakeToolSpecs -Dir (Join-Path $sb.Root 'dl-bad') -BadHash
        $rc = Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; SkipPrereqs = $false; PortableOnly = $true; ClaudeConfigDir = $null; ToolSpecs = $bad; ToolProbe = { @{} } }
        $rc | Should -Be 3
        Test-Path -LiteralPath (Join-Path $sb.InstallDir 'tools/uv') | Should -BeFalse
    }
    It 'uninstall deletes the folder and leaves the profile alone' {
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; SkipPrereqs = $false; PortableOnly = $true; ClaudeConfigDir = $null; ToolSpecs = $fake; ToolProbe = { @{} } } | Should -Be 0
        $before = Get-TreeSnapshot $home0
        Invoke-SandboxInstall $sb -Extra @{ Uninstall = $true } | Should -Be 0
        Test-Path -LiteralPath $sb.InstallDir | Should -BeFalse
        Compare-Snapshot $before (Get-TreeSnapshot $home0) | Should -Be ''
    }
}

Describe 'Self-contained install reusing the PC''s tools (v1.0.1 #7)' -Tag 'Spec' -Skip:(-not $script:PosixHost) {
    BeforeEach {
        $script:sb = New-Sandbox
        $script:home0 = Join-Path $sb.Root 'home'
        $script:fake = New-FakeToolSpecs -Dir (Join-Path $sb.Root 'dl')
        $script:pyFound = Get-HostPythonFound
    }
    AfterEach { Remove-Sandbox $script:sb }

    It 'reuses Python, Node, uv and pnpm, records them, downloads only git and Claude Code, and writes nothing outside' {
        $specs = Get-NoDownloadSpecs
        $specs.git = $fake.git; $specs.claude = $fake.claude
        $found = @{ python = $pyFound; node = @{ path = '/opt/node/bin/node'; version = 'v20.11.1' }; uv = @{ path = '/opt/uv/uv'; version = '0.12.0' }; pnpm = @{ path = '/opt/pnpm/pnpm'; version = '10.0.0' } }
        $before = Get-TreeSnapshot $home0
        $rc = Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; SkipPrereqs = $false; ClaudeConfigDir = $null; ToolSpecs = $specs; ToolProbe = { $found }.GetNewClosure() }
        $rc | Should -Be 0
        Compare-Snapshot $before (Get-TreeSnapshot $home0) | Should -Be ''
        $st = Read-CclInstallState -InstallDir $sb.InstallDir
        $st.tools.python.source | Should -Be 'reused'; $st.tools.python.path | Should -Be $pyFound.path
        $st.tools.node.source | Should -Be 'reused'; $st.tools.node.version | Should -Be 'v20.11.1'
        $st.tools.uv.source | Should -Be 'reused'; $st.tools.pnpm.source | Should -Be 'reused'
        $st.tools.git.source | Should -Be 'bundled'; $st.tools.claude.source | Should -Be 'bundled'
        foreach ($n in 'python', 'node', 'uv', 'pnpm') { Test-Path -LiteralPath (Join-Path $sb.InstallDir "tools/$n") | Should -BeFalse -Because $n }
        Test-Path (Join-Path $sb.InstallDir 'claude-config/settings.json') | Should -BeTrue
    }
    It 'with -UseSystemTools and everything found, downloads nothing' {
        $found = @{ python = $pyFound; node = @{ path = '/n'; version = 'v22.0.0' }; uv = @{ path = '/u'; version = '1' }; pnpm = @{ path = '/p'; version = '1' }
            git = @{ path = '/g'; version = '2.56.0' }; claude = @{ path = '/c'; version = '2.1.0' }; poppler = @{ path = '/pp/pdftoppm'; version = '24.08.0' } }
        $rc = Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; SkipPrereqs = $false; UseSystemTools = $true; ClaudeConfigDir = $null; ToolSpecs = (Get-NoDownloadSpecs); ToolProbe = { $found }.GetNewClosure() }
        $rc | Should -Be 0
        $st = Read-CclInstallState -InstallDir $sb.InstallDir
        foreach ($n in 'python', 'node', 'uv', 'pnpm', 'git', 'claude', 'poppler') { $st.tools.$n.source | Should -Be 'reused' -Because $n }
        @(Get-ChildItem -LiteralPath (Join-Path $sb.InstallDir 'tools') -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}

Describe 'Upgrading a v1.0.0 install (v1.0.1 #7)' -Tag 'Spec' {
    BeforeEach { $script:sb = New-Sandbox }
    AfterEach { Remove-Sandbox $script:sb }

    It 'moves Claude config into the folder and cleans what v1.0.0 left in the profile' {
        New-Item -ItemType Directory -Force $sb.ClaudeDir | Out-Null
        '{"theme":"dark"}' | Set-Content (Join-Path $sb.ClaudeDir 'settings.json')
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x' } | Should -Be 0     # like v1.0.0: config in the profile
        $p = Join-Path $sb.InstallDir 'install.json'
        $j = Get-Content $p -Raw | ConvertFrom-Json
        $v1 = [ordered]@{ schema = 'claude-code-launcher.install.v1'; version = '1.0.0-windows'; ref = 'v1.0.0-windows'; port = $j.port
            instance_id = $j.instance_id; task_name = $j.task_name; claude_settings_created = $false }
        ($v1 | ConvertTo-Json) | Set-Content $p
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; ClaudeConfigDir = $null } | Should -Be 0
        $old = Get-Content (Join-Path $sb.ClaudeDir 'settings.json') -Raw | ConvertFrom-Json
        @($old.PSObject.Properties.Name) | Should -Be @('theme')
        Test-Path (Join-Path $sb.ClaudeDir 'agents/planner.md') | Should -BeFalse
        (Get-Content (Join-Path $sb.InstallDir 'claude-config/settings.json') -Raw | ConvertFrom-Json).advisorModel | Should -Be 'fable'
        (Read-CclInstallState -InstallDir $sb.InstallDir).claude_config_dir | Should -Be (Join-Path $sb.InstallDir 'claude-config')
    }
}

Describe 'Self-contained relations (v1.0.1 #7)' -Tag 'Metamorphic' -Skip:(-not $script:PosixHost) {
    It 'reusing or bundling the tools gives the same app, secrets and Claude config' {
        $a = New-Sandbox; $b = New-Sandbox
        try {
            $fa = New-FakeToolSpecs -Dir (Join-Path $a.Root 'dl'); $fb = New-FakeToolSpecs -Dir (Join-Path $b.Root 'dl')
            $py = Get-HostPythonFound
            $found = @{ python = $py; node = @{ path = '/n'; version = 'v22.0.0' }; uv = @{ path = '/u'; version = '1' }; pnpm = @{ path = '/p'; version = '1' } }
            Invoke-SandboxInstall $a -Extra @{ InferHubKey = 'ih-m'; SkipPrereqs = $false; PortableOnly = $true; ClaudeConfigDir = $null; ToolSpecs = $fa; ToolProbe = { @{} } } | Should -Be 0
            Invoke-SandboxInstall $b -Extra @{ InferHubKey = 'ih-m'; SkipPrereqs = $false; ClaudeConfigDir = $null; ToolSpecs = $fb; ToolProbe = { $found }.GetNewClosure() } | Should -Be 0
            foreach ($sub in 'app', 'secrets', 'claude-config', 'bin') {
                Compare-Snapshot (Get-TreeSnapshot (Join-Path $a.InstallDir $sub)) (Get-TreeSnapshot (Join-Path $b.InstallDir $sub)) | Should -Be '' -Because $sub
            }
        } finally { Remove-Sandbox $a; Remove-Sandbox $b }
    }
    It 'a second install reuses the private tools it already has (no downloads) and changes no state' {
        $sb = New-Sandbox
        try {
            $f = New-FakeToolSpecs -Dir (Join-Path $sb.Root 'dl')
            Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-m'; SkipPrereqs = $false; PortableOnly = $true; ClaudeConfigDir = $null; ToolSpecs = $f; ToolProbe = { @{} } } | Should -Be 0
            $one = Get-InstallSnapshot $sb -KeepInstance
            $tools1 = Get-TreeSnapshot (Join-Path $sb.InstallDir 'tools')
            $nd = Get-NoDownloadSpecs
            foreach ($n in 'uv', 'node', 'pnpm', 'git', 'claude', 'poppler') { $nd[$n].version = $f[$n].version; $nd[$n].exe = $f[$n].exe }
            Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-m'; SkipPrereqs = $false; PortableOnly = $true; ClaudeConfigDir = $null; ToolSpecs = $nd; ToolProbe = { @{} } } | Should -Be 0
            Compare-Snapshot $one (Get-InstallSnapshot $sb -KeepInstance) | Should -Be ''
            Compare-Snapshot $tools1 (Get-TreeSnapshot (Join-Path $sb.InstallDir 'tools')) | Should -Be ''
        } finally { Remove-Sandbox $sb }
    }
}


Describe 'Poppler for PDF pages (pdftoppm)' -Tag 'Spec' {
    It 'reuses a pdftoppm already on the PC and bundles it otherwise' {
        (Get-CclToolPlan -Found @{ poppler = @{ path = '/usr/bin/pdftoppm'; version = '24.02.0' } }).poppler | Should -Be 'reuse'
        (Get-CclToolPlan -Found @{}).poppler | Should -Be 'bundle'
        (Get-CclToolPlan -Found @{ poppler = @{ path = '/usr/bin/pdftoppm'; version = '24.02.0' } } -PortableOnly).poppler | Should -Be 'bundle'
    }
    It 'pins the official poppler-windows release zip by SHA-256' {
        $s = $script:CclToolSpecs.poppler
        $s.url | Should -Match '^https://github\.com/oschwartz10612/poppler-windows/releases/download/'
        $s.sha256 | Should -Match '^[0-9a-f]{64}$'
        $s.exe | Should -Be 'Library\bin\pdftoppm.exe'
        $script:CclToolOrder | Should -Contain 'poppler'
    }
    It 'puts the private poppler bin, or the reused pdftoppm folder, on the PATH the launcher sets' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) 'ccl poppler'
        $front = @((Get-CclToolEnv -InstallDir $dir).PATH)
        $front | Should -Contain (Join-Path (Join-Path (Join-Path (Join-Path $dir 'tools') 'poppler') 'Library') 'bin')
        $st = [pscustomobject]@{ claude_config_dir = (Join-Path $dir 'claude-config'); tools = [pscustomobject]@{ poppler = [pscustomobject]@{ source = 'reused'; path = (Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'pp bin') 'pdftoppm.exe'); version = '24' } } }
        @((Get-CclToolEnv -InstallDir $dir -State $st).PATH) | Should -Contain (Join-Path ([IO.Path]::GetTempPath()) 'pp bin')
    }
}

Describe 'Poppler in a real sandbox install' -Tag 'Spec' -Skip:(-not $script:PosixHost) {
    BeforeEach { $script:sb = New-Sandbox; $script:pyFound = Get-HostPythonFound }
    AfterEach { Remove-Sandbox $script:sb }
    It 'unpacks the private pdftoppm into tools\poppler and it runs' {
        $fake = New-FakeToolSpecs -Dir (Join-Path $sb.Root 'dl')
        Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; SkipPrereqs = $false; PortableOnly = $true; ClaudeConfigDir = $null; ToolSpecs = $fake; ToolProbe = { @{} } } | Should -Be 0
        $st = Read-CclInstallState -InstallDir $sb.InstallDir
        $st.tools.poppler.path | Should -Be (Join-Path $sb.InstallDir 'tools/poppler/Library/bin/pdftoppm.exe')
        (& $st.tools.poppler.path -v 2>&1 | Out-String) | Should -Match 'pdftoppm version'
    }
    It 'a poppler download that fails only warns; the rest of the install goes on' {
        $found = @{ python = $pyFound; node = @{ path = '/n'; version = 'v22.0.0' }; uv = @{ path = '/u'; version = '1' }; pnpm = @{ path = '/p'; version = '1' }
            git = @{ path = '/g'; version = '2.56.0' }; claude = @{ path = '/c'; version = '2.1.0' } }
        $specs = Get-NoDownloadSpecs
        $specs.poppler = @{ version = 'x'; url = (Join-Path $sb.Root 'no-such.zip'); sha256 = ('0' * 64); kind = 'zip'; exe = 'Library/bin/pdftoppm.exe' }
        $rc = Invoke-SandboxInstall $sb -Extra @{ InferHubKey = 'ih-x'; SkipPrereqs = $false; UseSystemTools = $true; ClaudeConfigDir = $null; ToolSpecs = $specs; ToolProbe = { $found }.GetNewClosure() }
        $rc | Should -Be 0
        $st = Read-CclInstallState -InstallDir $sb.InstallDir
        $st.tools.PSObject.Properties.Name | Should -Not -Contain 'poppler'
        Test-Path -LiteralPath (Join-Path $sb.InstallDir 'tools/poppler') | Should -BeFalse
    }
}
