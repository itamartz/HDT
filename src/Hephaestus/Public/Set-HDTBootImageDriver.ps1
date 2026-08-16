function Set-HDTBootImageDriver {
    <#
        .SYNOPSIS
            Names the driver group injected into the boot image, leaving every
            other line of workspace.yaml byte-identical.

        .DESCRIPTION
            The command an administrator types to give the boot image its network
            and storage drivers, and the one anything with a driver picker has to
            run.

            THE VALUE IS A GROUP UNDER Drivers\, NOT A PATH AND NOT A FILE. The
            build injects that folder recursively, so a group is how a set of
            .inf files is named once and kept together.

            A BOOT IMAGE GETS NETWORK AND STORAGE DRIVERS ONLY, never the whole
            driver store. WinPE has to reach the share and see the disk; every
            other driver belongs to the deployed operating system, and a boot
            image carrying the lot is a slow boot and a larger image for no gain.

            A GROUP THAT IS NOT THERE YET IS FINE. Nothing on the share is checked
            here, and the build only warns: the driver store is imported into over
            time, and a boot image build must not be blocked by a folder nobody
            has filled in.

            -Clear REMOVES THE KEY RATHER THAN EMPTYING IT. A drivers: written
            blank is a document the engine refuses, so "no driver group" can only
            be spelled by the key's absence. If that empties the bootImage block,
            the block goes too.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTWorkspaceDocument is what
            touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The driver group, as a folder name under the share's Drivers\ folder.

        .PARAMETER Clear
            Inject no drivers at all.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the driver group set.

        .EXAMPLE
            Set-HDTBootImageDriver -Line $line -Name 'boot-critical'

        .EXAMPLE
            Set-HDTBootImageDriver -Line $line -Clear

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
                        -Message 'a driver group is a folder name under the share Drivers\ folder. Pass -Clear to inject no drivers at all.'))
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
