BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:helperManifest = Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1'
    Import-Module -Name $script:helperManifest -Force -ErrorAction Stop

    $script:compatRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/compat'

    function Get-HDTCompatFixturePath {
        param([string] $FileName)
        Join-Path -Path $script:compatRoot -ChildPath $FileName
    }
}

Describe 'Get-HDTScriptCompatibilityViolation' {

    # Windows PowerShell 5.1 rejects ??, ?., ?[] and ternary at parse time, while
    # PowerShell 7 parses them and needs AST inspection. Every operator fixture is
    # therefore asserted twice: "at least one violation" on both engines, and an
    # exact Feature per engine in the two engine-specific Contexts below.
    Context 'detects PS7-only constructs on every engine' {

        It 'flags <FileName>' -ForEach @(
            @{ FileName = 'Ps7-NullCoalescing.ps1' }
            @{ FileName = 'Ps7-NullCoalescingAssignment.ps1' }
            @{ FileName = 'Ps7-NullConditionalMember.ps1' }
            @{ FileName = 'Ps7-NullConditionalIndex.ps1' }
            @{ FileName = 'Ps7-Ternary.ps1' }
            @{ FileName = 'Ps7-ForEachParallel.ps1' }
            @{ FileName = 'Ps7-CleanBlock.ps1' }
            @{ FileName = 'Ps7-GetError.ps1' }
            @{ FileName = 'Ps7-PSStyle.ps1' }
            @{ FileName = 'Ps7-ConvertFromJsonAsHashtable.ps1' }
        ) {
            $path = Get-HDTCompatFixturePath -FileName $FileName
            @(Get-HDTScriptCompatibilityViolation -Path $path).Count | Should -BeGreaterThan 0
        }
    }

    Context 'classifies constructs precisely under PowerShell 7' -Skip:($PSVersionTable.PSVersion.Major -lt 6) {

        It 'classifies <FileName> as <Feature>' -ForEach @(
            @{ FileName = 'Ps7-NullCoalescing.ps1'; Feature = 'NullCoalescing' }
            @{ FileName = 'Ps7-NullCoalescingAssignment.ps1'; Feature = 'NullCoalescing' }
            @{ FileName = 'Ps7-NullConditionalMember.ps1'; Feature = 'NullConditional' }
            @{ FileName = 'Ps7-NullConditionalIndex.ps1'; Feature = 'NullConditional' }
            @{ FileName = 'Ps7-Ternary.ps1'; Feature = 'Ternary' }
            @{ FileName = 'Ps7-ForEachParallel.ps1'; Feature = 'ForEachParallel' }
            @{ FileName = 'Ps7-CleanBlock.ps1'; Feature = 'CleanBlock' }
            @{ FileName = 'Ps7-GetError.ps1'; Feature = 'ForbiddenCommand' }
            @{ FileName = 'Ps7-PSStyle.ps1'; Feature = 'ForbiddenVariable' }
            @{ FileName = 'Ps7-ConvertFromJsonAsHashtable.ps1'; Feature = 'ForbiddenParameter' }
        ) {
            $path = Get-HDTCompatFixturePath -FileName $FileName
            $violation = @(Get-HDTScriptCompatibilityViolation -Path $path)
            @($violation | ForEach-Object { $_.Feature }) | Should -Contain $Feature
        }
    }

    Context 'classifies constructs precisely under Windows PowerShell 5.1' -Skip:($PSVersionTable.PSVersion.Major -ge 6) {

        It 'classifies <FileName> as a ParseError' -ForEach @(
            @{ FileName = 'Ps7-NullCoalescing.ps1' }
            @{ FileName = 'Ps7-NullCoalescingAssignment.ps1' }
            @{ FileName = 'Ps7-NullConditionalMember.ps1' }
            @{ FileName = 'Ps7-NullConditionalIndex.ps1' }
            @{ FileName = 'Ps7-Ternary.ps1' }
        ) {
            $path = Get-HDTCompatFixturePath -FileName $FileName
            @(Get-HDTScriptCompatibilityViolation -Path $path | ForEach-Object { $_.Feature }) |
                Should -Contain 'ParseError'
        }

        It 'still classifies -Parallel as ForEachParallel (5.1 parses it)' {
            $path = Get-HDTCompatFixturePath -FileName 'Ps7-ForEachParallel.ps1'
            @(Get-HDTScriptCompatibilityViolation -Path $path | ForEach-Object { $_.Feature }) |
                Should -Contain 'ForEachParallel'
        }

        It 'still classifies clean as CleanBlock or ForbiddenCommand' {
            $path = Get-HDTCompatFixturePath -FileName 'Ps7-CleanBlock.ps1'
            $feature = @(Get-HDTScriptCompatibilityViolation -Path $path | ForEach-Object { $_.Feature })
            @($feature | Where-Object { $_ -in @('CleanBlock', 'ForbiddenCommand') }).Count |
                Should -BeGreaterThan 0
        }
    }

    Context 'clean input' {

        It 'returns nothing for a 5.1-compatible file' {
            $path = Get-HDTCompatFixturePath -FileName 'Ps51-Clean.ps1'
            @(Get-HDTScriptCompatibilityViolation -Path $path).Count | Should -Be 0
        }

        It 'returns nothing for the repository build script' {
            $path = Join-Path -Path $script:repoRoot -ChildPath 'build.ps1'
            @(Get-HDTScriptCompatibilityViolation -Path $path).Count | Should -Be 0
        }

        It 'reports the file path on every violation' {
            $path = Get-HDTCompatFixturePath -FileName 'Ps7-Ternary.ps1'
            $violation = @(Get-HDTScriptCompatibilityViolation -Path $path)
            $violation.Count | Should -BeGreaterThan 0
            foreach ($item in $violation) {
                $item.Path | Should -BeExactly ([System.IO.Path]::GetFullPath($path))
            }
        }

        It 'reports a line number greater than zero on every violation' {
            $path = Get-HDTCompatFixturePath -FileName 'Ps7-Ternary.ps1'
            foreach ($item in @(Get-HDTScriptCompatibilityViolation -Path $path)) {
                $item.Line | Should -BeGreaterThan 0
                $item.Column | Should -BeGreaterThan 0
            }
        }

        It 'carries a human-readable message on every violation' {
            $path = Get-HDTCompatFixturePath -FileName 'Ps7-ForEachParallel.ps1'
            foreach ($item in @(Get-HDTScriptCompatibilityViolation -Path $path)) {
                $item.Message | Should -Not -BeNullOrEmpty
            }
        }

        It 'accepts multiple paths and attributes each violation to its own file' {
            $parallel = Get-HDTCompatFixturePath -FileName 'Ps7-ForEachParallel.ps1'
            $getError = Get-HDTCompatFixturePath -FileName 'Ps7-GetError.ps1'
            $violation = @(Get-HDTScriptCompatibilityViolation -Path @($parallel, $getError))

            @($violation | Where-Object { $_.Path -eq [System.IO.Path]::GetFullPath($parallel) }).Count |
                Should -BeGreaterThan 0
            @($violation | Where-Object { $_.Path -eq [System.IO.Path]::GetFullPath($getError) }).Count |
                Should -BeGreaterThan 0
        }

        It 'throws when a path does not exist' {
            # The message must name the missing file: a bare -Throw would also be
            # satisfied by a CommandNotFoundException, which would make this test
            # pass before the function existed.
            $missing = Join-Path -Path $TestDrive -ChildPath 'no-such-file.ps1'
            { Get-HDTScriptCompatibilityViolation -Path $missing } |
                Should -Throw -ExpectedMessage '*no-such-file.ps1*'
        }
    }
}

Describe 'Test-HDTScriptCompatibility' {

    It 'returns $true for a 5.1-compatible file' {
        Test-HDTScriptCompatibility -Path (Get-HDTCompatFixturePath -FileName 'Ps51-Clean.ps1') |
            Should -BeTrue
    }

    It 'returns $false for a file using the null-coalescing operator' {
        Test-HDTScriptCompatibility -Path (Get-HDTCompatFixturePath -FileName 'Ps7-NullCoalescing.ps1') |
            Should -BeFalse
    }

    It 'returns a plain boolean' {
        Test-HDTScriptCompatibility -Path (Get-HDTCompatFixturePath -FileName 'Ps51-Clean.ps1') |
            Should -BeOfType [bool]
    }
}
