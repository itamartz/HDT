function Get-HDTAdkInstallPlan {
    <#
        .SYNOPSIS
            Decides how the Windows ADK gets onto this machine - already here,
            from staged media, from Microsoft, or not at all.

        .DESCRIPTION
            THE WHOLE DECISION, AND NOTHING THAT ACTS ON IT. Install-HDTAdk
            establishes the three facts and runs the installers; this weighs
            them. It touches no disk and no network - every input is a bool -
            so the choice is unit tested without a 1.5 GB download.

            Three facts settle it and the ORDER MATTERS:

              1. The ADK already resolves       -> AlreadyInstalled
              2. Both installers are staged     -> InstallFromPayload
              3. There is a route to Microsoft  -> Download
              4. None of the above              -> Blocked, with instructions

            STAGED MEDIA BEATS A LIVE CONNECTION. A site that is airgapped by
            policy rather than by cable can still reach go.microsoft.com, and
            must install the build its change board approved rather than
            whatever is current today. Reversing 2 and 3 would silently install
            something nobody signed off.

            HALF A PAYLOAD IS NOT A PAYLOAD. The Windows PE add-on is a separate
            download from the ADK, and an ADK without it builds no boot image -
            a failure that would otherwise surface much later, inside
            Update-HDTBootImage, where it reads as a boot image defect.

            BLOCKED IS AN ANSWER, NOT AN ERROR. An IT department behind an
            airgap needs the two links, the command that produces an offline
            layout, and the folder to drop it in. Throwing 'no internet' would
            send them searching for all three.

        .PARAMETER AdkPresent
            Whether the ADK already resolves on this machine. Passed in rather
            than probed, so the decision stays pure.

        .PARAMETER InternetAvailable
            Whether Microsoft is reachable. Passed in for the same reason - no
            unit test should touch the network.

        .PARAMETER PayloadStaged
            Whether both installers are sitting in PayloadPath. Passed in like
            the other two: this used to be probed here through an IFileSystem,
            which made one of the three facts arrive differently from the other
            two and left a caller asserting -AdkPresent next to a payload the
            command could see for itself.

        .PARAMETER PayloadPath
            Where an offline layout is staged, and where a download is put.
            Names the folder in the instructions; nothing here reads it.

        .OUTPUTS
            PSCustomObject. Action, Version, the two URLs, the two setup paths,
            the argument each installer takes, and Instruction - the runbook,
            populated when the answer is Blocked.

        .EXAMPLE
            Get-HDTAdkInstallPlan -AdkPresent $false -PayloadStaged $false -InternetAvailable $false
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [bool] $AdkPresent,

        [Parameter(Mandatory = $true)]
        [bool] $PayloadStaged,

        [Parameter(Mandatory = $true)]
        [bool] $InternetAvailable,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $PayloadPath = 'C:\HDTPayload\ADK'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # PINNED, NOT "LATEST". 10.1.28000.1 (November 2025) is the newest ADK and
    # supports Windows 11 26H1 Arm64 only; 10.1.26100.2454 is the one that
    # covers x64 Windows 11 24H2/25H2 and Server 2025, which is what this
    # toolkit deploys. Verified against learn.microsoft.com, adk-install.
    $version = '10.1.26100.2454'
    $adkUrl = 'https://go.microsoft.com/fwlink/?linkid=2289980'
    $winPeUrl = 'https://go.microsoft.com/fwlink/?linkid=2289981'
    $servicingUrl = 'https://learn.microsoft.com/windows-hardware/get-started/adk-servicing'

    $adkSetup = [System.IO.Path]::Combine($PayloadPath, 'adksetup.exe')
    $winPeSetup = [System.IO.Path]::Combine($PayloadPath, 'adkwinpesetup.exe')

    # /features NAMES ONLY WHAT THE TOOLKIT USES. Deployment Tools carries
    # oscdimg and DISM, which is all Get-HDTAdkPath ever asks for; installing
    # the whole kit costs several GB nobody reads. The add-on ships a single
    # feature and takes no /features switch.
    $adkArgument = '/quiet /features OptionId.DeploymentTools'
    $winPeArgument = '/quiet'

    if ($AdkPresent) {
        $action = 'AlreadyInstalled'
    }
    elseif ($PayloadStaged) {
        $action = 'InstallFromPayload'
    }
    elseif ($InternetAvailable) {
        $action = 'Download'
    }
    else {
        $action = 'Blocked'
    }

    $instruction = @()

    if ($action -eq 'Blocked') {
        # THE RUNBOOK. Written for somebody who has to walk it to a machine on
        # another network, which is why it names the file, the folder and the
        # command rather than saying "download the ADK".
        $instruction = @(
            ("This machine cannot reach Microsoft and no ADK payload is staged in {0}." -f $PayloadPath),
            '',
            ("On a machine that DOES have internet, download ADK {0}:" -f $version),
            ("  1. Windows ADK            {0}" -f $adkUrl),
            ("  2. Windows PE add-on      {0}" -f $winPeUrl),
            '',
            'Both are needed. The add-on is a separate download and without it no boot image can be built.',
            '',
            'Those two files are stubs that pull the rest down. To capture the FULL offline layout, run',
            'each of them on the connected machine with /layout:',
            '',
            ("  adksetup.exe /quiet /layout {0}" -f $PayloadPath),
            ("  adkwinpesetup.exe /quiet /layout {0}" -f $PayloadPath),
            '',
            ("Copy the whole of {0} to this machine - same folder name - and run this command again." -f $PayloadPath),
            'It will find the payload and install from it without asking for a network.',
            '',
            ("SECURITY: ADK {0} needs patch KB5079391 or later, which fixes CVE-2026-25166." -f $version),
            ("Fetch the patch on the connected machine too and apply it after installing: {0}" -f $servicingUrl)
        )
    }

    return [pscustomobject] ([ordered] @{
            Action         = $action
            Version        = $version
            AdkUrl         = $adkUrl
            WinPeUrl       = $winPeUrl
            PayloadPath    = $PayloadPath
            AdkSetupPath   = $adkSetup
            WinPeSetupPath = $winPeSetup
            AdkArgument    = $adkArgument
            WinPeArgument  = $winPeArgument
            PatchUrl       = $servicingUrl
            Instruction    = [string[]] $instruction
        })
}
