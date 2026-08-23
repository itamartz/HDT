function Add-HDTBootImageCertificate {
    <#
        .SYNOPSIS
            Declares a certificate authority the boot image is to trust.

        .DESCRIPTION
            WinPE BOOTS WITH MICROSOFT'S ROOT STORE AND NOTHING ELSE IN IT. An
            internal CA is trusted by every domain-joined machine on the network
            and by no machine that has just come up off a WIM - so an HTTPS
            endpoint, a WSUS server or a package feed signed by that CA is
            reachable from everywhere except the one place a deployment runs.
            This is what puts it in the image.

            IT IS THE PUBLIC CERTIFICATE AND ONLY THAT. A .pfx is refused here:
            everything in this list is imported into the LOCAL MACHINE ROOT store
            of every machine that boots the image, and a private key in a trusted
            root store is not a thing anybody asks for on purpose. The machine's
            own certificate is Set-HDTBootImageClientCertificate's.

            THE PATH IS A PATH, exactly as extraContent's source and the answer
            file are: relative to the share, or rooted on the build host.
            Update-HDTBootImage resolves both, and refuses a named certificate it
            cannot find BEFORE it mounts anything.

            IT SPLICES LINES AND NEVER PARSES AND RE-EMITS, so an administrator's
            comments survive. It returns lines and writes nothing;
            Save-HDTWorkspaceDocument is what touches the share.

        .PARAMETER Line
            The workspace.yaml lines to edit.

        .PARAMETER Path
            The certificate file. Certs\contoso-root.cer is read from the share;
            C:\pki\contoso-root.cer is read from there.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the workspace.yaml lines, spliced.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\workspace.yaml'))
            $line = Add-HDTBootImageCertificate -Line $line -Path 'Certs\contoso-root.cer'
            Save-HDTWorkspaceDocument -Path 'C:\HDTLab\Share\workspace.yaml' -Line $line

            Trusts a certificate authority in the boot image. The next
            Update-HDTBootImage is what puts it there.

        .EXAMPLE
            @($line | Where-Object { $_ -match 'contoso-root' })

            The one line the edit added. Everything else in workspace.yaml - the
            comments included - is byte for byte what it was.

        .LINK
            Set-HDTBootImageClientCertificate
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Path -match '\.pfx$') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path `
                    -Message ("'{0}' is a .pfx, and this list is imported into the trusted root store of every machine that boots the image - a private key does not belong there. Run Set-HDTBootImageClientCertificate for the machine's own certificate, and name the CA's .cer here." -f $Path)))
    }

    $workspace = ConvertFrom-HDTWorkspaceLine -Line $Line

    $declared = New-Object -TypeName System.Collections.ArrayList
    foreach ($current in @($workspace.BootImage.RootCertificate)) {
        [void] $declared.Add([string] $current)
    }

    foreach ($current in @($declared)) {
        if (([string] $current) -eq $Path) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path `
                        -Message ("this document already trusts '{0}'. Importing the same certificate twice changes nothing and hides which entry an administrator meant to remove." -f $Path)))
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Trust this certificate authority in the boot image')) {
        return [string[]] @($Line)
    }

    $block = Get-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'rootCertificates')
    $result = [string[]] @($Line)

    if ($null -ne $block) {
        # APPENDED, NOT REWRITTEN. Rewriting the list would lose whatever was
        # written beside the entries already in it.
        $result = [string[]] @(Add-HDTWorkspaceItem -Line $result -Block $block `
                -Text ([string[]] @('- {0}' -f (ConvertTo-HDTRuleScalarText -Value $Path))))
    } else {
        $written = New-Object -TypeName System.Collections.ArrayList
        [void] $written.Add('rootCertificates:')
        [void] $written.Add('  - {0}' -f (ConvertTo-HDTRuleScalarText -Value $Path))

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $result -Path @('bootImage', 'rootCertificates') `
                -Text ([string[]] @($written)))
    }

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
