function Protect-HDTShareSecret {
    <#
        .SYNOPSIS
            Obfuscates the share password for storage in
            Control\share-credential.json.

        .DESCRIPTION
            AES-CBC with a random IV and the module constant from
            Get-HDTShareSecretKey, base64 encoded as IV followed by ciphertext.

            IT IS OBFUSCATION AND IT IS NOT CLAIMED AS SECURITY. The key is in
            the module, the module is in the boot image, and the boot image is
            handed to whichever machine PXE boots - so anyone who can read either
            can recover the password. DESIGN 6.3 says exactly that, the file this
            writes carries a warning sentence saying it, and docs/share-account.md
            says it again in prose. What this buys is that the password is not
            sitting in plain text in a JSON file on a share, which is a real if
            modest thing.

            NOT DPAPI, deliberately: DPAPI is user- and machine-bound and the
            value has to be readable inside WinPE on a machine that has never
            seen the one that wrote it.

        .PARAMETER Secret
            The plain text to obfuscate.

        .OUTPUTS
            System.String - base64 of the IV followed by the ciphertext.

        .EXAMPLE
            Protect-HDTShareSecret -Secret $plain
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'This is the function that turns the plain text into the stored form; taking a SecureString here would unwrap it one line later.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Secret
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = Get-HDTShareSecretKey
        $aes.GenerateIV()

        $encryptor = $aes.CreateEncryptor()
        try {
            $plain = [System.Text.Encoding]::UTF8.GetBytes($Secret)
            $cipher = $encryptor.TransformFinalBlock($plain, 0, $plain.Length)

            return [System.Convert]::ToBase64String($aes.IV + $cipher)
        } finally {
            $encryptor.Dispose()
        }
    } finally {
        $aes.Dispose()
    }
}
