function New-HDTExecutionContext {
    <#
        .SYNOPSIS
            Builds the execution context every step is handed alongside its step.

        .DESCRIPTION
            One object carrying everything a step is allowed to reach:

              RunId, Phase, WorkspaceRoot
              Variable   the LIVE ordered, case-insensitive dictionary. A step
                         may write to it, and the next step's condition sees the
                         write - which is what makes SetVariable work at all
              Service    the New-HDTServiceCatalog catalog
              Log        the 03-01 log context
              State      the 03-01 run state, or $null
              Attempt    the 1-based attempt number, set by the loop before each
                         call so a step can tell a retry from a first try

              SetStep($index, $name, $type [, $stepLogPath])

            IT SEEDS THE ENGINE VARIABLES into the live dictionary:
            _HDTRunId, _HDTPhase, _HDTLogPath, _HDTDeployRoot, _HDTVersion, and
            per step _HDTStepName and _HDTStepType. They are readable by
            conditions and by user scripts and are never assignable from a
            sequence - Assert-HDTSequenceDocument refuses a variables: block that
            names one, exactly as Assert-HDTRuleDocument does.

            SETSTEP FORWARDS TO THE LOG CONTEXT, which is what makes
            "entries carry the step name automatically, so a custom
            step's output is attributable without the author doing anything"
            true. One call updates the variables and the log at once, so the two
            cannot drift.

            IT PERFORMS NO I/O. It is built in WinPE before a disk exists.

        .PARAMETER RunId
            The deployment run id, also _HDTRunId.

        .PARAMETER Phase
            WinPE or FullOS, also _HDTPhase.

        .PARAMETER WorkspaceRoot
            The resolved workspace root, also _HDTDeployRoot.

        .PARAMETER Variable
            The live variable dictionary. Held by reference, never copied.

        .PARAMETER Service
            A New-HDTServiceCatalog catalog.

        .PARAMETER Log
            A New-HDTLogContext context.

        .PARAMETER State
            A New-HDTRunState document, or nothing in a phase that has none yet.

        .OUTPUTS
            System.Management.Automation.PSCustomObject.

        .EXAMPLE
            $clock = New-HDTClock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE `
                -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) `
                -Service (New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock) -Log $log

            What every step is handed: the variables resolved so far, the services it
            may touch the machine through, and somewhere to write. A step reaches
            hardware only through the catalogue, which is what lets the whole
            engine run under Pester against fakes.

        .EXAMPLE
            $context.SetStep(3, 'Apply OS', 'ApplyImage')
            $context.Variable['HDTStage'] = 'install'

            Which step is running, for every record written from here on, and the
            variable bag a SetVariable step writes into. The same dictionary the
            rules resolved into - a step sees what the rules decided.

    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory context object; it performs no I/O.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $RunId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('WinPE', 'FullOS')]
        [string] $Phase,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Variable,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Service,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Log,

        [Parameter()]
        [AllowNull()]
        [object] $State = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $Variable['_HDTRunId'] = $RunId
    $Variable['_HDTPhase'] = $Phase
    $Variable['_HDTLogPath'] = [string] $Log.LogPath
    $Variable['_HDTDeployRoot'] = $WorkspaceRoot
    $Variable['_HDTVersion'] = [string] (Get-HDTModuleVersion)

    $context = [pscustomobject] @{
        RunId         = $RunId
        Phase         = $Phase
        WorkspaceRoot = $WorkspaceRoot
        Variable      = $Variable
        Service       = $Service
        Log           = $Log
        State         = $State
        Attempt       = 1
    }

    $context | Add-Member -MemberType ScriptMethod -Name SetStep -Value {
        param([int] $Index, [string] $Name, [string] $Type, [string] $StepLogPath)

        $this.Variable['_HDTStepName'] = $Name
        $this.Variable['_HDTStepType'] = $Type

        # THE OTHER HALF OF HDTDeploymentStart, and the reason a tattoo step can
        # write a duration at all.
        #
        # IT IS THE CLOCK, REFRESHED BEFORE EVERY STEP, and it has to be: the
        # deployment's real end is after the last step, when there is nothing
        # left to read it. A tattoo is the last step, so what it reads IS the
        # end to the second - and RESULT.json carries the true final value for
        # anything reading afterwards.
        #
        # UTC AND ISO 8601, LIKE THE START, and for its reason: WinPE runs on
        # the hardware clock and the deployed OS is put into a time zone half
        # way through, so two local readings are hours apart for reasons that
        # have nothing to do with how long the deployment took.
        $this.Variable['HDTDeploymentEnd'] = [System.DateTime]::UtcNow.ToString(
            'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)

        $this.Log.SetStep($Index, $Name, $Type, $StepLogPath)
    }

    return $context
}
