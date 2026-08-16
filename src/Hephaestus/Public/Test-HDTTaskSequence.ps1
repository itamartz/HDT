function Test-HDTTaskSequence {
    <#
        .SYNOPSIS
            Lints an imported sequence for the problems a schema cannot see.

        .DESCRIPTION
            Assert-HDTSequenceDocument answers "is this a well formed sequence
            document". This answers a different question: "would this sequence
            actually work on the machine you are about to deploy".

            IT RETURNS FINDINGS RATHER THAN THROWING, because it is a lint. The
            console (M8) surfaces them inline while somebody is still editing,
            and a lint that stopped at the first problem would make that
            experience worse than useless.

            One Error:

              a step whose type NO LOADED MODULE IMPLEMENTS, with the types this
              engine can run listed. Import deliberately does not check this - a
              sequence authored for a workspace whose Modules\ carries a
              third-party step must still import on a machine that does not
 - so this is where an author finds out.

            Three Warnings:

              a `runIn: WinPE` step AFTER a Restart. Nothing in HDT boots back
              into WinPE, so such a step can only be skipped at runtime. It is a
              warning rather than an error because a sequence may legitimately be
              authored for a machine that PXE-boots between legs.

              a %Var% NO SOURCE COULD SUPPLY: not a sequence variable, not an
              engine variable, not set by an EARLIER SetVariable step, and not in
              -KnownVariable. Order matters - a variable set by a later step is
              still a warning, because the condition reading it runs first.

              `continueOnError: true` on a Restart. Tolerating a failed reboot
              means continuing in WinPE a sequence that expected the full OS.

            IT DOES NOT EVALUATE CONDITIONS. Whether %HDTIsLaptop% is True is a
            property of a machine, and this runs at authoring time where there is
            no machine.

        .PARAMETER Sequence
            An Import-HDTSequenceDocument result.

        .PARAMETER StepType
            A pre-built Get-HDTStepType registry. Without one it discovers the
            types loaded in this session, which for an authoring machine is the
            right answer.

        .PARAMETER KnownVariable
            Names a rules document, a machine override or the gather would
            supply. Everything the engine sets itself is already known.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[], one per finding:
            Severity (Error | Warning), Index, Step, Message.

        .EXAMPLE
            Test-HDTTaskSequence -Sequence $sequence | Format-Table Severity, Index, Step, Message

        .EXAMPLE
            Test-HDTTaskSequence -Sequence $sequence -KnownVariable @($rules.Variable.Keys)
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Sequence,

        [Parameter()]
        [AllowNull()]
        [object[]] $StepType,

        [Parameter()]
        [AllowNull()]
        [string[]] $KnownVariable
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $registry = $StepType
    if ($null -eq $registry) {
        $registry = @(Get-HDTStepType)
    }

    $knownType = @($registry | ForEach-Object { [string] $_.Type })
    $knownTypeText = $knownType -join ', '
    if ([string]::IsNullOrWhiteSpace($knownTypeText)) {
        $knownTypeText = '<none - no step type module is loaded>'
    }

    # Everything a %Var% could legitimately name at this point in the sequence.
    # The engine variables of DESIGN 4.4.1 are always there; the sequence's own
    # defaults are DESIGN 3.1 source 5; a rules document's names arrive through
    # -KnownVariable; and a SetVariable step adds its names as the walk passes it.
    $supplied = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($name in @('_HDTRunId', '_HDTPhase', '_HDTLogPath', '_HDTDeployRoot', '_HDTVersion', '_HDTStepName', '_HDTStepType')) {
        $supplied[$name] = ''
    }
    foreach ($name in @($Sequence.Variable.Keys)) {
        $supplied[[string] $name] = ''
    }
    if ($null -ne $KnownVariable) {
        foreach ($name in @($KnownVariable)) {
            $supplied[[string] $name] = ''
        }
    }

    $finding = New-Object -TypeName System.Collections.ArrayList

    $add = {
        param([string] $Severity, [int] $Index, [string] $Step, [string] $Message)

        [void] $finding.Add([pscustomobject] ([ordered] @{
                    Severity = $Severity
                    Index    = $Index
                    Step     = $Step
                    Message  = $Message
                }))
    }

    $restartSeen = $false

    foreach ($step in @($Sequence.Step)) {

        $index = [int] $step.Index
        $name = [string] $step.Name
        $type = [string] $step.Type

        if ($knownType -notcontains $type) {
            & $add 'Error' $index $name ("the step type '{0}' is not implemented by any loaded module. A step type is a function named Invoke-HDT<Type>Step (DESIGN 4.2). The types this engine can run are: {1}." -f $type, $knownTypeText)
        }

        if ($type -eq 'Restart' -and [bool] $step.ContinueOnError) {
            & $add 'Warning' $index $name 'continueOnError: true on a Restart step means a failed reboot is tolerated, which continues the sequence in the phase it was trying to leave.'
        }

        if ($restartSeen -and [string] $step.RunIn -eq 'WinPE') {
            & $add 'Warning' $index $name ("runIn: WinPE on step {0} comes after a Restart step, and nothing in HDT boots back into WinPE, so this step can only be skipped at run time." -f $index)
        }

        # Every %Var% this step could read: its own condition, the conditions of
        # every group it sits in, and each of its type-specific property values.
        $unresolved = New-Object -TypeName System.Collections.ArrayList

        $text = New-Object -TypeName System.Collections.ArrayList
        if (-not [string]::IsNullOrWhiteSpace([string] $step.Condition)) {
            [void] $text.Add([string] $step.Condition)
        }
        foreach ($ancestor in @($step.GroupCondition)) {
            [void] $text.Add([string] $ancestor.Condition)
        }
        foreach ($key in @($step.Property.Keys)) {
            $value = $step.Property[$key]
            if ($value -is [string]) {
                [void] $text.Add($value)
            }
        }

        foreach ($item in $text) {
            [void] (Expand-HDTVariableToken -Value $item -Scope $supplied -Unresolved $unresolved)
        }

        if (@($unresolved).Count -gt 0) {
            & $add 'Warning' $index $name ("{0} variable token(s) are read here that no sequence variable, rule or earlier SetVariable step supplies: {1}. An unsupplied token is left literal at run time, so a condition reading it is false." -f
                @($unresolved).Count, (@($unresolved) -join ', '))
        }

        # A SetVariable step supplies its names to everything AFTER it, which is
        # why this happens at the end of the step rather than at the start.
        if ($type -eq 'SetVariable') {
            if ($step.Property.Contains('variable')) {
                $supplied[[string] $step.Property['variable']] = ''
            }
            if ($step.Property.Contains('variables') -and ($step.Property['variables'] -is [System.Collections.IDictionary])) {
                foreach ($key in @($step.Property['variables'].Keys)) {
                    $supplied[[string] $key] = ''
                }
            }
        }

        if ($type -eq 'Restart') {
            $restartSeen = $true
        }
    }

    return [object[]] $finding.ToArray()
}
