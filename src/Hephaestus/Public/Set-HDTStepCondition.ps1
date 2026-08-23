function Set-HDTStepCondition {
    <#
        .SYNOPSIS
            Gives a step the expression that decides whether it runs, or takes
            it away.

        .DESCRIPTION
            THE FILTER MDT PUTS ON THE OPTIONS TAB. Workbench lists conditions
            under the two checkboxes and a step with none runs every time; HDT
            carries the same idea as one expression on the step's `condition`
            key, evaluated by the engine before the step is invoked. This is
            that control, as a command: every button maps to a
            cmdlet invocation, and the console shows the invocation.

            ONE EXPRESSION, NOT A CLAUSE BUILDER. MDT's dialog composes an
            if-statement tree out of variable tests, WMI queries and registry
            reads, and stores it as XML nobody can read in a diff. HDT's
            condition is a PowerShell expression over the rules' variables,
            which is the same power in a form an administrator can also grep,
            and which `rules.yaml` already gave them the vocabulary for.

            CLEARING IT REMOVES THE LINE RATHER THAN EMPTYING IT. `condition:`
            with nothing after it is a key whose value is null, which reads at a
            glance like a condition somebody forgot to finish. A step that runs
            every time should say so by carrying no condition at all, the way a
            newly added step does.

            IT SPLICES, LIKE EVERY EDIT HERE, and it quotes only when leaving
            the expression bare would change what the engine reads back - a
            colon-space inside it would otherwise turn one key into two.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The step or group to change. Ambiguous names are refused rather
            than guessed - see Resolve-HDTStepBlock.

        .PARAMETER Condition
            The expression. Empty removes the condition.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document, with one line changed.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'))
            Set-HDTStepCondition -Line $line -Name 'Apply Drivers' -Condition '$Make -eq "Dell Inc."'

        .EXAMPLE
            Set-HDTStepCondition -Line $line -Name 'Apply Drivers' -Condition ''

            Takes the condition off, so the step runs every time.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        # WHICH OF THE SAME-NAMED STEPS, 1-BASED, IN DOCUMENT ORDER. Omitted, an
        # ambiguous name is refused rather than guessed at. The console passes
        # it because it has a selected row; a person typing a name has not said
        # which one they mean, and is told so.
        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $Occurrence = 0,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowEmptyString()]
        [string] $Condition
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $target = Resolve-HDTStepBlock -Line $Line -Name $Name -Occurrence $Occurrence

    $found = Get-HDTStepKey -Line $Line -Block $target -Key 'condition'

    $clear = [string]::IsNullOrWhiteSpace($Condition)

    # Nothing to remove and nothing to write.
    if ($clear -and $found.Index -lt 0) {
        return [string[]] @($Line)
    }

    $action = "Set the condition to {0}" -f $Condition
    if ($clear) { $action = 'Remove the condition' }

    if (-not $PSCmdlet.ShouldProcess($Name, $action)) {
        return [string[]] @($Line)
    }

    # Bare wherever bare reads back the same, quoted where it would not - see
    # Get-HDTConsoleScalarText, which Set-HDTStepProperty shares.
    $written = '{0}condition: {1}' -f (' ' * $found.Indent), (Get-HDTConsoleScalarText -Value $Condition)

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($found.Index -ge 0 -and $i -eq $found.Index) {
            # Cleared: the line goes, and the keys around it close up.
            if (-not $clear) { [void] $result.Add($written) }
            continue
        }

        [void] $result.Add($Line[$i])

        if ($found.Index -lt 0 -and $i -eq $found.Insert) {
            [void] $result.Add($written)
        }
    }

    return [string[]] @($result)
}
