<#
    .SYNOPSIS
        Imports the boot image's certificates into WinPE, before wpeinit.

    .DESCRIPTION
        WHAT startnet.cmd RUNS FIRST, and only when the image carries
        certificates - Get-HDTStartnetScript writes the line only then.

        BEFORE wpeinit, WHICH IS THE ENTIRE POINT. wpeinit is what brings the
        network up. A machine certificate that arrives afterwards has missed the
        authentication it was carried for: a switch port running 802.1X decides
        whether to give this machine an address BEFORE anything on it can ask.
        Everything else startnet.cmd runs goes after wpeinit, for the opposite
        reason.

        WHAT IS IMPORTED, AND WHERE:

          root   -> LocalMachine\Root   the certificate authorities to trust.
                                        WinPE boots with Microsoft's roots and
                                        nothing else, so an internal CA is
                                        trusted everywhere except here.

          client -> LocalMachine\My     the machine's own certificate, with its
                                        private key, persisted to the machine
                                        key set so a service can use it.

        A FAILURE IS LOUD AND NOT FATAL. Nothing here stops the boot: a WinPE
        that refused to continue because a certificate would not import is a
        machine with no engine, no log and no command prompt. The message goes
        to the screen - which at this moment is the only thing anybody watching
        can read - and to X:\HDT\certificate-import.log for afterwards.

        IT IS AN ADAPTER OVER X509Store AND IT STAYS ONE. Every decision it acts
        on was made by Get-HDTBootstrapConfiguration, which is unit tested with
        no machine attached: which files, which store, and what the .pfx
        password is.

    .PARAMETER BootstrapPath
        The document naming the certificates. Written by Update-HDTBootImage.

    .PARAMETER ModuleRoot
        Where the engine module was staged in the image.

    .PARAMETER LogPath
        Where to write what happened.

    .EXAMPLE
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Import-HDTBootCertificate.ps1

        What startnet.cmd runs, before wpeinit.
#>
# $LogPath is used inside the $say closure, which the analyzer does not follow -
# the same suppression, for the same reason, as Start-HDTDeployment.ps1's.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Used inside a closure, which PSReviewUnusedParameter does not follow.')]
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $BootstrapPath = 'X:\HDT\bootstrap.json',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ModuleRoot = 'X:\HDT\Modules',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $LogPath = 'X:\HDT\certificate-import.log'
)

Set-StrictMode -Version Latest

# NOT 'Stop'. This script's contract is that it never stops the boot; a
# terminating default would make every unlucky import fatal, and the machine
# would sit at a prompt nobody asked for.
$ErrorActionPreference = 'Continue'

# Visible at the WinPE console without Write-Host, which the analyzer refuses -
# the same idiom Start-HDTDeployment.ps1 uses, and for the same reason: at this
# moment the console is the only thing anybody watching can read.
$InformationPreference = 'Continue'

$say = {
    param([string] $Message)

    $text = '{0}  {1}' -f (Get-Date).ToString('HH:mm:ss'), $Message

    Write-Information -MessageData $text
    try {
        [System.IO.File]::AppendAllText($LogPath, $text + [System.Environment]::NewLine)
    } catch {
        # THE LOG IS THE THING THAT MAY FAIL HERE, not the import. X: is a RAM
        # disk and it is writable, but a boot image built with a tiny scratch
        # space can fill it - and losing the log is not a reason to lose the
        # certificate.
        Write-Information -MessageData ('  (the log at {0} could not be written: {1})' -f $LogPath, $_.Exception.Message)
    }
}

try {
    Import-Module -Name (Join-Path -Path $ModuleRoot -ChildPath 'Hephaestus') -Force -ErrorAction Stop

    $bootstrap = Get-HDTBootstrapConfiguration -Path $BootstrapPath -FileSystem (New-HDTFileSystem)
} catch {
    & $say ('the certificates could not be read from {0}: {1}' -f $BootstrapPath, $_.Exception.Message)
    return
}

# -- the certificate authorities ---------------------------------------------

foreach ($current in @($bootstrap.RootCertificate)) {
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

if (-not [string]::IsNullOrWhiteSpace([string] $bootstrap.ClientCertificate)) {
    try {
        # MachineKeySet, BECAUSE THERE IS NO USER PROFILE HERE, and
        # PersistKeySet because a key that vanished with this process would
        # leave a certificate nothing can use. Exportable is deliberately NOT
        # set: nothing in WinPE needs to export it again.
        $flag = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet

        $certificate = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 `
            -ArgumentList ([string] $bootstrap.ClientCertificate),
        ([string] $bootstrap.GetCertificatePassword()), $flag

        $store = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store `
            -ArgumentList 'My', 'LocalMachine'

        $store.Open('ReadWrite')
        try {
            $store.Add($certificate)
        } finally {
            $store.Close()
        }

        & $say ('this machine will authenticate as {0} ({1})' -f $certificate.Subject, $certificate.Thumbprint)
    } catch {
        # THE MESSAGE NAMES THE PASSWORD, because it is what is wrong most of
        # the time - a .pfx exported with one password and
        # Set-HDTBootImageCertificatePassword run with another produces exactly
        # this failure, on a machine with nobody at the keyboard.
        & $say ('{0} could not be imported: {1}. If the file is right, the password stored with Set-HDTBootImageCertificatePassword is not the one it was exported with.' -f
            $bootstrap.ClientCertificate, $_.Exception.Message)
    }
}
