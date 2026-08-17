<#
    .SYNOPSIS
        Imports the staged certificates on the deployed machine's first boot.

    .DESCRIPTION
        WHAT SetupComplete.cmd RUNS, staged onto the applied volume by the
        InstallCertificate step - never run on the build host, and never in
        WinPE. Windows runs SetupComplete.cmd after Setup and BEFORE THE FIRST
        LOGON, which puts this ahead of autologon and therefore ahead of
        Start-HDTResume needing the network.

        IT IS THE SAME TWO STORES AS THE BOOT IMAGE'S IMPORT: certificate
        authorities into LocalMachine\Root, the machine's own certificate into
        LocalMachine\My with its private key persisted to the machine key set.

        IT DOES NOT LOAD THE HDT MODULE. This runs on a machine that has not
        started the engine yet and may have no module staged at all, so the one
        thing it needs from HDT - undoing the manifest's obfuscation - is done
        here with the same key derivation, written out rather than imported.
        THE KEY IS A CONSTANT AND OBFUSCATION IS NOT CLAIMED AS SECURITY: it
        stops the password sitting in plain text in a file every user of this
        machine can read, and nothing else.

        A FAILURE IS LOUD AND NOT FATAL. Nothing here stops the first boot: a
        machine that refused to finish because a certificate would not import is
        a machine nobody can log on to. It goes to
        %WINDIR%\Setup\Files\HDT\certificate-import.log, which is where the
        files it was reading already are.

    .PARAMETER ManifestPath
        The document naming what to import, written by the step beside this
        script.

    .EXAMPLE
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Files\HDT\Import-HDTOsCertificate.ps1
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ManifestPath = (Join-Path -Path $PSScriptRoot -ChildPath 'certificate.json')
)

Set-StrictMode -Version Latest

# NOT 'Stop'. This script's contract is that it never stops the first boot.
$ErrorActionPreference = 'Continue'
$InformationPreference = 'Continue'

$logPath = Join-Path -Path $PSScriptRoot -ChildPath 'certificate-import.log'

$say = {
    param([string] $Message)

    $text = '{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message

    Write-Information -MessageData $text
    try {
        [System.IO.File]::AppendAllText($logPath, $text + [System.Environment]::NewLine)
    } catch {
        Write-Information -MessageData ('  (the log could not be written: {0})' -f $_.Exception.Message)
    }
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    & $say ('there is nothing to import: {0} is not there.' -f $ManifestPath)
    return
}

try {
    $manifest = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($ManifestPath))
} catch {
    & $say ('{0} could not be read: {1}' -f $ManifestPath, $_.Exception.Message)
    return
}

# THE SAME DERIVATION AS Get-HDTShareSecretKey, written out because no module is
# loaded here. If that sentence ever changes there, it changes here too - and the
# contract test that compares them is what says so.
$unprotect = {
    param([string] $Protected)

    if ([string]::IsNullOrWhiteSpace($Protected)) { return '' }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $key = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(
                'Hephaestus Deployment Toolkit share credential obfuscation key v1'))
    } finally {
        $sha.Dispose()
    }

    $raw = [System.Convert]::FromBase64String($Protected)

    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $key
        $aes.IV = $raw[0..15]

        $decryptor = $aes.CreateDecryptor()
        try {
            $plain = $decryptor.TransformFinalBlock($raw, 16, $raw.Length - 16)
            return [System.Text.Encoding]::UTF8.GetString($plain)
        } finally {
            $decryptor.Dispose()
        }
    } finally {
        $aes.Dispose()
    }
}

# -- the certificate authorities ---------------------------------------------

foreach ($current in @($manifest.root)) {
    try {
        $certificate = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 `
            -ArgumentList ([string] $current)

        $store = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store `
            -ArgumentList 'Root', 'LocalMachine'

        $store.Open('ReadWrite')
        try {
            $store.Add($certificate)
        } finally {
            $store.Close()
        }

        & $say ('trusting {0} ({1})' -f $certificate.Subject, $certificate.Thumbprint)
    } catch {
        & $say ('{0} could not be trusted: {1}' -f $current, $_.Exception.Message)
    }
}

# -- the machine's own certificate --------------------------------------------

$client = ''
if ($null -ne $manifest.PSObject.Properties['client']) { $client = [string] $manifest.client }

if (-not [string]::IsNullOrWhiteSpace($client)) {
    try {
        # MachineKeySet BECAUSE NOBODY IS LOGGED ON, and PersistKeySet because a
        # key that vanished with this process would leave a certificate the
        # supplicant cannot use.
        $flag = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet

        $password = & $unprotect ([string] $manifest.protected)

        $certificate = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 `
            -ArgumentList $client, $password, $flag

        $store = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store `
            -ArgumentList 'My', 'LocalMachine'

        $store.Open('ReadWrite')
        try {
            $store.Add($certificate)
        } finally {
            $store.Close()
        }

        & $say ('this machine will authenticate as {0} ({1})' -f $certificate.Subject, $certificate.Thumbprint)

        # THE CERTIFICATE ALONE AUTHENTICATES NOTHING. Wired AutoConfig is the
        # supplicant, and Windows ships it stopped and set to Manual - so a
        # machine holding a perfectly good certificate still never speaks EAP.
        # Set to Automatic and started here, where the certificate it needs has
        # just arrived.
        try {
            Set-Service -Name 'dot3svc' -StartupType Automatic
            Start-Service -Name 'dot3svc'

            & $say 'wired AutoConfig (dot3svc) set to Automatic and started.'
        } catch {
            & $say ('dot3svc could not be started: {0}. The certificate is installed; 802.1X will not run until the service does.' -f
                $_.Exception.Message)
        }
    } catch {
        & $say ('{0} could not be imported: {1}. If the file is right, the password stored with Set-HDTBootImageCertificatePassword is not the one it was exported with.' -f
            $client, $_.Exception.Message)
    }
}
