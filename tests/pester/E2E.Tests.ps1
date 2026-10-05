# End-to-end test of windows/install.ps1 on a real Windows machine (the CI windows-installer job).
# Tag: E2E. Skipped elsewhere. Builds the real LiteLLM venv with uv, registers the logon task,
# starts the proxy next to a fake "other LiteLLM" that holds the start port, then uninstalls.
# Never uses port 4000: the start port is 47400.

BeforeDiscovery { $script:OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows }

Describe 'Windows install end to end' -Tag 'E2E' -Skip:(-not $script:OnWindows) {
    BeforeAll {
        $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:Installer = Join-Path $Repo 'windows\install.ps1'
        $script:Root = Join-Path ([IO.Path]::GetTempPath()) ('ccl-e2e-' + [guid]::NewGuid().ToString('N'))
        $script:InstallDir = Join-Path $Root 'install'
        $script:ClaudeDir = Join-Path $Root 'claude'
        New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
        $env:CLAUDE_CONFIG_DIR = $ClaudeDir
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
        $script:Log = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Installer -Source $Repo -InstallDir $InstallDir `
            -InferHubKey $Key -TinyFishKey $TfKey -StartPort $StartPort -SkipPrereqs -NoPath -NonInteractive *>&1 | Out-String
        $script:InstallExit = $LASTEXITCODE
        Write-Host $Log
    }
    AfterAll {
        try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'app\windows\install.ps1') -InstallDir $InstallDir -Uninstall -NonInteractive *>&1 | Out-Null } catch {}
        try { $Other.Stop() } catch {}
        try { $OtherPs.Dispose() } catch {}
        Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        if (Test-Path $Root) { Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'installs with exit 0' { $InstallExit | Should -Be 0 }
    It 'never prints the key' { $Log | Should -Not -BeLike "*$Key*" }
    It 'stores the TinyFish key without printing it' {
        $Log | Should -Not -BeLike "*$TfKey*"
        (Get-Content (Join-Path $InstallDir 'secrets\tinyfish.env') -Raw) | Should -Be "TINYFISH_API_KEY=$TfKey`n"
        Get-Content (Join-Path $InstallDir 'logs\*.log') -Raw -ErrorAction SilentlyContinue | Should -Not -BeLike "*$TfKey*"
    }
    It 'skips the port held by the other LiteLLM' {
        $port = (Get-Content (Join-Path $InstallDir 'install.json') -Raw | ConvertFrom-Json).port
        $port | Should -Not -Be $StartPort
        $port | Should -BeGreaterThan $StartPort
    }
    It 'registers the hidden logon task with the chosen port' {
        $port = (Get-Content (Join-Path $InstallDir 'install.json') -Raw | ConvertFrom-Json).port
        $t = Get-ScheduledTask -TaskName 'claude-code-launcher-proxy' -ErrorAction Stop
        $t.Actions[0].Execute | Should -Match 'conhost\.exe$'
        $t.Actions[0].Arguments | Should -Match "-Port $port"
        $t.Actions[0].Arguments | Should -Not -Match $Key
    }
    It 'runs our proxy on the chosen port (identity matches)' {
        $st = Get-Content (Join-Path $InstallDir 'install.json') -Raw | ConvertFrom-Json
        $r = Invoke-RestMethod "http://127.0.0.1:$($st.port)/ccl/identity" -TimeoutSec 10
        $r.app | Should -Be 'claude-code-launcher'
        $r.instance | Should -Be $st.instance_id
    }
    It 'points Claude at the chosen port in non-interactive mode and syncs the advisor' {
        $st = Get-Content (Join-Path $InstallDir 'install.json') -Raw | ConvertFrom-Json
        $env:CCL_HOME = $InstallDir
        try {
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'app\windows\launch-claude-inferhub.ps1') --non-interactive --print-env json
        } finally { Remove-Item Env:CCL_HOME }
        $doc = ($out | Select-Object -Last 1) | ConvertFrom-Json
        $doc.set.ANTHROPIC_BASE_URL | Should -Be "http://127.0.0.1:$($st.port)"
        (Get-Content (Join-Path $ClaudeDir 'settings.json') -Raw | ConvertFrom-Json).advisorModel | Should -Be 'fable'
    }
    It 'the claude-inferhub shim exists' {
        Test-Path (Join-Path $InstallDir 'bin\claude-inferhub.cmd') | Should -BeTrue
    }
    It 'uninstall removes the task, the proxy and the folder' {
        $st = Get-Content (Join-Path $InstallDir 'install.json') -Raw | ConvertFrom-Json
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'app\windows\install.ps1') -InstallDir $InstallDir -Uninstall -NonInteractive *>&1 | Out-Host
        $LASTEXITCODE | Should -Be 0
        Get-ScheduledTask -TaskName 'claude-code-launcher-proxy' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Test-Path $InstallDir | Should -BeFalse
        { Invoke-RestMethod "http://127.0.0.1:$($st.port)/ccl/identity" -TimeoutSec 3 } | Should -Throw
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
        $st = Get-Content -LiteralPath (Join-Path $InstallDir 'install.json') -Raw | ConvertFrom-Json
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
