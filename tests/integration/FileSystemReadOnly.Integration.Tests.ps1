# THE ADK SHIPS A READ-ONLY FILE, AND IT MADE EVERY SECOND MEDIA BUILD FAIL.
#
# Update-HDTMediaContent clears its scratch media tree before assembling a new
# one. The tree is a copy of the ADK's WinPE Media directory, which carries
# autorun.inf with the read-only attribute set, and the copy carries it too. So
# the first build of a media item worked and the second died:
#
#   Update-HDTMediaContent : Exception calling "RemoveItem" with "2"
#   argument(s): "Exception calling "Delete" with "2" argument(s):
#   "Access to the path 'autorun.inf' is denied.""
#
# Watched on 2026-09-03, rebuilding the hydration disc after a rules.yaml edit.
#
# WHY .NET AND Remove-Item DISAGREE. Remove-Item -Force clears the read-only
# attribute and then deletes; [System.IO.Directory]::Delete does not, it throws.
# The adapter uses System.IO deliberately - the contract asserts System.IO
# exception types and the fake reproduces them - so the fix belongs in the
# adapter rather than in a caller that would have to know this about every
# directory it removes.
#
# A READ-ONLY BIT IS NOT A PERMISSION AND NOT A PROTECTION HERE. Every caller of
# RemoveItem in this repository is deleting something it created in this run -
# a scratch tree, a staging directory, a mount folder. The attribute arrived by
# being copied off an ADK file, and nobody chose it.
#
# THIS IS AN INTEGRATION TEST BECAUSE THE BEHAVIOUR IS THE REAL FILESYSTEM'S.
# The adapter is one of the thin ones CLAUDE.md exempts from unit testing, and a
# fake cannot reproduce a read-only attribute that only NTFS enforces.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # Under the session's own temp, created here and removed here.
    $script:root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('HDT-ro-' + [guid]::NewGuid().ToString('N'))
    [void] (New-Item -ItemType Directory -Path $script:root -Force)
}

AfterAll {
    if ($script:root -and (Test-Path -LiteralPath $script:root)) {
        # -Force here for the same reason the adapter needs it: this cleanup
        # deletes the very read-only files the test made.
        Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'New-HDTFileSystem RemoveItem and the read-only attribute' {

    It 'removes a read-only file' {
        $fileSystem = New-HDTFileSystem
        $path = Join-Path -Path $script:root -ChildPath 'lone.txt'

        Set-Content -LiteralPath $path -Value 'x'
        Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $true

        # ANTI-VACUITY: prove the attribute is actually set, or this test passes
        # against a file that was never read-only and proves nothing.
        (Get-Item -LiteralPath $path).IsReadOnly | Should -BeTrue

        $fileSystem.RemoveItem($path, $false)

        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'removes a tree containing a read-only file, which is what the ADK media tree is' {
        $fileSystem = New-HDTFileSystem
        $tree = Join-Path -Path $script:root -ChildPath 'media'
        $nested = Join-Path -Path $tree -ChildPath 'nested'

        [void] (New-Item -ItemType Directory -Path $nested -Force)

        # autorun.inf by name, because that is the file that did it.
        $autorun = Join-Path -Path $tree -ChildPath 'autorun.inf'
        Set-Content -LiteralPath $autorun -Value '[autorun]'
        Set-ItemProperty -LiteralPath $autorun -Name IsReadOnly -Value $true

        $deep = Join-Path -Path $nested -ChildPath 'bootmgr'
        Set-Content -LiteralPath $deep -Value 'x'
        Set-ItemProperty -LiteralPath $deep -Name IsReadOnly -Value $true

        (Get-Item -LiteralPath $autorun).IsReadOnly | Should -BeTrue
        (Get-Item -LiteralPath $deep).IsReadOnly | Should -BeTrue

        $fileSystem.RemoveItem($tree, $true)

        Test-Path -LiteralPath $tree | Should -BeFalse
    }

    It 'still refuses a populated directory when recursion was not asked for' {
        # THE CONTRACT THE FIX MUST NOT BREAK. Directory.Delete throws
        # IOException for a populated directory without recursion, the fake
        # reproduces that, and callers rely on it.
        $fileSystem = New-HDTFileSystem
        $tree = Join-Path -Path $script:root -ChildPath 'populated'

        [void] (New-Item -ItemType Directory -Path $tree -Force)
        Set-Content -LiteralPath (Join-Path -Path $tree -ChildPath 'a.txt') -Value 'x'

        { $fileSystem.RemoveItem($tree, $false) } | Should -Throw

        Test-Path -LiteralPath $tree | Should -BeTrue
    }
}
