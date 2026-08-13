function Get-HDTApplyImageStepDescription {
    <#
        .SYNOPSIS
            Describes an ApplyImage step by the image and index it will apply.

        .DESCRIPTION
            The optional third of DESIGN 4.2's triple. This is the step a
            technician watches for four minutes, so the line names what is being
            applied and which index of it - the two facts that distinguish a
            correct build from one that just installed the N edition.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTApplyImageStepDescription -Step $step
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
