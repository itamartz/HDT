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
            is a Category like the others and behaves like one; it just does not
            look like a folder. Asking for a named glyph keeps that choice in
            this table with all the others rather than putting a literal
            character in the node builder.

            AND EVERY CATEGORY DOES THAT NOW. Drivers and Selection Profiles
            were the only two that did, so the other five rows under a share -
            Boot Image, Applications, Operating Systems, Task Sequences and
            Monitoring - all drew the same closed folder, one under another.
            Five identical pictures is worse than none: the eye stops on each
            one and learns nothing, so the tree has to be read top to bottom
            every time. Each category wears the glyph of what it HOLDS, which is
            the pattern those two already set.

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
        [ValidateSet('Root', 'Share', 'Category', 'TaskSequence', 'OperatingSystem', 'Application', 'BootImage', 'Empty',
            'DriverStore', 'SelectionProfile', 'DriverFolder', 'Folder', 'StepGroup', 'Step', 'MonitorRun', 'MonitorCategory',
            'WindowsUpdate', 'UpdateRelease', 'Media')]
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
        Application     = [char]::ConvertFromUtf32(0x1F4E6)   # package - one thing that gets installed
        # A SATELLITE DISH, NOT A FLOPPY. The floppy is the universal Save icon -
        # every toolbar in Windows has used it for thirty years - so on the one
        # row that is a bootable image it read as "save this", which is not an
        # action this row has. A dish is where a boot image is SERVED FROM: the
        # thing a bare machine reaches for over PXE before it has an operating
        # system, which is the whole point of the row.
        BootImage       = [char]::ConvertFromUtf32(0x1F4E1)   # satellite antenna - served to a machine that has nothing yet
        DriverStore     = [char]::ConvertFromUtf32(0x1F5A7)   # networked computers - the NIC nobody can boot without

        # A CLIPBOARD - A SAVED LIST - AND DELIBERATELY NOT A TICK BOX. The
        # first version used one, and a tick box in a tree says "tick me": these
        # rows cannot be ticked, and the ticking happens in the profile editor
        # this row OPENS. An icon that offers an interaction the row does not
        # have is worse than a dull one, because somebody clicks it to find out.
        SelectionProfile = [char]::ConvertFromUtf32(0x1F4CB)   # clipboard - a saved list of folders
        # THE STORE'S OWN FOLDERS ARE THEIR OWN KIND. They look like folders and
        # are not: Delete Folder edits a folder: LABEL in a document, and a driver
        # folder is a real directory - so a shared Kind offered the wrong action.
        DriverFolder    = [char]::ConvertFromUtf32(0x1F4C1)   # closed folder, like any container
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
        # A CHART, NOT A FOLDER AND NOT A SECOND COMPUTER. The category is the
        # list of what is happening; a run under it is one machine. Giving the
        # category the machine glyph too would put the same picture on a parent
        # and its child, which is the thing this table stopped doing.
        MonitorCategory = [char]::ConvertFromUtf32(0x1F4CA)   # bar chart - what every machine is doing
        # A SHIELD, WHICH IS WHAT WINDOWS ITSELF PUTS ON AN UPDATE. Windows
        # Update, Security and every elevation prompt use it, so it is the one
        # glyph an administrator already reads as "patch" without being taught.
        # NOT a wrench (that is Tools in every browser) and not a download arrow
        # (these are already downloaded - the arrow would say the row does the
        # fetching, which is the deferred ONLINE step's job, not this one).
        # ConvertFromUtf32, NOT [char]: 0x1F6E1 is above the basic multilingual
        # plane and does not fit in a [char] at all - the cast is a compile-time
        # overflow, not a wrong-looking glyph.
        WindowsUpdate   = [char]::ConvertFromUtf32(0x1F6E1)   # shield
        # THE RELEASE GROUPING ROW IS A DISC, MATCHING OperatingSystem, because
        # that is what it names: "Windows 11 24H2" is an operating system, and
        # the updates under it are for that. A folder glyph here would say the
        # row is somewhere to put things, and it is not - it is computed from
        # what the updates declare and cannot be created or renamed.
        UpdateRelease   = [char]::ConvertFromUtf32(0x1F4BF)   # optical disc - the release these updates are for

        # A BRIEFCASE, AND DELIBERATELY NOT A DISC. The obvious picture for a
        # node that burns an ISO is an optical disc, and OperatingSystem has
        # already got it - two rows under the same share wearing the same
        # picture is the exact defect this table was rewritten to remove, and it
        # would be the worst place to reintroduce it: an operating system and a
        # disc BUILT FROM one are the two things somebody most needs to tell
        # apart at a glance.
        #
        # AND THE BRIEFCASE SAYS WHAT THE NODE IS FOR. Standalone media is the
        # share PACKED TO TRAVEL - DESIGN 13 calls it a content projection of
        # the share with the provider swapped - carried to a site with no
        # network by somebody who cannot reach the deployment share at all. The
        # output happens to be an ISO today and a USB stick tomorrow; what does
        # not change is that it leaves the building.
        Media           = [char]::ConvertFromUtf32(0x1F4BC)   # briefcase - the share packed to travel
        Empty           = [string] ([char] 0x25AB)            # small white square
    }

    return [string] $glyph[$Kind]
}
