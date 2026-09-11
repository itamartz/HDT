# A JUNCTION IS A DOOR, AND THE FRAMEWORK'S RECURSIVE DELETE WALKS THROUGH IT.
#
# On 2026-09-10 the first Refresh ever launched from a running Windows reached
# step 7 of 18 and stopped:
#
#   step 7 'Clean the OS volume' failed: step 'Clean the OS volume':
#   C:\Documents and Settings could not be deleted from C:\, so the volume is
#   only half cleaned.
#   Could not find a part of the path 'C:\Documents and Settings\Administrator\
#   AppData\Local\Application Data\Application Data\Application Data\...
#   \IconCache.db'
#
# TWO JUNCTIONS EVERY WINDOWS INSTALL HAS. C:\Documents and Settings is a legacy
# junction to C:\Users, and inside each profile AppData\Local\Application Data
# is a junction to its own parent. [System.IO.Directory]::GetFiles with
# SearchOption::AllDirectories follows both, so it walked the second one round
# and round until the path ran past MAX_PATH and the walk threw.
#
# "ONLY HALF CLEANED" IS THE WORST ANSWER A WIPE-AND-LOAD CAN GIVE. The old
# installation is neither kept nor gone, and the run that was going to replace
# it has stopped.
#
# AND THE QUIETER HALF, WHICH NO LOG WOULD EVER HAVE SHOWN. A junction pointing
# somewhere else on the machine is followed just as willingly. Deleting a
# directory that merely CONTAINS one would clear the read-only attribute on, and
# then delete, files outside the tree that was asked for. On a volume being
# wiped nobody would notice; on a staging directory beside somebody's data it is
# the last thing a deployment tool should do. That is what the second test here
# is about, and it is the reason this fix is in the adapter rather than in
# CleanVolume.
#
# THIS IS AN INTEGRATION TEST BECAUSE A JUNCTION IS THE REAL FILESYSTEM'S.
# New-HDTFileSystem is one of the thin adapters CLAUDE.md exempts from unit
# testing, and a hand-written fake has no reparse points to reproduce - which is
# exactly why every unit test of CleanVolume passed while this was broken.
# FileSystemReadOnly.Integration.Tests.ps1 is the same shape for the same reason.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # Under the session's own temp, created here and removed here.
    $script:root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('HDT-rp-' + [guid]::NewGuid().ToString('N'))
    [void] (New-Item -ItemType Directory -Path $script:root -Force)

    # mklink /J RATHER THAN New-Item -ItemType Junction, because the cmdlet
    # arrived in PowerShell 5.0 and the engine's floor is 5.1 in WinPE where
    # neither is available anyway - cmd is the one that has always been there.
    $script:newJunction = {
        param([string] $Link, [string] $Target)

        $output = & "$env:SystemRoot\System32\cmd.exe" /c mklink /J "$Link" "$Target" 2>&1

        if (-not (Test-Path -LiteralPath $Link)) {
            throw ("could not create the junction '{0}' -> '{1}': {2}" -f $Link, $Target, ($output -join ' '))
        }
    }
}

AfterAll {
    if ($script:root -and (Test-Path -LiteralPath $script:root)) {
        Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'RemoveItem and reparse points' {

    It 'deletes a tree containing a junction that points at its own parent' {
        # THE PRODUCTION FAILURE, IN MINIATURE. This is the shape of
        # AppData\Local\Application Data: a junction inside a directory,
        # pointing back at the directory that holds it. Following it does not
        # terminate.
        $case = Join-Path -Path $script:root -ChildPath 'loop'
        $profileDir = Join-Path -Path $case -ChildPath 'Administrator'
        [void] (New-Item -ItemType Directory -Path $profileDir -Force)
        [System.IO.File]::WriteAllText((Join-Path -Path $profileDir -ChildPath 'IconCache.db'), 'x')

        & $script:newJunction (Join-Path -Path $profileDir -ChildPath 'Application Data') $profileDir

        $fileSystem = New-HDTFileSystem

        { $fileSystem.RemoveItem($case, $true) } | Should -Not -Throw

        Test-Path -LiteralPath $case | Should -BeFalse
    }

    It 'unlinks a junction and leaves what it points at alone' {
        # THE HALF NO LOG WOULD HAVE SHOWN. 'outside' is not in the tree being
        # deleted and must survive it, file and all.
        $case = Join-Path -Path $script:root -ChildPath 'door'
        [void] (New-Item -ItemType Directory -Path $case -Force)

        $outside = Join-Path -Path $script:root -ChildPath 'outside'
        [void] (New-Item -ItemType Directory -Path $outside -Force)
        $keeper = Join-Path -Path $outside -ChildPath 'keep.txt'
        [System.IO.File]::WriteAllText($keeper, 'this file is not in the tree being deleted')

        & $script:newJunction (Join-Path -Path $case -ChildPath 'link') $outside

        $fileSystem = New-HDTFileSystem
        $fileSystem.RemoveItem($case, $true)

        Test-Path -LiteralPath $case | Should -BeFalse

        Test-Path -LiteralPath $outside | Should -BeTrue -Because 'the junction is the door; deleting it must not delete the room'
        Test-Path -LiteralPath $keeper | Should -BeTrue -Because 'a file outside the tree was never asked about'
        [System.IO.File]::ReadAllText($keeper) | Should -BeExactly 'this file is not in the tree being deleted'
    }

    It 'still deletes an ordinary tree, files and folders alike' {
        # THE CASE THAT ALREADY WORKED, kept because the walk is now this
        # adapter's own rather than the framework's.
        $case = Join-Path -Path $script:root -ChildPath 'plain'
        $nested = Join-Path -Path $case -ChildPath 'a\b\c'
        [void] (New-Item -ItemType Directory -Path $nested -Force)
        [System.IO.File]::WriteAllText((Join-Path -Path $nested -ChildPath 'deep.txt'), 'x')
        [System.IO.File]::WriteAllText((Join-Path -Path $case -ChildPath 'top.txt'), 'x')

        $fileSystem = New-HDTFileSystem
        $fileSystem.RemoveItem($case, $true)

        Test-Path -LiteralPath $case | Should -BeFalse
    }

    It 'still clears a read-only attribute on the way through' {
        # FileSystemReadOnly.Integration.Tests.ps1's subject, asserted again
        # here because the walk that clears the bit was rewritten.
        $case = Join-Path -Path $script:root -ChildPath 'readonly'
        [void] (New-Item -ItemType Directory -Path $case -Force)
        $locked = Join-Path -Path $case -ChildPath 'autorun.inf'
        [System.IO.File]::WriteAllText($locked, 'x')
        [System.IO.File]::SetAttributes($locked, [System.IO.FileAttributes]::ReadOnly)

        $fileSystem = New-HDTFileSystem

        { $fileSystem.RemoveItem($case, $true) } | Should -Not -Throw

        Test-Path -LiteralPath $case | Should -BeFalse
    }

    It 'refuses a populated directory when recursion was not asked for' {
        # THE CONTRACT, unchanged: Directory.Delete throws IOException.
        $case = Join-Path -Path $script:root -ChildPath 'populated'
        [void] (New-Item -ItemType Directory -Path $case -Force)
        [System.IO.File]::WriteAllText((Join-Path -Path $case -ChildPath 'one.txt'), 'x')

        $fileSystem = New-HDTFileSystem

        { $fileSystem.RemoveItem($case, $false) } | Should -Throw

        Test-Path -LiteralPath $case | Should -BeTrue
    }
}

# A DIRECTORY CARRIES ATTRIBUTES TOO, AND Directory.Delete REFUSES ON THEM.
#
# RemoveTree cleared ReadOnly on every FILE it deleted and never on a FOLDER, so
# a directory marked ReadOnly or System threw "Access to the path ... is denied"
# from Directory.Delete - the same sentence an ACL refusal produces, which is
# why four runs on 2026-09-10 were spent taking ownership of C:\Program Files
# and granting Administrators Modify over it. takeown and icacls both SUCCEEDED
# every time; the folder simply had the System bit set, and Windows sets it on
# plenty of them - C:\Program Files\Internet Explorer\images was the one that
# stopped the Refresh.
Describe 'RemoveItem and directory attributes' {

    It 'deletes a directory marked ReadOnly and System' {
        $case = Join-Path -Path $script:root -ChildPath 'attributed'
        $inner = Join-Path -Path $case -ChildPath 'images'
        [void] (New-Item -ItemType Directory -Path $inner -Force)
        [System.IO.File]::WriteAllText((Join-Path -Path $inner -ChildPath 'icon.png'), 'x')

        $info = New-Object System.IO.DirectoryInfo($inner)
        $info.Attributes = [System.IO.FileAttributes]::Directory -bor
            [System.IO.FileAttributes]::ReadOnly -bor [System.IO.FileAttributes]::System

        $fileSystem = New-HDTFileSystem

        { $fileSystem.RemoveItem($case, $true) } | Should -Not -Throw

        Test-Path -LiteralPath $case | Should -BeFalse
    }
}
