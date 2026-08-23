function Test-HDTPowerShellStepApplicable {
    <#
        .SYNOPSIS
            Reports whether a PowerShell step has a script to run.

        .DESCRIPTION
            The optional second of the step contract's triple. A PowerShell step with no
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
            $clock = New-HDTClock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE `
                -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) `
                -Service (New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock) -Log $log
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'PowerShell' })[0]
            Test-HDTPowerShellStepApplicable -Step $step -Context $context

            Whether the step has a script to run. A PowerShell step whose file is not
            on the share is not applicable rather than broken.

        .EXAMPLE
            @(Get-HDTStepType | Where-Object { $_.Type -eq 'PowerShell' }).Applicable

            The same check as the engine finds it: a step type declares its
            applicability by name, and this is the function that name resolves to.

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
