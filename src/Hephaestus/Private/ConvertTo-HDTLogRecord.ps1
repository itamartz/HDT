function ConvertTo-HDTLogRecord {
    <#
        .SYNOPSIS
            Builds one DESIGN 4.4.2 JSONL record as an ordered dictionary.

        .DESCRIPTION
            The structured half of "two formats, one write". HDT.jsonl is the
            source of truth the report renderer and the console's monitoring view
            consume, so every line is one object with the same shape:

              ts, runId, seq, level, phase, stepIndex, stepName, stepType,
              component, event, message, durationMs, data

            THE TIMESTAMP IS A FORMATTED STRING, NEVER A [datetime]. ConvertTo-Json
            renders a raw [datetime] as ISO 8601 under pwsh 7 and as
            "\/Date(1786579862481)\/" under Windows PowerShell 5.1 - and 5.1 is the
            engine that runs in WinPE, so a raw [datetime] would make the log
            unreadable exactly where it matters. The round-trip 'o' format in the
            invariant culture is identical on both engines.

            The step fields are OMITTED, not nulled, when no step is executing,
            and so are durationMs and data when the caller supplied neither: a
            record whose absent fields are absent reads correctly in a JSONL
            viewer and filters correctly in the console.

            The function is pure - no clock, no filesystem, no state.

        .PARAMETER Context
            The log context, for runId, phase and the step fields.

        .PARAMETER Timestamp
            The instant, already read from the injected clock.

        .PARAMETER Seq
            The sequence number, already taken from the context.

        .PARAMETER Level
            Error, Warning, Info or Debug.

        .PARAMETER Event
            One of DESIGN 4.4.2's controlled vocabulary names.

        .PARAMETER Component
            The component the entry came from.

        .PARAMETER Message
            The message an administrator reads.

        .PARAMETER DurationMs
            How long the thing being reported took. Omitted when not supplied.

        .PARAMETER Data
            Step-specific detail, nested rather than polluting the top level.
            Omitted when not supplied.

        .OUTPUTS
            System.Collections.Specialized.OrderedDictionary

        .EXAMPLE
            ConvertTo-HDTLogRecord -Context $context -Timestamp $now -Seq 417 `
                -Level Info -Event step.complete -Component ImageService `
                -Message 'Applied index 1'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Event',
        Justification = 'DESIGN 4.4.2 names this field event; it is never PowerShell eventing''s automatic variable.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [datetime] $Timestamp,

        [Parameter(Mandatory = $true)]
        [long] $Seq,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Error', 'Warning', 'Info', 'Debug')]
        [string] $Level,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Event,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Component,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Message,

        [Parameter()]
        [AllowNull()]
        [System.Nullable[long]] $DurationMs,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Data
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $record = [ordered] @{}

    # A [string], never the [datetime] itself - see the description.
    $record['ts'] = $Timestamp.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $record['runId'] = $Context.RunId
    $record['seq'] = $Seq
    $record['level'] = $Level
    $record['phase'] = $Context.Phase

    if ($Context.StepIndex -gt 0) {
        $record['stepIndex'] = $Context.StepIndex
        $record['stepName'] = $Context.StepName
        $record['stepType'] = $Context.StepType
    }

    $record['component'] = $Component
    $record['event'] = $Event
    $record['message'] = $Message

    if ($null -ne $DurationMs) {
        $record['durationMs'] = $DurationMs
    }

    if ($null -ne $Data) {
        $record['data'] = $Data
    }

    return $record
}
