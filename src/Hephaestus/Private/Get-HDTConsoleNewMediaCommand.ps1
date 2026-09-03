function Get-HDTConsoleNewMediaCommand {
    <#
        .SYNOPSIS
            The New Media window's footer line: the whole New-HDTMedia
            invocation Create is about to run.

        .DESCRIPTION
            DESIGN 12 IS THE WHOLE REASON THIS EXISTS - every action the
            console performs maps to a cmdlet invocation, and the console
            shows that invocation, so an administrator can learn the
            automation surface by clicking around and script anything they can
            do in the UI.

            AN EMPTY OUTPUT BOX IS NOT AN ANSWER SOMEBODY GAVE. New-HDTMedia
            fills in Media\<id>\HDT_<id>.iso on its own when -Output is left
            off, so a line that always named -Output even when the box was
            never touched would be a line that no longer matches what Create
            is about to do.

        .PARAMETER Workspace
            The share the media definition is being created on.

        .PARAMETER Id
            The media id, which is also its folder name under Media\.

        .PARAMETER Name
            What the media item is called.

        .PARAMETER SelectionProfile
            The profile chosen in the box.

        .PARAMETER Output
            The output box's text. Empty renders no -Output at all.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - one line, ready to paste.

        .EXAMPLE
            Get-HDTConsoleNewMediaCommand -Workspace 'C:\Share' -Id 'WIN11-FIELD' `
                -Name 'Windows 11 field media' -SelectionProfile 'everything' -Output ''

            New-HDTMedia -WorkspaceRoot 'C:\Share' -Id 'WIN11-FIELD' -Name 'Windows 11 field media' -SelectionProfile 'everything'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Workspace,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [string] $Id,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter(Position = 3)]
        [AllowEmptyString()]
        [string] $SelectionProfile = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $Output = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A POWERSHELL LITERAL, NOT A VALUE WITH QUOTES ROUND IT. A share called
    # Frank's is ordinary, and a line that broke on one would be a line
    # nobody could paste - which is the only thing this string is for.
    $literal = {
        param([string] $Value)

        return "'" + ($Value -replace "'", "''") + "'"
    }

    $line = "New-HDTMedia -WorkspaceRoot {0} -Id {1} -Name {2} -SelectionProfile {3}" -f
        (& $literal $Workspace), (& $literal $Id), (& $literal $Name), (& $literal $SelectionProfile)

    if (-not [string]::IsNullOrWhiteSpace($Output)) {
        $line = '{0} -Output {1}' -f $line, (& $literal $Output)
    }

    return $line
}
