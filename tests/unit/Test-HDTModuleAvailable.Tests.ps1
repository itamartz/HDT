BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:helperManifest = Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1'
    Import-Module -Name $script:helperManifest -Force -ErrorAction Stop
}

Describe 'Test-HDTModuleAvailable' {

    # "Available" has to mean importable, not merely listed. On this machine
    # Get-Module -ListAvailable PSScriptAnalyzer reports the analyzer under
    # Windows PowerShell 5.1 - it is visible inside another module's
    # RequiredModules tree - yet Import-Module fails. Anything that skips or
    # enables an analyzer leg on -ListAvailable alone is wrong under 5.1.

    BeforeAll {
        $script:brokenRoot = Join-Path -Path $TestDrive -ChildPath 'brokenModules'
        $script:brokenDirectory = Join-Path -Path $script:brokenRoot -ChildPath 'HDTBrokenTestModule'
        New-Item -Path $script:brokenDirectory -ItemType Directory -Force | Out-Null

        Set-Content -Path (Join-Path -Path $script:brokenDirectory -ChildPath 'HDTBrokenTestModule.psm1') `
            -Value "throw 'deliberate load failure'" -Encoding ASCII

        New-ModuleManifest -Path (Join-Path -Path $script:brokenDirectory -ChildPath 'HDTBrokenTestModule.psd1') `
            -RootModule 'HDTBrokenTestModule.psm1' -ModuleVersion '1.0.0'
    }

    It 'returns a Boolean' {
        Test-HDTModuleAvailable -Name 'Microsoft.PowerShell.Management' | Should -BeOfType [bool]
    }

    It 'returns true for a module that imports successfully' {
        Test-HDTModuleAvailable -Name 'Microsoft.PowerShell.Management' | Should -BeTrue
    }

    It 'returns false for a module that is not installed at all' {
        Test-HDTModuleAvailable -Name 'HDTModuleThatDoesNotExist' | Should -BeFalse
    }

    It 'returns false for a module that is listed but fails to import' {
        $originalPath = $env:PSModulePath
        try {
            $env:PSModulePath = $script:brokenRoot + [System.IO.Path]::PathSeparator + $originalPath

            # Precondition: the module really is discoverable, so a false result
            # can only come from the import attempt.
            [bool] (Get-Module -ListAvailable -Name 'HDTBrokenTestModule') | Should -BeTrue

            Test-HDTModuleAvailable -Name 'HDTBrokenTestModule' | Should -BeFalse
        } finally {
            $env:PSModulePath = $originalPath
            Remove-Module -Name 'HDTBrokenTestModule' -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not throw when the module is listed but fails to import' {
        $originalPath = $env:PSModulePath
        try {
            $env:PSModulePath = $script:brokenRoot + [System.IO.Path]::PathSeparator + $originalPath
            { Test-HDTModuleAvailable -Name 'HDTBrokenTestModule' } | Should -Not -Throw
        } finally {
            $env:PSModulePath = $originalPath
            Remove-Module -Name 'HDTBrokenTestModule' -Force -ErrorAction SilentlyContinue
        }
    }

    It 'agrees with a direct import attempt for PSScriptAnalyzer on this engine' {
        $expected = $false
        try {
            Import-Module -Name PSScriptAnalyzer -ErrorAction Stop
            $expected = $true
        } catch {
            $expected = $false
        }

        Test-HDTModuleAvailable -Name 'PSScriptAnalyzer' | Should -Be $expected
    }

    It 'rejects an empty Name at parameter binding' {
        # -ErrorId matters here: without it a CommandNotFoundException would
        # satisfy Should -Throw and the test would pass before the function
        # exists.
        { Test-HDTModuleAvailable -Name '' } |
            Should -Throw -ErrorId 'ParameterArgumentValidationError,Test-HDTModuleAvailable'
    }
}
