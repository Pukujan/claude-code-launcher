# Pester 5 tests for the SlopSearX setup's generated start script (issue #82).
# Library-only mode: nothing is cloned, installed, started or registered.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $env:CCL_SLOPSEARX_LIBRARY_ONLY = '1'
    . (Join-Path $Repo 'windows/slopsearx/setup-slopsearx.ps1')
    Remove-Item Env:CCL_SLOPSEARX_LIBRARY_ONLY

    function New-TestStart([string]$DisableEngines) {
        Get-SlopSearXStartScript -Port 18091 -RunDir 'C:\Users\me\.slopsearx' -InstallDir 'C:\src\SlopSearX' `
            -Python 'C:\src\SlopSearX\.venv\Scripts\python.exe' -DisableEngines $DisableEngines
    }
}

Describe 'Get-SlopSearXEngineEnv' -Tag Spec {
    It 'turns each name into an ENGINE_name_ENABLED=false line' {
        $lines = @(Get-SlopSearXEngineEnv -DisableEngines 'google, reddit,duckduckgo')
        $lines | Should -Be @(
            "`$env:ENGINE_GOOGLE_ENABLED = 'false'",
            "`$env:ENGINE_REDDIT_ENABLED = 'false'",
            "`$env:ENGINE_DUCKDUCKGO_ENABLED = 'false'"
        )
    }

    It 'returns nothing for an empty list' {
        @(Get-SlopSearXEngineEnv -DisableEngines '').Count | Should -Be 0
    }

    It 'drops repeated names' {
        @(Get-SlopSearXEngineEnv -DisableEngines 'Google,google').Count | Should -Be 1
    }

    It 'rejects a name that could inject code into the start script' {
        { Get-SlopSearXEngineEnv -DisableEngines "google;Remove-Item x" } | Should -Throw '*engine name*'
        { Get-SlopSearXEngineEnv -DisableEngines "goo'gle" } | Should -Throw '*engine name*'
    }
}

Describe 'Get-SlopSearXStartScript' -Tag Spec {
    It 'disables the engines blocked from a home PC by default' {
        $start = Get-SlopSearXStartScript -Port 18091 -RunDir 'C:\r' -InstallDir 'C:\s' -Python 'C:\s\python.exe'
        foreach ($name in 'GOOGLE', 'REDDIT', 'DUCKDUCKGO', 'BRAVE') {
            $start | Should -Match ([regex]::Escape("`$env:ENGINE_$($name)_ENABLED = 'false'"))
        }
    }

    It 'sets the engine switches before uvicorn starts' {
        $start = New-TestStart 'google'
        $start.IndexOf('ENGINE_GOOGLE_ENABLED') | Should -BeLessThan $start.IndexOf('uvicorn')
        $start.IndexOf('ENGINE_GOOGLE_ENABLED') | Should -BeGreaterThan -1
    }

    It 'keeps every engine when the list is empty' {
        New-TestStart '' | Should -Not -Match 'ENGINE_'
    }

    It 'still runs uvicorn on 127.0.0.1 and the given port from the checkout' {
        $start = New-TestStart 'google'
        $start | Should -Match ([regex]::Escape('slopsearx.server:app --host 127.0.0.1 --port 18091'))
        $start | Should -Match ([regex]::Escape("Set-Location -LiteralPath 'C:\src\SlopSearX'"))
        $start | Should -Match ([regex]::Escape('C:\src\SlopSearX\.venv\Scripts\python.exe'))
    }

    It 'is valid PowerShell' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput((New-TestStart 'google,brave'), [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
}

Describe 'Test-SlopSearXSameRepo' -Tag Spec {
    It 'treats .git, a trailing slash and case as the same repository' {
        Test-SlopSearXSameRepo 'https://github.com/magnus919/SlopSearX.git' 'https://github.com/Magnus919/slopsearx/' | Should -BeTrue
    }

    It 'tells a fork from upstream' {
        Test-SlopSearXSameRepo 'https://github.com/magnus919/SlopSearX.git' 'https://github.com/Pukujan/SlopSearX.git' | Should -BeFalse
    }
}
