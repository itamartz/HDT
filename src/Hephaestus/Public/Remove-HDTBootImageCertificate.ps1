function Remove-HDTBootImageCertificate {
    <#
        .SYNOPSIS
            Stops the boot image trusting a certificate authority.

        .DESCRIPTION
            THE OTHER HALF OF Add-HDTBootImageCertificate, and the half that
            matters when a CA is retired: a root certificate left in an image
            outlives the authority it belongs to, and every machine built from
            that image keeps trusting it.

            THE KEY GOES WITH THE LAST ENTRY. An empty rootCertificates is a
            document saying "there are certificate authorities" and naming none,
            which the validator refuses - so removing the last one removes the
            key rather than leaving an empty list behind.

            It splices lines, returns them, and writes nothing.

        .PARAMETER Line
            The workspace.yaml lines to edit.

        .PARAMETER Path
            The certificate to stop trusting, exactly as the document names it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the workspace.yaml lines, spliced.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\workspace.yaml'))
            $line = Remove-HDTBootImageCertificate -Line $line -Path 'Certs\contoso-root.cer'
            Save-HDTWorkspaceDocument -Path 'C:\HDTLab\Share\workspace.yaml' -Line $line

            Stops trusting it. A path the document does not list is not an error:
            the document already says what this was asked to make it say.

        .EXAMPLE
            @($line | Where-Object { $_ -match 'contoso-root' }).Count

            Zero. The certificate file itself is untouched - this edits the list,
            not the store.

        .LINK
            Add-HDTBootImageCertificate
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
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

    $workspace = ConvertFrom-HDTWorkspaceLine -Line $Line

    $declared = [string[]] @($workspace.BootImage.RootCertificate)
    $at = [array]::IndexOf($declared, $Path)

    if ($at -lt 0) {
        $trusted = 'nothing'
        if (@($declared).Count -gt 0) { $trusted = @($declared) -join ', ' }

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path -Category ObjectNotFound `
                    -Message ("this boot image does not trust '{0}'. It trusts {1}, and a path is compared exactly as the document writes it." -f
                        $Path, $trusted)))
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Stop trusting this certificate authority in the boot image')) {
        return [string[]] @($Line)
    }

    # NO -EmptyText. Unlike optionalComponents, an absent rootCertificates and an
    # empty one mean the same thing - no certificate authorities of your own -
    # so the key goes with the last entry rather than staying as [].
    $result = [string[]] @(Remove-HDTWorkspaceItem -Line $Line `
            -Path @('bootImage', 'rootCertificates') -Position $at)

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
