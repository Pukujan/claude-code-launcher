# Pester 5 tests for windows/install.ps1 (docs/specs/windows-package.md).
# Tags: Spec (examples), Property (table invariants), Metamorphic (relations between runs).
# Runs on Linux and Windows pwsh. Never installs prerequisites, never registers a task,
# never touches the real PATH or ~/.claude, never binds port 4000.

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
        param($Sandbox, [hashtable]$Extra = @{}, [scriptblock]$KeyPrompt = $null, [hashtable]$Environment = $null)
        $env:CLAUDE_CONFIG_DIR = $Sandbox.ClaudeDir
        $p = @{
            InstallDir = $Sandbox.InstallDir; Source = $script:Repo; SkipPrereqs = $true; SkipVenv = $true
            NoTask = $true; NoPath = $true; NoStart = $true; NonInteractive = ($null -eq $KeyPrompt)
            StartPort = 47100
        }
        foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
        if ($KeyPrompt) { $p.KeyPrompt = $KeyPrompt }
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
        @($j.PSObject.Properties.Name | Sort-Object) | Should -Be @('claude_settings_created', 'instance_id', 'port', 'ref', 'schema', 'task_name', 'version')
        $j.schema | Should -Be 'claude-code-launcher.install.v1'
        $j.task_name | Should -Be 'claude-code-launcher-proxy'
        (Read-CclInstallState -InstallDir $d).port | Should -Be 4001
    }
    It 'shim runs the launcher with CCL_HOME and handles --set-key and --uninstall' {
        $t = Get-CclShimText -InstallDir 'X:\inst'
        $t | Should -Match 'CCL_HOME=X:\\inst'
        $t | Should -Match 'launch-claude-inferhub\.ps1'
        $t | Should -Match '--set-key'
        $t | Should -Match '-ChangeKey'
        $t | Should -Match '--uninstall'
        $t | Should -Match '-Uninstall'
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
            $canon = 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8-sig")), sort_keys=True))'
            $ca = & $py -c $canon (Join-Path $a.ClaudeDir 'settings.json')
            $cb = & $py -c $canon (Join-Path $b.ClaudeDir 'settings.json')
            $ca | Should -Not -BeNullOrEmpty
            $ca | Should -Be $cb
        } finally { Remove-Sandbox $a; Remove-Sandbox $b }
    }
}
