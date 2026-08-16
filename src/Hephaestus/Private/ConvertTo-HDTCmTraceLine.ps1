function ConvertTo-HDTCmTraceLine {
    <#
        .SYNOPSIS
            Renders one CMTrace line.

        .DESCRIPTION
            The second of the two formats every Write-HDTLog call emits. MDT
            administrators have CMTrace or OneTrace open already and know how to
            read it, so emitting the same format means their existing workflow,
            filtering and error highlighting work on day one - deliberately not a
            new thing to learn.

            The line, exactly:

              <![LOG[<message>]LOG]!><time="HH:mm:ss.fff+000" date="MM-dd-yyyy"
              component="<component>" context="" type="<1|2|3>" thread="<id>"
              file="<file>">

            type maps 1 = Info and Debug, 2 = Warning, 3 = Error, which is what
            gives CMTrace its colour coding for free.

            ONE PHYSICAL LINE, ALWAYS. CMTrace's parser is line oriented, so a
            carriage return or a line feed inside the message would split one
            entry into two malformed ones. Both are replaced by a space.

            Every field is rendered in the INVARIANT culture. A German or Swedish
            machine would otherwise write a dotted date or a comma decimal
            separator into a format whose reader expects neither, and the engine
            ships to machines whose culture nobody chose.

            The function is pure: same arguments, same string, no clock, no
            filesystem, no state.

        .PARAMETER Message
            The message. Carriage returns and line feeds are replaced by spaces.

        .PARAMETER Component
            The component attribute - the subsystem the entry came from.

        .PARAMETER Severity
            Error, Warning, Info or Debug.

        .PARAMETER Timestamp
            The instant to render. Rendered as given, so the caller decides
            whether it is UTC.

        .PARAMETER ThreadId
            The thread attribute.

        .PARAMETER File
            The file attribute - the step type, the script name or Engine.

        .OUTPUTS
            System.String

        .EXAMPLE
            ConvertTo-HDTCmTraceLine -Message 'Applied index 1' -Component 'ImageService' `
                -Severity Info -Timestamp $now -ThreadId 4820 -File 'ApplyImage'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Message,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Component,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Error', 'Warning', 'Info', 'Debug')]
        [string] $Severity,

        [Parameter(Mandatory = $true)]
        [datetime] $Timestamp,

        [Parameter(Mandatory = $true)]
        [int] $ThreadId,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $File
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture

    # CRLF first, so one line break becomes one space rather than two.
    $flat = $Message.Replace("`r`n", ' ').Replace("`r", ' ').Replace("`n", ' ')

    $type = '1'
    if ($Severity -eq 'Warning') {
        $type = '2'
    }
    if ($Severity -eq 'Error') {
        $type = '3'
    }

    return ('<![LOG[{0}]LOG]!><time="{1}+000" date="{2}" component="{3}" context="" type="{4}" thread="{5}" file="{6}">' -f
        $flat,
        $Timestamp.ToString('HH:mm:ss.fff', $invariant),
        $Timestamp.ToString('MM-dd-yyyy', $invariant),
        $Component,
        $type,
        $ThreadId.ToString($invariant),
        $File)
}
