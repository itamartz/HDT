function Get-HDTConsoleIcon {
    <#
        .SYNOPSIS
            Chooses the glyph a console row shows.

        .DESCRIPTION
            WHICH PICTURE BELONGS TO A TASK SEQUENCE IS A DECISION, so it lives
            in a command rather than in the window or the host. One table, one
            place, and a test can assert that a share that would not open does
            not look like one that did.

            AN ERROR OVERRIDES THE KIND. A row an administrator must look at is
            the one thing an icon is genuinely good at: the eye finds a warning
            triangle in a tree of folders without reading a word. Everything else
            takes the icon of what it is.

            'Missing' IS NOT AN ERROR AND DOES NOT GET THE TRIANGLE. A share
            whose boot image has never been built is a share partway through
            being set up, and its row already says 'not built' in words. Marking
            it as a fault would train an administrator to ignore the mark.

            THEY ARE CHARACTERS, NOT IMAGE FILES. A .png in the tree is another
            file that has to ship, be found at runtime, and be right in two
            themes. Windows renders these from its own fonts, they scale with the
            row, and they survive being copied out of the window as text.

            'DriverStore' IS A GLYPH NAME, NOT A ROW KIND. The Drivers category
            is a Category like the other three and behaves like one; it just
            does not look like a folder, because "where the drivers are" is the
            one category an administrator scans the tree for by eye. Asking for
            a named glyph keeps that choice in this table with all the others
            rather than putting a literal character in the node builder.

        .PARAMETER Kind
            The row's kind, or a glyph name for a caller that wants a specific
            picture.

        .PARAMETER Status
            The row's status. 'Error' wins over Kind.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTConsoleIcon -Kind 'TaskSequence' -Status 'Ok'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('Root', 'Share', 'Category', 'TaskSequence', 'OperatingSystem', 'BootImage', 'Empty',
            'DriverStore', 'Folder', 'StepGroup', 'Step', 'MonitorRun', 'MonitorCategory')]
        [string] $Kind,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet('Ok', 'Error', 'Missing', 'Warning')]
        [string] $Status
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Status -eq 'Error') {
        return [string] ([char] 0x26A0)          # warning sign
    }

    # A LINT FINDING GETS THE SAME GLYPH AND A DIFFERENT COLOUR. The shape says
    # "look at this"; the colour says how much. Giving a warning its own picture
    # would mean an administrator had to learn two symbols to be told one thing.
    if ($Status -eq 'Warning') {
        return [string] ([char] 0x26A0)
    }

    $glyph = @{
        Root            = [char]::ConvertFromUtf32(0x1F5C4)   # file cabinet - every share
        Share           = [char]::ConvertFromUtf32(0x1F5C2)   # dividers - one share
        Category        = [char]::ConvertFromUtf32(0x1F4C1)   # folder
        TaskSequence    = [char]::ConvertFromUtf32(0x1F5D2)   # spiral notepad - an ordered list of steps
        OperatingSystem = [char]::ConvertFromUtf32(0x1F4BF)   # optical disc
        BootImage       = [char]::ConvertFromUtf32(0x1F4BE)   # floppy disk
        DriverStore     = [char]::ConvertFromUtf32(0x1F5A7)   # networked computers - the NIC nobody can boot without
        Folder          = [char]::ConvertFromUtf32(0x1F4C1)   # closed folder - it holds things and does nothing itself
        StepGroup       = [char]::ConvertFromUtf32(0x1F4C2)   # open folder - a group holds steps, it does not do anything
        # A GEAR, NOT A TRIANGLE. The first version used a small right triangle,
        # which in a TreeView is what an expander looks like - so every step
        # appeared to be a branch that would not open. An action gets an action's
        # icon, the way Deployment Workbench gives each step type one.
        Step            = [string] ([char] 0x2699)            # gear - one thing that runs

        # A MACHINE, NOT A CLOCK. A monitoring row is a computer somewhere
        # partway through a deployment, and that is what a technician is
        # picturing when they scan the list. A stalled one takes the warning
        # sign at the top of this function, like everything else that is wrong.
        MonitorRun      = [char]::ConvertFromUtf32(0x1F5A5)   # desktop computer - one machine deploying
        MonitorCategory = [char]::ConvertFromUtf32(0x1F4C1)   # folder - it is a category like the others
        Empty           = [string] ([char] 0x25AB)            # small white square
    }

    return [string] $glyph[$Kind]
}
