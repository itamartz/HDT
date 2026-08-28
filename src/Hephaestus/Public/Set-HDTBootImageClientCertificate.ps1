function Set-HDTBootImageClientCertificate {
    <#
        .SYNOPSIS
            Names the machine certificate the boot image authenticates with.

        .DESCRIPTION
            THE CERTIFICATE THAT OPENS THE PORT. A switch running 802.1X
            authenticates a machine BEFORE it gives it an address, and a machine
            in WinPE has no domain identity to authenticate with - so the image
            boots, gets no lease, and looks exactly like a broken deployment
            share. MDT and ConfigMgr both grew a way to put a certificate in the
            boot media for this; so does HDT.

            IT IS A .pfx AND NOTHING ELSE. This is the certificate the machine
            authenticates WITH, which means it needs its private key: a .cer has
            none, and a machine holding one can prove nothing. It is imported
            into the LOCAL MACHINE MY store, not Root - a certificate authority
            is Add-HDTBootImageCertificate's.

            THE PASSWORD IS NOT IN THIS DOCUMENT. workspace.yaml is what an
            administrator hand-edits and commits, and a private key's password in
            git is worse than no certificate at all. Run
            Set-HDTBootImageCertificatePassword, which writes it to
            Control\certificate-password.json the way the share credential's is
            written - and obfuscated, not encrypted, with the file saying so.

            WHAT THE IMAGE COSTS YOU IS THE KEY ITSELF. A .pfx in a boot image
            served over PXE is a private key handed to anything that can boot;
            the certificate should be one issued for this purpose, scoped to it,
            and revocable on its own. No amount of care in the build makes that
            untrue.

            IT IS SHAPED LIKE Set-HDTBootImageUnattend - one value, -Clear to
            take it away, and the key removed rather than written empty.

        .PARAMETER Line
            The workspace.yaml lines to edit.

        .PARAMETER Path
            The .pfx. Certs\winpe.pfx is read from the share; C:\pki\winpe.pfx is
            read from there.

        .PARAMETER Clear
            Build the image with no machine certificate.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the workspace.yaml lines, spliced.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\workspace.yaml'))
            $line = Set-HDTBootImageClientCertificate -Line $line -Path 'Certs\winpe.pfx'
            Save-HDTWorkspaceDocument -Path 'C:\HDTLab\Share\workspace.yaml' -Line $line

            The document half: the boot image is told which .pfx it presents.

        .EXAMPLE
            $secure = (Get-Credential -UserName certificate -Message 'The .pfx password').Password
            Set-HDTBootImageCertificatePassword -WorkspaceRoot 'C:\HDTLab\Share' -Password $secure

            The other half. The password is not in the document and never is - it goes
            beside the share, obfuscated, where the build reads it.

        .LINK
            Set-HDTBootImageCertificatePassword

        .LINK
            Add-HDTBootImageCertificate
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'File')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1, ParameterSetName = 'File')]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, ParameterSetName = 'Clear')]
        [switch] $Clear
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # The document has to be readable before it is worth editing.
    [void] (ConvertFrom-HDTWorkspaceLine -Line $Line)

    # Read from the switch rather than from the parameter set name, as
    # Set-HDTBootImageUnattend and Set-HDTBootImageDriver do.
    if ($Clear) {
        if (-not $PSCmdlet.ShouldProcess('bootImage: clientCertificate', 'Build the boot image with no machine certificate')) {
            return [string[]] @($Line)
        }

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'clientCertificate') `
                -Text ([string[]] @()))
    } else {
        if ($Path -notmatch '\.pfx$') {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path `
                        -Message ("'{0}' is not a .pfx. This is the certificate the machine authenticates WITH, so it needs its private key - a .cer has none, and an 802.1X port stays shut for a machine holding one. A certificate authority to TRUST is Add-HDTBootImageCertificate's." -f $Path)))
        }

        if (-not $PSCmdlet.ShouldProcess($Path, 'Authenticate with this certificate from the boot image')) {
            return [string[]] @($Line)
        }

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'clientCertificate') `
                -Text ([string[]] @('clientCertificate: {0}' -f (ConvertTo-HDTRuleScalarText -Value $Path))))
    }

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
