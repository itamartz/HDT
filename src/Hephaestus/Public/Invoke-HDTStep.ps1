function Invoke-HDTStep {
    <#
        .SYNOPSIS
            Dispatches one step to the Invoke-HDT<Type>Step function that
            implements it.

        .DESCRIPTION
            The one door every step goes through, so the loop (03-04) never needs
            to know which types exist. It resolves the step's Type through the
            Get-HDTStepType registry, calls
            Invoke-HDT<Type>Step -Step $Step -Context $Context, and returns what
            that returned, unchanged.

            AN UNKNOWN TYPE IS A CONFIGURATION ERROR THAT LISTS THE ALTERNATIVES.
            A typo in sequence.yaml should print the types that do exist, not
            just a refusal - and it fails the STEP rather than the document,
            because Assert-HDTSequenceDocument deliberately does not validate
            types: a sequence authored for a workspace whose Modules\ carries a
            third-party step must still import on a machine that does not.

            IT DOES NOT CATCH. Classifying a thrown exception as Transient,
            Configuration or Environment, deciding whether to
            retry, and honouring continueOnError all belong to the loop, which
            owns the retry policy and the state document. Swallowing an exception
            here would hide it from both.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument, or anything
            carrying Name, Type and Property.

        .PARAMETER Context
            A New-HDTExecutionContext context.

        .PARAMETER StepType
            A pre-built Get-HDTStepType registry. The loop discovers once per run
            and passes it to every dispatch, rather than re-enumerating
            Get-Command on every step of every sequence. Omit it and one is
            built.

        .OUTPUTS
            The step's New-HDTStepResult, unchanged.

        .EXAMPLE
            $registry = Get-HDTStepType
            Invoke-HDTStep -Step $step -Context $context -StepType $registry
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter()]
        [AllowNull()]
        [object[]] $StepType
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $registry = $StepType
    if ($null -eq $registry) {
        $registry = @(Get-HDTStepType)
    }

    $type = [string] $Step.Type
    $entry = @($registry | Where-Object { $_.Type -eq $type })

    if ($entry.Count -eq 0) {
        $known = @($registry | ForEach-Object { $_.Type }) -join ', '
        if ([string]::IsNullOrWhiteSpace($known)) {
            $known = '<none - no step type module is loaded>'
        }

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                    -Message ("step '{0}' declares the type '{1}', which no loaded module implements. A step type is a function named Invoke-HDT<Type>Step. The types this engine can run are: {2}." -f $Step.Name, $type, $known)))
    }

    return (& $entry[0].InvokeCommand -Step $Step -Context $Context)
}
