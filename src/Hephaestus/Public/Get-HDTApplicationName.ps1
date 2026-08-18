function Get-HDTApplicationName {
    <#
        .SYNOPSIS
            Composes an application's display name and its id from the publisher,
            the name and the version.

        .DESCRIPTION
            DEPLOYMENT WORKBENCH ASKS FOR THREE THINGS AND MAKES BOTH NAMES OUT
            OF THEM, and this is that rule. '7-Zip' on its own is not an
            application: it is three of them a year apart, and a share where the
            difference between the version everybody runs and the version being
            piloted is somebody's memory of which folder is which is a share that
            installs the wrong one.

            THE ID IS NOT THE DISPLAY NAME. HDT's id is a folder name under
            Applications\ and what a task sequence names to install the entry, so
            it cannot hold a space; the display name can, and should, because it
            is what a technician reads. Composing one from the other is why this
            exists rather than two boxes somebody fills in twice.

            WHAT A FOLDER NAME CANNOT HOLD BECOMES A HYPHEN, and runs of it
            collapse: 'Contoso (Europe)' is an id, not a refusal. A publisher is
            whatever is on the vendor's page, brackets and all, and a dialog that
            refuses the name of the thing being installed is one somebody works
            around by typing something else.

            IT COMPOSES; IT DOES NOT RENAME. Nothing here changes an entry that
            exists - an id is what every sequence, rule and half-finished
            deployment names, so it is decided once, when the application is
            added. Set-HDTApplication has no -Id for the same reason.

        .PARAMETER Publisher
            Who makes it. Workbench's first question, and the reason two entries
            called Reader are tellable apart.

        .PARAMETER Name
            What it is called.

        .PARAMETER Version
            Which version this entry installs.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Display and Id.
            Both are empty when there was nothing to compose from, which is the
            dialog's cue to leave the boxes alone.

        .EXAMPLE
            Get-HDTApplicationName -Publisher 'Igor Pavlov' -Name '7-Zip' -Version '24.09'

            Display 'Igor Pavlov 7-Zip 24.09', Id 'Igor-Pavlov-7-Zip-24.09'.

        .LINK
            Import-HDTApplication
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string] $Publisher = '',

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string] $Name = '',

        [Parameter(Position = 2)]
        [AllowEmptyString()]
        [string] $Version = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $part = @(@($Publisher, $Name, $Version) |
            ForEach-Object { ([string] $_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $display = (@($part) -join ' ').Trim()

    # DOT, DASH AND UNDERSCORE SURVIVE, because they are what a version number
    # is written with - 24.09 must not become 24-09.
    $id = $display -replace '[^A-Za-z0-9._-]+', '-'

    # A LEADING DOT OR DASH IS NOT AN ID the engine accepts, and '.NET Desktop
    # Runtime' is a real name somebody will type.
    $id = $id -replace '^[^A-Za-z0-9]+', ''
    $id = $id -replace '[^A-Za-z0-9]+$', ''

    return [pscustomobject] @{
        Display = $display
        Id      = $id
    }
}
