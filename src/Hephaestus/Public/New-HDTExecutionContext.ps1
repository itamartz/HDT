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

            IT SEEDS DESIGN 4.4.1'S ENGINE VARIABLES into the live dictionary:
            _HDTRunId, _HDTPhase, _HDTLogPath, _HDTDeployRoot, _HDTVersion, and
            per step _HDTStepName and _HDTStepType. They are readable by
            conditions and by user scripts and are never assignable from a
            sequence - Assert-HDTSequenceDocument refuses a variables: block that
            names one, exactly as Assert-HDTRuleDocument does.

            SETSTEP FORWARDS TO THE LOG CONTEXT, which is what makes DESIGN
            4.4.4's "entries carry the step name automatically, so a custom
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
            $context = New-HDTExecutionContext -RunId $runId -Phase WinPE `
                -WorkspaceRoot 'X:\Deploy' -Variable $variable -Service $catalog -Log $log
            $context.SetStep(3, 'Apply OS', 'ApplyImage')
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

        $this.Log.SetStep($Index, $Name, $Type, $StepLogPath)
    }

    return $context
}
