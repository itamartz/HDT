# DESIGN 9.2: apply the image, by an index that was RESOLVED rather than guessed.
#
# Two refusals meet here. The catalog's - two images matching one request is an
# HDTAmbiguousImageError, not a coin toss (04-02) - and this step's own: a
# `target` that resolves to nothing is a failure naming the variable, NEVER a
# guess at C:. Applying 4 GB of Windows over whatever happens to be on C: is the
# second most destructive thing this toolkit could do.
#
# The apply itself is one call on the injected IImageService. SPIKES S6 measured
# 95 seconds for a 4 GB WIM over SMB, so the elapsed time is logged: it is the
# number that says whether a slow deployment was the network or the disk.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:workspaceRoot = 'Z:\Deploy'
    $script:catalogPath = 'Z:\Deploy\OperatingSystems\Win11-LTSC-2024\os.yaml'
    $script:wimPath = 'Z:\Deploy\OperatingSystems\Win11-LTSC-2024\sources\install.wim'

    # The real captured indices of the staged Windows 11 LTSC media.
    $script:catalogYaml = @'
schemaVersion: 1
id: Win11-LTSC-2024
name: Windows 11 Enterprise LTSC 2024
type: wim
architecture: x64
sourcePath: sources\install.wim
importedUtc: '2026-08-13T09:14:22.0000000Z'
defaultIndex: 1
images:
  - index: 1
    name: Windows 11 Enterprise LTSC
    edition: EnterpriseS
    sizeBytes: 18356832906
    version: 10.0.26100.1742
  - index: 2
    name: Windows 11 Enterprise N LTSC
    edition: EnterpriseSN
    sizeBytes: 17928774068
    version: 10.0.26100.1742
'@

    # The real Server 2025 shape: two images sharing the edition id
    # ServerStandard, which is what makes an edition-only request ambiguous.
    $script:serverYaml = @'
schemaVersion: 1
id: WS2025-Std
name: Windows Server 2025 Standard
type: wim
architecture: x64
sourcePath: sources\install.wim
importedUtc: '2026-08-13T09:14:22.0000000Z'
images:
  - index: 1
    name: Windows Server 2025 Standard
    edition: ServerStandard
    sizeBytes: 8000000000
    version: 10.0.26100.1742
  - index: 2
    name: Windows Server 2025 Standard (Desktop Experience)
    edition: ServerStandard
    sizeBytes: 20000000000
    version: 10.0.26100.1742
'@

    $script:newStep = {
        param([System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index = 3; Name = 'Apply OS'; Type = 'ApplyImage'; TimeoutMinutes = 60; Log = $null; Property = $bag
        }
    }
}

Describe 'Invoke-HDTApplyImageStep' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -File @{ $script:catalogPath = $script:catalogYaml }
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 9, 26, [System.DateTimeKind]::Utc)) -TickMillisecond 500
        $script:image = New-HDTFakeImageService
        $script:disk = New-HDTFakeDiskService

        $script:newContextFor = {
            param([object] $ImageService, [System.Collections.IDictionary] $Variable)

            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
                -Disk $script:disk -Image $ImageService

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'
            if ($null -ne $Variable) {
                foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
            }

            return (New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot $script:workspaceRoot `
                    -Variable $live -Service $catalog -Log $log)
        }

        $script:context = & $script:newContextFor $script:image $null
    }

    Context 'resolving the image' {

        It 'reads the catalog for the os id' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1 })

            $result = Invoke-HDTApplyImageStep -Step $step -Context $script:context

            $result.Status | Should -BeExactly 'Completed'
            @($script:fileSystem.Operations | Where-Object { $_.Operation -eq 'ReadAllText' } |
                    ForEach-Object { [string] $_.Arguments[0] }) | Should -Contain $script:catalogPath
        }

        It 'expands a %Var% in the os property' {
            $context = & $script:newContextFor $script:image ([ordered] @{ HDTOSImage = 'Win11-LTSC-2024' })
            $step = & $script:newStep ([ordered] @{ os = '%HDTOSImage%'; index = 1 })

            (Invoke-HDTApplyImageStep -Step $step -Context $context).Status | Should -BeExactly 'Completed'
        }

        It 'resolves the index by number' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 2 })

            Invoke-HDTApplyImageStep -Step $step -Context $script:context | Out-Null

            @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })[0].Arguments[1] | Should -Be 2
        }

        It 'resolves the index by name' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; name = 'Windows 11 Enterprise N LTSC' })

            Invoke-HDTApplyImageStep -Step $step -Context $script:context | Out-Null

            @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })[0].Arguments[1] | Should -Be 2
        }

        It 'resolves the index by edition' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; edition = 'EnterpriseSN' })

            Invoke-HDTApplyImageStep -Step $step -Context $script:context | Out-Null

            @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })[0].Arguments[1] | Should -Be 2
        }

        It 'applies the default index when none is named' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024' })

            Invoke-HDTApplyImageStep -Step $step -Context $script:context | Out-Null

            @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })[0].Arguments[1] | Should -Be 1
        }

        It 'fails naming the catalog id when no catalog exists' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-24H2-Ent'; index = 1 })

            $result = Invoke-HDTApplyImageStep -Step $step -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*Win11-24H2-Ent*'
        }

        It 'fails when neither os nor image is declared' {
            $result = Invoke-HDTApplyImageStep -Step (& $script:newStep $null) -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*os*'
        }

        It 'fails when the index does not exist' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 7 })

            $result = Invoke-HDTApplyImageStep -Step $step -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*7*'
            @($script:image.GetOperationName() | Where-Object { $_ -eq 'ApplyImage' }) | Should -BeNullOrEmpty
        }

        It 'carries HDTAmbiguousImageError in the data when two images match' {
            $script:fileSystem.SeedFile('Z:\Deploy\OperatingSystems\WS2025-Std\os.yaml', $script:serverYaml)
            $step = & $script:newStep ([ordered] @{ os = 'WS2025-Std'; edition = 'ServerStandard' })

            $result = Invoke-HDTApplyImageStep -Step $step -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            [string] $result.Data['errorId'] | Should -BeExactly 'HDTAmbiguousImageError'
        }

        It 'resolves the pair the edition alone could not' {
            # -Edition ServerStandard -Index 2 resolves where the edition alone
            # is ambiguous: each criterion is matched independently, then
            # intersected.
            $script:fileSystem.SeedFile('Z:\Deploy\OperatingSystems\WS2025-Std\os.yaml', $script:serverYaml)
            $step = & $script:newStep ([ordered] @{ os = 'WS2025-Std'; edition = 'ServerStandard'; index = 2 })

            (Invoke-HDTApplyImageStep -Step $step -Context $script:context).Status | Should -BeExactly 'Completed'
        }

        It 'accepts an explicit image path instead of a catalog id' {
            $wim = 'Z:\Media\Win11\sources\install.wim'
            $image = New-HDTFakeImageService -Image @{
                $wim = @(@{ Index = 1; Name = 'Windows 11 Enterprise LTSC'; Edition = 'EnterpriseS' })
            }

            $context = & $script:newContextFor $image $null
            $step = & $script:newStep ([ordered] @{ image = $wim; index = 1 })

            $result = Invoke-HDTApplyImageStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            [string] @($image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })[0].Arguments[0] |
                Should -BeExactly $wim
        }

        It 'reads the indices off an explicit image with the image service' {
            $wim = 'Z:\Media\Win11\sources\install.wim'
            $image = New-HDTFakeImageService -Image @{
                $wim = @(@{ Index = 1; Name = 'Windows 11 Enterprise LTSC'; Edition = 'EnterpriseS' })
            }

            $context = & $script:newContextFor $image $null
            Invoke-HDTApplyImageStep -Step (& $script:newStep ([ordered] @{ image = $wim })) -Context $context | Out-Null

            @($image.GetOperationName()) | Should -Be @('GetImageInfo', 'ApplyImage')
        }
    }

    Context 'applying' {

        It 'applies to the volume DiskPartition published' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1; target = 'primary' })

            Invoke-HDTApplyImageStep -Step $step -Context $script:context | Out-Null

            [string] @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })[0].Arguments[2] |
                Should -BeExactly 'W:\'
        }

        It 'applies to an explicit target drive letter' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1; target = 'D' })

            Invoke-HDTApplyImageStep -Step $step -Context $script:context | Out-Null

            [string] @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })[0].Arguments[2] |
                Should -BeExactly 'D:\'
        }

        It 'accepts a target written with a colon' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1; target = 'D:' })

            Invoke-HDTApplyImageStep -Step $step -Context $script:context | Out-Null

            [string] @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })[0].Arguments[2] |
                Should -BeExactly 'D:\'
        }

        It 'fails when target is primary and HDTOSVolume is unset' {
            # NEVER a guess at C:.
            $context = & $script:newContextFor $script:image $null
            $context.Variable['HDTOSVolume'] = ''

            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1; target = 'primary' })
            $result = Invoke-HDTApplyImageStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*HDTOSVolume*'
            @($script:image.GetOperationName() | Where-Object { $_ -eq 'ApplyImage' }) | Should -BeNullOrEmpty
        }

        It 'defaults the target to primary' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1 })

            Invoke-HDTApplyImageStep -Step $step -Context $script:context | Out-Null

            [string] @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })[0].Arguments[2] |
                Should -BeExactly 'W:\'
        }

        It 'calls the image service exactly once' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1 })

            Invoke-HDTApplyImageStep -Step $step -Context $script:context | Out-Null

            @($script:image.GetOperationName() | Where-Object { $_ -eq 'ApplyImage' }).Count | Should -Be 1
        }

        It 'passes the full WIM path' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1 })

            Invoke-HDTApplyImageStep -Step $step -Context $script:context | Out-Null

            [string] @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })[0].Arguments[0] |
                Should -BeExactly $script:wimPath
        }

        It 'sets HDTImageIndex' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 2 })

            Invoke-HDTApplyImageStep -Step $step -Context $script:context | Out-Null

            $script:context.Variable['HDTImageIndex'] | Should -Be 2
        }

        It 'logs a native.exec record naming the image and the index' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1 })

            Invoke-HDTApplyImageStep -Step $step -Context $script:context | Out-Null

            $record = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'native.exec')

            $record | Should -Not -BeNullOrEmpty
            @($record | ForEach-Object { [string] $_.message }) -join ' ' | Should -BeLike '*install.wim*'
            @($record | ForEach-Object { [string] $_.message }) -join ' ' | Should -BeLike '*W:\*'
        }

        It 'logs the duration on completion' {
            # SPIKES S6 measured 95 s for a 4 GB WIM over SMB. The number is what
            # says whether a slow deployment was the network or the disk.
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1 })

            $result = Invoke-HDTApplyImageStep -Step $step -Context $script:context

            $result.Data['durationMs'] | Should -BeGreaterThan 0

            $record = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'native.exec' |
                    Where-Object { $null -ne $_.data.PSObject.Properties['durationMs'] })

            $record | Should -Not -BeNullOrEmpty
        }

        It 'returns the resolved index in the result data' {
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 2 })

            (Invoke-HDTApplyImageStep -Step $step -Context $script:context).Data['index'] | Should -Be 2
        }
    }

    Context 'failure' {

        It 'returns Failed with the tool message when the apply throws' {
            $image = New-HDTFakeImageService -Failure @{
                ApplyImage = 'The system cannot find the file specified. Error: 0x80070002'
            }

            $context = & $script:newContextFor $image $null
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1 })

            $result = Invoke-HDTApplyImageStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*0x80070002*'
        }

        It 'does not rethrow' {
            $image = New-HDTFakeImageService -Failure @{ ApplyImage = 'boom' }
            $context = & $script:newContextFor $image $null
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1 })

            { Invoke-HDTApplyImageStep -Step $step -Context $context } | Should -Not -Throw
        }

        It 'returns Failed rather than throwing for a step with no properties' {
            $result = Invoke-HDTApplyImageStep -Step (& $script:newStep $null) -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Get-HDTApplyImageStepDescription' {

    It 'names the image and the index it will apply' {
        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $bag['os'] = 'Win11-LTSC-2024'
        $bag['index'] = 1

        $step = [pscustomobject] @{ Index = 3; Name = 'Apply OS'; Type = 'ApplyImage'; Property = $bag }

        $description = Get-HDTApplyImageStepDescription -Step $step

        $description | Should -BeLike '*Win11-LTSC-2024*'
        $description | Should -BeLike '*1*'
    }

    It 'describes a step that names nothing' {
        $step = [pscustomobject] @{ Index = 3; Name = 'Apply OS'; Type = 'ApplyImage'
            Property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        }

        Get-HDTApplyImageStepDescription -Step $step | Should -Not -BeNullOrEmpty
    }
}
