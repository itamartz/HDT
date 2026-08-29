function New-HDTRunState {
    <#
        .SYNOPSIS
            Builds the state document for a new deployment run.

        .DESCRIPTION
            "The engine maintains a state document (state.json): resolved
            variables, the step index, per-step results, and a run ID".
This builds it, in memory. It has NO -FileSystem
            parameter and reads nothing: only Save-HDTRunState writes.

            The document, in this key order:

              schemaVersion  1
              runId          the deployment run id, also _HDTRunId
              sequenceId     the sequence's id from sequence.yaml
              status         Running | Succeeded | Failed
              phase          WinPE | FullOS
              leg            1-based, incremented on every resume
              seq            the last JSONL seq written - how the
                             monotonic counter survives a reboot
              logLevel       the verbosity the run started at - how the
                             LEVEL survives the same reboot
              startedUtc     formatted string
              updatedUtc     formatted string
              stepIndex      the 1-based index of the NEXT step to run
              pauseOnError   bool
              variable       name -> value, ordered and case-insensitive
              step[]         index, name, type, group, status, attempt, leg,
                             resumable, startedUtc, endedUtc, durationMs,
                             exitCode, message
              autoLogon      armed, userName, domainName, countSet, secretName,
                             runOnceName

            EVERY TIMESTAMP IS A FORMATTED STRING. ConvertTo-Json renders a raw
            [datetime] as "\/Date(1786579862481)\/" under Windows PowerShell
            5.1, and 5.1 is the engine that writes this file in WinPE, so a raw
            date would produce a document the full-OS leg could not read back.

        .PARAMETER SequenceId
            The sequence's id from sequence.yaml.

        .PARAMETER RunId
            The deployment run id.

        .PARAMETER Phase
            WinPE or FullOS.

        .PARAMETER Clock
            An IClock. Mandatory, and deliberately so: PROJECT constraint 4
            forbids engine logic from reading the wall clock directly, and a
            state document whose timestamps came from a real clock could not be
            asserted on.

        .PARAMETER Variable
            The resolved variables. Copied into an ordered, case-insensitive
            dictionary, so a hand-written rules.yaml may spell a name however it
            likes and a state.json diff stays readable.

        .PARAMETER Step
            One entry per flattened step, as a dictionary or an object with
            Index, Name, Type, GroupPath (or Group) and Resumable. Both shapes
            are accepted because 03-02's flattener emits objects and a test
            writes dictionaries, and a state document must not care which -
            and GroupPath is read in preference to Group, because GroupPath is
            what the flattener actually emits.

        .PARAMETER LogLevel
            The verbosity the run started at, so the resumed leg can log at the
            same one. DESIGN 4.4.5 makes LogLevel a property of the SHARE, and
            the share is not reachable at the moment the resumed leg builds its
            log context - the state document is, and it is already the thing
            that spans the reboot. Defaults to Info, which is New-HDTLogContext's
            own default: a document that names no level and a context that was
            given none must mean the same thing.

        .PARAMETER PauseOnError
            The LTISuspend equivalent: on failure, drop to a PowerShell
            prompt with the state loaded rather than ending the sequence.

        .OUTPUTS
            System.Management.Automation.PSCustomObject

        .EXAMPLE
            $clock = New-HDTClock
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $state = New-HDTRunState -SequenceId 'DEMO-05' -RunId 'run-0001' -Phase WinPE `
                -Clock $clock -Variable ([ordered] @{}) -Step @($sequence.Step)

            The checkpoint a deployment survives its reboots on. It carries every step
            with a status, so a resumed run knows what already happened rather
            than starting again.

        .EXAMPLE
            $state.stepIndex

            Zero - nothing has run yet. This is the number that makes the reboot
            survivable: the OS changes underneath the engine, and this says where
            it had got to.

    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory document object; it changes no state and writes no file.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $SequenceId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $RunId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('WinPE', 'FullOS')]
        [string] $Phase,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Clock,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Variable,

        [Parameter()]
        [AllowNull()]
        [object[]] $Step,

        # The same set New-HDTLogContext validates, and the same default. Stated
        # rather than inherited because a state document is read by an engine
        # that may be newer than the one that wrote it.
        [Parameter()]
        [ValidateSet('Error', 'Warning', 'Info', 'Debug')]
        [string] $LogLevel = 'Info',

        [Parameter()]
        [switch] $PauseOnError
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $stamp = $Clock.GetUtcNow().ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)

    $variableMap = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $Variable) {
        foreach ($key in @($Variable.Keys)) {
            $variableMap[[string] $key] = $Variable[$key]
        }
    }

    $record = New-Object -TypeName System.Collections.ArrayList
    $position = 0

    foreach ($item in @($Step)) {
        if ($null -eq $item) {
            continue
        }

        $position++

        # A dictionary and an object both answer the same five questions; the
        # flattener in 03-02 emits objects, a test writes dictionaries.
        $source = @{}
        if ($item -is [System.Collections.IDictionary]) {
            foreach ($key in @($item.Keys)) {
                $source[[string] $key] = $item[$key]
            }
        } else {
            foreach ($property in @($item.PSObject.Properties)) {
                $source[$property.Name] = $property.Value
            }
        }

        $index = $position
        if ($source.ContainsKey('Index')) {
            $index = [int] $source['Index']
        }

        # GroupPath is what Import-HDTSequenceDocument's flattener emits, and it
        # is the only thing that builds a step list in production. Group is what
        # a hand-written test dictionary says. Reading only the latter left the
        # state document's group array - and every report column rendered from
        # it - empty on every real run.
        $group = [string[]] @()
        if ($source.ContainsKey('GroupPath') -and $null -ne $source['GroupPath']) {
            $group = [string[]] @($source['GroupPath'])
        } elseif ($source.ContainsKey('Group') -and $null -ne $source['Group']) {
            $group = [string[]] @($source['Group'])
        }

        $resumable = $false
        if ($source.ContainsKey('Resumable')) {
            $resumable = [bool] $source['Resumable']
        }

        [void] $record.Add([pscustomobject] ([ordered] @{
                    index      = $index
                    name       = [string] $source['Name']
                    type       = [string] $source['Type']
                    group      = $group
                    status     = 'Pending'
                    attempt    = 0

                    # Which leg last touched this step. Null until it runs, and
                    # the only way a resume can say "step 3 completed on leg 1"
                    # rather than "on some earlier leg".
                    leg        = $null
                    resumable  = $resumable
                    startedUtc = $null
                    endedUtc   = $null
                    durationMs = $null
                    exitCode   = $null
                    message    = $null
                }))
    }

    return [pscustomobject] ([ordered] @{
            schemaVersion      = 1
            runId              = $RunId
            sequenceId         = $SequenceId
            status             = 'Running'
            phase              = $Phase
            leg                = 1
            seq                = [long] 0

            # BESIDE seq, AND FOR THE SAME REASON. seq is here so the log's
            # NUMBERING survives the reboot; this is here so its VERBOSITY does.
            # Without it a share that set logLevel: Debug got a WinPE leg at
            # Debug and a full-OS leg at Info - which is the leg the
            # applications install on.
            logLevel           = $LogLevel
            startedUtc         = $stamp
            updatedUtc         = $stamp
            stepIndex          = 1
            pauseOnError       = [bool] $PauseOnError
            variable           = $variableMap
            step               = @($record)
            autoLogon          = [pscustomobject] ([ordered] @{
                    armed       = $false
                    userName    = $null
                    domainName  = $null
                    countSet    = 0
                    secretName  = $null
                    runOnceName = $null
                })
        })
}
