# EVERY bcdedit COMMAND LINE THE TRANSPORT RUNS, AS DATA.
#
# DERIVED FROM MDT - ZTIBCDUtility.vbs, CreateNewBCDEntryEx (:108-160),
# CreateRamDiskEntryEx (:85-99) and AdjustBCDDefaults (:163-172). See NOTICE.md.
#
# WHY THIS IS A FUNCTION AND NOT TEN LINES IN THE ADAPTER. New-HDTImageService is
# deliberately untested - every method in it writes to a disk or reorders a
# machine's boot configuration - and the price of not testing it is that it must
# stay dumb (CLAUDE.md rule 1). Ten bcdedit invocations, in an order that
# matters, with a ramdisk device syntax that is wrong in six ways it does not
# report, is not dumb. So the ORDER and the ARGUMENTS are decided here, where
# they can be asserted character by character, and the adapter is a loop that
# runs them.
#
# THE ONE DIFFERENCE FROM MDT THAT MATTERS IS WHAT IS *NOT* HERE.
# AdjustBCDDefaults runs four commands - /timeout 0, /displayorder /addfirst,
# /bootsequence and /default. HDT runs one: /bootsequence. MDT's version is not
# a one-shot at all, which is why LTICleanup.wsf:119-121 has to delete the entry
# afterwards or the machine boots WinPE forever. With /bootsequence alone,
# {default} goes on naming Windows, so a machine that never comes back to be
# torn down degrades to "boots Windows" instead of "stranded in WinPE".
#
# It is private, so every call runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:id = '{7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}'

    $script:command = {
        param([hashtable] $Argument)

        # The result is re-wrapped OUTSIDE InModuleScope: a unary comma inside it
        # is not unrolled on the way out, so the caller would get one array
        # object where it asked for ten commands - which fails as "got /", the
        # first character of a string, rather than as anything readable.
        $result = InModuleScope Hephaestus -Parameters @{ Argument = $Argument } {
            param($Argument)
            Get-HDTBcdCommand @Argument
        }

        return , ([object[]] @($result))
    }

    $script:createArgument = {
        param([string] $Store)

        return @{
            Action        = 'Create'
            Store         = $Store
            Id            = $script:id
            Description   = 'HDT Windows PE'
            RamdiskVolume = 'C:'
            WimDevicePath = '\HDT\Boot\boot.wim'
            SdiDevicePath = '\HDT\Boot\boot.sdi'
            LoaderPath    = '\windows\system32\boot\winload.efi'
        }
    }

    # The whole command as one string, which is what an assertion about argument
    # ORDER reads like without a page of index arithmetic.
    $script:line = {
        param([object[]] $Command)

        return [string[]] @($Command | ForEach-Object { $_.Argument -join ' ' })
    }

    $script:createLine = {
        param([string] $Store)

        return & $script:line (& $script:command (& $script:createArgument $Store))
    }
}

Describe 'Get-HDTBcdCommand' {

    Context 'Create' {

        It 'creates the ramdisk options object before anything references it' {
            $line = & $script:createLine ''

            $line[0] | Should -BeExactly '/create {ramdiskoptions} -d Ramdisk Device Options'
            $line[1] | Should -BeExactly '/set {ramdiskoptions} ramdisksdidevice partition=C:'
            $line[2] | Should -BeExactly '/set {ramdiskoptions} ramdisksdipath \HDT\Boot\boot.sdi'
        }

        # THE ONE TOLERATED COMMAND, AND IT HAS TO BE TOLERATED.
        # {ramdiskoptions} is a well-known object: a machine with a registered
        # WinRE already has one, and bcdedit /create on an existing object fails
        # with "The object already exists". Deleting it first is not an option -
        # WinRE points at it, and removing it would break Reset This PC on a
        # machine HDT was only supposed to reboot. So the create is allowed to
        # fail, and the two /set calls after it are what prove the object is
        # there.
        It 'tolerates the ramdisk options object already existing, and nothing else' {
            $command = & $script:command (& $script:createArgument '')

            @($command | Where-Object { $_.Tolerate }).Count | Should -Be 1
            $command[0].Tolerate | Should -BeTrue
        }

        # THE DESCRIPTION IS ONE BARE TOKEN, NOT A QUOTED ONE. These arguments
        # are splatted at bcdedit.exe as an array and Windows PowerShell quotes
        # what needs quoting; quotes written into the token would reach bcdedit
        # as literal characters and end up in the entry's own name.
        It 'passes the description as a single unquoted argument' {
            $command = & $script:command (& $script:createArgument '')

            $command[3].Argument[2] | Should -BeExactly '-d'
            $command[3].Argument[3] | Should -BeExactly 'HDT Windows PE'
        }

        It 'creates the entry as an OSLOADER application carrying the fixed id' {
            $line = & $script:createLine ''

            $line[3] | Should -BeExactly ('/create {0} -d HDT Windows PE -application OSLOADER' -f $script:id)
        }

        # THE RAMDISK DEVICE SYNTAX, WHICH IS THE PART THAT GOES WRONG SILENTLY.
        # bcdedit accepts device and osdevice strings it cannot boot and reports
        # success; the failure arrives as a black screen with an 0xc000000f, on a
        # machine that has already been generalized.
        It 'points device and osdevice at the staged wim through the ramdisk options' {
            $line = & $script:createLine ''

            $line[4] | Should -BeExactly ('/set {0} device ramdisk=[C:]\HDT\Boot\boot.wim,{{ramdiskoptions}}' -f $script:id)
            $line[5] | Should -BeExactly ('/set {0} osdevice ramdisk=[C:]\HDT\Boot\boot.wim,{{ramdiskoptions}}' -f $script:id)
        }

        It 'sets the loader path it was given rather than choosing one' {
            $line = & $script:createLine ''

            $line[6] | Should -BeExactly ('/set {0} path \windows\system32\boot\winload.efi' -f $script:id)
        }

        It 'sets systemroot, detecthal and winpe, which is what makes it a WinPE entry' {
            $line = & $script:createLine ''

            $line[7] | Should -BeExactly ('/set {0} systemroot \windows' -f $script:id)
            $line[8] | Should -BeExactly ('/set {0} detecthal yes' -f $script:id)
            $line[9] | Should -BeExactly ('/set {0} winpe yes' -f $script:id)
        }

        It 'runs ten commands and no more' {
            (& $script:command (& $script:createArgument '')).Count | Should -Be 10
        }

        # NOT IN THE LIST, DELIBERATELY. Adding the entry to /displayorder makes
        # it a permanent menu item on a machine that is about to be captured or
        # handed over; MDT does it, and MDT needs LTICleanup to undo it.
        It 'never touches displayorder, default or timeout' {
            $joined = (& $script:createLine '') -join ' '

            $joined | Should -Not -Match 'displayorder'
            $joined | Should -Not -Match '/default'
            $joined | Should -Not -Match 'timeout'
        }
    }

    Context 'Arm' {

        It 'is one command, and it is bootsequence' {
            $command = & $script:command @{ Action = 'Arm'; Store = ''; Id = $script:id }

            $command.Count | Should -Be 1
            ($command[0].Argument -join ' ') | Should -BeExactly ('/bootsequence {0}' -f $script:id)
            $command[0].Tolerate | Should -BeFalse
        }
    }

    Context 'Remove' {

        # /cleanup is what takes the entry out of every list that references it.
        # Without it bcdedit leaves a dangling displayorder entry behind. This is
        # MDT's own teardown (LTICleanup.wsf:120) and the one part of its BCD
        # handling that is unambiguously right.
        It 'deletes the entry and cleans up the references to it' {
            $command = & $script:command @{ Action = 'Remove'; Store = ''; Id = $script:id }

            $command.Count | Should -Be 1
            ($command[0].Argument -join ' ') | Should -BeExactly ('/delete {0} /cleanup' -f $script:id)
        }

        # The ramdisk options object is NOT deleted. A registered WinRE points at
        # it, so removing it would break Reset This PC on a machine HDT was only
        # asked to reboot.
        It 'leaves the ramdisk options object alone' {
            $command = & $script:command @{ Action = 'Remove'; Store = ''; Id = $script:id }

            ($command[0].Argument -join ' ') | Should -Not -Match 'ramdiskoptions'
        }
    }

    Context 'the store' {

        # THE BRANCH THAT KEEPS THE ADAPTER BRANCH-FREE. In the full OS the
        # machine booted through the store bcdedit already targets, so naming one
        # would mean finding the EFI System Partition's drive letter - which it
        # does not have. In WinPE the running store is the RAM disk's and is the
        # wrong one, so the path is named explicitly.
        It 'prefixes every command with /store when one is named' {
            foreach ($entry in @(& $script:command (& $script:createArgument 'S:\EFI\Microsoft\Boot\BCD'))) {
                $entry.Argument[0] | Should -BeExactly '/store'
                $entry.Argument[1] | Should -BeExactly 'S:\EFI\Microsoft\Boot\BCD'
            }
        }

        It 'prefixes nothing when the store is empty, so bcdedit uses the system store' {
            foreach ($entry in @(& $script:command (& $script:createArgument ''))) {
                $entry.Argument[0] | Should -Not -BeExactly '/store'
            }
        }

        It 'prefixes the arm and the removal too' {
            foreach ($action in @('Arm', 'Remove')) {
                $command = & $script:command @{ Action = $action; Store = 'S:\Boot\BCD'; Id = $script:id }

                $command[0].Argument[0] | Should -BeExactly '/store'
                $command[0].Argument[1] | Should -BeExactly 'S:\Boot\BCD'
            }
        }
    }

    Context 'what it refuses' {

        It 'refuses an action it does not know' {
            { & $script:command @{ Action = 'Adjust'; Store = ''; Id = $script:id } } | Should -Throw
        }

        # A bare word here becomes a bcdedit command line that silently does
        # something else - {default}, {current} and {bootmgr} are all legal
        # identifiers, and deleting one of those is a machine that will not start.
        It 'refuses an id that is not a braced GUID' {
            { & $script:command @{ Action = 'Remove'; Store = ''; Id = 'default' } } | Should -Throw
        }
    }
}
