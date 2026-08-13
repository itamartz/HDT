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
            [string] $WorkspaceYaml = ''
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
        $seed[($script:enginePath + '\Private\ConvertFrom-HDTYaml.ps1')] = '# private'
        $seed[($script:enginePath + '\Payload\Start-HDTDeployment.ps1')] = '# the entry point'
        $seed[($script:enginePath + '\Payload\Start-HDTResume.ps1')] = '# the resume leg'

        $seed[($script:yamlPath + '\powershell-yaml.psd1')] = '@{ ModuleVersion = ''0.4.12'' }'
        $seed[($script:yamlPath + '\net47\YamlDotNet.dll')] = 'binary'

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
            [object[]] $Driver
        )

        $journal = [System.Collections.ArrayList]::new()
        $fs = New-HDTFakeFileSystem -File (New-HDTBootImageTestSeed -WorkspaceYaml $WorkspaceYaml) -Journal $journal
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
            [hashtable] $Argument
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

        It 'stages the engine module, powershell-yaml and both payload scripts' {
            foreach ($path in @(
                    ($script:mountPath + '\HDT\Modules\Hephaestus\Hephaestus.psd1'),
                    ($script:mountPath + '\HDT\Modules\powershell-yaml\net47\YamlDotNet.dll'),
                    ($script:mountPath + '\HDT\Start-HDTDeployment.ps1'),
                    ($script:mountPath + '\HDT\Start-HDTResume.ps1'))) {

                $script:contentContext.FileSystem.TestPath($path) | Should -BeTrue -Because "$path must be in the image"
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

        It 'adds the boot-critical driver group when it exists' {
            $call = @($script:contentContext.Boot.Operations | Where-Object { $_.Operation -eq 'AddDriver' })

            $call.Count | Should -Be 1
            [string] $call[0].Arguments[0] | Should -BeExactly $script:mountPath
            [string] $call[0].Arguments[1] | Should -BeExactly ($script:workspaceRoot + '\Drivers\boot-critical')
            [bool] $call[0].Arguments[2] | Should -BeTrue
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

        It 'exports the WIM to Boot\<name>.wim' {
            $call = @($script:artifactContext.Boot.Operations | Where-Object { $_.Operation -eq 'ExportImage' })

            $call.Count | Should -Be 1
            [string] $call[0].Arguments[0] | Should -BeExactly $script:scratchWim
            [int] $call[0].Arguments[1] | Should -Be 1
            [string] $call[0].Arguments[2] | Should -BeExactly $script:wimPath

            $script:artifactResult.WimPath | Should -BeExactly $script:wimPath
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
            [string] $copy[0].Arguments[0] | Should -BeExactly $script:wimPath

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
            [string] $call[0].Arguments[1] | Should -BeExactly $script:isoPath
        }

        It 'passes -NoPromptForKey by default' {
            # DESIGN 5.2: on for New-HDTBootIso invoked by Update-HDTBootImage,
            # because a boot image you mount to test something should just boot.
            $call = @($script:artifactContext.Boot.Operations | Where-Object { $_.Operation -eq 'NewIso' })[0]

            @($call.Arguments[2]) | Should -Contain ('-bootdata:1#pEF,e,b{0}\efisys_noprompt.bin' -f $script:bitPath)
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
            $record.Exception.Message | Should -BeLike '*S2*'
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

        It 'writes nothing when it refuses' {
            # 04-02's discipline: a command that refuses has performed no
            # operation at all, so a failed build cannot leave half a boot image
            # anywhere.
            $context = New-HDTBootImageTestContext

            try {
                Invoke-HDTBootImageTestBuild -Context $context -Argument @{ ScratchPath = 'C:\Program Files\HDT scratch' }
            } catch { $null = $_ }

            @($context.Boot.Operations).Count | Should -Be 0
            @($context.Journal | Where-Object { $_.Service -eq 'FileSystem' -and
                    @('WriteAllText', 'CopyItem', 'RemoveItem', 'CreateDirectory') -contains $_.Operation }).Count |
                Should -Be 0
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

        It 'reports a duration' {
            $context = New-HDTBootImageTestContext
            $result = Invoke-HDTBootImageTestBuild -Context $context

            $result.DurationSecond | Should -BeGreaterOrEqual 0
        }
    }
}
