# THE CERTIFICATES, CARRIED PAST THE REBOOT.
#
# WinPE imported them into a store on a RAM disk, and that disk is gone the
# moment the machine restarts. The applied OS then comes up on the same 802.1X
# port with no identity of its own: no lease, no share, and a resume leg that
# never reaches the engine. Every step before it reported Completed.
#
# WHY SetupComplete.cmd AND NOT AN OFFLINE IMPORT. A private key is protected by
# the machine's own key storage, which does not exist until something boots -
# there is no supported way to write a usable machine certificate into an image
# that has never run. SetupComplete.cmd is Windows' own "run this once, after
# Setup, before anybody logs on" hook, which puts the import ahead of autologon
# and therefore ahead of Start-HDTResume needing the network.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # bootstrap.json as Update-HDTBootImage writes it for an image that carries
    # both kinds - the paths are the image's own, which is what the step copies
    # FROM.
    $script:bootstrapText = ConvertTo-Json -Depth 5 -InputObject ([ordered] @{
            schemaVersion = 1
            workspaceId   = 'LAB'
            provider      = 'Local'
            deployRoot    = 'C:\Deploy'
            certificate   = [ordered] @{
                root      = @('X:\HDT\Certs\contoso-root.cer')
                client    = 'X:\HDT\Certs\winpe.pfx'
                protected = 'JMuHPVvrPBjfPgboyM1UjETROKiE1tnYozPAtYSsozJPsnalvz9Yulkm7aJtG/GC'
            }
        })

    $script:newRun = {
        param([string] $Bootstrap)

        $file = @{
            'X:\HDT\Certs\contoso-root.cer' = 'root der'
            'X:\HDT\Certs\winpe.pfx'        = 'pfx bytes'
        }

        if (-not [string]::IsNullOrWhiteSpace($Bootstrap)) { $file['X:\HDT\bootstrap.json'] = $Bootstrap }

        $fileSystem = New-HDTFakeFileSystem -File $file
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 17, 12, 0, 0, [System.DateTimeKind]::Utc))

        $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock

        $log = New-HDTLogContext -RunId 'run-cert' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $fileSystem -Clock $clock -Level Debug

        $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $variable['HDTOSVolume'] = 'W:'

        $context = New-HDTExecutionContext -RunId 'run-cert' -Phase WinPE -WorkspaceRoot 'C:\ws' `
            -Variable $variable -Service $catalog -Log $log

        return [pscustomobject] @{ Context = $context; FileSystem = $fileSystem }
    }

    $script:newStep = {
        param([System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Name            = 'Install certificates'
            Type            = 'InstallCertificate'
            Index           = 1
            GroupPath       = @('Postinstall')
            RunIn           = 'WinPE'
            Condition       = ''
            Disabled        = $false
            ContinueOnError = $false
            Property        = $bag
        }
    }

    $script:step = & $script:newStep $null
}

Describe 'Invoke-HDTInstallCertificateStep' {

    It 'copies every certificate onto the applied volume' {
        $run = & $script:newRun $script:bootstrapText

        $result = Invoke-HDTInstallCertificateStep -Step $script:step -Context $run.Context

        [string] $result.Status | Should -BeExactly 'Completed'
        $run.FileSystem.TestPath('W:\Windows\Setup\Files\HDT\Certs\contoso-root.cer') | Should -BeTrue
        $run.FileSystem.TestPath('W:\Windows\Setup\Files\HDT\Certs\winpe.pfx') | Should -BeTrue
    }

    It 'writes SetupComplete.cmd where Windows looks for it' {
        # \Windows\Setup\Scripts\SetupComplete.cmd, and nowhere else. Windows
        # runs exactly that path, after Setup and before the first logon.
        $run = & $script:newRun $script:bootstrapText

        [void] (Invoke-HDTInstallCertificateStep -Step $script:step -Context $run.Context)

        $run.FileSystem.TestPath('W:\Windows\Setup\Scripts\SetupComplete.cmd') | Should -BeTrue
    }

    It 'stages the script SetupComplete.cmd calls' {
        $run = & $script:newRun $script:bootstrapText

        [void] (Invoke-HDTInstallCertificateStep -Step $script:step -Context $run.Context)

        $cmd = [string] $run.FileSystem.ReadAllText('W:\Windows\Setup\Scripts\SetupComplete.cmd')
        $run.FileSystem.TestPath('W:\Windows\Setup\Files\HDT\Import-HDTOsCertificate.ps1') | Should -BeTrue
        $cmd | Should -BeLike '*Import-HDTOsCertificate.ps1*'
    }

    It 'never writes the password into the script or the batch file' {
        # BOTH FILES SIT ON THE DEPLOYED MACHINE'S DISK for the life of it.
        # The password rides in the manifest beside them, obfuscated the same way
        # the share credential is - which is not security, and is still better
        # than plain text in a .cmd every user can read.
        $run = & $script:newRun $script:bootstrapText

        [void] (Invoke-HDTInstallCertificateStep -Step $script:step -Context $run.Context)

        $cmd = [string] $run.FileSystem.ReadAllText('W:\Windows\Setup\Scripts\SetupComplete.cmd')
        $script = [string] $run.FileSystem.ReadAllText('W:\Windows\Setup\Files\HDT\Import-HDTOsCertificate.ps1')

        $cmd | Should -Not -BeLike '*JMuHPVvr*'
        $script | Should -Not -BeLike '*JMuHPVvr*'
    }

    It 'writes a manifest naming what to import and into which store' {
        $run = & $script:newRun $script:bootstrapText

        [void] (Invoke-HDTInstallCertificateStep -Step $script:step -Context $run.Context)

        $manifest = ConvertFrom-Json -InputObject ([string] $run.FileSystem.ReadAllText(
                'W:\Windows\Setup\Files\HDT\certificate.json'))

        @($manifest.root).Count | Should -Be 1
        [string] $manifest.client | Should -BeLike '*winpe.pfx'
    }

    It 'reports what it staged, and never the password' {
        $run = & $script:newRun $script:bootstrapText

        $result = Invoke-HDTInstallCertificateStep -Step $script:step -Context $run.Context

        [int] $result.Data['certificateCount'] | Should -Be 2
        (ConvertTo-Json -InputObject $result -Depth 4) | Should -Not -BeLike '*JMuHPVvr*'
    }

    It 'completes without doing anything when the image carries none' {
        # THE CONDITION IN THE TEMPLATE IS THE FIRST GUARD AND THIS IS THE
        # SECOND. A sequence somebody wrote by hand has no condition on it, and
        # a step that failed there would fail a deployment over a feature that
        # was never asked for.
        $bare = ConvertTo-Json -Depth 5 -InputObject ([ordered] @{
                schemaVersion = 1
                workspaceId   = 'LAB'
                provider      = 'Local'
                deployRoot    = 'C:\Deploy'
            })

        $run = & $script:newRun $bare

        $result = Invoke-HDTInstallCertificateStep -Step $script:step -Context $run.Context

        [string] $result.Status | Should -BeExactly 'Completed'
        $run.FileSystem.TestPath('W:\Windows\Setup\Scripts\SetupComplete.cmd') | Should -BeFalse
    }

    It 'completes when there is no bootstrap document at all' {
        # THE FULL-OS LEG AND A HAND-RUN SEQUENCE both reach this with no
        # X:\HDT\bootstrap.json. Neither is an error.
        $run = & $script:newRun ''

        $result = Invoke-HDTInstallCertificateStep -Step $script:step -Context $run.Context

        [string] $result.Status | Should -BeExactly 'Completed'
    }

    It 'fails when it does not know which volume to stage onto' {
        $run = & $script:newRun $script:bootstrapText
        $run.Context.Variable.Remove('HDTOSVolume')

        $result = Invoke-HDTInstallCertificateStep -Step $script:step -Context $run.Context

        [string] $result.Status | Should -BeExactly 'Failed'
        [string] $result.Message | Should -BeLike '*HDTOSVolume*'
    }

    It 'refuses to write over a SetupComplete.cmd somebody else put there' {
        # IT IS ONE FILE AND WINDOWS RUNS ONE. An image with its own
        # SetupComplete.cmd - a shop's own post-Setup script - would lose it
        # silently, and nothing would say so until whatever it did stopped
        # happening.
        $run = & $script:newRun $script:bootstrapText
        $run.FileSystem.WriteAllText('W:\Windows\Setup\Scripts\SetupComplete.cmd', 'rem mine')

        $result = Invoke-HDTInstallCertificateStep -Step $script:step -Context $run.Context

        [string] $result.Status | Should -BeExactly 'Failed'
        [string] $result.Message | Should -BeLike '*SetupComplete.cmd*'
        [string] $run.FileSystem.ReadAllText('W:\Windows\Setup\Scripts\SetupComplete.cmd') |
            Should -BeExactly 'rem mine'
    }

    It 'takes the volume from the step when the step says' {
        $run = & $script:newRun $script:bootstrapText

        $named = & $script:newStep @{ target = 'S:' }

        [void] (Invoke-HDTInstallCertificateStep -Step $named -Context $run.Context)

        $run.FileSystem.TestPath('S:\Windows\Setup\Scripts\SetupComplete.cmd') | Should -BeTrue
    }
}

Describe 'the step contract' {

    It 'offers a template that names the type' {
        $line = Get-HDTInstallCertificateStepTemplate

        ($line -join "`n") | Should -BeLike '*type: InstallCertificate*'
    }

    It 'describes itself in one line' {
        [string] (Get-HDTInstallCertificateStepDescription -Step $script:step) | Should -Not -BeNullOrEmpty
    }

    It 'is offered by the console catalog, under a name an MDT admin would look for' {
        # PIPED, NOT (...).Item. On a collection, .Item is the INDEXER rather
        # than member enumeration, so the dotted form quietly answers nothing.
        $row = @(Get-HDTConsoleStepCatalog | ForEach-Object { $_.Item } |
                Where-Object { $_.Type -eq 'InstallCertificate' })

        @($row).Count | Should -Be 1
        [string] $row[0].Text | Should -BeExactly 'Install Certificates'
    }
}


}
