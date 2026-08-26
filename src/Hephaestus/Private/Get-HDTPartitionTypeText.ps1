function Get-HDTConsolePartitionTypeText {
    <#
        .SYNOPSIS
            A built-in layout's partition type, as the word an author writes.

        .DESCRIPTION
            THE GRID SHOWS EFI, Primary AND Recovery - the three words an
            authored table uses - whichever side of the toolkit a row came from.
            A built-in layout does not carry that word: it carries the GPT type
            GUID the partition ends up with, because that is what the disk
            service needs.

            SO THE GUID IS READ BACK INTO THE WORD. c12a7328-... is the EFI
            System partition and de94bba4-... is a recovery partition; anything
            else is a basic data partition, which this toolkit calls Primary.
            Printing the GUID instead would be true and useless: nobody compares
            a disk layout by GUID.

            THE ROLE IS NOT USED FOR THIS. A role is what the partition is FOR -
            Windows, Recovery, System - and an authored table is free to call a
            volume anything at all. The type is what it IS.

        .PARAMETER Partition
            One partition from Get-HDTDiskLayout.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - EFI, Recovery or Primary.

        .EXAMPLE
            Get-HDTConsolePartitionTypeText -Partition (Get-HDTDiskLayout -Name uefi-standard).Partition[0]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Partition
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $type = ''
    if ($null -ne $Partition.PSObject.Properties['GptType']) { $type = [string] $Partition.GptType }

    if ($type -match 'c12a7328') { return 'EFI' }
    if ($type -match 'de94bba4') { return 'Recovery' }

    return 'Primary'
}
