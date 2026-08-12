# Behaviour that belongs to the fake itself rather than to the IFileSystem
# contract: seeding, operation recording, and the guarantee that nothing the
# fake does reaches the real disk.
#
# The fake is only ever obtained through New-HDTFakeFileSystem. The class name
# is never written as a type literal here: a type literal binds to whichever
# dynamic assembly loaded first and breaks across a module reload.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTFakeFileSystem' {

    It 'starts empty when given no seed' {
        $fs = New-HDTFakeFileSystem

        $fs.TestPath('C:\ws\anything.txt') | Should -BeFalse
        $fs.TestPath('C:\ws') | Should -BeFalse
    }

    It 'seeds files from the -File hashtable' {
        $fs = New-HDTFakeFileSystem -File @{
            'C:\ws\rules.yaml'    = 'schemaVersion: 1'
            'C:\ws\sequence.yaml' = 'steps: []'
        }

        $fs.ReadAllText('C:\ws\rules.yaml') | Should -BeExactly 'schemaVersion: 1'
        $fs.ReadAllText('C:\ws\sequence.yaml') | Should -BeExactly 'steps: []'
    }

    It 'seeds the parent directories of seeded files' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\control\deep\rules.yaml' = 'x' }

        $fs.TestPath('C:\ws') | Should -BeTrue
        $fs.TestPath('C:\ws\control') | Should -BeTrue
        $fs.TestPath('C:\ws\control\deep') | Should -BeTrue
        @($fs.GetChildItem('C:\ws\control\deep')).Count | Should -Be 1
    }

    It 'seeds directories from -Directory' {
        $fs = New-HDTFakeFileSystem -Directory @('C:\ws\Drivers', 'C:\ws\Applications')

        $fs.TestPath('C:\ws\Drivers') | Should -BeTrue
        $fs.TestPath('C:\ws\Applications') | Should -BeTrue
        @($fs.GetChildItem('C:\ws')).Count | Should -Be 2
    }

    It 'does not record seeding as an operation' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\a.txt' = 'x' } -Directory @('C:\ws\b')

        @($fs.Operations).Count | Should -Be 0
    }

    It 'records each call in Operations' {
        $fs = New-HDTFakeFileSystem
        $fs.CreateDirectory('C:\ws')
        $fs.WriteAllText('C:\ws\a.txt', 'x')

        @($fs.Operations).Count | Should -Be 2
    }

    It 'numbers operations from one, in call order' {
        $fs = New-HDTFakeFileSystem
        $fs.CreateDirectory('C:\ws')
        $fs.WriteAllText('C:\ws\a.txt', 'x')
        $fs.TestPath('C:\ws\a.txt') | Out-Null

        @($fs.Operations | ForEach-Object { $_.Sequence }) | Should -Be @(1, 2, 3)
    }

    It 'records the arguments of each call' {
        $fs = New-HDTFakeFileSystem
        $fs.WriteAllText('C:\ws\a.txt', 'payload')
        $fs.RemoveItem('C:\ws\a.txt', $true)

        @($fs.Operations[0].Arguments) | Should -Be @('C:\ws\a.txt', 'payload')
        @($fs.Operations[1].Arguments) | Should -Be @('C:\ws\a.txt', $true)
    }

    It 'returns operation names in order from GetOperationName' {
        # DESIGN 12.2.1: "assert the ordered list of operations it would have
        # performed". This is that assertion in miniature, and the template every
        # later fake copies.
        $fs = New-HDTFakeFileSystem
        $fs.CreateDirectory('C:\ws')
        $fs.WriteAllText('C:\ws\a.txt', 'x')
        $fs.TestPath('C:\ws\a.txt') | Out-Null
        $fs.ReadAllText('C:\ws\a.txt') | Out-Null

        $fs.GetOperationName() | Should -Be @('CreateDirectory', 'WriteAllText', 'TestPath', 'ReadAllText')
    }

    It 'records read-only operations as well as writes' {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\a.txt' = 'payload' }
        $fs.TestPath('C:\ws\a.txt') | Out-Null
        $fs.ReadAllText('C:\ws\a.txt') | Out-Null
        $fs.GetChildItem('C:\ws') | Out-Null
        $fs.GetLength('C:\ws\a.txt') | Out-Null

        $fs.GetOperationName() | Should -Be @('TestPath', 'ReadAllText', 'GetChildItem', 'GetLength')
    }

    It 'never touches the real filesystem' {
        $realPath = 'C:\HDTLab\does-not-exist\x.txt'

        $fs = New-HDTFakeFileSystem
        $fs.WriteAllText($realPath, 'this must stay in memory')
        $fs.CreateDirectory('C:\HDTLab\does-not-exist\deeper')

        $fs.TestPath($realPath) | Should -BeTrue
        Test-Path -LiteralPath $realPath | Should -BeFalse
        Test-Path -LiteralPath 'C:\HDTLab\does-not-exist' | Should -BeFalse
    }

    It 'reads no data from the real filesystem' {
        # A path that certainly exists on disk must still be invisible to the fake.
        $fs = New-HDTFakeFileSystem

        $fs.TestPath($PSCommandPath) | Should -BeFalse
        { $fs.ReadAllText($PSCommandPath) } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
    }

    It 'is independent between instances' {
        $first = New-HDTFakeFileSystem -File @{ 'C:\ws\a.txt' = 'first' }
        $second = New-HDTFakeFileSystem

        $second.TestPath('C:\ws\a.txt') | Should -BeFalse

        $second.WriteAllText('C:\ws\b.txt', 'second')
        $first.TestPath('C:\ws\b.txt') | Should -BeFalse

        @($first.Operations).Count | Should -Be 1
        @($second.Operations).Count | Should -Be 2
    }
}
