function Assert-HDTStepPartitionTable {
    <#
        .SYNOPSIS
            Refuses a spliced document whose partition table the engine will not
            accept.

        .DESCRIPTION
            THE CHECK IS ON THE WHOLE TABLE, NOT THE ROW BEING WRITTEN. Half the
            refusals ConvertTo-HDTDiskLayout makes are about how the rows relate
            to each other - two of them bootable, two claiming the remainder,
            percentages adding past a hundred - and none of those can be seen
            from the row in front of you. Validating one row at a time let every
            one of them through to the disk.

            IT PARSES WHAT WOULD BE SAVED. Not the caller's intention, not a
            table rebuilt from parameters: the actual spliced lines, through the
            same reader the engine uses, so anything this accepts is something
            Import-HDTSequenceDocument and then the build will accept too.

            IT IS THE COST OF AN EDIT, NOT OF A BUILD. One parse per keystroke
            would be wrong; one parse per press of New or Edit is what turns a
            mistake found at 3am in front of a machine into a message beside the
            box that caused it.

        .PARAMETER Line
            The spliced document, as it would be saved.

        .PARAMETER Name
            The step whose table to check.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            None. It throws, or it says nothing.

        .EXAMPLE
            Assert-HDTStepPartitionTable -Line $result -Name 'Format and Partition'
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A path that is never touched: New-HDTFileSystemFromText answers out of the
    # text it was given, and the name only ever appears in a message.
    $reader = New-HDTFileSystemFromText -Path 'X:\sequence.yaml' `
        -Text ($Line -join [System.Environment]::NewLine)

    $document = Import-HDTSequenceDocument -Path 'X:\sequence.yaml' -FileSystem $reader

    $step = @($document.Step | Where-Object { $_.Name -eq $Name })
    if (@($step).Count -eq 0) { return }

    $property = $step[0].Property
    if ($null -eq $property) { return }
    if (-not $property.Contains('partition')) { return }

    $style = 'GPT'
    if ($property.Contains('style')) { $style = [string] $property['style'] }

    [void] (ConvertTo-HDTDiskLayout -Style $style -Partition @($property['partition']))
}
