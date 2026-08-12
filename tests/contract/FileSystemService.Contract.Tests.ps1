# The IFileSystem contract (PROJECT constraint 4, DESIGN 12.2.1).
#
# Every implementation of IFileSystem - the hand-written fake today, a real
# adapter in a later phase - must pass this file unchanged. Adding an
# implementation is a one-row change to $script:HDTImplementation below, not a
# new test file.
#
# The registry is built at discovery time, not in BeforeAll: Pester 5 expands
# -ForEach while discovering, so a BeforeAll would produce zero test cases.

# Each Factory is invoked at run time as & $Factory $repositoryRoot. It takes the
# repository root as its one argument because a discovery-phase variable does not
# survive into the run phase, so a factory may not close over one.
$script:HDTImplementation = @(
    @{ Name = 'FakeFileSystem'; Factory = { param($RepositoryRoot) New-HDTFakeFileSystem } }
    # Phase 04 appends: @{ Name = 'RealFileSystem'; Factory = { param($RepositoryRoot) New-HDTFileSystem } }
)

Describe 'IFileSystem contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    }

    BeforeEach {
        # $TestDrive is a real, empty directory, so a real adapter added to the
        # registry later passes this file without touching anything else.
        $script:root = Join-Path -Path $TestDrive -ChildPath 'contract'
        $script:fs = & $Factory $script:repoRoot
    }

    It 'exposes every method the contract requires' {
        $method = @($script:fs | Get-Member -MemberType Method | ForEach-Object { $_.Name })

        foreach ($name in @('TestPath', 'ReadAllText', 'WriteAllText', 'CreateDirectory',
                'RemoveItem', 'CopyItem', 'GetChildItem', 'GetLength')) {
            $method | Should -Contain $name -Because "IFileSystem requires $name"
        }
    }

    It 'reports a written file as existing' {
        $path = Join-Path -Path $script:root -ChildPath 'exists.txt'
        $script:fs.WriteAllText($path, 'content')

        $script:fs.TestPath($path) | Should -BeTrue
    }

    It 'reports an unknown path as not existing' {
        $script:fs.TestPath((Join-Path -Path $script:root -ChildPath 'unknown.txt')) | Should -BeFalse
    }

    It 'round-trips text through WriteAllText and ReadAllText' {
        $path = Join-Path -Path $script:root -ChildPath 'roundtrip.txt'
        $script:fs.WriteAllText($path, "line one`nline two")

        $script:fs.ReadAllText($path) | Should -BeExactly "line one`nline two"
    }

    It 'overwrites an existing file on a second WriteAllText' {
        $path = Join-Path -Path $script:root -ChildPath 'overwrite.txt'
        $script:fs.WriteAllText($path, 'first')
        $script:fs.WriteAllText($path, 'second')

        $script:fs.ReadAllText($path) | Should -BeExactly 'second'
    }

    It 'creates missing parent directories when writing' {
        $path = Join-Path -Path $script:root -ChildPath 'deep/deeper/file.txt'
        $script:fs.WriteAllText($path, 'x')

        $script:fs.TestPath((Join-Path -Path $script:root -ChildPath 'deep')) | Should -BeTrue
        $script:fs.TestPath((Join-Path -Path $script:root -ChildPath 'deep/deeper')) | Should -BeTrue
    }

    It 'throws FileNotFoundException when reading a missing file' {
        $path = Join-Path -Path $script:root -ChildPath 'missing.txt'

        { $script:fs.ReadAllText($path) } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
    }

    It 'throws UnauthorizedAccessException when reading a directory' {
        $path = Join-Path -Path $script:root -ChildPath 'adirectory'
        $script:fs.CreateDirectory($path)

        { $script:fs.ReadAllText($path) } | Should -Throw -ExceptionType ([System.UnauthorizedAccessException])
    }

    It 'creates a directory' {
        $path = Join-Path -Path $script:root -ChildPath 'created'
        $script:fs.CreateDirectory($path)

        $script:fs.TestPath($path) | Should -BeTrue
    }

    It 'treats CreateDirectory as idempotent' {
        $path = Join-Path -Path $script:root -ChildPath 'twice'
        $script:fs.CreateDirectory($path)

        { $script:fs.CreateDirectory($path) } | Should -Not -Throw
        $script:fs.TestPath($path) | Should -BeTrue
    }

    It 'creates intermediate directories' {
        $path = Join-Path -Path $script:root -ChildPath 'a/b/c'
        $script:fs.CreateDirectory($path)

        $script:fs.TestPath((Join-Path -Path $script:root -ChildPath 'a')) | Should -BeTrue
        $script:fs.TestPath((Join-Path -Path $script:root -ChildPath 'a/b')) | Should -BeTrue
        $script:fs.TestPath($path) | Should -BeTrue
    }

    It 'lists only immediate children' {
        $path = Join-Path -Path $script:root -ChildPath 'listing'
        $script:fs.WriteAllText((Join-Path -Path $path -ChildPath 'top.txt'), 'x')
        $script:fs.WriteAllText((Join-Path -Path $path -ChildPath 'nested/deep.txt'), 'x')

        $child = @($script:fs.GetChildItem($path))

        $child.Count | Should -Be 2
        @($child | ForEach-Object { Split-Path -Path $_ -Leaf }) | Should -Contain 'top.txt'
        @($child | ForEach-Object { Split-Path -Path $_ -Leaf }) | Should -Contain 'nested'
        @($child | ForEach-Object { Split-Path -Path $_ -Leaf }) | Should -Not -Contain 'deep.txt'
    }

    It 'returns children sorted' {
        # Ordinal, so an implementation has to sort deliberately rather than
        # inherit whatever order the underlying store happens to hand back.
        $path = Join-Path -Path $script:root -ChildPath 'sorted'
        foreach ($leaf in @('c.txt', 'a.txt', 'B.txt')) {
            $script:fs.WriteAllText((Join-Path -Path $path -ChildPath $leaf), 'x')
        }

        $child = @($script:fs.GetChildItem($path) | ForEach-Object { Split-Path -Path $_ -Leaf })

        $child | Should -Be @('B.txt', 'a.txt', 'c.txt')
    }

    It 'throws DirectoryNotFoundException when listing a missing directory' {
        $path = Join-Path -Path $script:root -ChildPath 'no-such-directory'

        { $script:fs.GetChildItem($path) } | Should -Throw -ExceptionType ([System.IO.DirectoryNotFoundException])
    }

    It 'returns an empty array for an empty directory' {
        $path = Join-Path -Path $script:root -ChildPath 'empty'
        $script:fs.CreateDirectory($path)

        @($script:fs.GetChildItem($path)).Count | Should -Be 0
    }

    It 'copies a file' {
        $source = Join-Path -Path $script:root -ChildPath 'source.txt'
        $destination = Join-Path -Path $script:root -ChildPath 'copies/destination.txt'
        $script:fs.WriteAllText($source, 'payload')

        $script:fs.CopyItem($source, $destination)

        $script:fs.ReadAllText($destination) | Should -BeExactly 'payload'
        $script:fs.TestPath($source) | Should -BeTrue
    }

    It 'throws FileNotFoundException when copying a missing source' {
        $source = Join-Path -Path $script:root -ChildPath 'absent.txt'
        $destination = Join-Path -Path $script:root -ChildPath 'copied.txt'

        { $script:fs.CopyItem($source, $destination) } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
    }

    It 'removes a file' {
        $path = Join-Path -Path $script:root -ChildPath 'doomed.txt'
        $script:fs.WriteAllText($path, 'x')

        $script:fs.RemoveItem($path, $false)

        $script:fs.TestPath($path) | Should -BeFalse
    }

    It 'ignores RemoveItem on a missing path' {
        $path = Join-Path -Path $script:root -ChildPath 'never-existed.txt'

        { $script:fs.RemoveItem($path, $false) } | Should -Not -Throw
    }

    It 'throws IOException removing a non-empty directory without Recurse' {
        $path = Join-Path -Path $script:root -ChildPath 'populated'
        $script:fs.WriteAllText((Join-Path -Path $path -ChildPath 'child.txt'), 'x')

        { $script:fs.RemoveItem($path, $false) } | Should -Throw -ExceptionType ([System.IO.IOException])
    }

    It 'removes a non-empty directory with Recurse' {
        $path = Join-Path -Path $script:root -ChildPath 'tree'
        $script:fs.WriteAllText((Join-Path -Path $path -ChildPath 'a/child.txt'), 'x')

        $script:fs.RemoveItem($path, $true)

        $script:fs.TestPath($path) | Should -BeFalse
        $script:fs.TestPath((Join-Path -Path $path -ChildPath 'a')) | Should -BeFalse
        $script:fs.TestPath((Join-Path -Path $path -ChildPath 'a/child.txt')) | Should -BeFalse
    }

    It 'reports the byte length of a file' {
        $path = Join-Path -Path $script:root -ChildPath 'length.txt'
        $script:fs.WriteAllText($path, 'hello')

        $script:fs.GetLength($path) | Should -Be 5
    }

    It 'treats paths case-insensitively' {
        $path = Join-Path -Path $script:root -ChildPath 'CaseSensitive.txt'
        $script:fs.WriteAllText($path, 'insensitive')

        $script:fs.TestPath((Join-Path -Path $script:root -ChildPath 'casesensitive.TXT')) | Should -BeTrue
        $script:fs.ReadAllText((Join-Path -Path $script:root -ChildPath 'CASESENSITIVE.txt')) | Should -BeExactly 'insensitive'
    }

    It 'normalises a trailing separator' {
        $path = Join-Path -Path $script:root -ChildPath 'trailing'
        $script:fs.CreateDirectory(($path + [System.IO.Path]::DirectorySeparatorChar))

        $script:fs.TestPath($path) | Should -BeTrue
        @($script:fs.GetChildItem(($path + [System.IO.Path]::DirectorySeparatorChar))).Count | Should -Be 0
    }
}
