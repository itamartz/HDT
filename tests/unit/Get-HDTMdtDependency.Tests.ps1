BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:helperManifest = Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1'
    Import-Module -Name $script:helperManifest -Force -ErrorAction Stop

    $script:baitFixture = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/mdt/MdtDependency.ps1'
    $script:freeFixture = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/mdt/MdtFreeReference.ps1'
    $script:ternaryFixture = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/compat/Ps7-Ternary.ps1'

    # tests/contract/NoMdtDependency.Contract.Tests.ps1 scans this file too. The
    # term names ZtiScript and LtiScript would match the very patterns they name,
    # so those two are assembled from fragments; the rest are safe as literals.
    $script:termZti = 'Z' + 'tiScript'
    $script:termLti = 'L' + 'tiScript'

    $script:baitViolation = @(Get-HDTMdtDependency -Path $script:baitFixture)
}

Describe 'Get-HDTMdtDependency' {

    It 'flags the MDT PowerShell module import' {
        @($script:baitViolation | ForEach-Object { $_.Term }) | Should -Contain 'MdtModule'
    }

    It 'flags the MDT PSDrive provider' {
        @($script:baitViolation | ForEach-Object { $_.Term }) | Should -Contain 'MdtDrive'
    }

    It 'flags a Microsoft.BDD type reference' {
        @($script:baitViolation | ForEach-Object { $_.Term }) | Should -Contain 'BddAssembly'
    }

    It 'flags a ZTI script invocation' {
        @($script:baitViolation | ForEach-Object { $_.Term }) | Should -Contain $script:termZti
    }

    It 'flags an MDT cmdlet' {
        @($script:baitViolation | ForEach-Object { $_.Term }) | Should -Contain 'MdtCmdlet'
    }

    It 'flags the MDT task sequence file' {
        @($script:baitViolation | ForEach-Object { $_.Term }) | Should -Contain 'TaskSequenceXml'
    }

    It 'knows about the LTI script family as well' {
        $path = Join-Path -Path $TestDrive -ChildPath 'LtiBait.ps1'
        Set-Content -Path $path -Value ('& ".\LT' + 'ISuspend.wsf"') -Encoding ASCII
        @(Get-HDTMdtDependency -Path $path | ForEach-Object { $_.Term }) | Should -Contain $script:termLti
    }

    It 'reports one violation per offending line' {
        $script:baitViolation.Count | Should -Be 6
        @($script:baitViolation | ForEach-Object { $_.Line } | Select-Object -Unique).Count | Should -Be 6
    }

    It 'reports the term that matched' {
        foreach ($item in $script:baitViolation) {
            $item.Term | Should -Not -BeNullOrEmpty
            $item.Message | Should -BeLike ("*{0}*" -f $item.Term)
        }
    }

    It 'reports a line number greater than zero' {
        foreach ($item in $script:baitViolation) {
            $item.Line | Should -BeGreaterThan 0
            $item.Column | Should -BeGreaterThan 0
        }
    }

    It 'reports the file path on every violation' {
        foreach ($item in $script:baitViolation) {
            $item.Path | Should -BeExactly ([System.IO.Path]::GetFullPath($script:baitFixture))
        }
    }

    It 'names the rule it is enforcing' {
        $script:baitViolation[0].Message | Should -BeLike '*rule 4*'
    }

    It 'ignores MDT terms inside comments' {
        @(Get-HDTMdtDependency -Path $script:freeFixture).Count | Should -Be 0
    }

    It 'does not flag Import-WdsBootImage (WDS is permitted)' {
        $path = Join-Path -Path $TestDrive -ChildPath 'WdsOnly.ps1'
        Set-Content -Path $path -Value "Import-WdsBootImage -Path 'X:\boot.wim' -WhatIf" -Encoding ASCII
        @(Get-HDTMdtDependency -Path $path).Count | Should -Be 0
    }

    It 'does not flag oscdimg (ADK is permitted)' {
        $path = Join-Path -Path $TestDrive -ChildPath 'AdkOnly.ps1'
        Set-Content -Path $path -Value "& 'oscdimg.exe' '-h'" -Encoding ASCII
        @(Get-HDTMdtDependency -Path $path).Count | Should -Be 0
    }

    It 'returns nothing for the MDT-free fixture' {
        @(Get-HDTMdtDependency -Path $script:freeFixture).Count | Should -Be 0
    }

    It 'accepts multiple paths' {
        $violation = @(Get-HDTMdtDependency -Path @($script:baitFixture, $script:freeFixture))
        $violation.Count | Should -Be 6
    }

    It 'throws when a path does not exist' {
        # Matching the message keeps this from passing on a CommandNotFoundException.
        $missing = Join-Path -Path $TestDrive -ChildPath 'no-such-file.ps1'
        { Get-HDTMdtDependency -Path $missing } | Should -Throw -ExpectedMessage '*no-such-file.ps1*'
    }

    It 'falls back to a raw text scan when a file cannot be parsed' {
        # Ps7-Ternary.ps1 does not parse under 5.1 at all. The scanner must still
        # answer rather than throw, and this file holds no MDT dependency.
        { Get-HDTMdtDependency -Path $script:ternaryFixture } | Should -Not -Throw
        @(Get-HDTMdtDependency -Path $script:ternaryFixture).Count | Should -Be 0
    }

    It 'still finds a dependency in an unparseable file, and still ignores its comments' {
        # Assembled from fragments for the same reason as the term names above.
        $line = @(
            '# MDT' + 'Provider in a comment stays free'
            'Import-Module Microsoft' + 'DeploymentToolkit'
            '$script:HDTResult = $true ? ''a'' : ''b'''
        )
        $path = Join-Path -Path $TestDrive -ChildPath 'UnparseableUnder51.ps1'
        Set-Content -Path $path -Value $line -Encoding ASCII

        $violation = @(Get-HDTMdtDependency -Path $path)
        $violation.Count | Should -Be 1
        $violation[0].Term | Should -BeExactly 'MdtModule'
    }

    It 'says so in the message when it fell back to a text scan' -Skip:($PSVersionTable.PSVersion.Major -ge 6) {
        $line = @(
            'Import-Module Microsoft' + 'DeploymentToolkit'
            '$script:HDTResult = $true ? ''a'' : ''b'''
        )
        $path = Join-Path -Path $TestDrive -ChildPath 'UnparseableMessage.ps1'
        Set-Content -Path $path -Value $line -Encoding ASCII

        @(Get-HDTMdtDependency -Path $path)[0].Message | Should -BeLike '*text scan*'
    }
}
