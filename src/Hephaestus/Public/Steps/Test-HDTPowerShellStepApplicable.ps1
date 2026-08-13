function Test-HDTPowerShellStepApplicable {
    <#
        .SYNOPSIS
            Reports whether a PowerShell step has a script to run.

        .DESCRIPTION
            The optional second of DESIGN 4.2's triple. A PowerShell step with no
            `script:` has nothing to do, and saying so through applicability lets
            the loop record a step.skip naming the step rather than a failure that
            reads like the script itself went wrong.

            Invoke-HDTPowerShellStep still fails a step that reaches it without a
            script, because a caller may dispatch without asking first, and a step
            that silently did nothing is worse than one that said so.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Not read: applicability here is a
            property of the step alone.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTPowerShellStepApplicable -Step $step -Context $context
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Context',
        Justification = 'The DESIGN 4.2 step contract fixes the parameter list; this type decides applicability from the step alone.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $property = $Step.Property

    if ($null -eq $property -or -not $property.Contains('script')) {
        return $false
    }

    return (-not [string]::IsNullOrWhiteSpace([string] $property['script']))
}
