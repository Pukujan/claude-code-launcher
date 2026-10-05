# Pester 5 tests for the installer's search check (issue #69).
# `claude doctor` prints "Search: OK (bundled)" when Claude Code's ripgrep works.
# Never runs the real claude: a fake one on PATH answers.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $env:CCL_INSTALL_LIBRARY_ONLY = '1'
    . (Join-Path $Repo 'windows/install.ps1')
    Remove-Item Env:CCL_INSTALL_LIBRARY_ONLY

    function New-FakeClaude([string]$Output) {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('ccl-doctor-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $file = Join-Path $dir 'doctor.txt'
        [IO.File]::WriteAllText($file, $Output)
        $script = Join-Path $dir 'fake-claude.ps1'
        [IO.File]::WriteAllText($script, "param([Parameter(ValueFromRemainingArguments = `$true)]`$Rest)`nif (`$Rest -and `$Rest[0] -eq 'doctor') { Get-Content -LiteralPath '$file' }`n")
        return $script
    }
}

Describe 'Test-CclClaudeSearch' -Tag Spec {
    It 'passes when claude doctor reports Search: OK' {
        $fake = New-FakeClaude "Claude Code doctor`nSearch: OK (bundled)`nNo installation issues found.`n"
        Test-CclClaudeSearch -Claude $fake -WarningAction SilentlyContinue | Should -BeTrue
    }

    It 'fails and warns when the search line is not OK' {
        $fake = New-FakeClaude "Claude Code doctor`nSearch: Not working (ripgrep missing)`n"
        $w = $null
        Test-CclClaudeSearch -Claude $fake -WarningVariable w -WarningAction SilentlyContinue | Should -BeFalse
        ($w -join ' ') | Should -Match 'Search: Not working'
    }

    It 'fails without throwing when claude is missing' {
        Test-CclClaudeSearch -Claude (Join-Path ([IO.Path]::GetTempPath()) 'no-such-claude.ps1') -WarningAction SilentlyContinue | Should -BeFalse
    }
}

Describe 'Test-CclClaudeSearch time limit' -Tag Spec {
    It 'gives up on a doctor that never finishes, without throwing' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('ccl-doctor-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $hang = Join-Path $dir 'hang-claude.ps1'
        [IO.File]::WriteAllText($hang, "Start-Sleep -Seconds 60`n")
        $t = [Diagnostics.Stopwatch]::StartNew()
        Test-CclClaudeSearch -Claude $hang -TimeoutSec 3 -WarningAction SilentlyContinue | Should -BeFalse
        $t.Elapsed.TotalSeconds | Should -BeLessThan 30
    }
}
