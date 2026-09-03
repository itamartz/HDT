# EVERY CATEGORY ON A SHARE DREW THE SAME FOLDER.
#
# Boot Image, Applications, Operating Systems, Task Sequences and Monitoring are
# all Kind 'Category', and Get-HDTConsoleIcon gives that kind a closed folder -
# so five of the seven rows under a share were the same picture, one under
# another. Drivers and Selection Profiles were not, because each asks for a named
# glyph; the other five simply never did.
#
# WHAT AN ICON IS FOR. Deployment Workbench gives every node its own, and the
# reason is the one thing an icon is genuinely good at: finding the row you want
# without reading. Five identical folders is a tree that has to be read
# top-to-bottom every time, which is slower than no icons at all - the eye stops
# on each one and learns nothing.
#
# THE CATEGORY TAKES THE GLYPH OF WHAT IT HOLDS, which is the pattern the two
# working rows already set: the Drivers category wears the driver-store glyph and
# Selection Profiles wears the clipboard. This test asserts the SET is distinct
# rather than naming the characters, because which picture belongs to a task
# sequence is a decision that may be revisited and "they are all different" is
# the part that must not regress.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') `
            -Force -ErrorAction Stop

        # A SHARE WITH NOTHING ON IT STILL DRAWS EVERY CATEGORY, which is the
        # case that matters: a new share is where somebody is looking hardest for
        # the row they want.
        $script:emptyShare = New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
        }

        $script:tree = Get-HDTConsoleShareNode -Workspace (
            Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem $script:emptyShare)

        # THE CATEGORY ROWS, in the order the tree draws them.
        $script:category = @(@($script:tree.Children) | Where-Object {
                [string] $_.Kind -eq 'Category' -or [string] $_.Kind -eq 'MonitorCategory'
            })

        $script:iconOf = {
            param([string] $Text)
            $row = @($script:category) | Where-Object { [string] $_.Text -like ('{0}*' -f $Text) } |
                Select-Object -First 1
            if ($null -eq $row) { return '' }
            return [string] $row.Icon
        }
    }

    Describe 'the icons on a share''s category rows' {

        It 'draws all nine categories' {
            # If this drops, the assertion below stops covering what it names.
            @($script:category).Count | Should -Be 9
        }

        It 'gives every category a glyph of some kind' {
            foreach ($row in @($script:category)) {
                [string] $row.Icon |
                    Should -Not -BeNullOrEmpty -Because ('{0} needs an icon' -f $row.Text)
            }
        }

        # THE ONE THAT WAS WRONG.
        It 'gives no two categories the same picture' {
            $icon = @(@($script:category) | ForEach-Object { [string] $_.Icon })

            @($icon | Select-Object -Unique).Count |
                Should -Be @($icon).Count -Because 'a row you cannot tell apart is a row you have to read'
        }

        It 'does not draw <Category> as a plain folder any more' -ForEach @(
            @{ Category = 'Boot Image' }
            @{ Category = 'Applications' }
            @{ Category = 'Operating Systems' }
            @{ Category = 'Task Sequences' }
        ) {
            $folder = [char]::ConvertFromUtf32(0x1F4C1)

            (& $script:iconOf $Category) | Should -Not -BeExactly $folder
        }

        It 'keeps the two that were already right' {
            (& $script:iconOf 'Drivers') |
                Should -BeExactly (Get-HDTConsoleIcon -Kind 'DriverStore' -Status 'Ok')

            (& $script:iconOf 'Selection Profiles') |
                Should -BeExactly (Get-HDTConsoleIcon -Kind 'SelectionProfile' -Status 'Ok')
        }

        # THE CATEGORY WEARS WHAT IT HOLDS, as Drivers and Selection Profiles
        # already did. Anything else would be a second decision to remember.
        It 'gives <Category> the glyph of a <Kind>' -ForEach @(
            @{ Category = 'Boot Image'; Kind = 'BootImage' }
            @{ Category = 'Applications'; Kind = 'Application' }
            @{ Category = 'Operating Systems'; Kind = 'OperatingSystem' }
            @{ Category = 'Task Sequences'; Kind = 'TaskSequence' }
        ) {
            (& $script:iconOf $Category) |
                Should -BeExactly (Get-HDTConsoleIcon -Kind $Kind -Status 'Ok')
        }

        # THE NEWEST CATEGORY, AND THE ONE MOST AT RISK OF THE OLD DEFECT: an
        # optical disc is already the Operating Systems glyph, so the obvious
        # picture for a disc-burning node is one somebody would have to read the
        # label to tell apart.
        It 'gives Media a glyph of its own, not the plain folder every category used to wear' {
            (& $script:iconOf 'Media') |
                Should -BeExactly (Get-HDTConsoleIcon -Kind 'Media' -Status 'Ok')

            (& $script:iconOf 'Media') | Should -Not -BeExactly ([char]::ConvertFromUtf32(0x1F4C1))
            (& $script:iconOf 'Media') |
                Should -Not -BeExactly (Get-HDTConsoleIcon -Kind 'OperatingSystem' -Status 'Ok')
        }
    }

    # THE SET, NOT THE ONE THAT WAS JUST ADDED.
    #
    # Get-HDTConsoleIcon's -Kind ValidateSet is closed on purpose, and the glyph
    # table beside it is a separate hashtable - so a kind added to the set and
    # not to the table returns an EMPTY STRING rather than throwing, which draws
    # as a row with no picture and looks like a theme problem. This reads the
    # ValidateSet by reflection and makes every value in it account for itself.
    Describe 'every Kind Get-HDTConsoleIcon accepts' {

        BeforeAll {
            $script:kind = @(
                (Get-Command -Name 'Get-HDTConsoleIcon').Parameters['Kind'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                    ForEach-Object { $_.ValidValues }
            )
        }

        It 'read the set at all, so the rest of this is testing something' {
            @($script:kind).Count | Should -BeGreaterThan 10
            $script:kind | Should -Contain 'Media'
        }

        It 'gives every Kind in the ValidateSet a glyph, with none falling through' {
            foreach ($current in @($script:kind)) {
                Get-HDTConsoleIcon -Kind $current -Status 'Ok' |
                    Should -Not -BeNullOrEmpty -Because ("{0} is in the ValidateSet and needs a line in the glyph table" -f $current)
            }
        }

        # THE SAME TRAP, ONE TABLE OVER. Get-HDTConsoleIconColor carries its own
        # copy of the set and its own hashtable, and a kind missing from that one
        # returns an empty brush - a glyph drawn in whatever the row inherits.
        It 'gives every Kind a colour too, from the other table that keeps its own copy' {
            foreach ($current in @($script:kind)) {
                Get-HDTConsoleIconColor -Kind $current -Status 'Ok' |
                    Should -Not -BeNullOrEmpty -Because ("{0} needs a line in the colour table as well" -f $current)
            }
        }
    }

    Describe 'Get-HDTConsoleIcon for the Monitoring category' {

        It 'is not a folder' {
            Get-HDTConsoleIcon -Kind 'MonitorCategory' -Status 'Ok' |
                Should -Not -BeExactly ([char]::ConvertFromUtf32(0x1F4C1))
        }

        It 'still gives a stalled row the warning sign, like everything else' {
            # An error overrides the kind. That must not have been lost.
            Get-HDTConsoleIcon -Kind 'MonitorCategory' -Status 'Error' |
                Should -BeExactly ([string] ([char] 0x26A0))
        }
    }
}
