function New-HDTConsoleMonitorRow {
    <#
        .SYNOPSIS
            One deployment's row on the monitoring view.

        .DESCRIPTION
            Split out of Get-HDTConsoleMonitor because reading a heartbeat and
            judging a heartbeat are two jobs, and the second one has all the
            decisions in it: what health means, what the row says, and what a
            file that would not parse still gets to show.

            HEALTH IS FOUR STATES AND NOT A BOOLEAN. Live and Stalled are the
            two an operator acts on; Finished exists so a completed run cannot
            age into a red row; Unreadable exists so a file caught mid-write
            still puts its machine on the screen.

            AN UNREADABLE HEARTBEAT KEEPS ITS ID, because the id is in the file
            NAME - <RunId>.json - and that is legible when nothing inside the
            file is. It sorts to the top by having no age of its own, which is
            where a machine nobody can see the state of belongs.

            THE ROW LEADS WITH THE RUN AND THE STEP. Those are what a person
            scanning twenty rows is matching against: which machine, and how far
            has it got.

        .PARAMETER RunId
            The run, taken from the file name.

        .PARAMETER Path
            The heartbeat file.

        .PARAMETER Document
            The parsed heartbeat, or nothing if it would not parse.

        .PARAMETER Now
            The instant to measure age against, in UTC.

        .PARAMETER StaleMinute
            How long a heartbeat may go unwritten before its run is stalled.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject

        .EXAMPLE
            New-HDTConsoleMonitorRow -RunId 'RUN-0001' -Path $path -Document $document -Now $now -StaleMinute 20
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds one row of a display model in memory; it changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $RunId,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Position = 2)]
        [AllowNull()]
        [object] $Document,

        [Parameter(Mandatory = $true, Position = 3)]
        [datetime] $Now,

        [Parameter(Mandatory = $true, Position = 4)]
        [int] $StaleMinute
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $command = "ConvertFrom-Json -InputObject ((New-HDTFileSystem).ReadAllText('{0}'))" -f $Path

    # -- the file that would not parse -------------------------------------

    if ($null -eq $Document) {
        return [pscustomobject] @{
            RunId       = $RunId
            Phase       = ''
            RunStatus   = ''
            StepIndex   = 0
            StepName    = ''
            StepType    = ''
            Updated     = $null
            SinceSecond = -1
            SinceText   = ''
            Health      = 'Unreadable'
            Icon        = [string] ([char] 0x26A0)      # warning sign
            Text        = '{0} - the heartbeat could not be read' -f $RunId
            Path        = $Path
            Command     = $command
        }
    }

    $property = @($Document.PSObject.Properties.Name)

    $read = {
        param([string] $Name, [object] $Fallback)

        if ($property -contains $Name) { return $Document.$Name }
        return $Fallback
    }

    $phase = [string] (& $read 'phase' '')
    $runStatus = [string] (& $read 'status' '')
    $stepIndex = [int] (& $read 'stepIndex' 0)
    $stepName = [string] (& $read 'stepName' '')
    $stepType = [string] (& $read 'stepType' '')

    # -- how long since it said anything -----------------------------------

    $updated = $null
    $since = -1

    $stamp = & $read 'updated' $null

    # ConvertFrom-Json ALREADY TURNED IT INTO A [datetime], and casting that back
    # to a string is where three hours went missing. PowerShell's JSON reader
    # silently converts an ISO-8601 string into a DateTime - a LOCAL one - so
    # [string] renders it in the current culture ("16/08/2026 01:00:00"), and
    # parsing THAT as a round-trip timestamp reads the local wall clock as
    # though it were UTC. Every age on this screen came out one time-zone
    # offset too large, on a host east of UTC, and the failures pointed at the
    # arithmetic rather than at the cast.
    #
    # So the value is taken as it arrives, whichever it is. A share is also
    # entitled to hold a heartbeat written by something that quoted the field
    # differently, and the string path still reads it.
    if ($stamp -is [datetime]) {
        $updated = ([datetime] $stamp).ToUniversalTime()
        $since = [int] ($Now - $updated).TotalSeconds
    } elseif (-not [string]::IsNullOrWhiteSpace([string] $stamp)) {
        $parsed = [datetime]::MinValue

        # RoundtripKind ALONE, and the conversion by hand. Write-HDTStatus
        # formats with 'o' precisely so this can be read back without a culture
        # in the middle of it, and 'o' carries the offset - which is what
        # RoundtripKind honours. It cannot be combined with AdjustToUniversal:
        # .NET rejects the pair outright rather than ignoring one of them.
        if ([datetime]::TryParse([string] $stamp, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind, [ref] $parsed)) {

            $updated = $parsed.ToUniversalTime()
            $since = [int] ($Now - $updated).TotalSeconds
        }
    }

    # -- what that makes it ------------------------------------------------
    #
    # A run the engine has finished is Finished however long ago that was: a
    # completed heartbeat is not a heartbeat that stopped, and ageing one into a
    # red row teaches a technician to ignore red.
    $health = 'Live'

    if ($runStatus -ne 'Running' -and -not [string]::IsNullOrWhiteSpace($runStatus)) {
        $health = 'Finished'
    } elseif ($since -lt 0) {
        # It parsed, but carried no timestamp anybody can read.
        $health = 'Unreadable'
    } elseif ($since -gt ($StaleMinute * 60)) {
        $health = 'Stalled'
    }

    $icon = [string] ([char] 0x25B6)                    # play - running
    if ($health -eq 'Stalled') { $icon = [string] ([char] 0x26A0) }
    if ($health -eq 'Finished') { $icon = [string] ([char] 0x2714) }
    if ($health -eq 'Unreadable') { $icon = [string] ([char] 0x26A0) }

    $sinceText = ''
    if ($since -ge 0) { $sinceText = Format-HDTConsoleDuration -Second $since }

    $step = Get-HDTConsoleDisplayText -Text $stepName -Fallback '(no step yet)'

    $text = '{0} - {1}' -f $RunId, $step
    if (-not [string]::IsNullOrWhiteSpace($sinceText)) {
        $text = '{0} - {1}  ({2} ago)' -f $RunId, $step, $sinceText
    }

    return [pscustomobject] @{
        RunId       = $RunId
        Phase       = $phase
        RunStatus   = $runStatus
        StepIndex   = $stepIndex
        StepName    = $stepName
        StepType    = $stepType
        Updated     = $updated
        SinceSecond = $since
        SinceText   = $sinceText
        Health      = $health
        Icon        = $icon
        Text        = $text
        Path        = $Path
        Command     = $command
    }
}
