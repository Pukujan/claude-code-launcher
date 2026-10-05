# End-to-end test of windows/install.ps1 on a real Windows machine (the CI windows-installer job).
# Tag: E2E. Skipped elsewhere. Real installs without -SkipPrereqs: one reuses the runner's tools
# (and builds the real venv, registers the logon task and starts the proxy next to a fake "other
# LiteLLM" that holds the start port), one fetches private copies of every tool (-PortableOnly).
# Both install outside the user profile, and the whole profile (except %TEMP%) is snapshotted
# before and after to prove nothing lands there. Never uses port 4000.

BeforeDiscovery { $script:OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows }

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Installer = Join-Path $Repo 'windows\install.ps1'
    # Outside the profile, so any write into the profile shows up in the snapshot.
    $script:E2EBase = $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { Join-Path $env:SystemDrive 'ccl-e2e' })

    function Invoke-RealInstall {
        # A real install in a child Windows PowerShell, prerequisites included.
        param([string]$InstallDir, [string[]]$More = @())
        $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Installer, '-Source', $script:Repo,
            '-InstallDir', $InstallDir, '-NonInteractive') + $More
        $log = & powershell.exe @argv *>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Log = $log }
    }

    function Get-ProfileSnapshot {
        # Every file and folder under %USERPROFILE% with size and time, skipping %TEMP% and the
        # folders Windows and PowerShell themselves keep writing to.
        $prof = $env:USERPROFILE
        $xd = @($env:TEMP, [IO.Path]::GetTempPath().TrimEnd('\')) | Select-Object -Unique
        $lines = & robocopy.exe $prof (Join-Path $env:SystemDrive 'ccl-null-target') /L /S /E /NJH /NJS /NP /FP /TS /BYTES /XJ /R:0 /W:0 /NC /XD @xd 2>&1
        $global:LASTEXITCODE = 0
        $noise = '\\AppData\\(Local|Roaming|LocalLow)\\(Microsoft|Packages|PowerShell|NuGet|D3DSCache|CrashDumps)(\\|$)|\\ntuser|\\AppData\\Local\\Temp(\\|$)'
        $set = @{}
        foreach ($l in $lines) { $s = ("$l" -replace '\s+', ' ').Trim(); if ($s -and $s -notmatch $noise) { $set[$s] = $true } }
        return $set
    }

    function Compare-ProfileSnapshot($Before, $After) {
        $d = @()
        foreach ($k in $After.Keys) { if (-not $Before.ContainsKey($k)) { $d += "+ $k" } }
        foreach ($k in $Before.Keys) { if (-not $After.ContainsKey($k)) { $d += "- $k" } }
        return ($d | Sort-Object) -join "`n"
    }
}

Describe 'Windows install end to end, reusing the runner''s tools' -Tag 'E2E' -Skip:(-not $script:OnWindows) {
    BeforeAll {
        $script:Root = Join-Path $E2EBase ('ccl e2e reuse ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:InstallDir = Join-Path $Root 'install'
        $script:ProfileBefore = Get-ProfileSnapshot
        $script:UserPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
        $script:Key = 'ih-e2e-' + [guid]::NewGuid().ToString('N')
        $script:TfKey = 'tf-e2e-' + [guid]::NewGuid().ToString('N')
        $script:StartPort = 47400
        # The "other LiteLLM": answers /health/liveliness on the start port, no identity.
        $script:Other = [Net.HttpListener]::new()
        $Other.Prefixes.Add("http://127.0.0.1:$StartPort/")
        $Other.Start()
        # A plain runspace, not Start-ThreadJob: Windows PowerShell 5.1 has no ThreadJob module.
        $script:OtherPs = [powershell]::Create()
        $null = $OtherPs.AddScript({
            param($l)
            while ($l.IsListening) {
                try { $c = $l.GetContext() } catch { break }
                $c.Response.StatusCode = $(if ($c.Request.Url.AbsolutePath -like '/health/*') { 200 } else { 404 })
                $c.Response.Close()
            }
        }).AddArgument($Other)
        $script:OtherHandle = $OtherPs.BeginInvoke()
        $r = Invoke-RealInstall -InstallDir $InstallDir -More @('-InferHubKey', $Key, '-TinyFishKey', $TfKey, '-StartPort', "$StartPort", '-NoPath')
        $script:Log = $r.Log
        $script:InstallExit = $r.Code
        Write-Host $Log
        $script:ProfileAfterInstall = Get-ProfileSnapshot
    }
    AfterAll {
        try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'app\windows\install.ps1') -InstallDir $InstallDir -Uninstall -NonInteractive *>&1 | Out-Null } catch {}
        try { $Other.Stop() } catch {}
        try { $OtherPs.Dispose() } catch {}
        if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'installs with exit 0' { $InstallExit | Should -Be 0 }
    It 'writes nothing into the user profile (outside %TEMP%) and leaves the user PATH alone' {
        Compare-ProfileSnapshot $ProfileBefore $ProfileAfterInstall | Should -Be ''
        [Environment]::GetEnvironmentVariable('Path', 'User') | Should -Be $UserPathBefore
    }
    It 'records which tools it reused and which it bundled' {
        $st = Get-Content -LiteralPath (Join-Path $InstallDir 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ($st.tools | ConvertTo-Json -Depth 4)
        foreach ($n in 'python', 'node', 'uv', 'pnpm', 'git', 'claude', 'poppler') {
            $st.tools.$n.source | Should -BeIn @('reused', 'bundled') -Because $n
            Test-Path -LiteralPath $st.tools.$n.path | Should -BeTrue -Because $n
        }
        $st.tools.uv.source | Should -Be 'reused'        # setup-uv put uv on PATH
        $st.tools.python.source | Should -Be 'reused'    # the runner's Python 3.12
        $st.tools.node.source | Should -Be 'reused'      # the runner's Node
        $st.tools.git.source | Should -Be 'bundled'
        $st.tools.claude.source | Should -Be 'bundled'
        $st.tools.claude.path | Should -Be (Join-Path $InstallDir 'tools\claude\claude.exe')
        (& $st.tools.claude.path --version) | Should -Match '\d+\.\d+\.\d+'
    }
    It 'never prints the key' { $Log | Should -Not -BeLike "*$Key*" }
    It 'stores the TinyFish key without printing it' {
        $Log | Should -Not -BeLike "*$TfKey*"
        (Get-Content (Join-Path $InstallDir 'secrets\tinyfish.env') -Raw -Encoding UTF8) | Should -Be "TINYFISH_API_KEY=$TfKey`n"
        Get-Content (Join-Path $InstallDir 'logs\*.log') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue | Should -Not -BeLike "*$TfKey*"
    }
    It 'skips the port held by the other LiteLLM' {
        $port = (Get-Content (Join-Path $InstallDir 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json).port
        $port | Should -Not -Be $StartPort
        $port | Should -BeGreaterThan $StartPort
    }
    It 'registers the hidden logon task with the chosen port' {
        $port = (Get-Content (Join-Path $InstallDir 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json).port
        $t = Get-ScheduledTask -TaskName 'claude-code-launcher-proxy' -ErrorAction Stop
        $t.Actions[0].Execute | Should -Match 'conhost\.exe$'
        $t.Actions[0].Arguments | Should -Match "-Port $port"
        $t.Actions[0].Arguments | Should -Not -Match $Key
    }
    It 'runs our proxy on the chosen port (identity matches)' {
        $st = Get-Content (Join-Path $InstallDir 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $r = Invoke-RestMethod "http://127.0.0.1:$($st.port)/ccl/identity" -TimeoutSec 10
        $r.app | Should -Be 'claude-code-launcher'
        $r.instance | Should -Be $st.instance_id
    }
    It 'points Claude at the chosen port in non-interactive mode and syncs the advisor' {
        $st = Get-Content (Join-Path $InstallDir 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $env:CCL_HOME = $InstallDir
        try {
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'app\windows\launch-claude-inferhub.ps1') --non-interactive --print-env json
        } finally { Remove-Item Env:CCL_HOME }
        $doc = ($out | Select-Object -Last 1) | ConvertFrom-Json
        $doc.set.ANTHROPIC_BASE_URL | Should -Be "http://127.0.0.1:$($st.port)"
        $doc.set.CLAUDE_CONFIG_DIR | Should -Be (Join-Path $InstallDir 'claude-config')
        $doc.set.CCL_CLAUDE_BIN | Should -Be (Join-Path $InstallDir 'tools\claude\claude.exe')
        (Get-Content (Join-Path $InstallDir 'claude-config\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json).advisorModel | Should -Be 'fable'
    }
    It 'the claude-inferhub shim exists' {
        Test-Path (Join-Path $InstallDir 'bin\claude-inferhub.cmd') | Should -BeTrue
    }
    It 'uninstall removes the task, the proxy and the folder' {
        $st = Get-Content (Join-Path $InstallDir 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'app\windows\install.ps1') -InstallDir $InstallDir -Uninstall -NonInteractive *>&1 | Out-Host
        $LASTEXITCODE | Should -Be 0
        Get-ScheduledTask -TaskName 'claude-code-launcher-proxy' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Test-Path $InstallDir | Should -BeFalse
        { Invoke-RestMethod "http://127.0.0.1:$($st.port)/ccl/identity" -TimeoutSec 3 } | Should -Throw
        Compare-ProfileSnapshot $ProfileBefore (Get-ProfileSnapshot) | Should -Be ''
    }
}

# v1.0.1 #7: every tool as a private copy in the folder (-PortableOnly), in a folder whose name
# isn't ASCII. Builds the real venv on the uv-managed Python in tools\python.
Describe 'Windows install end to end with private copies of every tool' -Tag 'E2E' -Skip:(-not $script:OnWindows) {
    BeforeAll {
        $script:Root = Join-Path $E2EBase ('ccl e2e portable Jos' + [char]0x00E9 + ' ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:InstallDir = Join-Path $Root 'install'
        $script:ProfileBefore = Get-ProfileSnapshot
        $script:UserPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
        $r = Invoke-RealInstall -InstallDir $InstallDir -More @('-PortableOnly', '-InferHubKey', 'ih-e2e-portable', '-SkipTinyFish', '-StartPort', '47700', '-NoTask', '-NoStart', '-NoPath')
        $script:InstallExit = $r.Code
        $script:InstallLog = [string]$r.Log
        Write-Host $r.Log
        $script:ProfileAfterInstall = Get-ProfileSnapshot
        $script:St = $(if (Test-Path -LiteralPath (Join-Path $InstallDir 'install.json')) { Get-Content -LiteralPath (Join-Path $InstallDir 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json })
    }
    AfterAll {
        if (Test-Path -LiteralPath $InstallDir) {
            try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Installer -InstallDir $InstallDir -Uninstall -NonInteractive *>&1 | Out-Null } catch {}
        }
        if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'installs with exit 0' { $InstallExit | Should -Be 0 }
    It 'writes nothing into the user profile (outside %TEMP%) and leaves the user PATH alone' {
        Compare-ProfileSnapshot $ProfileBefore $ProfileAfterInstall | Should -Be ''
        [Environment]::GetEnvironmentVariable('Path', 'User') | Should -Be $UserPathBefore
    }
    It 'bundles every tool inside the folder' {
        Write-Host ($St.tools | ConvertTo-Json -Depth 4)
        foreach ($n in 'python', 'node', 'uv', 'pnpm', 'git', 'claude', 'poppler') {
            $St.tools.$n.source | Should -Be 'bundled' -Because $n
            ([string]$St.tools.$n.path).StartsWith($InstallDir) | Should -BeTrue -Because $n
            Test-Path -LiteralPath $St.tools.$n.path | Should -BeTrue -Because $n
        }
    }
    It 'the private tools run' {
        (& $St.tools.node.path --version) | Should -Match '^v24\.'
        (& $St.tools.pnpm.path --version) | Should -Match '^\d+\.'
        (& $St.tools.uv.path --version) | Should -Match '^uv '
        (& $St.tools.git.path --version) | Should -Match '^git version'
        Test-Path -LiteralPath (Join-Path $InstallDir 'tools\git\bin\bash.exe') | Should -BeTrue
        (& $St.tools.claude.path --version) | Should -Match '\d+\.\d+\.\d+'
        (& $St.tools.python.path -c 'import sys; print(sys.version_info[:2])') | Should -Be '(3, 12)'
        $St.tools.poppler.path | Should -Be (Join-Path $InstallDir 'tools\poppler\Library\bin\pdftoppm.exe')
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $v = (& $St.tools.poppler.path -v 2>&1 | Out-String); $ErrorActionPreference = $prev
        $v | Should -Match 'pdftoppm version 26\.'
    }
    It 'renders a PDF page with the private pdftoppm, as Claude Code''s Read does' {
        # A plain folder for the PDF: this checks the tool, not poppler's handling of file names.
        $work = Join-Path $E2EBase ('ccl-pdf-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $pdf = Join-Path $work 'one-page.pdf'
        $objs = @('<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 72] >>')
        $sb = [Text.StringBuilder]::new('%PDF-1.4' + "`n"); $offs = @()
        for ($i = 0; $i -lt $objs.Count; $i++) { $offs += $sb.Length; [void]$sb.Append(("{0} 0 obj`n{1}`nendobj`n" -f ($i + 1), $objs[$i])) }
        $x = $sb.Length
        [void]$sb.Append("xref`n0 4`n0000000000 65535 f `n")
        foreach ($o in $offs) { [void]$sb.Append(("{0:D10} 00000 n `n" -f $o)) }
        [void]$sb.Append("trailer`n<< /Size 4 /Root 1 0 R >>`nstartxref`n$x`n%%EOF`n")
        [IO.File]::WriteAllText($pdf, $sb.ToString(), [Text.Encoding]::ASCII)
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $msg = & $St.tools.poppler.path -png -r 36 -f 1 -l 1 $pdf (Join-Path $work 'page') 2>&1 | Out-String
        $rc = $LASTEXITCODE; $ErrorActionPreference = $prev
        Write-Host "pdftoppm exit $rc $msg"
        $rc | Should -Be 0
        @(Get-ChildItem -LiteralPath $work -Filter 'page*.png').Count | Should -Be 1
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    It "gives the private Claude Code 120 s for ripgrep and its search check passes (issue #69)" {
        $doc = Get-Content -LiteralPath (Join-Path $InstallDir 'claude-config\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $doc.env.CLAUDE_CODE_GLOB_TIMEOUT_SECONDS | Should -Be '120'
        $InstallLog | Should -Not -Match "search check did not pass"
        $InstallLog | Should -Not -Match 'claude doctor did not finish'
    }
    It 'builds the venv on the private Python' {
        $cfg = Get-Content -LiteralPath (Join-Path $InstallDir 'venv\pyvenv.cfg') -Raw -Encoding UTF8
        $cfg | Should -Match ([regex]::Escape((Join-Path $InstallDir 'tools\python')))
        Test-Path -LiteralPath (Join-Path $InstallDir 'cache\uv') | Should -BeTrue
        & (Join-Path $InstallDir 'venv\Scripts\python.exe') -c 'import litellm' | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
    It 'hands the folder''s config and Claude Code to integrations' {
        $env:CCL_HOME = $InstallDir; $env:CCL_ALLOW_PROXY_DOWN = '1'
        try {
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'app\windows\launch-claude-inferhub.ps1') --non-interactive --print-env json
        } finally { Remove-Item Env:CCL_HOME, Env:CCL_ALLOW_PROXY_DOWN }
        $doc = ($out | Select-Object -Last 1) | ConvertFrom-Json
        $doc.set.CLAUDE_CONFIG_DIR | Should -Be (Join-Path $InstallDir 'claude-config')
        $doc.set.CCL_CLAUDE_BIN | Should -Be $St.tools.claude.path
        $doc.set.DISABLE_AUTOUPDATER | Should -Be '1'
        $doc.set.CLAUDE_CODE_GLOB_TIMEOUT_SECONDS | Should -Be '120'
        $p = $(if ($doc.set.PATH) { [string]$doc.set.PATH } else { [string]$doc.set.Path })
        ($p -split ';') | Should -Contain (Join-Path $InstallDir 'tools\poppler\Library\bin')
        Test-Path -LiteralPath (Join-Path $InstallDir 'claude-config\settings.json') | Should -BeTrue
    }
    It 'uninstall deletes the folder and the profile is still untouched' {
        $r = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'app\windows\install.ps1') -InstallDir $InstallDir -Uninstall -NonInteractive *>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $r
        Test-Path -LiteralPath $InstallDir | Should -BeFalse
        Compare-ProfileSnapshot $ProfileBefore (Get-ProfileSnapshot) | Should -Be ''
    }
}

# v1.0.1 (issue #63): the shim must work from a folder whose name cmd.exe can't read in its
# OEM code page. Installs into "ccl e2e José 测试 <guid>" (built from code points, so Windows
# PowerShell 5.1 reads this file correctly) and runs bin\claude-inferhub.cmd through a real
# cmd.exe with code page 437.
Describe 'claude-inferhub.cmd from a non-ASCII folder through cmd.exe' -Tag 'E2E' -Skip:(-not $script:OnWindows) {
    BeforeAll {
        $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:Installer = Join-Path $Repo 'windows\install.ps1'
        $name = 'ccl e2e Jos' + [char]0x00E9 + ' ' + [char]0x6D4B + [char]0x8BD5 + ' ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:Root = Join-Path ([IO.Path]::GetTempPath()) $name
        $script:InstallDir = Join-Path $Root 'install'
        $script:ClaudeDir = Join-Path $Root 'claude'
        $script:Shim = Join-Path $InstallDir 'bin\claude-inferhub.cmd'
        New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
        $env:CLAUDE_CONFIG_DIR = $ClaudeDir
        $script:Log = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Installer -Source $Repo -InstallDir $InstallDir `
            -InferHubKey 'ih-e2e-nonascii' -SkipTinyFish -StartPort 47600 -SkipPrereqs -SkipVenv -NoTask -NoPath -NoStart -NonInteractive *>&1 | Out-String
        $script:InstallExit = $LASTEXITCODE
        Write-Host $Log

        function Invoke-ShimCmd {
            # cmd.exe /d /c "chcp 437 >nul & "<shim>" <args>", built as one string so nothing
            # re-quotes it. Returns exit code and output.
            param([string]$Arguments, [hashtable]$Env = @{})
            $psi = [Diagnostics.ProcessStartInfo]::new("$env:WINDIR\System32\cmd.exe")
            $psi.Arguments = '/d /c "chcp 437 >nul & "' + $script:Shim + '" ' + $Arguments + '"'
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
            $psi.EnvironmentVariables.Remove('CCL_HOME')
            foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] }
            $p = [Diagnostics.Process]::Start($psi)
            $p.StandardInput.Close()
            $errTask = $p.StandardError.ReadToEndAsync()
            $out = $p.StandardOutput.ReadToEnd()
            $p.WaitForExit()
            return @{ Code = $p.ExitCode; Out = $out; Err = $errTask.Result }
        }
    }
    AfterAll {
        if (Test-Path -LiteralPath $InstallDir) {
            try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Installer -InstallDir $InstallDir -Uninstall -NonInteractive *>&1 | Out-Null } catch {}
        }
        Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'installs into the non-ASCII folder' { $InstallExit | Should -Be 0 }
    It 'writes a pure-ASCII shim' {
        @([IO.File]::ReadAllBytes($Shim) | Where-Object { $_ -ge 0x80 }).Count | Should -Be 0
    }
    It 'cmd.exe runs --set-tinyfish-key against the right folder' {
        $r = Invoke-ShimCmd -Arguments '--set-tinyfish-key' -Env @{ CCL_TINYFISH_KEY = 'tf-e2e-nonascii' }
        $r.Code | Should -Be 0 -Because ($r.Out + $r.Err)
        [IO.File]::ReadAllText((Join-Path $InstallDir 'secrets\tinyfish.env')) | Should -Be "TINYFISH_API_KEY=tf-e2e-nonascii`n"
        ($r.Out + $r.Err) | Should -Not -Match 'tf-e2e-nonascii'
    }
    It 'cmd.exe runs the launcher, which finds the install and points Claude at its port' {
        $st = Get-Content -LiteralPath (Join-Path $InstallDir 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        # Stand in for this install's proxy: /health/* and /ccl/identity with our instance id.
        $l = [Net.HttpListener]::new()
        $l.Prefixes.Add("http://127.0.0.1:$($st.port)/")
        $l.Start()
        $ps = [powershell]::Create()
        $null = $ps.AddScript({
            param($l, $id)
            while ($l.IsListening) {
                try { $c = $l.GetContext() } catch { break }
                if ($c.Request.Url.AbsolutePath -eq '/ccl/identity') {
                    $b = [Text.Encoding]::UTF8.GetBytes('{"app":"claude-code-launcher","instance":"' + $id + '"}')
                    $c.Response.ContentType = 'application/json'
                    $c.Response.OutputStream.Write($b, 0, $b.Length)
                } elseif ($c.Request.Url.AbsolutePath -notlike '/health*') { $c.Response.StatusCode = 404 }
                $c.Response.Close()
            }
        }).AddArgument($l).AddArgument([string]$st.instance_id)
        $null = $ps.BeginInvoke()
        try {
            $r = Invoke-ShimCmd -Arguments '--non-interactive --print-env json'
            $r.Code | Should -Be 0 -Because ($r.Out + $r.Err)
            $doc = (@($r.Out -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1) | ConvertFrom-Json
            $doc.set.ANTHROPIC_BASE_URL | Should -Be "http://127.0.0.1:$($st.port)"
        } finally { $l.Stop(); $ps.Dispose() }
    }
    It 'cmd.exe runs --uninstall and the folder is gone' {
        $r = Invoke-ShimCmd -Arguments '--uninstall'
        $r.Code | Should -Be 0 -Because ($r.Out + $r.Err)
        Test-Path -LiteralPath $InstallDir | Should -BeFalse
    }
}
