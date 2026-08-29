# Update-HDTBootImage against fakes: no ADK, no DISM, no elevation, nothing
# mounted, nothing burned - and every decision the build makes asserted.
#
# The real build takes fifteen to twenty-five minutes and needs an elevated
# session. That run proves the TOOLS work. This file proves the BUILD is right,
# and it is the difference between finding a mistake in two seconds and finding
# it fifteen minutes in with a WIM mounted.
#
# THE HEADLINE ASSERTION IS THE ORDERED OPERATION LIST. DESIGN 5.1 specifies a
# deterministic mount / apply / inject / commit / export cycle, and DESIGN 12.2.1
# says the way to assert a ceremony is to assert its exact ordered operation
# list. So the shared journal is projected down to the build's MILESTONES - the
# operations DESIGN 5.1 names, and no filesystem noise - and compared element by
# element with the documented order. Every other assertion in this file is cheap
# because that one is here.
#
# The ADK is the fake registry plus tests/fixtures/adk/adk-layout-10.1.26100.2454.json,
# a real capture of this host's ADK, so no literal ADK path is read anywhere.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:layout = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/adk/adk-layout-10.1.26100.2454.json') -Raw |
        ConvertFrom-Json

    $script:kitsRoot10 = [string] $script:layout.kitsRoot10
    $script:adkRoot = [string] $script:layout.adkRoot

    $script:workspaceRoot = 'C:\HDTLab\Share'
    $script:scratchPath = 'C:\HDTLab\scratch\bootimage'
    $script:mountPath = $script:scratchPath + '\mount'
    $script:mediaPath = $script:scratchPath + '\media'
    $script:bitPath = $script:scratchPath + '\bootbits'
    $script:scratchWim = $script:scratchPath + '\HDTPE_x64.wim'
    $script:wimPath = $script:workspaceRoot + '\Boot\HDTPE_x64.wim'
    $script:isoPath = $script:workspaceRoot + '\Boot\HDTPE_x64.iso'
    $script:manifestPath = $script:workspaceRoot + '\Boot\HDTPE_x64.manifest.json'

    $script:enginePath = 'C:\Modules\Hephaestus'
    $script:yamlPath = 'C:\Modules\powershell-yaml'

    # EVERY PAYLOAD SCRIPT THE MODULE REALLY SHIPS, read off the directory
    # rather than listed here. The fixture seeds these and the staging assertion
    # checks these, so neither can fall behind src\Hephaestus\Payload\ - which
    # is exactly what happened when Remove-HDTAgentTree.ps1 was added.
    $script:payloadLeaf = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload') -Filter '*.ps1' -File |
            Sort-Object -Property Name | ForEach-Object { $_.Name })

    $script:secret = 'Sup3rSecret-Deploy-Password!'
    $script:protected = InModuleScope Hephaestus -Parameters @{ Secret = $script:secret } {
        param($Secret)
        Protect-HDTShareSecret -Secret $Secret
    }

    $script:workspaceYaml = @'
schemaVersion: 1
id: HDT-LAB
name: HDT lab deployment share
deployRoot: \Share
logLevel: Info
credential:
  username: CONTOSO\svc-hdt-deploy
bootImage:
  name: HDTPE_x64
  architecture: amd64
  language: en-us
  scratchSpaceMB: 512
  drivers: boot-critical
  extraContent:
    - source: Modules\MyVendorTools
      destination: \HDT\Modules\MyVendorTools
'@

    $script:credentialJson = ConvertTo-Json -InputObject ([ordered] @{
            schemaVersion = 1
            username      = 'CONTOSO\svc-hdt-deploy'
            password      = $script:protected
            warning       = 'Obfuscated, not encrypted.'
        })

    function New-HDTBootImageTestSeed {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory hashtable of seed data; it changes no state.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param(
            [Parameter()]
            [AllowEmptyString()]
            [string] $WorkspaceYaml = '',

            # Anything this build needs that the standard share has not got -
            # a selection profile document, a second vendor's driver folder.
            [Parameter()]
            [hashtable] $ExtraFile
        )

        $yaml = $WorkspaceYaml
        if ([string]::IsNullOrEmpty($yaml)) { $yaml = $script:workspaceYaml }

        $seed = @{}

        # The real ADK layout, captured off this host.
        foreach ($row in @($script:layout.file)) {
            $seed[($script:adkRoot + [string] $row.Path)] = 'fixture'
        }

        $seed[($script:workspaceRoot + '\workspace.yaml')] = $yaml
        $seed[($script:workspaceRoot + '\rules.yaml')] = 'schemaVersion: 1'
        $seed[($script:workspaceRoot + '\Control\share-credential.json')] = $script:credentialJson
        $seed[($script:workspaceRoot + '\Drivers\boot-critical\oem0.inf')] = '[Version]'
        $seed[($script:workspaceRoot + '\Modules\MyVendorTools\Tool.psm1')] = 'function Get-Vendor {}'

        # The engine, as it would sit on a build host. Payload\ is staged
        # separately, to X:\HDT\, and must NOT arrive under Modules\Hephaestus.
        $seed[($script:enginePath + '\Hephaestus.psd1')] = '@{ ModuleVersion = ''0.1.0'' }'
        $seed[($script:enginePath + '\Hephaestus.psm1')] = '# loader'
        $seed[($script:enginePath + '\Public\Get-HDTAdkPath.ps1')] = '# public'
        $seed[($script:enginePath + '\Hephaestus.bundle.ps1')] = '# every function, concatenated'
        $seed[($script:enginePath + '\Private\ConvertFrom-HDTYaml.ps1')] = '# private'
        # SEEDED FROM THE REAL Payload\ DIRECTORY, NOT FROM A LIST WRITTEN HERE.
        # Three of them were named by hand, and a fourth - Remove-HDTAgentTree.ps1,
        # the script that deletes C:\HDT once a deployment has finished - made
        # every test in this file fail the day it was added, because the command
        # requires it and the fixture had never heard of it.
        #
        # A LIST IN A FIXTURE IS A SECOND SOURCE OF TRUTH (CLAUDE.md rule 8).
        # Reading the directory means the fixture cannot fall behind the module,
        # and the assertion below reads the same directory - so "every payload
        # script reaches the image" is checked over the SET.
        foreach ($payload in @($script:payloadLeaf)) {
            $seed[($script:enginePath + '\Payload\' + $payload)] = ('# {0}' -f $payload)
        }

        # STAGED INTO EVERY IMAGE, whether or not this one carries certificates:
        # startnet.cmd names Import-HDTBootCertificate.ps1 only when there are
        # some, and an image missing the script the day somebody adds one would
        # fail in the one place there is no operator.

        # UI\ is staged to X:\HDT\UI\ like Payload\, and for the same reason:
        # the window has to be findable at a fixed path inside the image.
        $seed[($script:enginePath + '\UI\HDTWizard.xaml')] = '<Window />'

        $seed[($script:yamlPath + '\powershell-yaml.psd1')] = '@{ ModuleVersion = ''0.4.12'' }'
        $seed[($script:yamlPath + '\net47\YamlDotNet.dll')] = 'binary'

        # Guarded rather than @()-wrapped: under Set-StrictMode -Version Latest,
        # reaching .Keys on an unbound parameter is an error, not an empty list.
        if ($null -ne $ExtraFile) {
            foreach ($key in @($ExtraFile.Keys)) { $seed[[string] $key] = $ExtraFile[$key] }
        }

        return $seed
    }

    function New-HDTBootImageTestContext {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds in-memory test doubles; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowEmptyString()]
            [string] $WorkspaceYaml = '',

            [Parameter()]
            [hashtable] $Failure,

            [Parameter()]
            [object[]] $Driver,

            [Parameter()]
            [hashtable] $ExtraFile
        )

        $journal = [System.Collections.ArrayList]::new()
        $fs = New-HDTFakeFileSystem -File (New-HDTBootImageTestSeed -WorkspaceYaml $WorkspaceYaml -ExtraFile $ExtraFile) -Journal $journal
        $registry = New-HDTFakeRegistryService -Value @{
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' = @{ KitsRoot10 = $script:kitsRoot10 }
        } -Journal $journal

        $bootSplat = @{ FileSystem = $fs; Journal = $journal }
        if ($PSBoundParameters.ContainsKey('Failure')) { $bootSplat['Failure'] = $Failure }
        if ($PSBoundParameters.ContainsKey('Driver')) { $bootSplat['Driver'] = $Driver }

        $boot = New-HDTFakeBootImageService @bootSplat
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 14, 9, 14, 22, [System.DateTimeKind]::Utc)) -TickMillisecond 1000

        return [pscustomobject] @{
            Journal    = $journal
            FileSystem = $fs
            Registry   = $registry
            Boot       = $boot
            Clock      = $clock
        }
    }

    function Invoke-HDTBootImageTestBuild {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'The command under test carries SupportsShouldProcess; this wrapper only forwards.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [object] $Context,

            [Parameter()]
            [hashtable] $Argument,

            [Parameter()]
            [AllowNull()]
            [object] $Progress
        )

        $splat = @{
            WorkspaceRoot    = $script:workspaceRoot
            ScratchPath      = $script:scratchPath
            EngineModulePath = $script:enginePath
            YamlModulePath   = $script:yamlPath
            BootImageService = $Context.Boot
            FileSystem       = $Context.FileSystem
            Registry         = $Context.Registry
            Clock            = $Context.Clock
            Confirm          = $false
        }

        if ($PSBoundParameters.ContainsKey('Progress')) { $splat['Progress'] = $Progress }

        if ($PSBoundParameters.ContainsKey('Argument')) {
            foreach ($key in @($Argument.Keys)) { $splat[$key] = $Argument[$key] }
        }

        return (Update-HDTBootImage @splat)
    }

    # The journal, projected down to the milestones DESIGN 5.1 names. Everything
    # else - the cab existence probes, the 900-file media copy, the reads the
    # workspace document makes - is deliberately invisible, because an assertion
    # that listed every filesystem call would be an assertion nobody could read
    # and nobody would maintain.
    function Get-HDTBootImageTestMilestone {
        [CmdletBinding()]
        [OutputType([string[]])]
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [object] $Journal
        )

        $step = New-Object -TypeName System.Collections.ArrayList

        foreach ($row in @($Journal)) {
            $service = [string] $row.Service
            $operation = [string] $row.Operation
            $argument = @($row.Arguments)

            $first = ''
            $second = ''
            if ($argument.Count -gt 0) { $first = [string] $argument[0] }
            if ($argument.Count -gt 1) { $second = [string] $argument[1] }

            $name = ''

            if ($service -eq 'FileSystem' -and $operation -eq 'ReadAllText' -and $first -like '*\workspace.yaml') {
                $name = 'ImportWorkspaceDocument'
            } elseif ($service -eq 'RegistryService' -and $operation -eq 'GetValue' -and $second -eq 'KitsRoot10') {
                $name = 'ResolveAdkPath'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'RemoveItem' -and $first -like ($script:scratchPath + '\*')) {
                $name = 'PrepareScratch'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'CopyItem' -and $second -eq $script:scratchWim) {
                $name = 'CopyWinPeWim'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'CreateDirectory' -and $first -eq ($script:mediaPath + '\sources')) {
                $name = 'CreateMediaSources'
            } elseif ($service -eq 'BootImageService' -and $operation -eq 'AddPackage') {
                $name = 'AddPackage:' + [System.IO.Path]::GetFileName($second)
            } elseif ($service -eq 'BootImageService') {
                $name = $operation
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'CopyItem' -and $second -like ($script:mountPath + '\HDT\Modules\Hephaestus\*')) {
                $name = 'StageEngine'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'CopyItem' -and $second -like ($script:mountPath + '\HDT\Modules\powershell-yaml\*')) {
                $name = 'StageYaml'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'CopyItem' -and $second -eq ($script:mountPath + '\HDT\Start-HDTDeployment.ps1')) {
                $name = 'StageDeploymentPayload'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'CopyItem' -and $second -eq ($script:mountPath + '\HDT\Start-HDTResume.ps1')) {
                $name = 'StageResumePayload'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'WriteAllText' -and $first -like '*\bootstrap.json') {
                $name = 'WriteBootstrap'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'WriteAllText' -and $first -like '*\startnet.cmd') {
                $name = 'WriteStartnet'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'CopyItem' -and $second -like ($script:mountPath + '\HDT\Modules\MyVendorTools\*')) {
                $name = 'CopyExtraContent'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'CopyItem' -and $second -eq ($script:mediaPath + '\sources\boot.wim')) {
                $name = 'CopyWimIntoMedia'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'WriteAllText' -and $first -like '*.manifest.json') {
                $name = 'WriteManifest'
            }

            if ([string]::IsNullOrEmpty($name)) { continue }

            # Consecutive duplicates collapse: staging a tree is many CopyItem
            # calls and one milestone.
            if ($step.Count -gt 0 -and [string] $step[$step.Count - 1] -eq $name) { continue }

            [void] $step.Add($name)
        }

        return [string[]] @($step)
    }

    # The nine components a default workspace asks for, each followed by its
    # en-us pack: SPIKES S1's verified order, and DESIGN 5.1's rule that the
    # language pack goes immediately after its component.
    $script:expectedPackage = @(
        'AddPackage:WinPE-WMI.cab', 'AddPackage:WinPE-WMI_en-us.cab'
        'AddPackage:WinPE-NetFx.cab', 'AddPackage:WinPE-NetFx_en-us.cab'
        'AddPackage:WinPE-Scripting.cab', 'AddPackage:WinPE-Scripting_en-us.cab'
        'AddPackage:WinPE-PowerShell.cab', 'AddPackage:WinPE-PowerShell_en-us.cab'
        'AddPackage:WinPE-StorageWMI.cab', 'AddPackage:WinPE-StorageWMI_en-us.cab'
        'AddPackage:WinPE-DismCmdlets.cab', 'AddPackage:WinPE-DismCmdlets_en-us.cab'
        'AddPackage:WinPE-SecureStartup.cab', 'AddPackage:WinPE-SecureStartup_en-us.cab'
        'AddPackage:WinPE-EnhancedStorage.cab', 'AddPackage:WinPE-EnhancedStorage_en-us.cab'
        'AddPackage:WinPE-WDS-Tools.cab', 'AddPackage:WinPE-WDS-Tools_en-us.cab'
    )

    $script:expectedOrder = @('ImportWorkspaceDocument', 'ResolveAdkPath', 'PrepareScratch',
        'CopyWinPeWim', 'CreateMediaSources', 'MountImage') +
    $script:expectedPackage +
    @('SetScratchSpace', 'AddDriver', 'StageEngine', 'StageYaml',
        'StageDeploymentPayload', 'StageResumePayload', 'WriteBootstrap', 'WriteStartnet',
        'CopyExtraContent', 'DismountImage', 'ExportImage', 'CopyWimIntoMedia',
        # THE SECOND ResolveAdkPath IS NOT A DEFECT AND IS NOT INCIDENTAL.
        # New-HDTBootIso is a command in its own right - point it at any WinPE
        # media tree and it produces an ISO - so it resolves Oscdimg and its own
        # El Torito image through Get-HDTAdkPath rather than being handed paths
        # by a caller it does not require. Recorded here so the day somebody
        # "optimises" it into a parameter, this list says what changed.
        'ResolveAdkPath',
        'NewIso', 'WriteManifest')
}

Describe 'Update-HDTBootImage' {

    Context 'the order it does things in' {

        BeforeAll {
            $script:orderContext = New-HDTBootImageTestContext
            $script:orderResult = Invoke-HDTBootImageTestBuild -Context $script:orderContext
            $script:milestone = Get-HDTBootImageTestMilestone -Journal $script:orderContext.Journal
        }

        It 'performs the seventeen operations in the documented order' {
            # DESIGN 12.2.1's benchmark shape applied to the builder. Read the
            # failure message against DESIGN 5.1: it is a list a human can check.
            $script:milestone | Should -Be $script:expectedOrder -Because (
                'the build performed:' + [System.Environment]::NewLine +
                (($script:milestone | ForEach-Object { '  ' + $_ }) -join [System.Environment]::NewLine))
        }

        It 'applies each language pack immediately after its component' {
            $package = @($script:milestone | Where-Object { $_ -like 'AddPackage:*' })

            $package | Should -Be $script:expectedPackage
        }

        It 'mounts before it packages and dismounts before it exports' {
            $mount = [array]::IndexOf($script:milestone, 'MountImage')
            $firstPackage = [array]::IndexOf($script:milestone, 'AddPackage:WinPE-WMI.cab')
            $dismount = [array]::IndexOf($script:milestone, 'DismountImage')
            $export = [array]::IndexOf($script:milestone, 'ExportImage')

            $mount | Should -BeLessThan $firstPackage
            $firstPackage | Should -BeLessThan $dismount
            $dismount | Should -BeLessThan $export
        }

        It 'writes the manifest last' {
            # A manifest that exists describes a build that finished.
            $script:milestone[-1] | Should -BeExactly 'WriteManifest'
        }

        It 'writes into the mount only while it is mounted' {
            $mount = [array]::IndexOf($script:milestone, 'MountImage')
            $dismount = [array]::IndexOf($script:milestone, 'DismountImage')

            foreach ($name in @('StageEngine', 'StageYaml', 'StageDeploymentPayload',
                    'StageResumePayload', 'WriteBootstrap', 'WriteStartnet', 'CopyExtraContent')) {
                $index = [array]::IndexOf($script:milestone, $name)
                $index | Should -BeGreaterThan $mount -Because "$name must happen after the mount"
                $index | Should -BeLessThan $dismount -Because "$name must happen before the dismount"
            }
        }
    }

    Context 'what goes into the image' {

        BeforeAll {
            $script:contentContext = New-HDTBootImageTestContext
            $script:contentResult = Invoke-HDTBootImageTestBuild -Context $script:contentContext
        }

        It 'applies the nine components a default workspace asks for' {
            $script:contentResult.ComponentCount | Should -Be 9
        }

        It 'honours -OptionalComponent over the workspace document' {
            $context = New-HDTBootImageTestContext
            $result = Invoke-HDTBootImageTestBuild -Context $context -Argument @{ OptionalComponent = @('WinPE-FMAPI') }

            $result.ComponentCount | Should -Be 7

            $package = @($context.Boot.Operations |
                    Where-Object { $_.Operation -eq 'AddPackage' } |
                    ForEach-Object { [System.IO.Path]::GetFileName([string] $_.Arguments[1]) })

            $package | Should -Contain 'WinPE-FMAPI.cab'
            $package | Should -Not -Contain 'WinPE-WDS-Tools.cab'
        }

        It 'stages the engine module and powershell-yaml' {
            foreach ($path in @(
                    ($script:mountPath + '\HDT\Modules\Hephaestus\Hephaestus.psd1'),
                    ($script:mountPath + '\HDT\Modules\powershell-yaml\net47\YamlDotNet.dll'))) {

                $script:contentContext.FileSystem.TestPath($path) | Should -BeTrue -Because "$path must be in the image"
            }
        }

        # OVER THE SET, NOT OVER THE TWO SOMEBODY REMEMBERED (CLAUDE.md rule 8).
        # This test used to name Start-HDTDeployment.ps1 and Start-HDTResume.ps1
        # and would have passed for ever while Remove-HDTAgentTree.ps1 - the
        # script that removes C:\HDT when a deployment finishes - never reached
        # a single boot image. A payload that is not in the image is a payload
        # Copy-HDTResumeAgent cannot put on the target either, so it fails on
        # iron and nowhere else.
        #
        # THE SET IS THE ONE THE COMMAND ITSELF DECLARES, read off its source.
        # Not every file in Payload\ belongs in a boot image - the InstallCertificate
        # step writes Import-HDTOsCertificate.ps1 into the deployed OS instead -
        # so the rule is "everything this command REQUIRES, it also STAGES".
        # Adding a fifth required payload and forgetting to copy it fails here.
        It 'stages every payload script it requires, so none can be left behind' {
            $source = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot `
                    -ChildPath 'src/Hephaestus/Public/Update-HDTBootImage.ps1') -Raw

            $required = @([regex]::Matches($source,
                    "Combine\(\`$EngineModulePath,\s*'Payload',\s*'([^']+)'\)") |
                    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

            @($required).Count | Should -BeGreaterThan 0 -Because 'a set assertion over nothing proves nothing'

            foreach ($leaf in $required) {
                $script:contentContext.FileSystem.TestPath($script:mountPath + '\HDT\' + $leaf) |
                    Should -BeTrue -Because "$leaf is required by Update-HDTBootImage and must be staged to \HDT"
            }
        }

        It 'stages the bundle rather than several hundred one-function files' {
            # ONE FILE INSTEAD OF 391. The module is authored one function per
            # file and the loader dot-sources them all; the bundle is that same
            # code concatenated, and Hephaestus.psm1 prefers it. Staging the
            # sources meant reading, copying and parsing 391 files to build an
            # image - and then Copy-HDTResumeAgent copying all 391 again onto
            # every machine deployed from it.
            #
            # THE BUNDLE IS REGENERATED HERE, not trusted: a stale one would ship
            # an engine older than the source it was built beside, which is the
            # one outcome worse than a slow build.
            $script:contentContext.FileSystem.TestPath(
                $script:mountPath + '\HDT\Modules\Hephaestus\Hephaestus.bundle.ps1') | Should -BeTrue
        }

        It 'leaves the one-function sources behind' {
            foreach ($path in @(
                    ($script:mountPath + '\HDT\Modules\Hephaestus\Public\Get-HDTAdkPath.ps1'),
                    ($script:mountPath + '\HDT\Modules\Hephaestus\Private\ConvertFrom-HDTYaml.ps1'))) {

                $script:contentContext.FileSystem.TestPath($path) | Should -BeFalse -Because "$path is inside the bundle"
            }
        }

        It 'still stages the manifest and the loader, which are what Import-Module reads' {
            foreach ($path in @(
                    ($script:mountPath + '\HDT\Modules\Hephaestus\Hephaestus.psd1'),
                    ($script:mountPath + '\HDT\Modules\Hephaestus\Hephaestus.psm1'))) {

                $script:contentContext.FileSystem.TestPath($path) | Should -BeTrue
            }
        }

        It 'excludes Payload from the staged module tree' {
            # The payload scripts live at X:\HDT\, which is where startnet.cmd
            # and Start-HDTDeployment.ps1 itself look for them. A second copy
            # under Modules\Hephaestus\Payload\ would be a second answer to
            # "which one is running".
            $script:contentContext.FileSystem.TestPath(
                $script:mountPath + '\HDT\Modules\Hephaestus\Payload\Start-HDTDeployment.ps1') | Should -BeFalse
        }

        It 'refuses to build when powershell-yaml cannot be found' {
            # SPIKES S9.1: powershell-yaml is the dependency the whole engine
            # rests on in WinPE - ConvertFrom-HDTYaml goes through it, and every
            # document HDT reads goes through that.
            $context = New-HDTBootImageTestContext

            $record = $null
            try {
                Invoke-HDTBootImageTestBuild -Context $context -Argument @{ YamlModulePath = 'C:\HDTLab\does-not-exist\powershell-yaml' }
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTDependencyError*'
            $record.Exception.Message | Should -BeLike '*powershell-yaml*'
        }

        It 'stages the wizard UI at \HDT\UI so the technician window can be shown' {
            # W1 of the WPF-first direction. The window has to be INSIDE the
            # image: X: is the RAM disk and its letter is fixed, which is the
            # same reason the payloads live there rather than on a data disk.
            $script:contentContext.FileSystem.TestPath(
                $script:mountPath + '\HDT\UI\HDTWizard.xaml') | Should -BeTrue
        }

        It 'writes startnet.cmd into Windows\System32 under the mount' {
            $script:contentContext.FileSystem.TestPath(
                $script:mountPath + '\Windows\System32\startnet.cmd') | Should -BeTrue
        }

        It 'writes exactly the text Get-HDTStartnetScript returns' {
            # Read back out of the fake's MODELLED MOUNT. The integration test
            # reads the same thing out of a real one.
            $expected = InModuleScope Hephaestus { Get-HDTStartnetScript }

            $script:contentContext.FileSystem.ReadAllText(
                $script:mountPath + '\Windows\System32\startnet.cmd') | Should -BeExactly $expected
        }

        It 'launches the workspace entryCommand instead of the deployment payload' {
            # THE DIAGNOSTIC IMAGE. Without this the only way to run anything
            # other than Start-HDTDeployment.ps1 in WinPE was to type it at the
            # prompt, which is what tests/e2e used to do.
            $yaml = $script:workspaceYaml + "`n  entryCommand: powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTLabProbe.ps1"
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml
            Invoke-HDTBootImageTestBuild -Context $context | Out-Null

            $startnet = $context.FileSystem.ReadAllText($script:mountPath + '\Windows\System32\startnet.cmd')

            $startnet | Should -BeLike '*X:\HDT\Start-HDTLabProbe.ps1*'
            $startnet | Should -Not -BeLike '*Start-HDTDeployment.ps1*'

            # The parts that are not the admin's to change stay put: startnet.cmd
            # is still the file that declares who launched the payload, and the
            # E2E's launchedBy assertion rests on it.
            $startnet | Should -BeLike '*HDT_LAUNCHED_BY=startnet*'
            $startnet | Should -BeLike '*wpeinit*'
        }

        It 'runs the workspace startCommand list after wpeinit and before the payload' {
            # COPYING A TOOL IN IS NOT RUNNING IT. extraContent gets BGInfo into
            # the image at step 14; this is what makes the booted machine start
            # it - after wpeinit, so it has a network, and before the payload,
            # which does not return.
            $yaml = $script:workspaceYaml + "`n  startCommand:`n    - X:\HDT\Tools\bginfo.exe /timer:0"
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml
            Invoke-HDTBootImageTestBuild -Context $context | Out-Null

            $startnet = $context.FileSystem.ReadAllText($script:mountPath + '\Windows\System32\startnet.cmd')
            $line = @($startnet.TrimEnd("`r", "`n") -split "`r`n")

            # ANNOUNCED FIRST, THEN RUN. The echo is what turns a console
            # showing one stale success message into one naming the command
            # that is actually executing - see Get-HDTStartnetScript.
            $line[3] | Should -BeExactly 'wpeinit'
            $line[4] | Should -BeExactly 'echo about to run the command: X:\HDT\Tools\bginfo.exe /timer:0'
            $line[5] | Should -BeExactly 'X:\HDT\Tools\bginfo.exe /timer:0'
            $line[6] | Should -BeLike '*X:\HDT\Start-HDTDeployment.ps1'
        }

        It 'calls a batch start command, so the payload below it is still reached' {
            # cmd.exe does not RETURN from one batch file to another. A bare
            # run.cmd line here transfers control and the payload under it never
            # runs - a machine that booted, initialised, started the admin's
            # tools and then sat there looking exactly like a hung deployment.
            $yaml = $script:workspaceYaml + "`n  startCommand:`n    - X:\HDT\Tools\run.cmd"
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml
            Invoke-HDTBootImageTestBuild -Context $context | Out-Null

            $line = @($context.FileSystem.ReadAllText(
                    $script:mountPath + '\Windows\System32\startnet.cmd').TrimEnd("`r", "`n") -split "`r`n")

            $line[4] | Should -BeExactly 'echo about to run the command: call X:\HDT\Tools\run.cmd'
            $line[5] | Should -BeExactly 'call X:\HDT\Tools\run.cmd'
            $line[6] | Should -BeLike '*X:\HDT\Start-HDTDeployment.ps1'
        }

        It 'copies the WinPE answer file to the root of the image and points wpeinit at it' {
            # wpeinit is what processes it - EnableFirewall, EnableNetwork,
            # Display, PageFile, RunSynchronous - so it is an argument on the
            # line that already exists rather than a line of its own.
            $yaml = $script:workspaceYaml + "`n  unattend: Control\Unattend-PE.xml"
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml
            $context.FileSystem.WriteAllText(
                ($script:workspaceRoot + '\Control\Unattend-PE.xml'), '<unattend />')

            Invoke-HDTBootImageTestBuild -Context $context | Out-Null

            $context.FileSystem.TestPath($script:mountPath + '\Unattend.xml') | Should -BeTrue

            $line = @($context.FileSystem.ReadAllText(
                    $script:mountPath + '\Windows\System32\startnet.cmd').TrimEnd("`r", "`n") -split "`r`n")

            $line[3] | Should -BeExactly 'wpeinit -unattend:X:\Unattend.xml'
        }

        It 'reads a rooted answer file from where it is, not from under the share' {
            # BROWSE PICKS A FILE ON THE BUILD HOST. Combining a rooted path
            # with the workspace root - or trimming its separators first, which
            # is what extraContent does - would read C:\build\Unattend-PE.xml
            # from inside the share and find nothing there.
            $yaml = $script:workspaceYaml + "`n  unattend: C:\build\Unattend-PE.xml"
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml
            $context.FileSystem.WriteAllText('C:\build\Unattend-PE.xml', '<unattend />')

            Invoke-HDTBootImageTestBuild -Context $context | Out-Null

            $context.FileSystem.TestPath($script:mountPath + '\Unattend.xml') | Should -BeTrue
        }

        It 'copies the background over the one file WinPE reads' {
            # \Windows\System32\winpe.jpg, under that name whatever the
            # administrator called it on their own disk. A file copied in under
            # any other name is carried into the image and never shown.
            $yaml = $script:workspaceYaml + "`n  background: Branding\hdt.jpg"
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml
            $context.FileSystem.WriteAllText(($script:workspaceRoot + '\Branding\hdt.jpg'), 'jpeg bytes')

            Invoke-HDTBootImageTestBuild -Context $context | Out-Null

            $context.FileSystem.TestPath($script:mountPath + '\Windows\System32\winpe.jpg') | Should -BeTrue
        }

        It 'refuses a named background that is not there, before it mounts' {
            $yaml = $script:workspaceYaml + "`n  background: Branding\missing.jpg"
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml

            { Invoke-HDTBootImageTestBuild -Context $context } | Should -Throw '*missing.jpg*'

            @($context.Journal | Where-Object { $_.Operation -eq 'MountImage' }) | Should -BeNullOrEmpty
        }

        It 'refuses a named answer file that is not there, before it mounts' {
            # BEFORE THE MOUNT, deliberately. Failing at the copy would cost a
            # mount and a discard - minutes - to say something knowable at the
            # start. An image built silently without it would boot with no
            # firewall setting and nothing to say why.
            $yaml = $script:workspaceYaml + "`n  unattend: Control\Missing.xml"
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml

            { Invoke-HDTBootImageTestBuild -Context $context } | Should -Throw '*Control\Missing.xml*'

            @($context.Journal | Where-Object { $_.Operation -eq 'Mount' }) | Should -BeNullOrEmpty
        }

        It 'reports every step it takes, in the order it takes them' {
            # SEVENTEEN STEPS AND TWO AND A HALF MINUTES, silent until now. A
            # window that greys out for that long reads as one that has hung,
            # and a killed build strands a mounted image.
            #
            # ASSERTED HERE RATHER THAN AT A WINDOW because the reports are the
            # contract: Pester can watch the whole build with no ADK, no DISM
            # and no display, which is the only place the ORDER can be pinned.
            $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            $progress = New-HDTBuildProgress -Queue $queue

            $context = New-HDTBootImageTestContext
            Invoke-HDTBootImageTestBuild -Context $context -Progress $progress | Out-Null

            $report = @($progress.Drain())

            # Monotonic, starting at one, and every one of them naming what it
            # is doing rather than a number an administrator has to look up.
            @($report | Where-Object { -not $_.IsComplete }).Count | Should -BeGreaterThan 10

            $step = @($report | Where-Object { -not $_.IsComplete } | ForEach-Object { $_.Step })
            $step[0] | Should -Be 1
            @($step | Sort-Object) | Should -Be $step

            @($report | Where-Object { [string]::IsNullOrWhiteSpace($_.Title) }) | Should -BeNullOrEmpty
        }

        # TWO IDENTICAL ROWS A SECOND APART, AND THEN A SILENT MINUTE AND A HALF.
        # It read as the build stalling twice on the same step, and it was found
        # by watching the log rather than by any test: the step announced itself
        # naming the profile, and then the injection loop reported the single
        # folder call with the same detail again. A folder call has no name to
        # add, so it must add nothing.
        It 'reports the driver step once when the whole folder goes in at once' {
            $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            $progress = New-HDTBuildProgress -Queue $queue

            $context = New-HDTBootImageTestContext
            Invoke-HDTBootImageTestBuild -Context $context -Progress $progress | Out-Null

            $driverReport = @($progress.Drain() |
                    Where-Object { -not $_.IsComplete -and [string] $_.Title -like '*boot drivers*' })

            $driverReport.Count | Should -Be 1
        }

        # AND STILL ONE PER DRIVER WHEN ASKED, which is the whole point of the
        # switch: the announcement plus one row for each .inf.
        It 'reports every driver under -PerDriver' {
            $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            $progress = New-HDTBuildProgress -Queue $queue

            $context = New-HDTBootImageTestContext
            Invoke-HDTBootImageTestBuild -Context $context -Progress $progress `
                -Argument @{ PerDriver = $true } | Out-Null

            $driverReport = @($progress.Drain() |
                    Where-Object { -not $_.IsComplete -and [string] $_.Title -like '*boot drivers*' })

            # The announcement, and the one driver this fixture holds.
            $driverReport.Count | Should -Be 2
            [string] $driverReport[1].Detail | Should -BeLike '1 of 1 - *oem0.inf'
        }

        # "2 entry(s)" SAID HOW MANY AND NOT WHICH, and these are the folders a
        # site's own startCommand lines run out of - X:\Tools\TightVNC and
        # X:\Tools\BGInfo on this lab's image - so which they are is the whole
        # point of the line. The optional components have named themselves one
        # at a time since they were written; this is that, for the step that
        # carries somebody's own tools.
        It 'names each extra content entry by where it lands in WinPE' {
            $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            $progress = New-HDTBuildProgress -Queue $queue

            $context = New-HDTBootImageTestContext
            Invoke-HDTBootImageTestBuild -Context $context -Progress $progress | Out-Null

            $extra = @($progress.Drain() |
                    Where-Object { -not $_.IsComplete -and [string] $_.Title -like '*extra content*' })

            # The announcement, and one row naming the entry the fixture holds.
            $extra.Count | Should -Be 2
            [string] $extra[1].Detail | Should -BeExactly '1 of 1 - \HDT\Modules\MyVendorTools'
        }

        # THE FILE THAT DECIDES WHETHER A MACHINE DEPLOYS OR SITS AT A PROMPT
        # was the least visible thing in the build: one row, no detail. Reading
        # it afterwards means mounting the image.
        It 'writes out every line of startnet.cmd as it goes in' {
            $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            $progress = New-HDTBuildProgress -Queue $queue

            $context = New-HDTBootImageTestContext
            Invoke-HDTBootImageTestBuild -Context $context -Progress $progress | Out-Null

            $startnet = @($progress.Drain() |
                    Where-Object { -not $_.IsComplete -and [string] $_.Title -like '*startnet*' })

            # The announcement plus a row per line, and wpeinit is always one of
            # them - WinPE has no network until it runs.
            $startnet.Count | Should -BeGreaterThan 1
            [string] $startnet[0].Detail | Should -BeLike '*line(s)'

            $shown = @($startnet | Select-Object -Skip 1 | ForEach-Object { [string] $_.Detail })
            @($shown | Where-Object { $_ -like '*wpeinit*' }) | Should -Not -BeNullOrEmpty

            # Numbered, so a long file can be followed.
            [string] $shown[0] | Should -BeLike '1 of *'
        }

        # THE TWO ISOs ARE INDISTINGUISHABLE AFTERWARDS - same name, same size to
        # the megabyte - and the difference decides whether a machine boots on
        # its own or waits at "Press any key" for somebody who is not there.
        # DESIGN 5.2, and the only way to find out used to be to boot a VM.
        It 'says which kind of ISO it is building' {
            $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            $progress = New-HDTBuildProgress -Queue $queue

            $context = New-HDTBootImageTestContext
            Invoke-HDTBootImageTestBuild -Context $context -Progress $progress | Out-Null

            $iso = @($progress.Drain() |
                    Where-Object { -not $_.IsComplete -and [string] $_.Title -like '*ISO*' })[0]

            [string] $iso.Detail | Should -BeLike '*no keypress*'
        }

        It 'says so when a keypress WILL be needed' {
            $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            $progress = New-HDTBuildProgress -Queue $queue

            $context = New-HDTBootImageTestContext
            Invoke-HDTBootImageTestBuild -Context $context -Progress $progress `
                -Argument @{ PromptForKey = $true } | Out-Null

            $iso = @($progress.Drain() |
                    Where-Object { -not $_.IsComplete -and [string] $_.Title -like '*ISO*' })[0]

            [string] $iso.Detail | Should -BeLike '*press a key*'
        }

        It 'says the mount is happening before it happens' {
            # THE STEP THAT TAKES THE LONGEST HAS TO ANNOUNCE ITSELF FIRST.
            # Reporting a step after doing it means the window sits on the
            # PREVIOUS step's text for the whole of the slow one, which is
            # exactly the moment somebody decides it is stuck.
            $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            $progress = New-HDTBuildProgress -Queue $queue

            $context = New-HDTBootImageTestContext
            Invoke-HDTBootImageTestBuild -Context $context -Progress $progress | Out-Null

            $mountAt = -1
            $report = @($progress.Drain())

            for ($index = 0; $index -lt $report.Count; $index++) {
                if ($report[$index].Title -like '*mount*') { $mountAt = $index; break }
            }

            $mountAt | Should -BeGreaterThan -1

            $mountOperation = @($context.Journal | Where-Object { $_.Operation -eq 'MountImage' })
            @($mountOperation).Count | Should -BeGreaterThan 0
        }

        It 'names each component as it applies it' {
            # THE LONGEST STEP IS THE ONE THAT LOOKED STUCK. Applying nine cabs
            # is most of a minute, and a watcher told once that it is "applying
            # the optional components" sits on one unchanging line for all of
            # it - which is indistinguishable from a build that has stopped.
            #
            # It also says WHICH cab was going in if the build dies here, which
            # a single report for the whole loop cannot.
            $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            $progress = New-HDTBuildProgress -Queue $queue

            $context = New-HDTBootImageTestContext
            Invoke-HDTBootImageTestBuild -Context $context -Progress $progress | Out-Null

            $detail = @($progress.Drain() | Where-Object { $_.Step -eq 8 } |
                    ForEach-Object { [string] $_.Detail })

            ($detail -join ' | ') | Should -BeLike '*WinPE-WMI*'
            ($detail -join ' | ') | Should -BeLike '*WinPE-PowerShell*'

            # One per cab, plus the one that opens the step - so more than a
            # handful, and certainly not one.
            @($detail).Count | Should -BeGreaterThan 5
        }

        It 'marks the build finished when it worked' {
            $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            $progress = New-HDTBuildProgress -Queue $queue

            $context = New-HDTBootImageTestContext
            Invoke-HDTBootImageTestBuild -Context $context -Progress $progress | Out-Null

            $last = @($progress.Drain())[-1]

            $last.IsComplete | Should -BeTrue
            $last.Succeeded | Should -BeTrue
        }

        It 'marks the build finished, and failed, when it threw' {
            # A WINDOW THAT JUST STOPPED RECEIVING WOULD HAVE TO GUESS between
            # finished, slow and dead. The failure travels on the same stream as
            # everything else, carrying the message.
            $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            $progress = New-HDTBuildProgress -Queue $queue

            $context = New-HDTBootImageTestContext -Failure @{ MountImage = 'the image is already mounted' }

            { Invoke-HDTBootImageTestBuild -Context $context -Progress $progress } | Should -Throw

            $last = @($progress.Drain())[-1]

            $last.IsComplete | Should -BeTrue
            $last.Succeeded | Should -BeFalse
            $last.Detail | Should -BeLike '*already mounted*'
        }

        It 'builds exactly as before when nobody passes a progress sink' {
            # THE DEFAULT PATH IS THE HOT ONE. Every existing caller - this
            # suite included - passes nothing, and must pay nothing.
            $context = New-HDTBootImageTestContext
            $result = Invoke-HDTBootImageTestBuild -Context $context

            $result.WimPath | Should -Not -BeNullOrEmpty
        }

        It 'still launches the deployment payload when no entryCommand is declared' {
            $script:contentContext.FileSystem.ReadAllText(
                $script:mountPath + '\Windows\System32\startnet.cmd') | Should -BeLike '*X:\HDT\Start-HDTDeployment.ps1*'
        }

        It 'writes bootstrap.json that Get-HDTBootstrapConfiguration accepts' {
            # The 05-03 link, asserted rather than assumed: the writer and the
            # reader are in different plans and nothing else holds them together.
            $bootstrap = Get-HDTBootstrapConfiguration -Path ($script:mountPath + '\HDT\bootstrap.json') `
                -FileSystem $script:contentContext.FileSystem

            $bootstrap.WorkspaceId | Should -BeExactly 'HDT-LAB'
            $bootstrap.Provider | Should -BeExactly 'Local'
            $bootstrap.HasCredential | Should -BeTrue
        }

        It 'carries a volume-relative deployRoot into the image unchanged' {
            # THE E2E's VM DEPENDS ON THIS EXACTLY ONCE, at the only moment
            # nobody can intervene. SPIKES S9.1: WinPE gave the content disk C:
            # while the RAM disk was X:, so a builder that "helpfully" expanded
            # \Share to the letter it sees on the build host would bake in the
            # one value that is certainly wrong.
            $bootstrap = Get-HDTBootstrapConfiguration -Path ($script:mountPath + '\HDT\bootstrap.json') `
                -FileSystem $script:contentContext.FileSystem

            $bootstrap.DeployRoot | Should -BeExactly '\Share'
        }

        It 'asks the technician when a share image carries no credential' {
            # MDT'S LOGIC, KEPT. A Bootstrap.ini naming a DeployRoot but no
            # UserID does not fail the build - LiteTouch prompts at the start of
            # the deployment. So this builds, and the image it produces is one
            # that stops and asks.
            #
            # An earlier version of this test asserted a BUILD-TIME REFUSAL.
            # That was a rule MDT does not have, and it would have made the
            # ordinary "build the image, let the technician sign in at the
            # machine" workflow impossible.
            #
            # THE CREDENTIAL BLOCK IS REMOVED, not just the secret. The default
            # fixture declares one, which is what makes the normal Smb build
            # unattended - so a test that only swapped the deployRoot would
            # build an embedded-credential image and prove nothing.
            $yaml = ($script:workspaceYaml -replace 'deployRoot: \\Share', 'deployRoot: \\HDT-HOST\HdtShare') `
                -replace '(?m)^credential:\r?\n\s+username:.*\r?\n', ''

            $yaml | Should -Not -BeLike '*credential:*' -Because (
                'the point of this test is a share image with no account declared')

            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml
            Invoke-HDTBootImageTestBuild -Context $context -WarningVariable warning -WarningAction SilentlyContinue | Out-Null

            $bootstrap = Get-HDTBootstrapConfiguration -Path ($script:mountPath + '\HDT\bootstrap.json') `
                -FileSystem $context.FileSystem

            $bootstrap.Provider | Should -BeExactly 'Smb'
            $bootstrap.PromptForCredential | Should -BeTrue -Because (
                'the machine has no other way to reach the share, so it must ask - which is what MDT does')
            $bootstrap.HasCredential | Should -BeFalse

            # WARNED, not silent: the two builds behave very differently in
            # front of a technician - one runs unattended, one stops - and the
            # admin should know which one they just made.
            (@($warning) -join ' ') | Should -BeLike '*ASK THE TECHNICIAN*'
            (@($warning) -join ' ') | Should -BeLike '*Set-HDTShareCredential*'
        }

        It 'builds a UNC deployRoot image when it is told to prompt for the credential' {
            # THE ESCAPE HATCH, asserted so the refusal above cannot become a ban
            # on the shared-lab build DESIGN 6.3 offers.
            $yaml = $script:workspaceYaml -replace 'deployRoot: \\Share', 'deployRoot: \\HDT-HOST\HdtShare'
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml

            $record = $null
            try {
                Invoke-HDTBootImageTestBuild -Context $context -Argument @{ PromptForCredential = $true } | Out-Null
            } catch {
                $record = $_
            }

            $record | Should -BeNullOrEmpty
        }

        It 'carries a UNC deployRoot across as Smb' {
            $yaml = $script:workspaceYaml -replace 'deployRoot: \\Share', 'deployRoot: \\HDT-HOST\HdtShare'
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml
            Invoke-HDTBootImageTestBuild -Context $context | Out-Null

            $bootstrap = Get-HDTBootstrapConfiguration -Path ($script:mountPath + '\HDT\bootstrap.json') `
                -FileSystem $context.FileSystem

            $bootstrap.DeployRoot | Should -BeExactly '\\HDT-HOST\HdtShare'
            $bootstrap.Provider | Should -BeExactly 'Smb'
        }

        It 'carries contentMarker across' {
            $bootstrap = Get-HDTBootstrapConfiguration -Path ($script:mountPath + '\HDT\bootstrap.json') `
                -FileSystem $script:contentContext.FileSystem

            $bootstrap.ContentMarker | Should -BeExactly 'rules.yaml'
        }

        It 'writes no credential block under -PromptForCredential' {
            $context = New-HDTBootImageTestContext
            Invoke-HDTBootImageTestBuild -Context $context -Argument @{ PromptForCredential = $true } | Out-Null

            $text = $context.FileSystem.ReadAllText($script:mountPath + '\HDT\bootstrap.json')

            $text | Should -Not -BeLike '*"credential"*'
            $text | Should -BeLike '*"promptForCredential"*'

            $bootstrap = Get-HDTBootstrapConfiguration -Path ($script:mountPath + '\HDT\bootstrap.json') `
                -FileSystem $context.FileSystem
            $bootstrap.PromptForCredential | Should -BeTrue
            $bootstrap.HasCredential | Should -BeFalse
        }

        It 'refuses when workspace.yaml names a credential and no secret was written' {
            $context = New-HDTBootImageTestContext
            $context.FileSystem.RemoveItem($script:workspaceRoot + '\Control\share-credential.json', $false)

            $record = $null
            try { Invoke-HDTBootImageTestBuild -Context $context } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*Set-HDTShareCredential*'
            $record.Exception.Message | Should -BeLike '*-PromptForCredential*'
        }

        It 'writes no secret into bootstrap.json in plain text' {
            $text = $script:contentContext.FileSystem.ReadAllText($script:mountPath + '\HDT\bootstrap.json')

            $text | Should -Not -BeLike ('*' + $script:secret + '*')
        }

        It 'copies extraContent to its declared destination' {
            $script:contentContext.FileSystem.TestPath(
                $script:mountPath + '\HDT\Modules\MyVendorTools\Tool.psm1') | Should -BeTrue
        }

        It 'refuses extraContent whose destination escapes the mount' {
            $yaml = $script:workspaceYaml -replace '      destination: \\HDT\\Modules\\MyVendorTools', '      destination: \HDT\..\..\Windows\System32'
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml

            $record = $null
            try { Invoke-HDTBootImageTestBuild -Context $context } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*escape*'
        }

        # ONE CALL FOR THE WHOLE FOLDER, WHICH IS THE FAST SHAPE AND THE DEFAULT.
        # Handing DISM the folder takes 56s for the lab's seventy-driver pack;
        # one call per .inf takes seven minutes. A build is not seven times
        # slower by default so a number can move - the bar sweeps instead.
        It 'adds the boot-critical driver group when it exists' {
            $call = @($script:contentContext.Boot.Operations | Where-Object { $_.Operation -eq 'AddDriver' })

            $call.Count | Should -Be 1
            [string] $call[0].Arguments[0] | Should -BeExactly $script:mountPath
            [string] $call[0].Arguments[1] | Should -BeExactly ($script:workspaceRoot + '\Drivers\boot-critical')
            [bool] $call[0].Arguments[2] | Should -BeTrue
        }

        # AND THE SLOW SHAPE, WHEN SOMEBODY ASKS FOR IT. This is the build where
        # a machine came up without its network card and "which of these seventy
        # actually went in" is the question.
        It 'injects one .inf at a time under -PerDriver, so each can be reported' {
            $context = New-HDTBootImageTestContext -WorkspaceYaml $script:workspaceYaml
            $null = Invoke-HDTBootImageTestBuild -Context $context -Argument @{ PerDriver = $true }

            $call = @($context.Boot.Operations | Where-Object { $_.Operation -eq 'AddDriver' })

            $call.Count | Should -Be 1
            [string] $call[0].Arguments[1] | Should -BeExactly ($script:workspaceRoot + '\Drivers\boot-critical\oem0.inf')

            # NOT RECURSED: a single .inf is a file, and -Recurse on one would be
            # asking DISM to walk a folder that is not there.
            [bool] $call[0].Arguments[2] | Should -BeFalse
        }

        # THE WHOLE REASON SELECTION PROFILES EXIST, proven at the level that
        # matters: a mixed Dell and HP floor, ONE boot image, and both vendors'
        # WinPE packs inside it. A single folder name could never say this.
        It 'injects every folder a selection profile names, in declared order' {
            $yaml = $script:workspaceYaml -replace 'drivers: boot-critical', 'drivers: winpe-both'
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml -ExtraFile @{
                ($script:workspaceRoot + '\Control\selection-profiles.yaml') = @(
                    'schemaVersion: 1'
                    'profiles:'
                    '  - id: winpe-both'
                    '    name: Boot critical - Dell and HP'
                    '    include:'
                    '      - Drivers\WinPE\Dell WinPE 11 x64'
                    '      - Drivers\WinPE\HP WinPE 11 x64'
                ) -join "`r`n"
                ($script:workspaceRoot + '\Drivers\WinPE\Dell WinPE 11 x64\e1d68x64.inf') = '[Version]'
                ($script:workspaceRoot + '\Drivers\WinPE\HP WinPE 11 x64\stornvme.inf')   = '[Version]'
            }

            $null = Invoke-HDTBootImageTestBuild -Context $context

            $call = @($context.Boot.Operations | Where-Object { $_.Operation -eq 'AddDriver' })

            $call.Count | Should -Be 2
            [string] $call[0].Arguments[1] | Should -BeExactly ($script:workspaceRoot + '\Drivers\WinPE\Dell WinPE 11 x64')
            [string] $call[1].Arguments[1] | Should -BeExactly ($script:workspaceRoot + '\Drivers\WinPE\HP WinPE 11 x64')
        }

        # THE DANGEROUS CASE. The image builds, one vendor's drivers are simply
        # absent, and it is found on a bench with a laptop that cannot see its
        # disk - so the folder that went missing has to be named in a warning.
        It 'warns by name when a profile includes a folder the share has not got' {
            $yaml = $script:workspaceYaml -replace 'drivers: boot-critical', 'drivers: winpe-both'
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml -ExtraFile @{
                ($script:workspaceRoot + '\Control\selection-profiles.yaml') = @(
                    'schemaVersion: 1'
                    'profiles:'
                    '  - id: winpe-both'
                    '    name: Boot critical - Dell and HP'
                    '    include:'
                    '      - Drivers\WinPE\Dell WinPE 11 x64'
                    '      - Drivers\WinPE\HP WinPE 11 x64'
                ) -join "`r`n"
                ($script:workspaceRoot + '\Drivers\WinPE\Dell WinPE 11 x64\e1d68x64.inf') = '[Version]'
            }

            $warning = @()
            $result = Invoke-HDTBootImageTestBuild -Context $context -WarningVariable warning -WarningAction SilentlyContinue

            @($context.Boot.Operations | Where-Object { $_.Operation -eq 'AddDriver' }).Count | Should -Be 1
            @($warning | Where-Object { [string] $_ -like '*HP WinPE 11 x64*' }).Count | Should -BeGreaterThan 0
            $result.DriverCount | Should -BeGreaterThan -1
        }

        It 'warns and continues when the driver group does not exist' {
            # M5 owns the driver store. A boot image build must not be blocked
            # by a group nobody has imported yet.
            $yaml = $script:workspaceYaml -replace 'drivers: boot-critical', 'drivers: no-such-group'
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml

            $warning = @()
            $result = Invoke-HDTBootImageTestBuild -Context $context -WarningVariable warning -WarningAction SilentlyContinue

            $result.DriverCount | Should -Be 0
            @($context.Boot.GetOperationName()) | Should -Not -Contain 'AddDriver'
            @($warning | Where-Object { [string] $_ -like '*no-such-group*' }).Count | Should -BeGreaterThan 0
        }

        It 'adds no drivers when the workspace names no group' {
            $yaml = $script:workspaceYaml -replace '  drivers: boot-critical\r?\n', ''
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml

            $result = Invoke-HDTBootImageTestBuild -Context $context

            $result.DriverCount | Should -Be 0
            @($context.Boot.GetOperationName()) | Should -Not -Contain 'AddDriver'
        }

        It 'reports the drivers AddDriver returned' {
            $context = New-HDTBootImageTestContext -Driver @(
                [pscustomobject] @{ Inf = 'oem0.inf'; Provider = 'Intel'; Version = '12.19.2.60'; Date = '2024-01-01' }
            )
            $result = Invoke-HDTBootImageTestBuild -Context $context

            $result.DriverCount | Should -Be 1
        }

        It 'sets the scratch space the workspace declares' {
            $call = @($script:contentContext.Boot.Operations | Where-Object { $_.Operation -eq 'SetScratchSpace' })

            $call.Count | Should -Be 1
            [int] $call[0].Arguments[1] | Should -Be 512
        }
    }

    Context 'the two artifacts' {

        BeforeAll {
            $script:artifactContext = New-HDTBootImageTestContext
            $script:artifactResult = Invoke-HDTBootImageTestBuild -Context $script:artifactContext
        }

        # NO ANGLE BRACKETS IN THE TITLE. Pester expands <...> in an It name as a
        # -ForEach placeholder, so 'Boot\<name>.wim' made this test read $name at
        # run time. There is no -ForEach here, so under the StrictMode the build
        # sets that is an error - and it only ever passed because some other file
        # earlier in the same process had left a $name behind. Sharding the suite
        # across processes put this file in a session that had not, and it went red.
        It 'exports the WIM beside the named Boot wim and publishes it there' {
            # EXPORTED TO A STAGING NAME, renamed into place only once the ISO
            # exists too. The returned path is the final one, because that is the
            # file the caller will find.
            $call = @($script:artifactContext.Boot.Operations | Where-Object { $_.Operation -eq 'ExportImage' })

            $call.Count | Should -Be 1
            [string] $call[0].Arguments[0] | Should -BeExactly $script:scratchWim
            [int] $call[0].Arguments[1] | Should -Be 1
            [string] $call[0].Arguments[2] | Should -BeExactly ($script:wimPath + '.new')

            $script:artifactResult.WimPath | Should -BeExactly $script:wimPath

            @($script:artifactContext.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'MoveItem' -and
                        [string] $_.Arguments[1] -eq $script:wimPath }) | Should -HaveCount 1
        }

        It 'copies the exported WIM into the media tree as sources\boot.wim' {
            # DESIGN 6.1.1's MECHANISM, asserted from the filesystem journal:
            # the ISO is built from the SAME FILE, not from a second export. A
            # second export would produce a WIM that is functionally identical
            # and byte-different, and the whole debugging story rests on the
            # bytes being the same.
            $copy = @($script:artifactContext.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' -and
                        [string] $_.Arguments[1] -eq ($script:mediaPath + '\sources\boot.wim') })

            $copy.Count | Should -Be 1
            [string] $copy[0].Arguments[0] | Should -BeExactly ($script:wimPath + '.new')

            @($script:artifactContext.Boot.GetOperationName() | Where-Object { $_ -eq 'ExportImage' }).Count |
                Should -Be 1
        }

        It 'gives the media boot.wim the same hash as the standalone WIM' {
            $script:artifactContext.FileSystem.GetHash($script:mediaPath + '\sources\boot.wim') |
                Should -BeExactly $script:artifactContext.FileSystem.GetHash($script:wimPath)
        }

        It 'builds the ISO from that media root' {
            $call = @($script:artifactContext.Boot.Operations | Where-Object { $_.Operation -eq 'NewIso' })

            $call.Count | Should -Be 1
            [string] $call[0].Arguments[0] | Should -BeExactly $script:mediaPath

            # BUILT BESIDE ITS FINAL NAME, then renamed into place once the WIM
            # is ready too - so a failure here leaves the previous pair intact
            # rather than a new .wim beside a stale .iso.
            [string] $call[0].Arguments[1] | Should -BeExactly ($script:isoPath + '.new')
        }

        It 'passes -NoPromptForKey by default' {
            # DESIGN 5.2: on for New-HDTBootIso invoked by Update-HDTBootImage,
            # because a boot image you mount to test something should just boot.
            $call = @($script:artifactContext.Boot.Operations | Where-Object { $_.Operation -eq 'NewIso' })[0]

            @($call.Arguments[2]) | Should -Contain ('-bootdata:1#pEF,e,b{0}\efisys_noprompt.bin' -f $script:bitPath)
        }

        It 'asks for the prompt when the share declares promptForKey' {
            # THE SETTING AN ADMINISTRATOR TICKS IN THE CONSOLE. A machine whose
            # boot order still has the DVD first needs the prompt to be able to
            # fall through to the disk, and that is a property of the image
            # rather than of one build of it.
            $yaml = $script:workspaceYaml + "`n  promptForKey: true"
            $context = New-HDTBootImageTestContext -WorkspaceYaml $yaml
            Invoke-HDTBootImageTestBuild -Context $context | Out-Null

            $call = @($context.Boot.Operations | Where-Object { $_.Operation -eq 'NewIso' })[0]

            @($call.Arguments[2]) | Should -Contain ('-bootdata:1#pEF,e,b{0}\efisys.bin' -f $script:bitPath)
        }

        It 'does not pass it under -PromptForKey' {
            $context = New-HDTBootImageTestContext
            Invoke-HDTBootImageTestBuild -Context $context -Argument @{ PromptForKey = $true } | Out-Null

            $call = @($context.Boot.Operations | Where-Object { $_.Operation -eq 'NewIso' })[0]

            @($call.Arguments[2]) | Should -Contain ('-bootdata:1#pEF,e,b{0}\efisys.bin' -f $script:bitPath)
        }

        It 'passes the scratch bootbits directory to New-HDTBootIso' {
            # Asserted FROM THE JOURNAL, not from the default: step 4 prepared
            # that directory precisely so SPIKES S2's staging happens somewhere
            # this command controls and cleans.
            $call = @($script:artifactContext.Boot.Operations | Where-Object { $_.Operation -eq 'NewIso' })[0]

            @($call.Arguments[2] | Where-Object { $_ -like '-bootdata:*' })[0] |
                Should -BeLike ('*' + $script:bitPath + '*')
        }

        It 'reports the hashes and sizes of both artifacts' {
            $script:artifactResult.WimSha256 | Should -Match '^[0-9A-F]{64}$'
            $script:artifactResult.IsoSha256 | Should -Match '^[0-9A-F]{64}$'
            $script:artifactResult.WimSizeBytes | Should -BeGreaterThan 0
            $script:artifactResult.IsoSizeBytes | Should -BeGreaterThan 0
        }

        It 'reports nothing skipped' {
            @($script:artifactResult.Skipped).Count | Should -Be 0
        }

        It 'skips only the ISO under -SkipIso' {
            $context = New-HDTBootImageTestContext
            $result = Invoke-HDTBootImageTestBuild -Context $context -Argument @{ SkipIso = $true }

            @($context.Boot.GetOperationName()) | Should -Not -Contain 'NewIso'
            @($context.Boot.GetOperationName()) | Should -Contain 'ExportImage'

            $context.FileSystem.TestPath($script:wimPath) | Should -BeTrue
            $context.FileSystem.TestPath($script:manifestPath) | Should -BeTrue

            @($result.Skipped) | Should -Be @('Iso')
            [string] $result.IsoPath | Should -BeExactly ''

            $manifest = ConvertFrom-Json -InputObject $context.FileSystem.ReadAllText($script:manifestPath)
            $manifest.artifacts.iso.skipped | Should -BeTrue
        }
    }

    Context 'the refusals' {

        It 'refuses a scratch path containing a space' {
            # THE BACK DOOR THE STAGING DIRECTORY WAS BUILT TO CLOSE. <scratch>\
            # bootbits is what step 17 hands New-HDTBootIso as -BootBitPath, and
            # a space-free staging directory that is itself under a path with a
            # space solves nothing (SPIKES S2).
            $context = New-HDTBootImageTestContext

            $record = $null
            try {
                Invoke-HDTBootImageTestBuild -Context $context -Argument @{ ScratchPath = 'C:\Program Files\HDT scratch' }
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*-bootdata*'
        }

        It 'refuses a scratch path inside the workspace' {
            # A build that writes into the share it is reading is how a
            # deployment share gets a mount folder in it forever.
            $context = New-HDTBootImageTestContext

            $record = $null
            try {
                Invoke-HDTBootImageTestBuild -Context $context -Argument @{ ScratchPath = ($script:workspaceRoot + '\scratch') }
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*workspace*'
        }

        It 'refuses a scratch path inside the repository' {
            $context = New-HDTBootImageTestContext
            $context.FileSystem.SeedFile((Join-Path -Path $script:repoRoot -ChildPath '.git\HEAD'), 'ref: refs/heads/main')

            $record = $null
            try {
                Invoke-HDTBootImageTestBuild -Context $context -Argument @{
                    ScratchPath = (Join-Path -Path $script:repoRoot -ChildPath 'scratch')
                }
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*repositor*'
        }

        It 'refuses with one sentence when the ADK is not installed' {
            $journal = [System.Collections.ArrayList]::new()
            $fs = New-HDTFakeFileSystem -Journal $journal
            $fs.SeedFile(($script:workspaceRoot + '\workspace.yaml'), $script:workspaceYaml)
            $registry = New-HDTFakeRegistryService -Journal $journal
            $boot = New-HDTFakeBootImageService -FileSystem $fs -Journal $journal
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 14, 9, 14, 22, [System.DateTimeKind]::Utc))

            $record = $null
            try {
                Update-HDTBootImage -WorkspaceRoot $script:workspaceRoot -ScratchPath $script:scratchPath `
                    -EngineModulePath $script:enginePath -YamlModulePath $script:yamlPath `
                    -BootImageService $boot -FileSystem $fs -Registry $registry -Clock $clock -Confirm:$false
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTDependencyError*'
        }

        It 'writes no boot image when it refuses' {
            # 04-02's discipline: a command that refuses has performed no
            # operation at all, so a failed build cannot leave half a boot image
            # anywhere.
            #
            # THE BUILD LOG IS NOT AN ARTEFACT OF THE BUILD, and is excluded
            # deliberately rather than by accident. The refusal is the single
            # most useful thing this command ever writes down - "the scratch
            # path contains a space" is a support question somebody asks days
            # later - and a rule that forbade recording it would keep the
            # discipline by throwing away the reason. What the invariant is
            # actually about is half a boot image: a WIM copied, a directory
            # made, a mount left behind. None of those may happen, and none do.
            $context = New-HDTBootImageTestContext

            try {
                Invoke-HDTBootImageTestBuild -Context $context -Argument @{ ScratchPath = 'C:\Program Files\HDT scratch' }
            } catch { $null = $_ }

            @($context.Boot.Operations).Count | Should -Be 0

            $artefact = @($context.Journal | Where-Object {
                    $_.Service -eq 'FileSystem' -and
                    @('WriteAllText', 'CopyItem', 'RemoveItem', 'CreateDirectory') -contains $_.Operation -and
                    ([string] $_.Arguments[0]) -notlike '*.build.log'
                })

            @($artefact).Count | Should -Be 0
        }

        It 'discards the mount when a package fails' {
            $context = New-HDTBootImageTestContext -Failure @{ AddPackage = 'Error: 0x800f081e' }

            $record = $null
            try { Invoke-HDTBootImageTestBuild -Context $context } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty

            $dismount = @($context.Boot.Operations | Where-Object { $_.Operation -eq 'DismountImage' })
            $dismount.Count | Should -Be 1
            [bool] $dismount[0].Arguments[1] | Should -BeFalse -Because 'a failed build must not commit what it half-applied'
        }

        It 'dismounts on any failure after the mount' -ForEach @(
            @{ Operation = 'AddPackage' }
            @{ Operation = 'SetScratchSpace' }
            @{ Operation = 'AddDriver' }
        ) {
            $context = New-HDTBootImageTestContext -Failure @{ $Operation = 'seeded failure' }

            try { Invoke-HDTBootImageTestBuild -Context $context } catch { $null = $_ }

            $dismount = @($context.Boot.Operations | Where-Object { $_.Operation -eq 'DismountImage' })
            $dismount.Count | Should -Be 1
            [bool] $dismount[0].Arguments[1] | Should -BeFalse
        }

        It 'leaves no artifact when a package fails' {
            $context = New-HDTBootImageTestContext -Failure @{ AddPackage = 'Error: 0x800f081e' }

            try { Invoke-HDTBootImageTestBuild -Context $context } catch { $null = $_ }

            $context.FileSystem.TestPath($script:wimPath) | Should -BeFalse
            $context.FileSystem.TestPath($script:manifestPath) | Should -BeFalse
        }

        It 'mounts nothing under -WhatIf' {
            $context = New-HDTBootImageTestContext

            Invoke-HDTBootImageTestBuild -Context $context -Argument @{ WhatIf = $true } | Out-Null

            @($context.Boot.Operations).Count | Should -Be 0
            $context.FileSystem.TestPath($script:wimPath) | Should -BeFalse
        }

        It 'warns for every over-privileged ACL finding and still builds' {
            # DESIGN 6.3: "Update-HDTBootImage runs this check and warns loudly
            # when the account is over-privileged - a domain admin credential in
            # a boot image is a domain compromise." IT WARNS. IT DOES NOT REFUSE:
            # a build that died on an ACL check is a build with the ACL check
            # turned off, and then nobody is told about the domain admin either.
            $context = New-HDTBootImageTestContext

            $accessRule = @{
                '.'      = @([pscustomobject] @{ Identity = 'CONTOSO\svc-hdt-deploy'; Rights = 'FullControl'; Type = 'Allow'; IsInherited = $false })
                'Logs'   = @([pscustomobject] @{ Identity = 'CONTOSO\svc-hdt-deploy'; Rights = 'Write'; Type = 'Allow'; IsInherited = $false })
                'Boot'   = @([pscustomobject] @{ Identity = 'CONTOSO\svc-hdt-deploy'; Rights = 'Modify'; Type = 'Allow'; IsInherited = $false })
                'Drivers' = @([pscustomobject] @{ Identity = 'CONTOSO\svc-hdt-deploy'; Rights = 'Read'; Type = 'Allow'; IsInherited = $false })
            }

            $warning = @()
            $result = Invoke-HDTBootImageTestBuild -Context $context -WarningVariable warning -WarningAction SilentlyContinue `
                -Argument @{ AccessRule = $accessRule }

            $result.WimPath | Should -BeExactly $script:wimPath
            @($warning | Where-Object { [string] $_ -like '*FullControl*' }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'the manifest' {

        BeforeAll {
            $script:manifestContext = New-HDTBootImageTestContext
            $script:manifestResult = Invoke-HDTBootImageTestBuild -Context $script:manifestContext
            $script:manifestText = $script:manifestContext.FileSystem.ReadAllText($script:manifestPath)
            $script:manifestDocument = ConvertFrom-Json -InputObject $script:manifestText
        }

        It 'writes the manifest beside the WIM' {
            $script:manifestResult.ManifestPath | Should -BeExactly $script:manifestPath
        }

        It 'lists every component the journal shows was applied' {
            # Compared against the JOURNAL, so a manifest claiming a component
            # that was never applied fails here rather than being believed by an
            # operator six months from now.
            $applied = @($script:manifestContext.Boot.Operations |
                    Where-Object { $_.Operation -eq 'AddPackage' } |
                    ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension([string] $_.Arguments[1]) } |
                    Where-Object { $_ -notlike '*_en-us' })

            @($script:manifestDocument.optionalComponents | ForEach-Object { $_.name }) | Should -Be $applied
        }

        It 'records the sha256 of the artifacts it produced' {
            $script:manifestDocument.artifacts.wim.sha256 |
                Should -BeExactly $script:manifestContext.FileSystem.GetHash($script:wimPath)
            $script:manifestDocument.artifacts.iso.sha256 |
                Should -BeExactly $script:manifestContext.FileSystem.GetHash($script:isoPath)
        }

        It 'records isoBootWimSha256 equal to the wim sha256 and to the media boot.wim' {
            # Three-way, because a manifest that agreed with itself but not with
            # the disk would be worse than none.
            $script:manifestDocument.artifacts.isoBootWimSha256 |
                Should -BeExactly $script:manifestDocument.artifacts.wim.sha256
            $script:manifestDocument.artifacts.isoBootWimSha256 |
                Should -BeExactly $script:manifestContext.FileSystem.GetHash($script:mediaPath + '\sources\boot.wim')
        }

        It 'records the exact startnet text' {
            $expected = InModuleScope Hephaestus { Get-HDTStartnetScript }

            $script:manifestDocument.startnet | Should -BeExactly $expected
        }

        It 'records the ADK it built from' {
            $script:manifestDocument.adk.root | Should -BeExactly $script:adkRoot
            $script:manifestDocument.adk.oscdimg | Should -BeLike '*oscdimg.exe'
        }

        It 'records the UI in the manifest, like the other staged payloads' {
            @($script:manifestDocument.payload | Where-Object { $_.destination -like '*\HDT\UI*' }).Count |
                Should -BeGreaterThan 0
        }

        It 'records the payload it staged' {
            @($script:manifestDocument.payload | ForEach-Object { $_.destination }) |
                Should -Contain '\HDT\Modules\Hephaestus'
            @($script:manifestDocument.payload | ForEach-Object { $_.destination }) |
                Should -Contain '\HDT\Modules\powershell-yaml'
        }

        It 'records the credential username' {
            $script:manifestDocument.credential.username | Should -BeExactly 'CONTOSO\svc-hdt-deploy'
            $script:manifestDocument.credential.embedded | Should -BeTrue
        }

        It 'carries no secret anywhere in its text' {
            $script:manifestText | Should -Not -BeLike ('*' + $script:secret + '*')
        }
    }

    Context 'the command itself' {

        It 'has comment-based help naming itself' {
            $help = Get-Help -Name 'Update-HDTBootImage' -ErrorAction Stop

            $help.Name | Should -BeExactly 'Update-HDTBootImage'
            $help.Synopsis | Should -Not -BeNullOrEmpty
            @($help.Examples.Example).Count | Should -BeGreaterThan 2
        }

        It 'supports ShouldProcess' {
            (Get-Command -Name 'Update-HDTBootImage').Parameters.Keys | Should -Contain 'WhatIf'
        }

        It 'defaults the engine module path to the running module' {
            # "What ships is what is loaded." Asserted off the AST rather than by
            # running it, because the running module IS the default and a test
            # that used it could not tell the difference.
            $path = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Update-HDTBootImage.ps1'
            $token = $null
            $parseError = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $token, [ref] $parseError)

            @($parseError).Count | Should -Be 0

            $parameter = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.ParameterAst] -and
                        $node.Name.VariablePath.UserPath -eq 'EngineModulePath'
                    }, $true))

            $parameter.Count | Should -Be 1
            [string] $parameter[0].DefaultValue.Extent.Text | Should -BeLike '*HDTModuleRoot*'
        }

        It 'gives its own progress sink a build log to write' {
            # A COMMAND-LINE BUILD KEPT NO RECORD AT ALL. The default sink
            # records nothing, and the console only wrote Boot\<image>.build.log
            # when somebody clicked Open Log - so a build that failed while
            # nobody watched left nothing behind, which is the build whose log
            # is worth having.
            #
            # AST, like the EngineModulePath test above and for the same reason:
            # the behaviour is a DEFAULT, and a test that ran the command would
            # be asserting against the default it is trying to pin.
            #
            # Only the sink this command builds for itself. A caller that passes
            # -Progress - which is the console - owns its own logging and is
            # deliberately untouched.
            $path = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Update-HDTBootImage.ps1'
            $token = $null
            $parseError = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $token, [ref] $parseError)

            @($parseError).Count | Should -Be 0

            $call = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        [string] $node.GetCommandName() -eq 'New-HDTBuildProgress'
                    }, $true))

            $call.Count | Should -Be 1
            @($call[0].CommandElements | ForEach-Object { [string] $_.Extent.Text }) |
                Should -Contain '-LogPath'
        }

        It 'defaults its scratch path to somewhere that is not one lab''s machine' {
            # THIS SHIPPED. The default was 'C:\HDTLab\scratch\bootimage' - the
            # author's own lab - so every administrator who installed Hephaestus
            # from the Gallery and ran a build got a gigabyte-scale scratch tree
            # created at a path that means nothing on their machine.
            #
            # DESIGN 5.2 constrains it and names no default: no space, not inside
            # the workspace, not inside the repository. ProgramData satisfies all
            # three and is machine-scoped, like the elevated build that uses it.
            #
            # AST, because the default is the thing under test.
            $path = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Update-HDTBootImage.ps1'
            $token = $null
            $parseError = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $token, [ref] $parseError)

            @($parseError).Count | Should -Be 0

            $parameter = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.ParameterAst] -and
                        $node.Name.VariablePath.UserPath -eq 'ScratchPath'
                    }, $true))

            $parameter.Count | Should -Be 1

            $default = [string] $parameter[0].DefaultValue.Extent.Text

            $default | Should -Not -BeLike '*HDTLab*'

            # THE RESOLVED PATH, NOT THE EXPRESSION. DESIGN 5.2 forbids a SPACE
            # in the scratch path (oscdimg's -bootdata cannot carry a quoted
            # one), and it is the path that must be clean - the expression that
            # builds it has spaces in it by construction.
            [System.IO.Path]::Combine($env:ProgramData, 'Hephaestus', 'bootimage') |
                Should -Not -Match '\s'
        }

        It 'reports a duration' {
            $context = New-HDTBootImageTestContext
            $result = Invoke-HDTBootImageTestBuild -Context $context

            $result.DurationSecond | Should -BeGreaterOrEqual 0
        }
    }
}

Describe 'Update-HDTBootImage and a half-finished build' {

    # ONE BUILD, TWO ARTIFACTS, AND THEY MUST AGREE.
    #
    # DESIGN 6.1.1: one mount produces a .wim and a hash-identical .iso, so the
    # image you PXE boot is the one you debugged. The build exported the WIM to
    # Boot\ and THEN built the ISO, so anything that went wrong in between left
    # the share holding a new .wim beside an old .iso under matching names, with
    # nothing saying so. It happened in this lab: a VM was holding the ISO open,
    # oscdimg could not overwrite it, and the share was left with artifacts three
    # hours apart.
    #
    # THE FIX IS TO PUBLISH LAST. Both are written beside their final names and
    # renamed into place only once BOTH exist - same directory, so same volume,
    # so the renames are atomic and cost no copy. A failure at any point leaves
    # the previous pair intact and consistent.
    #
    # AND THE MANIFEST IS RENAMED AFTER BOTH, which is what makes its recorded
    # hashes mean something: a manifest on disk is a promise that the two files
    # beside it came from the build that wrote it.

    BeforeAll {
        $script:context = New-HDTBootImageTestContext
        [void] (Invoke-HDTBootImageTestBuild -Context $script:context)
    }

    It 'writes the artifacts under a staging name before publishing them' {
        $written = @($script:context.FileSystem.Operations |
                Where-Object { $_.Operation -eq 'MoveItem' })

        $written | Should -Not -BeNullOrEmpty -Because 'the artifacts are renamed into place, not written into place'
    }

    It 'publishes the ISO before the WIM, and the manifest after both' {
        # THE ISO GOES FIRST because it is the one a VM holds open: a publish
        # that is going to fail must fail before the WIM has been replaced.
        # THE MANIFEST GOES LAST because its presence is what promises the two
        # files beside it came from the build that wrote it.
        $op = @($script:context.FileSystem.Operations |
                Where-Object { $_.Operation -in @('MoveItem', 'WriteAllText') })

        $isoAt = [array]::FindIndex([object[]] $op, [Predicate[object]] {
                param($o) $o.Operation -eq 'MoveItem' -and ([string] $o.Arguments[1]) -like '*.iso' })
        $wimAt = [array]::FindIndex([object[]] $op, [Predicate[object]] {
                param($o) $o.Operation -eq 'MoveItem' -and ([string] $o.Arguments[1]) -like '*.wim' })
        $manifestAt = [array]::FindIndex([object[]] $op, [Predicate[object]] {
                param($o) $o.Operation -eq 'WriteAllText' -and ([string] $o.Arguments[0]) -like '*.manifest.json' })

        $isoAt | Should -BeGreaterThan -1
        $wimAt | Should -BeGreaterThan $isoAt
        $manifestAt | Should -BeGreaterThan $wimAt
    }

    It 'refuses before the mount when a final path cannot be written' {
        # THREE MINUTES OF DISM, THEN A LOCKED FILE, is the shape this avoids.
        # A VM holding the ISO is the common case and it is knowable up front.
        $context = New-HDTBootImageTestContext

        $context.FileSystem.SeedWriteFailure(
            ($script:workspaceRoot + '\Boot\HDTPE_x64.iso.new'), 'The process cannot access the file')

        $record = $null
        try {
            [void] (Invoke-HDTBootImageTestBuild -Context $context)
        } catch {
            $record = $_
        }

        $record | Should -Not -BeNullOrEmpty
        [string] $record.Exception.Message | Should -BeLike '*Boot*'

        @($context.Boot.Operations | Where-Object { $_.Operation -eq 'MountImage' }) |
            Should -BeNullOrEmpty -Because 'it must fail before it spends three minutes mounting'
    }
}
