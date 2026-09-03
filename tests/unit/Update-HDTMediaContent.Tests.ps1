#requires -Version 5.1

# Update-HDTMediaContent against fakes: no ADK, no DISM, no oscdimg, nothing
# mounted, nothing burned - and every decision the media build makes asserted.
#
# tests/unit/Update-HDTBootImage.Tests.ps1 is the harness this copies: the same
# fakes, the same ADK fixture (a real capture of this host's ADK, so no literal
# ADK path is read anywhere), and the same headline assertion - THE EXACT ORDERED
# OPERATION LIST, projected off the shared journal (DESIGN 12.2.1).
#
# THE WORKSPACE ROOT IS X:\Share, A DRIVE THIS SESSION HAS NOT MOUNTED, and the
# ADK is resolved through the injected registry. That is the only way this file
# can tell that every injected service was passed on: none of -FileSystem,
# -Registry, -BootImageService, -Clock or -Progress is mandatory anywhere in the
# chain and all default to the real adapter, so DROPPING ONE IS NOT A BIND ERROR
# AND NOT A RED TEST - it is a unit test that quietly talks to this laptop's
# registry, disk and ADK. A call that fell through throws DriveNotFound, or
# HDTDependencyError for the ADK, or hangs on oscdimg.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:layout = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/adk/adk-layout-10.1.26100.2454.json') -Raw |
        ConvertFrom-Json

    $script:kitsRoot10 = [string] $script:layout.kitsRoot10
    $script:adkRoot = [string] $script:layout.adkRoot

    # NOT MOUNTED, ON PURPOSE. See the file header.
    $script:workspaceRoot = 'X:\Share'
    $script:scratchPath = 'C:\HDTLab\scratch\mediabuild'
    $script:mediaPath = $script:scratchPath + '\media'
    $script:projectedShare = $script:mediaPath + '\Share'
    $script:mediaSources = $script:mediaPath + '\sources'
    $script:bootScratch = $script:scratchPath + '\bootimage'
    $script:bitPath = $script:scratchPath + '\bootbits'
    $script:stagedIso = $script:scratchPath + '\HDT_LAB-DISC.iso'
    $script:outputPath = $script:workspaceRoot + '\Media\LAB-DISC\HDT_LAB-DISC.iso'
    $script:manifestPath = $script:workspaceRoot + '\Media\LAB-DISC\media.manifest.json'

    $script:enginePath = 'C:\Modules\Hephaestus'
    $script:yamlPath = 'C:\Modules\powershell-yaml'

    $script:payloadLeaf = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload') -Filter '*.ps1' -File |
            Sort-Object -Property Name | ForEach-Object { $_.Name })

    # A REAL SHARE'S deployRoot IS A UNC PATH, which is the whole reason the
    # provider swap exists: copying this share's own Boot\ wim onto the disc
    # would put an Smb image on it.
    $script:workspaceYaml = @(
        'schemaVersion: 1'
        'id: HDT-LAB'
        'name: HDT lab deployment share'
        'deployRoot: \\server\HDTShare'
        'logLevel: Info'
        ''
        'credential:'
        '  username: CONTOSO\svc-hdt-deploy'
        ''
        'bootImage:'
        '  name: HDTPE_x64'
        '  architecture: amd64'
        '  language: en-us'
        '  scratchSpaceMB: 512'
    ) -join "`r`n"

    $script:profileYaml = @(
        'schemaVersion: 1'
        'profiles:'
        '  - id: two-vendor'
        '    name: Two vendor folders'
        '    include:'
        '      - Drivers\WinPE\Dell WinPE 11 x64'
        '      - Applications\TightVNC'
        '  - id: missing-folder'
        '    name: Names a folder the share has not got'
        '    include:'
        '      - Drivers\WinPE\Lenovo WinPE 11 x64'
    ) -join "`r`n"

    function New-HDTMediaTestDocument {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a string; it changes no state.')]
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter()]
            [string] $Id = 'LAB-DISC',

            [Parameter()]
            [string] $SelectionProfile = 'everything',

            [Parameter()]
            [AllowEmptyString()]
            [string] $Enabled = ''
        )

        $line = @(
            'schemaVersion: 1'
            ('id: {0}' -f $Id)
            'name: Lab standalone disc'
            'description: What a technician carries to a machine with no network.'
            ('selectionProfile: {0}' -f $SelectionProfile)
            ('output: Media\{0}\HDT_{0}.iso' -f $Id)
        )

        if (-not [string]::IsNullOrEmpty($Enabled)) { $line += ('enabled: {0}' -f $Enabled) }

        return ($line -join "`r`n")
    }

    function New-HDTMediaTestSeed {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory hashtable of seed data; it changes no state.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param(
            [Parameter()]
            [AllowNull()]
            [hashtable] $ExtraFile,

            [Parameter()]
            [AllowNull()]
            [string[]] $Without
        )

        $seed = @{}

        # The real ADK layout, captured off this host.
        foreach ($row in @($script:layout.file)) {
            $seed[($script:adkRoot + [string] $row.Path)] = 'fixture'
        }

        $seed[($script:workspaceRoot + '\workspace.yaml')] = $script:workspaceYaml
        $seed[($script:workspaceRoot + '\rules.yaml')] = 'schemaVersion: 1'
        $seed[($script:workspaceRoot + '\bootstrap-rules.yaml')] = 'schemaVersion: 1'
        $seed[($script:workspaceRoot + '\Control\selection-profiles.yaml')] = $script:profileYaml
        $seed[($script:workspaceRoot + '\Control\share-credential.json')] = '{ "username": "CONTOSO\\svc-hdt-deploy" }'
        $seed[($script:workspaceRoot + '\Control\machines\PC-1234.yaml')] = 'schemaVersion: 1'

        # TightVNC depends on Acrobat, which is the 2026-09-03 disc exactly.
        $seed[($script:workspaceRoot + '\Applications\TightVNC\app.yaml')] = @(
            'schemaVersion: 1'
            'id: TightVNC'
            'name: TightVNC'
            'install: setup.exe /S'
            'dependencies:'
            '  - Acrobat'
        ) -join "`r`n"

        $seed[($script:workspaceRoot + '\Applications\Acrobat\app.yaml')] = @(
            'schemaVersion: 1'
            'id: Acrobat'
            'name: Acrobat Reader'
            'install: setup.exe /sAll'
        ) -join "`r`n"

        $seed[($script:workspaceRoot + '\OperatingSystems\Win11\os.yaml')] = 'schemaVersion: 1'
        $seed[($script:workspaceRoot + '\Drivers\WinPE\Dell WinPE 11 x64\oem0.inf')] = '[Version]'
        $seed[($script:workspaceRoot + '\TaskSequences\PNP-TEST\sequence.yaml')] = 'schemaVersion: 1'
        $seed[($script:workspaceRoot + '\Scripts\UI\HDTWizard.xaml')] = '<Window />'

        # THE FOUR ARTIFACTS A DISC REFUSES, all present on the share so a test
        # that says one did not travel is saying something.
        $seed[($script:workspaceRoot + '\Boot\HDTPE_x64.wim')] = 'the share''s own Smb boot image'
        $seed[($script:workspaceRoot + '\Logs\PC-9876\HDT.log')] = 'another machine''s log'
        $seed[($script:workspaceRoot + '\Captures\PC-9876.wim')] = 'another machine''s image'

        $seed[($script:workspaceRoot + '\Media\LAB-DISC\media.yaml')] = (New-HDTMediaTestDocument)

        # The engine, as it would sit on a build host.
        $seed[($script:enginePath + '\Hephaestus.psd1')] = '@{ ModuleVersion = ''0.1.0'' }'
        $seed[($script:enginePath + '\Hephaestus.psm1')] = '# loader'
        $seed[($script:enginePath + '\Public\Get-HDTAdkPath.ps1')] = '# public'
        $seed[($script:enginePath + '\Hephaestus.bundle.ps1')] = '# every function, concatenated'
        $seed[($script:enginePath + '\Private\ConvertFrom-HDTYaml.ps1')] = '# private'

        foreach ($payload in @($script:payloadLeaf)) {
            $seed[($script:enginePath + '\Payload\' + $payload)] = ('# {0}' -f $payload)
        }

        $seed[($script:enginePath + '\UI\HDTWizard.xaml')] = '<Window />'
        $seed[($script:yamlPath + '\powershell-yaml.psd1')] = '@{ ModuleVersion = ''0.4.12'' }'
        $seed[($script:yamlPath + '\net47\YamlDotNet.dll')] = 'binary'

        foreach ($path in @($Without)) { [void] $seed.Remove([string] $path) }

        if ($null -ne $ExtraFile) {
            foreach ($key in @($ExtraFile.Keys)) { $seed[[string] $key] = $ExtraFile[$key] }
        }

        return $seed
    }

    function New-HDTMediaTestContext {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds in-memory test doubles; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowNull()]
            [hashtable] $ExtraFile,

            [Parameter()]
            [AllowNull()]
            [string[]] $Without
        )

        $journal = [System.Collections.ArrayList]::new()
        $fs = New-HDTFakeFileSystem -File (New-HDTMediaTestSeed -ExtraFile $ExtraFile -Without $Without) -Journal $journal
        $registry = New-HDTFakeRegistryService -Value @{
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' = @{ KitsRoot10 = $script:kitsRoot10 }
        } -Journal $journal

        $boot = New-HDTFakeBootImageService -FileSystem $fs -Journal $journal
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 9, 3, 9, 14, 22, [System.DateTimeKind]::Utc)) -TickMillisecond 1000

        return [pscustomobject] @{
            Journal    = $journal
            FileSystem = $fs
            Registry   = $registry
            Boot       = $boot
            Clock      = $clock
        }
    }

    function Invoke-HDTMediaTestBuild {
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
            Id               = 'LAB-DISC'
            ScratchPath      = $script:scratchPath
            EngineModulePath = $script:enginePath
            YamlModulePath   = $script:yamlPath

            # NO -AdkRoot, DELIBERATELY. The ADK is found through the INJECTED
            # registry - the fake carries KitsRoot10 and the fixture carries the
            # layout - so a Get-HDTAdkPath call that dropped either service
            # would read this host's real registry and real disk, and the "no
            # ADK need be installed" claim would be one nothing checks.
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

        return (Update-HDTMediaContent @splat)
    }

    # The journal, projected down to the milestones DESIGN 6.2 names. Everything
    # else - the ADK probes, the media tree copy, the boot image's own seventeen
    # steps - is deliberately invisible: an assertion listing every filesystem
    # call is one nobody can read and nobody would maintain.
    function Get-HDTMediaTestMilestone {
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

            if ($service -eq 'FileSystem' -and $operation -eq 'ReadAllText' -and $first -like '*\media.yaml') {
                $name = 'ReadMediaDocument'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'ReadAllText' -and
                $first -eq ($script:workspaceRoot + '\workspace.yaml')) {
                $name = 'ImportWorkspaceDocument'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'ReadAllText' -and $first -like '*\selection-profiles.yaml') {
                $name = 'ProjectShare'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'ReadAllText' -and $first -like '*\app.yaml') {
                $name = 'ReadApplicationCatalog'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'RemoveItem' -and $first -eq $script:mediaPath) {
                $name = 'PrepareScratch'
            } elseif ($service -eq 'RegistryService' -and $operation -eq 'GetValue' -and $second -eq 'KitsRoot10') {
                $name = 'ResolveAdkPath'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'CreateDirectory' -and $first -eq $script:mediaSources) {
                $name = 'CreateMediaSources'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'CopyItem' -and $second -like ($script:projectedShare + '\*')) {
                $name = 'ProjectContent'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'WriteAllText' -and
                $first -eq ($script:projectedShare + '\workspace.yaml')) {
                $name = 'WriteProjectedWorkspace'
            } elseif ($service -eq 'BootImageService' -and $operation -eq 'MountImage') {
                $name = 'MountBootImage'
            } elseif ($service -eq 'BootImageService' -and $operation -eq 'ExportImage') {
                $name = 'ExportBootImage'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'MoveItem' -and
                $second -eq ($script:mediaSources + '\boot.wim')) {
                $name = 'MoveWimToMedia'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'RemoveItem' -and
                $first -eq ($script:projectedShare + '\Boot')) {
                $name = 'RemoveProjectedBoot'
            } elseif ($service -eq 'BootImageService' -and $operation -eq 'NewIso') {
                $name = 'NewIso'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'MoveItem' -and $second -eq $script:outputPath) {
                $name = 'PublishIso'
            } elseif ($service -eq 'FileSystem' -and $operation -eq 'WriteAllText' -and $first -like '*\media.manifest.json') {
                $name = 'WriteManifest'
            }

            if ([string]::IsNullOrEmpty($name)) { continue }

            # Consecutive duplicates collapse: projecting five folders is many
            # CopyItem calls and one milestone.
            if ($step.Count -gt 0 -and [string] $step[$step.Count - 1] -eq $name) { continue }

            [void] $step.Add($name)
        }

        return [string[]] @($step)
    }

    # THE ORDER DESIGN 6.2 SPECIFIES: read the definition, project, swap the
    # provider, build the image against the PROJECTED share, move its wim to
    # sources\boot.wim, take the Boot folder off the disc, burn once, publish,
    # and write the manifest LAST.
    $script:expectedOrder = @(
        'ReadMediaDocument'
        'ImportWorkspaceDocument'
        'ProjectShare'
        'ReadApplicationCatalog'
        'PrepareScratch'
        'ResolveAdkPath'
        'CreateMediaSources'
        'ProjectContent'
        'WriteProjectedWorkspace'
        # The boot image resolves the ADK itself - it is a command in its own
        # right and is not handed paths by a caller it does not require.
        'ResolveAdkPath'
        'MountBootImage'
        'ExportBootImage'
        'MoveWimToMedia'
        'RemoveProjectedBoot'
        # And so does New-HDTBootIso, for the same reason.
        'ResolveAdkPath'
        'NewIso'
        'PublishIso'
        'WriteManifest'
    )
}

Describe 'Update-HDTMediaContent' {

    Context 'the ordered build' {

        BeforeAll {
            $script:orderContext = New-HDTMediaTestContext
            $script:orderResult = Invoke-HDTMediaTestBuild -Context $script:orderContext -WarningAction SilentlyContinue
            $script:milestone = Get-HDTMediaTestMilestone -Journal $script:orderContext.Journal
        }

        It 'is exported by Hephaestus' {
            (Get-Command -Name 'Update-HDTMediaContent' -Module 'Hephaestus' -ErrorAction SilentlyContinue) |
                Should -Not -BeNullOrEmpty
        }

        It 'performs exactly these operations, in this order, against fakes' {
            $script:milestone | Should -Be $script:expectedOrder -Because (
                'the build performed:' + [System.Environment]::NewLine +
                (($script:milestone | ForEach-Object { '  ' + $_ }) -join [System.Environment]::NewLine))
        }

        It 'writes the manifest last, so a manifest on disk means the ISO beside it is that build' {
            $script:milestone[-1] | Should -BeExactly 'WriteManifest'
        }

        It 'returns the disc it built' {
            $script:orderResult.Id | Should -BeExactly 'LAB-DISC'
            $script:orderResult.IsoPath | Should -BeExactly $script:outputPath
            $script:orderResult.SelectionProfile | Should -BeExactly 'everything'
            $script:orderResult.ManifestPath | Should -BeExactly $script:manifestPath
            $script:orderResult.IsoSha256 | Should -Not -BeNullOrEmpty
            @($script:orderResult.Projected) | Should -Not -BeNullOrEmpty
            @($script:orderResult.Excluded) | Should -Not -BeNullOrEmpty
        }

        It 'reports every step through the injected progress sink' {
            $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            $progress = New-HDTBuildProgress -Queue $queue

            $context = New-HDTMediaTestContext
            Invoke-HDTMediaTestBuild -Context $context -Progress $progress -WarningAction SilentlyContinue | Out-Null

            $report = @($progress.Drain())

            @($report | Where-Object { -not $_.IsComplete }).Count | Should -BeGreaterThan 5
            @($report | Where-Object { [string]::IsNullOrWhiteSpace($_.Title) }) | Should -BeNullOrEmpty
        }

        It 'reports a step count that matches the steps it actually runs' {
            $queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            $progress = New-HDTBuildProgress -Queue $queue

            $context = New-HDTMediaTestContext
            Invoke-HDTMediaTestBuild -Context $context -Progress $progress -WarningAction SilentlyContinue | Out-Null

            # THIS COMMAND'S OWN REPORTS, not the boot image's - that command
            # reports its own seventeen through the same sink, and a total that
            # counted both would be a bar that went backwards.
            $mine = @($progress.Drain() | Where-Object { -not $_.IsComplete -and $_.Total -le 20 })

            $total = @($mine | ForEach-Object { $_.Total } | Sort-Object -Unique)
            @($total).Count | Should -BeGreaterThan 0

            $highest = @($mine | ForEach-Object { $_.Step } | Sort-Object)[-1]
            $highest | Should -BeLessOrEqual ([int] $total[-1])
        }
    }

    Context 'the projection reaches the disc' {

        BeforeAll {
            $script:copyContext = New-HDTMediaTestContext
            Invoke-HDTMediaTestBuild -Context $script:copyContext -WarningAction SilentlyContinue | Out-Null

            $script:copied = @($script:copyContext.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' } |
                    ForEach-Object { [string] @($_.Arguments)[1] })
        }

        It 'copies rules.yaml to \Share, because a disc without the marker cannot be found' {
            $script:copied | Should -Contain ($script:projectedShare + '\rules.yaml')
        }

        It 'copies Control to \Share\Control' {
            @($script:copied | Where-Object { $_ -like ($script:projectedShare + '\Control\*') }) |
                Should -Not -BeNullOrEmpty
        }

        It 'copies every folder the profile names, recursing with Copy-HDTContentTree' {
            # A recursion that stopped at the folder would copy nothing under it.
            $script:copied | Should -Contain ($script:projectedShare + '\Applications\TightVNC\app.yaml')
            $script:copied | Should -Contain ($script:projectedShare + '\OperatingSystems\Win11\os.yaml')
            $script:copied | Should -Contain ($script:projectedShare + '\Drivers\WinPE\Dell WinPE 11 x64\oem0.inf')
            $script:copied | Should -Contain ($script:projectedShare + '\TaskSequences\PNP-TEST\sequence.yaml')
            $script:copied | Should -Contain ($script:projectedShare + '\Scripts\UI\HDTWizard.xaml')
        }

        It 'never copies bootstrap-rules.yaml' {
            @($script:copied | Where-Object { $_ -like '*\Share\bootstrap-rules.yaml' }) | Should -BeNullOrEmpty
        }

        It 'never copies Control share-credential.json' {
            @($script:copied | Where-Object { $_ -like '*share-credential.json' }) | Should -BeNullOrEmpty
        }

        It 'never leaves a Boot folder inside \Share' {
            $removed = @($script:copyContext.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'RemoveItem' } |
                    ForEach-Object { [string] @($_.Arguments)[0] })

            $removed | Should -Contain ($script:projectedShare + '\Boot')
        }

        It 'never copies Logs or Captures' {
            @($script:copied | Where-Object { $_ -like ($script:projectedShare + '\Logs\*') }) | Should -BeNullOrEmpty
            @($script:copied | Where-Object { $_ -like ($script:projectedShare + '\Captures\*') }) | Should -BeNullOrEmpty
        }

        It 'copies no folder the profile does not name' {
            $context = New-HDTMediaTestContext -ExtraFile @{
                ($script:workspaceRoot + '\Media\LAB-DISC\media.yaml') = (New-HDTMediaTestDocument -SelectionProfile 'two-vendor')
            }

            Invoke-HDTMediaTestBuild -Context $context -WarningAction SilentlyContinue | Out-Null

            $copied = @($context.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' } |
                    ForEach-Object { [string] @($_.Arguments)[1] })

            $copied | Should -Contain ($script:projectedShare + '\Applications\TightVNC\app.yaml')
            @($copied | Where-Object { $_ -like ($script:projectedShare + '\OperatingSystems\*') }) | Should -BeNullOrEmpty
            @($copied | Where-Object { $_ -like ($script:projectedShare + '\TaskSequences\*') }) | Should -BeNullOrEmpty
        }
    }

    Context 'the provider swap' {

        BeforeAll {
            $script:swapContext = New-HDTMediaTestContext
            Invoke-HDTMediaTestBuild -Context $script:swapContext -WarningAction SilentlyContinue | Out-Null

            # THE STAGING TREE IS GONE BY NOW - the build removes it in a
            # finally, which is the point of the 'scratch' context below. So the
            # projected document is read out of the journal, where the write is
            # recorded with its content.
            $script:projectedWorkspace = [string] @($script:swapContext.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'WriteAllText' -and
                        [string] @($_.Arguments)[0] -eq ($script:projectedShare + '\workspace.yaml') } |
                    ForEach-Object { [string] @($_.Arguments)[1] })[0]
        }

        It 'writes a projected workspace.yaml carrying deployRoot \Share' {
            $script:projectedWorkspace | Should -Match '(?m)^deployRoot:\s*\\Share\s*$'
            $script:projectedWorkspace | Should -Not -Match 'server\\HDTShare'
        }

        It 'writes no credential block into the projected workspace.yaml' {
            $script:projectedWorkspace | Should -Not -Match '(?m)^credential:'
            $script:projectedWorkspace | Should -Not -Match 'svc-hdt-deploy'
        }

        It 'builds the boot image against the PROJECTED share and not the original one' {
            # THE DECISION WORTH BEING EXPLICIT ABOUT. Copying the share's own
            # Boot\HDTPE_x64.wim would put an Smb image on the disc, because the
            # image derives its provider from the workspace.yaml it was built
            # against - and every real share's deployRoot is a UNC path.
            $bootstrap = @($script:swapContext.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'WriteAllText' -and
                        [string] @($_.Arguments)[0] -like '*\bootstrap.json' })

            @($bootstrap).Count | Should -Be 1

            $document = ConvertFrom-Json -InputObject ([string] @($bootstrap)[0].Arguments[1])
            $document.provider | Should -BeExactly 'Local'
            $document.deployRoot | Should -BeExactly '\Share'
        }

        It 'passes -SkipIso to Update-HDTBootImage, because this command burns the ISO' {
            # ONE NewIso IN THE WHOLE BUILD. Without -SkipIso the boot image
            # would burn a debugging ISO nobody asked for, in the middle of
            # building the one that was asked for.
            @($script:swapContext.Boot.Operations | Where-Object { $_.Operation -eq 'NewIso' }).Count |
                Should -Be 1
        }

        It 'puts the built wim at sources boot.wim on the media tree' {
            # OFF THE JOURNAL, because the staging tree is gone by now - the
            # build removes it in a finally, which the 'scratch' context below
            # is about.
            @($script:swapContext.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'MoveItem' -and
                        [string] @($_.Arguments)[1] -eq ($script:mediaSources + '\boot.wim') }).Count |
                Should -Be 1
        }

        It 'removes the projected share Boot folder after moving the wim out of it' {
            $names = Get-HDTMediaTestMilestone -Journal $script:swapContext.Journal
            [array]::IndexOf($names, 'MoveWimToMedia') |
                Should -BeLessThan ([array]::IndexOf($names, 'RemoveProjectedBoot'))
        }
    }

    Context 'the media tree' {

        BeforeAll {
            $script:treeContext = New-HDTMediaTestContext
            Invoke-HDTMediaTestBuild -Context $script:treeContext -WarningAction SilentlyContinue | Out-Null
        }

        It 'copies the ADK WinPE Media tree, resolved through Get-HDTAdkPath -Asset WinPeMedia' {
            $copied = @($script:treeContext.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' -and
                        [string] @($_.Arguments)[1] -like ($script:mediaPath + '\*') -and
                        [string] @($_.Arguments)[0] -like ($script:adkRoot + '*') })

            @($copied).Count | Should -BeGreaterThan 0
        }

        It 'creates sources on the media tree, which the ADK template has not got' {
            @($script:treeContext.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CreateDirectory' -and
                        [string] @($_.Arguments)[0] -eq $script:mediaSources }) | Should -Not -BeNullOrEmpty
        }

        It 'resolves the ADK through the INJECTED registry and filesystem, not this machine' {
            @($script:treeContext.Registry.Operations |
                    Where-Object { $_.Operation -eq 'GetValue' }) | Should -Not -BeNullOrEmpty
        }

        It 'reads no literal ADK path anywhere' {
            # Every path this build touched came from the fixture or from a
            # parameter. A hard-coded 'C:\Program Files (x86)\Windows Kits' would
            # be a build that works on one laptop.
            $source = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot `
                    -ChildPath 'src/Hephaestus/Public/Update-HDTMediaContent.ps1') -Raw

            $source | Should -Not -Match 'Windows Kits'
            $source | Should -Not -Match 'Program Files'
        }
    }

    Context 'the burn' {

        BeforeAll {
            $script:burnContext = New-HDTMediaTestContext
            Invoke-HDTMediaTestBuild -Context $script:burnContext -WarningAction SilentlyContinue | Out-Null

            $script:isoCall = @($script:burnContext.Boot.Operations | Where-Object { $_.Operation -eq 'NewIso' })
        }

        It 'calls New-HDTBootIso once, with the media tree and the media output path' {
            # ASSERTED OFF THE FAKE BOOT IMAGE SERVICE'S JOURNAL, which is only
            # possible if the fake got there. New-HDTBootIso's own service
            # parameters are [AllowNull()] and fall back to the real adapters,
            # so omitting one is SILENT - it shells out to the real oscdimg.
            @($script:isoCall).Count | Should -Be 1

            [string] @($script:isoCall)[0].Arguments[0] | Should -BeExactly $script:mediaPath
        }

        It 'passes -NoPromptForKey, because a VM nobody is standing at cannot press a key' {
            $argument = @(@($script:isoCall)[0].Arguments[2]) -join ' '

            $argument | Should -Match 'efisys_noprompt\.bin'
        }

        It 'stages the boot bits somewhere with no space in the path' {
            $argument = @(@($script:isoCall)[0].Arguments[2]) -join ' '

            $argument | Should -Match ([regex]::Escape($script:bitPath))
            $script:bitPath | Should -Not -Match '\s'
        }

        It 'writes media.manifest.json beside the media document, last' {
            $script:burnContext.FileSystem.TestPath($script:manifestPath) | Should -BeTrue

            $manifest = ConvertFrom-Json -InputObject ([string] $script:burnContext.FileSystem.ReadAllText($script:manifestPath))
            $manifest.mediaId | Should -BeExactly 'LAB-DISC'
            $manifest.provider | Should -BeExactly 'Local'
            $manifest.deployRoot | Should -BeExactly '\Share'
            @($manifest.excluded | ForEach-Object { $_.source }) | Should -Contain 'bootstrap-rules.yaml'
        }
    }

    Context 'the warnings, which are the point of building on a workstation' {

        It 'warns naming a folder the profile names that the share has not got' {
            $context = New-HDTMediaTestContext -ExtraFile @{
                ($script:workspaceRoot + '\Media\LAB-DISC\media.yaml') = (New-HDTMediaTestDocument -SelectionProfile 'missing-folder')
            }

            $warning = @()
            Invoke-HDTMediaTestBuild -Context $context -WarningVariable warning -WarningAction SilentlyContinue | Out-Null

            ($warning -join ' ') | Should -Match 'Lenovo WinPE 11 x64'
        }

        It 'warns naming both applications when a dependency is not on the disc' {
            # 2026-09-03: TightVNC without the Acrobat its app.yaml names, and
            # the deployment reached step 11 of 15 before refusing.
            $context = New-HDTMediaTestContext -ExtraFile @{
                ($script:workspaceRoot + '\Media\LAB-DISC\media.yaml') = (New-HDTMediaTestDocument -SelectionProfile 'two-vendor')
            }

            $warning = @()
            Invoke-HDTMediaTestBuild -Context $context -WarningVariable warning -WarningAction SilentlyContinue | Out-Null

            ($warning -join ' ') | Should -Match 'TightVNC'
            ($warning -join ' ') | Should -Match 'Acrobat'
        }

        It 'builds the disc anyway after either warning, because the profile is the administrator statement of intent' {
            $context = New-HDTMediaTestContext -ExtraFile @{
                ($script:workspaceRoot + '\Media\LAB-DISC\media.yaml') = (New-HDTMediaTestDocument -SelectionProfile 'two-vendor')
            }

            $result = Invoke-HDTMediaTestBuild -Context $context -WarningAction SilentlyContinue

            $result.IsoPath | Should -BeExactly $script:outputPath
            $context.FileSystem.TestPath($script:outputPath) | Should -BeTrue
            @($result.Warning) | Should -Not -BeNullOrEmpty
        }

        It 'does not add the missing dependency' {
            $context = New-HDTMediaTestContext -ExtraFile @{
                ($script:workspaceRoot + '\Media\LAB-DISC\media.yaml') = (New-HDTMediaTestDocument -SelectionProfile 'two-vendor')
            }

            Invoke-HDTMediaTestBuild -Context $context -WarningAction SilentlyContinue | Out-Null

            $copied = @($context.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' } |
                    ForEach-Object { [string] @($_.Arguments)[1] })

            @($copied | Where-Object { $_ -like '*\Applications\Acrobat\*' }) | Should -BeNullOrEmpty
        }
    }

    Context 'the refusals' {

        It 'refuses a media id the share has not got' {
            $context = New-HDTMediaTestContext

            { Invoke-HDTMediaTestBuild -Context $context -Argument @{ Id = 'NO-SUCH-DISC' } } |
                Should -Throw -ExpectedMessage '*NO-SUCH-DISC*'
        }

        It 'refuses a media definition whose enabled is false, naming Set-HDTMedia' {
            $context = New-HDTMediaTestContext -ExtraFile @{
                ($script:workspaceRoot + '\Media\LAB-DISC\media.yaml') = (New-HDTMediaTestDocument -Enabled 'false')
            }

            { Invoke-HDTMediaTestBuild -Context $context } | Should -Throw -ExpectedMessage '*Set-HDTMedia*'
        }

        It 'refuses a selection profile the share has not got' {
            $context = New-HDTMediaTestContext -ExtraFile @{
                ($script:workspaceRoot + '\Media\LAB-DISC\media.yaml') = (New-HDTMediaTestDocument -SelectionProfile 'no-such-profile')
            }

            { Invoke-HDTMediaTestBuild -Context $context } | Should -Throw -ExpectedMessage '*no-such-profile*'
        }

        It 'refuses when the workspace has no rules.yaml, saying the disc would be invisible' {
            $context = New-HDTMediaTestContext -Without @(($script:workspaceRoot + '\rules.yaml'))

            { Invoke-HDTMediaTestBuild -Context $context } | Should -Throw -ExpectedMessage '*rules.yaml*'
        }

        It 'declares SupportsShouldProcess and writes nothing under -WhatIf' {
            (Get-Command -Name 'Update-HDTMediaContent' -Module 'Hephaestus').Parameters.ContainsKey('WhatIf') |
                Should -BeTrue

            $context = New-HDTMediaTestContext
            Invoke-HDTMediaTestBuild -Context $context -Argument @{ WhatIf = $true } -WarningAction SilentlyContinue | Out-Null

            @($context.Journal | Where-Object {
                    $_.Operation -in @('WriteAllText', 'CopyItem', 'MoveItem', 'RemoveItem', 'CreateDirectory')
                }) | Should -BeNullOrEmpty

            @($context.Boot.GetOperationName()) | Should -Not -Contain 'NewIso'
        }
    }

    Context 'nothing real is reached' {

        It 'runs to completion with a workspace root on a drive this session has not mounted' {
            (Test-Path -LiteralPath 'X:\') | Should -BeFalse

            $context = New-HDTMediaTestContext
            $result = Invoke-HDTMediaTestBuild -Context $context -WarningAction SilentlyContinue

            $result.IsoPath | Should -BeExactly $script:outputPath
        }

        It 'burns through the injected boot image service, so no oscdimg is started' {
            $context = New-HDTMediaTestContext
            Invoke-HDTMediaTestBuild -Context $context -WarningAction SilentlyContinue | Out-Null

            @($context.Boot.GetOperationName()) | Should -Contain 'NewIso'
        }

        It 'resolves every ADK asset through the injected registry, so no ADK need be installed' {
            $context = New-HDTMediaTestContext
            Invoke-HDTMediaTestBuild -Context $context -WarningAction SilentlyContinue | Out-Null

            @($context.Registry.GetOperationName()) | Should -Not -BeNullOrEmpty
        }

        It 'passes its injected services on to Update-HDTBootImage, New-HDTBootIso and Get-HDTAdkPath' {
            # THE ASSERTION THAT A DROPPED SERVICE CANNOT HIDE. All three of
            # these appear on the ONE shared journal, which is only possible if
            # every command in the chain got the fakes rather than defaulting to
            # the real adapter.
            $context = New-HDTMediaTestContext
            Invoke-HDTMediaTestBuild -Context $context -WarningAction SilentlyContinue | Out-Null

            $service = @($context.Journal | ForEach-Object { [string] $_.Service } | Sort-Object -Unique)

            $service | Should -Contain 'FileSystem'
            $service | Should -Contain 'RegistryService'
            $service | Should -Contain 'BootImageService'
        }
    }

    Context 'the scratch' {

        It 'stages under a directory it created in this run' {
            $context = New-HDTMediaTestContext
            Invoke-HDTMediaTestBuild -Context $context -WarningAction SilentlyContinue | Out-Null

            $created = @($context.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CreateDirectory' } |
                    ForEach-Object { [string] @($_.Arguments)[0] })

            $created | Should -Contain $script:mediaPath
        }

        It 'removes its own staging directory in a finally, even when the build throws' {
            # THE BURN FAILS AND THE STAGING STILL GOES. A build that left a
            # multi-gigabyte tree behind on every failure fills the disk that
            # the next attempt needs.
            $journal = [System.Collections.ArrayList]::new()
            $fs = New-HDTFakeFileSystem -File (New-HDTMediaTestSeed) -Journal $journal
            $registry = New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' = @{ KitsRoot10 = $script:kitsRoot10 }
            } -Journal $journal
            $boot = New-HDTFakeBootImageService -FileSystem $fs -Journal $journal `
                -Failure @{ NewIso = 'oscdimg exited with 1.' }

            $context = [pscustomobject] @{
                Journal = $journal; FileSystem = $fs; Registry = $registry; Boot = $boot
                Clock = (New-HDTFakeClock -UtcNow ([datetime]::new(2026, 9, 3, 9, 14, 22, [System.DateTimeKind]::Utc)))
            }

            { Invoke-HDTMediaTestBuild -Context $context -WarningAction SilentlyContinue } | Should -Throw

            $removed = @($journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'RemoveItem' } |
                    ForEach-Object { [string] @($_.Arguments)[0] })

            $removed | Should -Contain $script:scratchPath
        }

        It 'never removes anything it did not create' {
            $context = New-HDTMediaTestContext
            Invoke-HDTMediaTestBuild -Context $context -WarningAction SilentlyContinue | Out-Null

            $removed = @($context.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'RemoveItem' } |
                    ForEach-Object { [string] @($_.Arguments)[0] })

            foreach ($path in $removed) {
                # Everything removed is under the scratch this run created, or is
                # the output ISO this build is replacing.
                ($path.StartsWith($script:scratchPath, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $path -eq $script:outputPath -or $path -eq $script:stagedIso) |
                    Should -BeTrue -Because ("'{0}' is outside the scratch this run created" -f $path)
            }
        }
    }

    Context 'the log, which is read once at the worst possible moment' {

        BeforeAll {
            $context = New-HDTMediaTestContext
            $script:information = @()
            Invoke-HDTMediaTestBuild -Context $context -InformationVariable information -WarningAction SilentlyContinue | Out-Null
            $script:information = @($information | ForEach-Object { [string] $_ })
            $script:logText = ($script:information -join [System.Environment]::NewLine)
        }

        It 'logs every projected folder and the profile row it came from' {
            foreach ($folder in @('Applications', 'OperatingSystems', 'Drivers', 'TaskSequences', 'Scripts')) {
                $script:logText | Should -Match ([regex]::Escape($folder))
            }

            $script:logText | Should -Match 'everything'
        }

        It 'logs every refused artifact and why' {
            $script:logText | Should -Match 'bootstrap-rules\.yaml'
            $script:logText | Should -Match 'share-credential\.json'
            $script:logText | Should -Match 'boot image'
        }

        It 'logs the boot image provider and deployRoot' {
            $script:logText | Should -Match 'Local'
            $script:logText | Should -Match '\\Share'
        }

        It 'logs the ISO path, its size and its SHA256' {
            $script:logText | Should -Match ([regex]::Escape($script:outputPath))
            $script:logText | Should -Match 'SHA256|sha256'
        }
    }
}
