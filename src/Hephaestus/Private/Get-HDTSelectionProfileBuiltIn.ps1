function Get-HDTSelectionProfileBuiltIn {
    <#
        .SYNOPSIS
            The selection profiles every share has whether or not it has a
            document.

        .DESCRIPTION
            MDT ships Everything, All Drivers and Nothing, and HDT keeps all
            three. THEY RESOLVE BY NAME WITH NO DOCUMENT BEHIND THEM, which is
            the point: a share nobody has authored a profile on still has to give
            the Windows PE window's picker something legal to point at, and a
            hand-made share with no Control\selection-profiles.yaml still has to
            build a boot image.

            THEY ARE ALSO THE RESERVED IDS. Assert-HDTSelectionProfileDocument
            reads this list to refuse an authored profile that would shadow one -
            an authored 'all-drivers' either beats the built-in or loses to it,
            and both answers leave a share where the name on the tab does not
            mean what it says.

            'nothing' INCLUDES NOTHING AND THAT IS A REAL ANSWER, not the absence
            of one. It is how a virtual machine's boot image is described: WinPE
            already has the drivers a VM presents, and injecting a driver store
            into it is a slower boot for no gain.

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
        [pscustomobject] @{
            Id      = 'nothing'
            Name    = 'Nothing'
            Include = [string[]] @()
        }
    )
}
