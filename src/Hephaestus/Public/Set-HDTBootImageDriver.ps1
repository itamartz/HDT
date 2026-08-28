function Set-HDTBootImageDriver {
    <#
        .SYNOPSIS
            Names the driver group injected into the boot image, leaving every
            other line of workspace.yaml byte-identical.

        .DESCRIPTION
            The command an administrator types to give the boot image its network
            and storage drivers, and the one anything with a driver picker has to
            run.

            THE VALUE IS A SELECTION PROFILE, NOT A PATH AND NOT A FILE. A
            profile is a named set of share folders, and that is what lets ONE
            boot image carry a Dell WinPE pack and an HP WinPE pack together. A
            single folder name could never say that, which is the whole reason
            profiles exist. Get-HDTSelectionProfile lists them, including the
            built-ins every share has.

            A PLAIN FOLDER UNDER Drivers\ STILL WORKS. This key used to mean one,
            and a share written before profiles existed still says so.
            Resolve-HDTBootImageDriverPath tries the profile first and falls back
            to the folder, so nothing has to be migrated. A profile wins a tie:
            an administrator who authored one with that name did it after the
            folder already existed, and the folder is what they were replacing.

            A BOOT IMAGE GETS NETWORK AND STORAGE DRIVERS ONLY, never the whole
            driver store. WinPE has to reach the share and see the disk; every
            other driver belongs to the deployed operating system, and a boot
            image carrying the lot is a slow boot and a larger image for no gain.

            A PROFILE THAT IS NOT THERE YET IS FINE. Nothing on the share is
            checked here, and the build only warns: the driver store is imported
            into over time, and a boot image build must not be blocked by a
            folder nobody has filled in.

            -Clear REMOVES THE KEY RATHER THAN EMPTYING IT. A drivers: written
            blank is a document the engine refuses, so "no driver group" can only
            be spelled by the key's absence. If that empties the bootImage block,
            the block goes too.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTWorkspaceDocument is what
            touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The selection profile, by id. A folder name under the share's
            Drivers\ folder is still accepted, which is what this key meant
            before profiles existed.

        .PARAMETER Clear
            Inject no drivers at all.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the driver group set.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\workspace.yaml'))
            $line = Set-HDTBootImageDriver -Line $line -Name 'boot-critical'
            Save-HDTWorkspaceDocument -Path 'C:\HDTLab\Share\workspace.yaml' -Line $line

            Which selection profile goes into the boot image. Point it at a
            profile naming both vendors' WinPE packs and one image serves a mixed
            floor - a machine whose storage or network driver is missing from
            WinPE is a machine that boots to a screen and stops.

        .EXAMPLE
            $line = Set-HDTBootImageDriver -Line $line -Clear

            No group at all, which is what a virtual machine wants: WinPE already has
            the drivers a VM presents.

        .LINK
            Save-HDTWorkspaceDocument
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low', DefaultParameterSetName = 'Group')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1, ParameterSetName = 'Group')]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory = $true, ParameterSetName = 'Clear')]
        [switch] $Clear
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # The document has to be readable before it is worth editing.
    [void] (ConvertFrom-HDTWorkspaceLine -Line $Line)

    # Read from the switch rather than from the parameter set name. The two say
    # the same thing here - -Clear is mandatory in its own set - and the switch
    # is the half a reader, and PSScriptAnalyzer, can follow.
    if ($Clear) {
        if (-not $PSCmdlet.ShouldProcess('bootImage: drivers', 'Inject no drivers into the boot image')) {
            return [string[]] @($Line)
        }

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'drivers') `
                -Text ([string[]] @()))
    } else {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name `
                        -Message 'name a selection profile - Get-HDTSelectionProfile lists them - or a folder under the share Drivers\ folder. Pass -Clear to inject no drivers at all.'))
        }

        if (-not $PSCmdlet.ShouldProcess($Name, 'Inject this driver group into the boot image')) {
            return [string[]] @($Line)
        }

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'drivers') `
                -Text ([string[]] @('drivers: {0}' -f (ConvertTo-HDTRuleScalarText -Value $Name))))
    }

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
