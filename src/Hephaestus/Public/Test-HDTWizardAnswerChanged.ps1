function Test-HDTWizardAnswerChanged {
    <#
        .SYNOPSIS
            Whether what came out of a box is an answer, or just a rule being
            shown back.

        .DESCRIPTION
            THE HALF OF SEEDING THAT KEEPS PROVENANCE HONEST. Get-HDTWizardSeed
            puts what the rules resolved into the boxes. But every value the
            wizard collects re-enters the engine as the Wizard SOURCE, the
            highest precedence in DESIGN 3.1, so a seeded box nobody touched
            would be collected as though somebody had typed it. The deployment
            would be right and the report would say a name was typed at the
            bench when a rule on the share produced it - which is the one
            question provenance exists to answer.

            So the harvest asks this first. A value that came back exactly as it
            went in is not collected at all: the rule stands and keeps its own
            provenance. Change the box and the answer is yours, recorded as
            Wizard, which is then true.

            A NULL SEED MEANS NOBODY PUT ANYTHING THERE - every box the rules
            could not fill. Whatever is in it now came from the technician, so
            it is an answer. Unless it is still empty, because an empty box is
            not a decision to set a variable to nothing; the engine's own
            resolution already covers "nobody said".

            CLEARING A SEEDED BOX *IS* AN ANSWER, and that is the opposite of
            the line above on purpose. A rule supplied a value and the
            technician deleted it: that is a decision about this machine, and
            swallowing it would put the rule's value straight back and make the
            box a lie.

            WHITESPACE EITHER SIDE IS NOT A DECISION; a stray space from a paste
            should not turn a rule into a wizard answer. CASE IS. The variable
            engine is case-insensitive about variable NAMES, not about their
            values - a computer name's case is what the machine ends up
            carrying, and a technician who retyped it meant to.

        .PARAMETER Seeded
            What Get-HDTWizardSeed put in the box, or $null if it seeded nothing
            there.

        .PARAMETER Answered
            What the box held when the page was left.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean. True when the value should be collected as a wizard
            answer.

        .EXAMPLE
            Test-HDTWizardAnswerChanged -Seeded 'WORKGROUP' -Answered 'WORKGROUP'

            False - the technician read it and moved on, so the rule keeps the
            variable and its provenance.

        .EXAMPLE
            Test-HDTWizardAnswerChanged -Seeded 'WORKGROUP' -Answered 'LAB'

            True - that is this machine's answer, and the report will say it was
            typed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Seeded,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Answered
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $now = ''
    if ($null -ne $Answered) { $now = $Answered.Trim() }

    # NOTHING WAS SEEDED HERE. A PowerShell [string] parameter turns $null into
    # '' on binding, so "not seeded" and "seeded with nothing" arrive the same -
    # and they mean the same thing anyway, because Get-HDTWizardSeed never seeds
    # an empty value. Either way the box was blank when the page opened.
    $before = ''
    if ($null -ne $Seeded) { $before = $Seeded.Trim() }

    if ([string]::IsNullOrEmpty($before)) { return (-not [string]::IsNullOrEmpty($now)) }

    return (-not [string]::Equals($before, $now, [System.StringComparison]::Ordinal))
}
