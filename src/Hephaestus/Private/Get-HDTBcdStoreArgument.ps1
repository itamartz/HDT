function Get-HDTBcdStoreArgument {
    <#
        .SYNOPSIS
            The /store prefix every bcdedit invocation carries, or nothing at all
            when the system store is the target.

        .DESCRIPTION
            ONE DECISION, ONE PLACE, BECAUSE TWO CALLERS NOW MAKE IT.
            Get-HDTBcdCommand composes the FullOS -> WinPE transport's ten
            commands; New-HDTImageService's TestRamdiskOptions composes an
            eleventh, the probe that asks whether this machine already owns a
            {ramdiskoptions}. Both have to resolve "which store" the same way, and
            two spellings of it is how a probe ends up reading a store the create
            did not write to - which is the question SPIKES S23.7 spent three
            reference builds unable to answer.

            AN EMPTY STORE IS NOT A MISSING VALUE. It means the system store,
            which bcdedit selects by being given no /store argument at all. That
            is right in the full OS, where the machine booted through the store
            bcdboot wrote and the EFI System Partition has no drive letter to
            name. A path is right in WinPE, where the running store is the RAM
            disk's and is not the one the machine boots from.

            MEASURED, NOT ASSUMED (SPIKES S23.8): on a running Windows 11 UEFI
            machine the store bare bcdedit edits and the file at
            <ESP>\EFI\Microsoft\Boot\BCD are the same store - the same object
            count, and an entry created through one enumerates through the other
            immediately.

            IT KEEPS THE ADAPTER BRANCH-FREE. New-HDTImageService is deliberately
            not unit tested (CLAUDE.md rule 1), so it concatenates what this
            returns rather than deciding anything itself.

        .PARAMETER Store
            The BCD store to edit, or '' for the system store.

        .OUTPUTS
            System.String[]. Two elements, or none.

        .EXAMPLE
            Get-HDTBcdStoreArgument -Store 'S:\EFI\Microsoft\Boot\BCD'

            /store S:\EFI\Microsoft\Boot\BCD

        .EXAMPLE
            Get-HDTBcdStoreArgument -Store ''

            Nothing, which is how bcdedit is told to use the system store.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Store
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # NO UNARY COMMA HERE, AND IT IS THE OPPOSITE OF THE USUAL RULE.
    # Everywhere else in this module the comma stops a one-element array
    # collapsing to a scalar. Here it would WRAP the result, so the empty case
    # returns an array containing an empty array - and the caller's
    # [string[]] @(...) turns that inner array into a single empty string. The
    # prefix then contributes a stray '' to every command line, which reads as
    # "expected length 50, actual 51, strings differ at index 0" and looks
    # nothing like the cause. Both callers wrap in @() already, so unrolling is
    # exactly what is wanted.
    if ([string]::IsNullOrWhiteSpace($Store)) {
        return [string[]] @()
    }

    return [string[]] @('/store', $Store)
}
