function Unprotect-HDTShareSecret {
    <#
        .SYNOPSIS
            Recovers the share password Protect-HDTShareSecret stored.

        .DESCRIPTION
            The other half of the obfuscation DESIGN 6.3 describes: base64 in,
            the first 16 bytes are the IV, the rest is AES-CBC ciphertext under
            the module constant from Get-HDTShareSecretKey.

            This is the half that runs inside WinPE, which is why the key cannot
            be user- or machine-bound. See Protect-HDTShareSecret.

        .PARAMETER Protected
            The base64 value written into Control\share-credential.json.

        .OUTPUTS
            System.String

        .EXAMPLE
            Unprotect-HDTShareSecret -Protected $document.password
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Protected
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $blob = [System.Convert]::FromBase64String($Protected)

    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = Get-HDTShareSecretKey

        $iv = New-Object -TypeName 'System.Byte[]' -ArgumentList 16
        [System.Array]::Copy($blob, 0, $iv, 0, 16)
        $aes.IV = $iv

        $decryptor = $aes.CreateDecryptor()
        try {
            $plain = $decryptor.TransformFinalBlock($blob, 16, $blob.Length - 16)

            return [System.Text.Encoding]::UTF8.GetString($plain)
        } finally {
            $decryptor.Dispose()
        }
    } finally {
        $aes.Dispose()
    }
}
