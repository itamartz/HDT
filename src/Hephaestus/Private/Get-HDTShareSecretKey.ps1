function Get-HDTShareSecretKey {
    <#
        .SYNOPSIS
            The AES key the share credential is obfuscated with.

        .DESCRIPTION
            A CONSTANT IN THE MODULE, AND THAT IS NOT AN OVERSIGHT. Obfuscation
            is not claimed as security: the boot image contains everything
            needed to reverse it, so HDT says so plainly rather than implying
            the image is safe to hand out.

            The value has to be recoverable inside WinPE, on a machine that has
            never seen the one that built the image, with no user profile and no
            network. That rules out DPAPI (user- and machine-bound), a key held
            in the registry of the build machine, and anything derived from a
            logged-on identity. What is left is a key that ships with the code,
            which stops the password being readable over somebody's shoulder in
            a JSON file and stops nothing else.

            Derived from a fixed sentence with SHA-256 rather than written as 32
            magic bytes, so the value is reproducible by reading this file and a
            transposed digit cannot silently change it.

        .OUTPUTS
            System.Byte[] - 32 bytes.

        .EXAMPLE
            $key = Get-HDTShareSecretKey
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [byte[]] $sha.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes('Hephaestus Deployment Toolkit share credential obfuscation key v1'))
    } finally {
        $sha.Dispose()
    }
}
