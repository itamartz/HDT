function Invoke-HDTInstallCertificateStep {
    <#
        .SYNOPSIS
            Carries the boot image's certificates into the applied OS.

        .DESCRIPTION
            Installing the certificates, as a step:

              - name: Install certificates
                type: InstallCertificate
                target: "%HDTOSVolume%"          # optional
                bootstrap: X:\HDT\bootstrap.json # optional
                condition: "%HDTHasCertificate% == True"

            THE REBOOT IS WHAT THIS EXISTS FOR. WinPE imported the certificates
            into a store on a RAM disk, and that disk is gone the moment the
            machine restarts. The applied OS then comes up on the same 802.1X
            port with no identity of its own: no lease, no share, and a resume
            leg that never reaches the engine - after every step before it
            reported Completed.

            IT DOES NOT IMPORT ANYTHING ITSELF, and cannot. A private key is
            protected by the machine's own key storage, which does not exist
            until something boots, so there is no supported way to write a
            usable machine certificate into an image that has never run. What
            this step does is STAGE the files and arrange for the machine to
            import them on its first boot.

            SetupComplete.cmd IS THE SLOT, and Windows chose it: it runs after
            Setup and BEFORE THE FIRST LOGON, which puts the import ahead of
            autologon and therefore ahead of Start-HDTResume needing the
            network. An unattend RunSynchronous would run earlier and fail
            Setup if anything went wrong; a FirstLogonCommand would run after
            the resume leg had already tried.

            IT REFUSES TO OVERWRITE A SetupComplete.cmd IT DID NOT WRITE.
            Windows runs one, and a shop's own post-Setup script silently
            replaced is a thing nobody notices until whatever it did stops
            happening.

            NOTHING TO DO IS NOT A FAILURE. An image carrying no certificates -
            and a run with no bootstrap document, which is every full-OS leg -
            completes having written nothing. The template puts a condition on
            this step as well; this is the second guard, for the sequence
            somebody wrote by hand.

            THE PASSWORD NEVER LANDS IN THE .cmd OR THE .ps1. Both files sit on
            the deployed machine's disk for the life of it and every user can
            read them. It rides in certificate.json beside them, obfuscated the
            same way the share credential is - which is not security, and is
            still not plain text in a batch file.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            The execution context. Its service catalog must carry a FileSystem.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - a step result. Data
            carries certificateCount and the staged paths, never the password.

        .EXAMPLE
            Invoke-HDTInstallCertificateStep -Step $step -Context $context

        .LINK
            Set-HDTBootImageClientCertificate
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $fail = {
        param([string] $Message, [string] $ErrorId)

        $data = [ordered] @{}
        if (-not [string]::IsNullOrWhiteSpace($ErrorId)) { $data['errorId'] = $ErrorId }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component 'InstallCertificate' -Data $data

        return (New-HDTStepResult -Status Failed -Message $Message -Data $data)
    }

    try {
        $target = Get-HDTStepProperty -Step $Step -Name 'target' -Context $Context -Expand -As String
        $bootstrapPath = Get-HDTStepProperty -Step $Step -Name 'bootstrap' -Default 'X:\HDT\bootstrap.json' `
            -Context $Context -Expand -As String
    } catch {
        return (& $fail ([string] $_.Exception.Message) 'HDTConfigurationError')
    }

    try {
        $fileSystem = $Context.Service.GetRequired('FileSystem', 'InstallCertificate')
    } catch {
        return (& $fail ([string] $_.Exception.Message) '')
    }

    # -- what the image carries ----------------------------------------------
    #
    # NO DOCUMENT IS AN ANSWER. The full-OS leg and a sequence run by hand both
    # reach this with no X:\HDT\bootstrap.json, and neither is an error.

    if (-not $fileSystem.TestPath($bootstrapPath)) {
        return (New-HDTStepResult -Status Completed `
                -Message ("no boot image document at '{0}', so this image carries no certificates to install." -f $bootstrapPath) `
                -Data ([ordered] @{ certificateCount = 0 }))
    }

    try {
        $bootstrap = Get-HDTBootstrapConfiguration -Path $bootstrapPath -FileSystem $fileSystem
    } catch {
        return (& $fail ("the boot image document '{0}' could not be read: {1}" -f
                $bootstrapPath, [string] $_.Exception.Message) '')
    }

    $rootCertificate = [string[]] @($bootstrap.RootCertificate)
    $clientCertificate = [string] $bootstrap.ClientCertificate

    if (@($rootCertificate).Count -eq 0 -and [string]::IsNullOrWhiteSpace($clientCertificate)) {
        return (New-HDTStepResult -Status Completed `
                -Message 'this boot image carries no certificates, so there is nothing to carry into the OS.' `
                -Data ([ordered] @{ certificateCount = 0 }))
    }

    # -- where they go --------------------------------------------------------

    $letter = $target
    if ([string]::IsNullOrWhiteSpace($letter)) {
        $letter = [string] $Context.Variable['HDTOSVolume']
    }

    if ([string]::IsNullOrWhiteSpace($letter)) {
        return (& $fail ("step '{0}' stages the certificates on the applied volume and HDTOSVolume is not set. The partition step publishes it; set target: on this step if the sequence knows better." -f
                $Step.Name) 'HDTConfigurationError')
    }

    $letter = $letter.Trim().TrimEnd(':')
    $volume = $letter.Substring(0, 1).ToUpperInvariant()

    # WINDOWS' OWN TWO FOLDERS. Setup\Scripts is where SetupComplete.cmd is
    # looked for and nowhere else; Setup\Files is copied to the machine and is
    # where everything it needs beside it belongs.
    $scriptRoot = '{0}:\Windows\Setup\Scripts' -f $volume
    $fileRoot = '{0}:\Windows\Setup\Files\HDT' -f $volume
    $certificateRoot = '{0}\Certs' -f $fileRoot
    $setupComplete = '{0}\SetupComplete.cmd' -f $scriptRoot

    # -- somebody else's script -----------------------------------------------

    if ($fileSystem.TestPath($setupComplete)) {
        $existing = [string] $fileSystem.ReadAllText($setupComplete)

        if ($existing -notlike '*Import-HDTOsCertificate.ps1*') {
            return (& $fail ("'{0}' is already there and was not written by HDT. Windows runs one SetupComplete.cmd, and replacing this one would silently drop whatever it does. Move that script's work into a step, or into the HDT one after it is written." -f
                    $setupComplete) 'HDTConfigurationError')
        }
    }

    # -- the files ------------------------------------------------------------

    $importScript = Join-Path -Path (Join-Path -Path $script:HDTModuleRoot -ChildPath 'Payload') `
        -ChildPath 'Import-HDTOsCertificate.ps1'

    $moduleFileSystem = New-HDTFileSystem

    if (-not $moduleFileSystem.TestPath($importScript)) {
        return (& $fail ("this module ships the first-boot import script and it is not at '{0}'. The install is incomplete." -f
                $importScript) 'HDTDependencyError')
    }

    try {
        $fileSystem.CreateDirectory($certificateRoot)
        $fileSystem.CreateDirectory($scriptRoot)

        $staged = New-Object -TypeName System.Collections.ArrayList
        $stagedClient = ''

        foreach ($current in @($rootCertificate)) {
            $leaf = [System.IO.Path]::GetFileName([string] $current)
            $fileSystem.CopyItem([string] $current, ('{0}\{1}' -f $certificateRoot, $leaf))
            [void] $staged.Add(('{0}\{1}' -f $certificateRoot, $leaf))
        }

        if (-not [string]::IsNullOrWhiteSpace($clientCertificate)) {
            $leaf = [System.IO.Path]::GetFileName($clientCertificate)
            $stagedClient = '{0}\{1}' -f $certificateRoot, $leaf
            $fileSystem.CopyItem($clientCertificate, $stagedClient)
        }

        # THE MANIFEST, WHICH IS WHAT THE FIRST BOOT READS. The password is
        # carried obfuscated - see the header - so neither the .cmd nor the .ps1
        # has to hold it.
        $manifest = [ordered] @{
            schemaVersion = 1
            root          = [string[]] @($staged)
            client        = $stagedClient
            protected     = ''
            warning       = 'This password is obfuscated, not encrypted: the key is a constant in the Hephaestus module. Delete this folder once the machine is built if the certificate matters.'
        }

        if (-not [string]::IsNullOrWhiteSpace($stagedClient)) {
            $manifest['protected'] = Protect-HDTShareSecret -Secret ([string] $bootstrap.GetCertificatePassword())
        }

        $fileSystem.WriteAllText(('{0}\certificate.json' -f $fileRoot),
            (ConvertTo-Json -InputObject $manifest -Depth 4))

        $fileSystem.WriteAllText(('{0}\Import-HDTOsCertificate.ps1' -f $fileRoot),
            [string] $moduleFileSystem.ReadAllText($importScript))

        # CRLF AND NO BOM, because cmd.exe reading a byte order mark as a command
        # is a class of failure with no useful message at all. IFileSystem writes
        # BOM-free on both engines.
        $batch = @(
            '@echo off'
            'rem Written by the HDT InstallCertificate step. Windows runs this once,'
            'rem after Setup and before the first logon.'
            ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File {0}\Import-HDTOsCertificate.ps1' -f $fileRoot)
        ) -join "`r`n"

        $fileSystem.WriteAllText($setupComplete, $batch + "`r`n")
    } catch {
        return (& $fail ("the certificates could not be staged onto {0}: {1}" -f $volume, [string] $_.Exception.Message) '')
    }

    $count = @($staged).Count
    if (-not [string]::IsNullOrWhiteSpace($stagedClient)) { $count++ }

    $data = [ordered] @{
        certificateCount = $count
        setupComplete    = $setupComplete
        certificateRoot  = $certificateRoot
    }

    $message = "{0} certificate(s) staged on {1}: and armed for the first boot, before the first logon." -f $count, $volume

    Write-HDTLog -Context $Context.Log -Message $message -Severity Info -Event message `
        -Component 'InstallCertificate' -Data $data

    return (New-HDTStepResult -Status Completed -Message $message -Data $data)
}
