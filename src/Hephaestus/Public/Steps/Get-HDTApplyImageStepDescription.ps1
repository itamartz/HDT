function Get-HDTApplyImageStepDescription {
    <#
        .SYNOPSIS
            Describes an ApplyImage step by the image and index it will apply.

        .DESCRIPTION
            The optional third of the step contract's triple. This is the step a
            technician watches for four minutes, so the line names what is being
            applied and which index of it - the two facts that distinguish a
            correct build from one that just installed the N edition.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'ApplyImage' })[0]

            Get-HDTApplyImageStepDescription -Step $step

            The one line the log and the progress display carry for this step.

        .EXAMPLE
            Get-HDTStepDescription -Step $step

            The same line through the dispatcher, which is how the engine asks.
            It finds this function by name; a step type that declares none gets
            '<Type>: <name>' instead.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $source = [string] (Get-HDTStepProperty -Step $Step -Name 'os' `
            -Default (Get-HDTStepProperty -Step $Step -Name 'image' -Default 'the operating system the sequence names'))

    $index = Get-HDTStepProperty -Step $Step -Name 'index'
    if ($null -ne $index) {
        return ('Apply: {0}, index {1}' -f $source, $index)
    }

    $name = Get-HDTStepProperty -Step $Step -Name 'name'
    if ($null -ne $name) {
        return ("Apply: {0}, the image named '{1}'" -f $source, $name)
    }

    $edition = Get-HDTStepProperty -Step $Step -Name 'edition'
    if ($null -ne $edition) {
        return ('Apply: {0}, the {1} edition' -f $source, $edition)
    }

    return ('Apply: {0}, the default index' -f $source)
}
