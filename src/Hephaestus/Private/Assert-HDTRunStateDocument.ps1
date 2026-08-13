function Assert-HDTRunStateDocument {
    <#
        .SYNOPSIS
            Validates a parsed state.json against DESIGN 4.3's state document.

        .DESCRIPTION
            The engine's own validator, and the one that actually runs in WinPE:
            Test-Json does not exist under Windows PowerShell 5.1, so
            schemas/state.schema.json is a gate for the console and CI while this
            is the gate for a deployment. The two must agree on every document -
            a state file a console calls valid and the engine rejects would fail
            on the machine that has already been wiped.

            It throws on the first violation and returns nothing otherwise. Every
            failure is a terminating error built by New-HDTErrorRecord, so it
            names the file, carries the file as its TargetObject and reports
            HDTConfigurationError - DESIGN 12.1's "fail fast and point at the
            file".

            The rules, in the order they are checked:

              document  not null; an object; schemaVersion present, an integer,
                        and not newer than this engine
              identity  runId and sequenceId present and non-empty
              lifecycle status in Running/Succeeded/Failed; phase in
                        WinPE/FullOS; leg an integer >= 1; seq an integer >= 0;
                        stepIndex an integer >= 1; pauseOnError a boolean
              stamps    startedUtc and updatedUtc present, and STRINGS - a raw
                        datetime here would mean somebody serialised one, which
                        renders as \/Date(...)\/ under 5.1
              variable  present and an object
              step      present and a list; every step has an integer index >= 1,
                        a non-empty name and type, a status in the set, an
                        integer attempt >= 0 and a boolean resumable
              autoLogon present, with a boolean armed

            The document arrives from ConvertFrom-Json, so it is a
            PSCustomObject tree rather than a dictionary, and every presence
            check goes through PSObject.Properties. That also keeps the function
            correct under Set-StrictMode -Version Latest, where reading an absent
            property throws instead of returning null.

        .PARAMETER Document
            The parsed document. $null is accepted and reported as an empty file
            rather than crashing.

        .PARAMETER Path
            The file the document came from. Used for the message and the
            TargetObject; this function reads nothing.

        .OUTPUTS
            None. It throws or it returns nothing.

        .EXAMPLE
            Assert-HDTRunStateDocument -Document (ConvertFrom-Json -InputObject $text) -Path $path
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Document,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $supportedSchemaVersion = 1

    # ConvertFrom-Json hands back a PSCustomObject tree; presence is a property
    # question, not a key question, and it must be asked before the read.
    $hasProperty = {
        param($Object, [string] $Name)

        if ($null -eq $Object) {
            return $false
        }

        return (@($Object.PSObject.Properties | ForEach-Object { $_.Name }) -contains $Name)
    }

    $isInteger = {
        param($Value)

        return (($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [int16]) -or ($Value -is [byte]))
    }

    # -- the document ---------------------------------------------------------

    if ($null -eq $Document) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the file is empty. A state document must declare schemaVersion, runId and a step list.'))
    }

    if (($Document -is [string]) -or ($Document -is [System.Collections.IList])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the document must be a JSON object, but it is a {0}." -f $Document.GetType().Name)))
    }

    if (-not (& $hasProperty $Document 'schemaVersion')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'schemaVersion is missing. Every HDT document declares one (DESIGN 2.2); this engine understands schemaVersion 1.'))
    }

    $schemaVersion = $Document.schemaVersion
    if (-not (& $isInteger $schemaVersion)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("schemaVersion must be an integer, but it is '{0}'." -f $schemaVersion)))
    }

    $supported = $false
    try {
        $supported = Test-HDTSchemaVersion -SchemaVersion ([int] $schemaVersion) -Supported $supportedSchemaVersion
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("schemaVersion {0} is not a valid schema version. It must be 1 or greater." -f $schemaVersion)))
    }

    if (-not $supported) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("schemaVersion {0} is newer than this engine understands (schemaVersion {1}). Upgrade the engine rather than the state document." -f $schemaVersion, $supportedSchemaVersion)))
    }

    # -- identity and lifecycle -----------------------------------------------

    foreach ($name in @('runId', 'sequenceId')) {
        if (-not (& $hasProperty $Document $name)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} is missing. A state document records it for every run." -f $name)))
        }

        $value = $Document.$name
        if (-not ($value -is [string]) -or [string]::IsNullOrWhiteSpace([string] $value)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} must be a non-empty string." -f $name)))
        }
    }

    # A timestamp is WRITTEN as a round-trip string, and the schema requires one.
    # It is READ back as either: ConvertFrom-Json under pwsh 7 rehydrates an
    # ISO 8601 string into a [datetime], and under Windows PowerShell 5.1 it does
    # not. Both are the same instant, so both are accepted here - rejecting the
    # [datetime] would make this validator disagree with the schema on exactly the
    # documents the schema accepts, which is the one thing it must never do.
    foreach ($name in @('startedUtc', 'updatedUtc')) {
        if (-not (& $hasProperty $Document $name)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} is missing. A state document stamps it for every run." -f $name)))
        }

        $value = $Document.$name
        $isStamp = ($value -is [datetime]) -or (($value -is [string]) -and -not [string]::IsNullOrWhiteSpace([string] $value))

        if (-not $isStamp) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} must be a non-empty timestamp, written in the round-trip 'o' format." -f $name)))
        }
    }

    $enumeration = @{ status = @('Running', 'Succeeded', 'Failed'); phase = @('WinPE', 'FullOS') }
    foreach ($name in @('status', 'phase')) {
        if (-not (& $hasProperty $Document $name)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} is missing. It must be one of {1}." -f $name, ($enumeration[$name] -join ', '))))
        }

        if ($enumeration[$name] -notcontains [string] $Document.$name) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} is '{1}', which is not one of {2}." -f $name, $Document.$name, ($enumeration[$name] -join ', '))))
        }
    }

    $minimum = @{ leg = 1; seq = 0; stepIndex = 1 }
    foreach ($name in @('leg', 'seq', 'stepIndex')) {
        if (-not (& $hasProperty $Document $name)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} is missing. A state document records it for every run." -f $name)))
        }

        $value = $Document.$name
        if (-not (& $isInteger $value) -or ([long] $value -lt $minimum[$name])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} must be an integer of at least {1}, but it is '{2}'." -f $name, $minimum[$name], $value)))
        }
    }

    if (-not (& $hasProperty $Document 'pauseOnError')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'pauseOnError is missing. It records whether a failure drops to a prompt (DESIGN 4.3).'))
    }

    if (-not ($Document.pauseOnError -is [bool])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("pauseOnError must be a boolean, but it is '{0}'." -f $Document.pauseOnError)))
    }

    # -- variable -------------------------------------------------------------

    if (-not (& $hasProperty $Document 'variable')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'variable is missing. A state document carries the resolved variables, even when there are none.'))
    }

    if ($null -eq $Document.variable -or ($Document.variable -is [System.Collections.IList])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'variable must be an object mapping variable name to value.'))
    }

    # -- step -----------------------------------------------------------------

    if (-not (& $hasProperty $Document 'step')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'step is missing. A state document carries one record per flattened step.'))
    }

    if (-not ($Document.step -is [System.Collections.IList])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'step must be a list of step records.'))
    }

    $stepStatus = @('Pending', 'Running', 'Completed', 'Failed', 'Skipped')
    $position = 0

    foreach ($step in @($Document.step)) {
        $position++
        $locator = 'step {0}' -f $position

        if ($null -eq $step -or ($step -is [string]) -or ($step -is [System.Collections.IList])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: a step record must be an object." -f $locator)))
        }

        if (-not (& $hasProperty $step 'index')) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: index is missing. The index is how a resume finds the next step to run (DESIGN 4.3)." -f $locator)))
        }

        if (-not (& $isInteger $step.index) -or ([long] $step.index -lt 1)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: index must be a 1-based integer, but it is '{1}'." -f $locator, $step.index)))
        }

        $locator = "step {0} (index {1})" -f $position, $step.index

        foreach ($name in @('name', 'type')) {
            if (-not (& $hasProperty $step $name)) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: {1} is missing." -f $locator, $name)))
            }

            if (-not ($step.$name -is [string]) -or [string]::IsNullOrWhiteSpace([string] $step.$name)) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: {1} must be a non-empty string." -f $locator, $name)))
            }
        }

        if (-not (& $hasProperty $step 'status')) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: status is missing. It must be one of {1}." -f $locator, ($stepStatus -join ', '))))
        }

        if ($stepStatus -notcontains [string] $step.status) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: status is '{1}', which is not one of {2}." -f $locator, $step.status, ($stepStatus -join ', '))))
        }

        if (-not (& $hasProperty $step 'attempt')) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: attempt is missing. It counts how many times the step has been started." -f $locator)))
        }

        if (-not (& $isInteger $step.attempt) -or ([long] $step.attempt -lt 0)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: attempt must be an integer of at least 0, but it is '{1}'." -f $locator, $step.attempt)))
        }

        if (-not (& $hasProperty $step 'resumable')) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: resumable is missing. DESIGN 4.3 re-runs an interrupted step only if it declares one." -f $locator)))
        }

        if (-not ($step.resumable -is [bool])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: resumable must be a boolean, but it is '{1}'." -f $locator, $step.resumable)))
        }
    }

    # -- autoLogon ------------------------------------------------------------

    if (-not (& $hasProperty $Document 'autoLogon')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'autoLogon is missing. The boot reconcile tears down exactly what this block records was armed (DESIGN 4.5.3).'))
    }

    if (-not (& $hasProperty $Document.autoLogon 'armed')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'autoLogon.armed is missing. Without it the boot reconcile cannot tell an armed machine from a torn-down one.'))
    }

    if (-not ($Document.autoLogon.armed -is [bool])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("autoLogon.armed must be a boolean, but it is '{0}'." -f $Document.autoLogon.armed)))
    }
}
