BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:helperManifest = Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1'
    Import-Module -Name $script:helperManifest -Force -ErrorAction Stop

    $script:fixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/naming'
    $script:goodName = Join-Path -Path $script:fixtureRoot -ChildPath 'GoodName.ps1'
    $script:badName = Join-Path -Path $script:fixtureRoot -ChildPath 'BadName.ps1'
    $script:sampleModule = Join-Path -Path $script:fixtureRoot -ChildPath 'SampleModule.psm1'
    $script:noFunction = Join-Path -Path $script:fixtureRoot -ChildPath 'NoFunction.ps1'
    $script:classMember = Join-Path -Path $script:fixtureRoot -ChildPath 'ClassMember.psm1'
}

Describe 'Get-HDTSourceFunction' {

    BeforeAll {
        $script:goodResult = @(Get-HDTSourceFunction -Path $script:goodName)
        $script:goodNameList = @($script:goodResult | ForEach-Object { $_.Name })
    }

    It 'finds a top-level function' {
        $script:goodNameList | Should -Contain 'Get-HDTThing'
        $script:goodNameList | Should -Contain 'ConvertTo-HDTReport'
        $script:goodNameList | Should -Contain 'New-HDTWorkspace'
    }

    It 'finds a function nested inside another function' {
        $script:goodNameList | Should -Contain 'Test-HDTNestedThing'
    }

    It 'reports the file path of each function' {
        foreach ($item in $script:goodResult) {
            $item.Path | Should -BeExactly ([System.IO.Path]::GetFullPath($script:goodName))
        }
    }

    It 'reports the line number of each function' {
        # GoodName.ps1 is pinned: do not reflow the fixture.
        $line = @{}
        foreach ($item in $script:goodResult) { $line[$item.Name] = $item.Line }

        $line['Get-HDTThing'] | Should -Be 7
        $line['Test-HDTNestedThing'] | Should -Be 8
        $line['ConvertTo-HDTReport'] | Should -Be 15
        $line['New-HDTWorkspace'] | Should -Be 19
    }

    It 'finds functions in a .psm1 file' {
        @(Get-HDTSourceFunction -Path $script:sampleModule | ForEach-Object { $_.Name }) |
            Should -Contain 'Get-HDTModuleScopedThing'
    }

    It 'returns nothing for a file with no functions' {
        @(Get-HDTSourceFunction -Path $script:noFunction).Count | Should -Be 0
    }

    It 'accepts multiple paths' {
        $result = @(Get-HDTSourceFunction -Path @($script:goodName, $script:sampleModule))
        @($result | ForEach-Object { $_.Name }) | Should -Contain 'Get-HDTThing'
        @($result | ForEach-Object { $_.Name }) | Should -Contain 'Get-HDTModuleScopedThing'
    }

    It 'finds every deliberately misnamed function in the bad fixture' {
        @(Get-HDTSourceFunction -Path $script:badName).Count | Should -Be 7
    }

    It 'reports only the functions in a file that also defines a class' {
        # PowerShell wraps every class member in a FunctionMemberAst that itself
        # contains a FunctionDefinitionAst, so a naive AST search reports the
        # constructor and every method as if they were commands. DESIGN 15.1 is a
        # command-naming rule; a service contract fixes its own method names
        # (IFileSystem.TestPath), so class members must never reach the naming
        # contract.
        @(Get-HDTSourceFunction -Path $script:classMember | ForEach-Object { $_.Name }) |
            Should -Be @('New-HDTFixtureService', 'Get-HDTFixtureNested')
    }

    It 'ignores class constructors, instance, hidden and static methods' {
        $name = @(Get-HDTSourceFunction -Path $script:classMember | ForEach-Object { $_.Name })

        foreach ($member in @('HDTFixtureService', 'TestPath', 'RecordSomething', 'Describe')) {
            $name | Should -Not -Contain $member -Because "$member is a class member, not a command"
        }
    }

    It 'reports the line number of a function declared after a class' {
        # ClassMember.psm1 is pinned: do not reflow the fixture.
        $line = @{}
        foreach ($item in @(Get-HDTSourceFunction -Path $script:classMember)) { $line[$item.Name] = $item.Line }

        $line['New-HDTFixtureService'] | Should -Be 31
        $line['Get-HDTFixtureNested'] | Should -Be 35
    }

    It 'throws when a path does not exist' {
        # The message must name the missing file: a bare -Throw would also be
        # satisfied by a CommandNotFoundException, so it would pass before the
        # function existed.
        $missing = Join-Path -Path $TestDrive -ChildPath 'no-such-file.ps1'
        { Get-HDTSourceFunction -Path $missing } | Should -Throw -ExpectedMessage '*no-such-file.ps1*'
    }

    It 'surfaces a parse error as a terminating error naming the file' -Skip:($PSVersionTable.PSVersion.Major -ge 6) {
        # Written here rather than read from tests/fixtures/compat so this suite
        # stands alone; the text is a string literal, never parsed by this file.
        $ternaryFile = Join-Path -Path $TestDrive -ChildPath 'Ps7Ternary.ps1'
        Set-Content -Path $ternaryFile -Value '$script:HDTResult = $true ? ''a'' : ''b''' -Encoding ASCII

        # Silent-empty-on-parse-error is the one failure mode that would make the
        # naming contract pass vacuously, so it gets its own test.
        { Get-HDTSourceFunction -Path $ternaryFile } | Should -Throw -ExpectedMessage '*Ps7Ternary.ps1*'
    }

    It 'parses PS7 syntax without error under PowerShell 7' -Skip:($PSVersionTable.PSVersion.Major -lt 6) {
        $ternaryFile = Join-Path -Path $TestDrive -ChildPath 'Ps7Ternary.ps1'
        Set-Content -Path $ternaryFile -Value '$script:HDTResult = $true ? ''a'' : ''b''' -Encoding ASCII

        { Get-HDTSourceFunction -Path $ternaryFile } | Should -Not -Throw
        @(Get-HDTSourceFunction -Path $ternaryFile).Count | Should -Be 0
    }
}
