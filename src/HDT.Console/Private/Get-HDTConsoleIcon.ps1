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

        .PARAMETER Kind
            The row's kind.

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
        [ValidateSet('Root', 'Share', 'Category', 'TaskSequence', 'OperatingSystem', 'BootImage', 'Empty')]
        [string] $Kind,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet('Ok', 'Error', 'Missing')]
        [string] $Status
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Status -eq 'Error') {
        return [string] ([char] 0x26A0)          # warning sign
    }

    $glyph = @{
        Root            = [char]::ConvertFromUtf32(0x1F5C4)   # file cabinet - every share
        Share           = [char]::ConvertFromUtf32(0x1F5C2)   # dividers - one share
        Category        = [char]::ConvertFromUtf32(0x1F4C1)   # folder
        TaskSequence    = [char]::ConvertFromUtf32(0x1F4CB)   # clipboard
        OperatingSystem = [char]::ConvertFromUtf32(0x1F4BF)   # optical disc
        BootImage       = [char]::ConvertFromUtf32(0x1F4BE)   # floppy disk
        Empty           = [string] ([char] 0x25AB)            # small white square
    }

    return [string] $glyph[$Kind]
}
