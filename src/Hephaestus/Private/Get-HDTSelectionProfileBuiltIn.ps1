function Get-HDTSelectionProfileBuiltIn {
    <#
        .SYNOPSIS
            The selection profiles every share has whether or not it has a
            document.

        .DESCRIPTION
            MDT ships Everything, All Drivers, All Packages, Nothing and Sample;
            HDT keeps TWO. THEY RESOLVE BY NAME WITH NO DOCUMENT BEHIND THEM,
            which is the point: a share nobody has authored a profile on still
            has to give the Windows PE window's picker something legal to point
            at, and a hand-made share with no Control\selection-profiles.yaml
            still has to build a boot image.

            NOTHING IS NOT ONE OF THEM, AND THAT IS DELIBERATE. The picker's
            first row already reads "(none - WinPE uses the drivers Microsoft
            ships)", so a Nothing profile is a SECOND way to say one thing - and
            the two would disagree the first time somebody picked one expecting
            the other. MDT needs its Nothing because a selection profile is a
            mandatory field on several of its dialogs; here the empty answer is
            an entry in the list, so it is not.

            The packages profiles are absent for a plainer reason: HDT has no
            Packages folder. A profile may only include from
            Get-HDTSelectionProfileContentFolder's five.

            THEY ARE ALSO THE RESERVED IDS. Assert-HDTSelectionProfileDocument
            reads this list to refuse an authored profile that would shadow one -
            an authored 'all-drivers' either beats the built-in or loses to it,
            and both answers leave a share where the name on the tab does not
            mean what it says.

            A VIRTUAL MACHINE'S BOOT IMAGE IS THE EMPTY ROW, not a profile.
            WinPE already has the drivers a VM presents, and injecting a driver
            store into it is a slower boot for no gain - so that answer is
            'drivers:' absent from workspace.yaml, which Set-HDTBootImageDriver
            -Clear writes and the picker shows as its first row.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per profile, in id order,
            with Id, Name and Include.

        .EXAMPLE
            Get-HDTSelectionProfileBuiltIn | ForEach-Object { $_.Id }

            all-drivers, everything, nothing - the ids no authored profile may
            take.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [pscustomobject[]] @(
        [pscustomobject] @{
            Id      = 'all-drivers'
            Name    = 'All drivers'
            Include = [string[]] @('Drivers')
        }
        [pscustomobject] @{
            Id      = 'everything'
            Name    = 'Everything'
            Include = [string[]] @(Get-HDTSelectionProfileContentFolder)
        }
    )
}
