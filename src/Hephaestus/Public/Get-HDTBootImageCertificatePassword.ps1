function Get-HDTBootImageCertificatePassword {
    <#
        .SYNOPSIS
            Reads back the machine certificate's password.

        .DESCRIPTION
            WHAT Update-HDTBootImage EMBEDS AND WHAT THE CONSOLE ASKS. The build
            needs the plain text to put in bootstrap.json, where the boot-time
            import reads it; the window needs to know only whether one has been
            written, so that a page offering a .pfx can say when the other half
            is missing.

            AN ABSENT FILE IS AN ANSWER, NOT A FAILURE. A share with no machine
            certificate has no password for one, which is the ordinary case -
            unlike Get-HDTShareCredential, which refuses, because a workspace
            that names a deployment account and has no secret for it is broken.
            Here the document naming a .pfx is what makes a missing password a
            problem, and Update-HDTBootImage is where the two are compared.

            IT RETURNS PLAIN TEXT, deliberately: the caller is the build, which
            has to hand the password to an X509Certificate2 constructor inside
            WinPE. Obfuscation is not claimed as security - see the warning the
            file carries.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the password, or an empty string when none has been
            written.

        .EXAMPLE
            Get-HDTBootImageCertificatePassword -WorkspaceRoot 'C:\HDTLab\Share'

        .LINK
            Set-HDTBootImageCertificatePassword
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $path = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Control -ChildPath 'certificate-password.json'

    if (-not $FileSystem.TestPath($path)) { return '' }

    $text = $FileSystem.ReadAllText($path)

    try {
        # Assigned first, wrapped second: under Windows PowerShell 5.1
        # ConvertFrom-Json does not enumerate a top-level array (README F12).
        $document = ConvertFrom-Json -InputObject $text
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message ("the certificate password could not be read as JSON: {0}. Rewrite it with Set-HDTBootImageCertificatePassword." -f $_.Exception.Message)))
    }

    $protected = ''
    if ($null -ne $document.PSObject.Properties['password']) { $protected = [string] $document.password }

    if ([string]::IsNullOrWhiteSpace($protected)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message 'the certificate password file carries no password. Rewrite it with Set-HDTBootImageCertificatePassword, or delete it if the image is built with no machine certificate.'))
    }

    try {
        return [string] (Unprotect-HDTShareSecret -Protected $protected)
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message ("the certificate password could not be decoded: {0}. Rewrite it with Set-HDTBootImageCertificatePassword." -f $_.Exception.Message)))
    }
}
