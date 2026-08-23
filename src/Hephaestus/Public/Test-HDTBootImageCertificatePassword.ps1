function Test-HDTBootImageCertificatePassword {
    <#
        .SYNOPSIS
            Whether a password has been stored for the machine certificate.

        .DESCRIPTION
            THE QUESTION A WINDOW ASKS, WITHOUT THE ANSWER IT MUST NOT HOLD. A
            page offering a .pfx has to say whether the other half is there -
            a certificate named with no password is a build refused and a
            deployment that never authenticates - and it has no business
            reading the password to find out.

            Get-HDTBootImageCertificatePassword is for the build, which needs
            the plain text. This is for everything that only needs to know.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean.

        .EXAMPLE
            Test-HDTBootImageCertificatePassword -WorkspaceRoot 'C:\HDTLab\Share'

            True when the stored password opens the .pfx the document names. It opens
            the file to find out - a password that is merely present proves
            nothing.

        .EXAMPLE
            $answer = Test-HDTBootImageCertificatePassword -WorkspaceRoot 'C:\HDTLab\Share'
            if (-not $answer) { 'set it again before building' }

            False covers three cases and does not distinguish them: no password stored,
            the wrong one, or no .pfx named in the first place.

        .LINK
            Set-HDTBootImageCertificatePassword
    #>
    [CmdletBinding()]
    [OutputType([bool])]
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

    return [bool] $FileSystem.TestPath($path)
}
