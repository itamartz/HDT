function Set-HDTBootImageCertificatePassword {
    <#
        .SYNOPSIS
            Writes the password of the boot image's machine certificate.

        .DESCRIPTION
            THE ONE VALUE THAT CANNOT GO IN workspace.yaml. That document is
            hand-edited and committed, and a .pfx password in it is a private
            key's password in git - which is why 05-01 made a password: key
            there a validation error, and why this file exists for the same
            reason share-credential.json does.

            IT IS OBFUSCATED, NOT ENCRYPTED, and the file says so in its own
            'warning' field. The key is a constant in this module, the module is
            in the boot image, and the boot image is handed to whichever machine
            PXE boots: anyone who can read either can recover this password.
            What it buys is that the password is not sitting in plain text in a
            JSON file on a share.

            THE .pfx IN THE IMAGE IS THE REAL EXPOSURE, not this file. A private
            key served over PXE is a private key handed to anything that can
            boot; the certificate should be issued for this purpose, scoped to
            it, and revocable on its own. MDT's and ConfigMgr's equivalents have
            the same property, and no amount of obfuscation changes it.

            IT IS NOT DPAPI, for the same reason the share credential is not:
            the value has to be readable inside WinPE on a machine that has
            never seen the one that wrote it.

            The path is built with Get-HDTWorkspacePath, never a literal.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Password
            The .pfx password. It must not be empty: a .pfx with no password is
            one that will not import, and storing an empty one produces a build
            that succeeds and a machine with no identity.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            None. A cmdlet that echoed the password would put it in a transcript.

        .EXAMPLE
            $secure = (Get-Credential -UserName certificate -Message 'The .pfx password').Password
            Set-HDTBootImageCertificatePassword -WorkspaceRoot 'C:\HDTLab\Share' -Password $secure

            Stores the .pfx password beside the share rather than in workspace.yaml,
            which is a file that gets copied, diffed and mailed about.

        .EXAMPLE
            Test-HDTBootImageCertificatePassword -WorkspaceRoot 'C:\HDTLab\Share'

            Whether what is stored actually opens the .pfx the document names. Worth
            asking before a build rather than after a boot.

        .LINK
            Set-HDTBootImageClientCertificate
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [securestring] $Password,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $path = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Control -ChildPath 'certificate-password.json'

    # UNWRAPPED HERE AND NOWHERE ELSE, and freed in a finally: the plain text
    # exists for the two lines it takes to obfuscate it.
    $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plain = [string] [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }

    if ([string]::IsNullOrEmpty($plain)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message 'the certificate password is empty. A .pfx with no password is one that will not import, and an image built with an empty one boots with no machine identity and no message saying why.'))
    }

    $document = [ordered] @{
        schemaVersion = 1
        password      = (Protect-HDTShareSecret -Secret $plain)
        warning       = 'This password is obfuscated, not encrypted: the key is a constant in the Hephaestus module, so anyone who can read this file - or the boot image, the ISO or the Boot folder that carry it - can recover it. The .pfx inside the image is the larger exposure: treat the boot image as a credential, and issue that certificate for this purpose alone so it can be revoked on its own.'
    }

    $text = ConvertTo-Json -InputObject $document -Depth 3

    if (-not $PSCmdlet.ShouldProcess($path, 'Write the boot image certificate password')) {
        return
    }

    $FileSystem.WriteAllText($path, $text)
}
