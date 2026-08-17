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

    Context 'the content provider seam' {

        It 'runs unchanged when the catalog has no content provider' {
            # The compatibility half: everything above this Context runs without
            # one, and this says so on purpose.
            $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1 })

            $result = Invoke-HDTApplyImageStep -Step $step -Context $script:context

            $result.Status | Should -BeExactly 'Completed'
            [string] @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })[0].Arguments[0] |
                Should -BeExactly $script:wimPath
        }

        It 'passes the catalog content provider when the catalog carries one' {
            $content = New-HDTFakeContentProvider -Root $script:workspaceRoot
            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
                -Image $script:image -Content $content
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug
            $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $variable['HDTOSVolume'] = 'W'
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot $script:workspaceRoot `
                -Variable $variable -Service $catalog -Log $log

            Invoke-HDTApplyImageStep -Step (& $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1 })) -Context $context | Out-Null

            @($content.GetOperationName()) | Should -Be @('ResolveContent')
        }

        It 'applies the path the provider returned' {
            $content = New-HDTFakeContentProvider -Root $script:workspaceRoot -Content @{
                'OperatingSystems\Win11-LTSC-2024\sources\install.wim' = 'E:\HDTMedia\OperatingSystems\Win11-LTSC-2024\sources\install.wim'
            }
            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
                -Image $script:image -Content $content
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug
            $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $variable['HDTOSVolume'] = 'W'
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot $script:workspaceRoot `
                -Variable $variable -Service $catalog -Log $log

            Invoke-HDTApplyImageStep -Step (& $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1 })) -Context $context | Out-Null

            [string] @($script:image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })[0].Arguments[0] |
                Should -BeExactly 'E:\HDTMedia\OperatingSystems\Win11-LTSC-2024\sources\install.wim'
        }

        It 'does not ask the provider when the step names an image path directly' {
            # image: on the step is an explicit path for media too large to bring
            # into the share, and a provider must not second-guess it.
            $image = New-HDTFakeImageService -Image @{
                'D:\Captures\surface.ffu' = @([pscustomobject] @{ Index = 1; Name = 'Surface capture'; Edition = 'EnterpriseS'; SizeBytes = 1; Version = '10.0.26100.1742' })
            }
            $content = New-HDTFakeContentProvider -Root $script:workspaceRoot
            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock -Image $image -Content $content
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug
            $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $variable['HDTOSVolume'] = 'W'
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot $script:workspaceRoot `
                -Variable $variable -Service $catalog -Log $log

            $result = Invoke-HDTApplyImageStep -Step (& $script:newStep ([ordered] @{ image = 'D:\Captures\surface.ffu'; index = 1 })) -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($content.Operations).Count | Should -Be 0
        }

        It 'produces an identical operation list under Local and under Smb' {
            # DESIGN 6.2's CENTRAL CLAIM, AS AN ASSERTION: "media generation is a
            # content projection plus a provider swap, not a parallel code path."
            # The same step, the same os.yaml and the same fake image service run
            # twice - once over a Local provider rooted at C:\Share, once over an
            # Smb provider rooted at \\server\Share - and the ordered list of
            # every service call is compared. The ARGUMENTS differ, because one
            # path is a UNC; the OPERATIONS must not, because a step that could
            # tell its transport apart would be the second code path.
            $run = {
                param([string] $Root, [object] $Provider)

                $journal = [System.Collections.ArrayList]::new()

                $fileSystem = New-HDTFakeFileSystem -File @{ ($Root + '\OperatingSystems\Win11-LTSC-2024\os.yaml') = $script:catalogYaml } -Journal $journal
                $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 9, 26, [System.DateTimeKind]::Utc)) -TickMillisecond 500 -Journal $journal
                $image = New-HDTFakeImageService -Journal $journal

                $content = & $Provider $Root $fileSystem $journal

                $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Image $image -Content $content
                $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                    -FileSystem $fileSystem -Clock $clock -Level Debug

                $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                $variable['HDTOSVolume'] = 'W'

                $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot $Root `
                    -Variable $variable -Service $catalog -Log $log

                $result = Invoke-HDTApplyImageStep -Step (& $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1 })) -Context $context

                return [pscustomobject] @{
                    Status    = $result.Status
                    Operation = @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation })
                    Applied   = [string] @($image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })[0].Arguments[0]
                }
            }

            $local = & $run 'C:\Share' {
                param($Root, $FileSystem, $Journal)
                New-HDTLocalContentProvider -Root $Root -FileSystem $FileSystem -Journal $Journal
            }

            $smb = & $run '\\server\Share' {
                param($Root, $FileSystem, $Journal)
                New-HDTSmbContentProvider -Root $Root -AllowAnonymous -FileSystem $FileSystem `
                    -SmbService (New-HDTFakeSmbService) -Journal $Journal
            }

            $local.Status | Should -BeExactly 'Completed'
            $smb.Status | Should -BeExactly 'Completed'

            # The operations, in order, across every service.
            $smb.Operation | Should -Be $local.Operation
            @($local.Operation) | Should -Contain 'ContentProvider.ResolveContent'

            # And the arguments, which are the half that is allowed to differ.
            $local.Applied | Should -BeExactly 'C:\Share\OperatingSystems\Win11-LTSC-2024\sources\install.wim'
            $smb.Applied | Should -BeExactly '\\server\Share\OperatingSystems\Win11-LTSC-2024\sources\install.wim'
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

Describe 'a target that resolves to nothing' {

    # 'primary' UNSET SAYS WHY AND NAMES WHO SHOULD HAVE SET IT. A target
    # written as %HDTOSVolume% is the same situation said a different way - the
    # partition step did not publish - and it used to get "target '' is not a
    # drive letter", which describes the symptom and none of the cause.
    #
    # THE MESSAGE MATTERS MORE HERE THAN ALMOST ANYWHERE. This is the step that
    # writes 18 GB of Windows somewhere, and the refusal is what stops it
    # choosing a letter on its own.

    It 'says the volume was never published, not that the empty string is a bad letter' {
        $context = & $script:newContextFor $script:image ([ordered] @{ HDTOSVolume = '' })
        $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; target = '%HDTOSVolume%' })

        $result = Invoke-HDTApplyImageStep -Step $step -Context $context

        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*HDTOSVolume*'
        $result.Message | Should -BeLike '*publish*'
    }

    It 'still refuses a target that is genuinely not a letter' {
        $context = & $script:newContextFor $script:image $null
        $step = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; target = 'the big disk' })

        (Invoke-HDTApplyImageStep -Step $step -Context $context).Status | Should -BeExactly 'Failed'
    }
}

Describe 'the apply says how far it has got' {

    # DESIGN 11.1 DERIVES PROGRESS FROM THE LOG, and for the whole of M4 the
    # longest step in a deployment wrote two lines: one when it started and one
    # when it finished. A technician watching a machine apply 18 GB had a bar
    # that had not moved in nine minutes and no way to tell a slow disk from a
    # dead one.
    #
    # dism.exe prints a percentage as it works, which is why the adapter runs
    # the tool MDT ran rather than Expand-WindowsImage - whose progress goes to
    # PowerShell's progress STREAM, which nothing in WinPE is reading.
    #
    # THE STEP THROTTLES, THE ADAPTER DOES NOT. dism prints about a hundred
    # meter lines and every one of them would otherwise be a JSONL record and a
    # re-read of that JSONL by the display. Five points is the granularity a bar
    # on a wall is read at.
    #
    # 100% IS ALWAYS REPORTED even when it would not clear the threshold: the
    # last thing the log says about an apply should be that it finished.

    BeforeEach {
        $script:progressLine = [string[]] [System.IO.File]::ReadAllLines(
            (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/image/dism-apply-image-output.txt'))

        $script:progressFs = New-HDTFakeFileSystem -File @{ $script:catalogPath = $script:catalogYaml }
        $script:progressClock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 9, 26, [System.DateTimeKind]::Utc)) -TickMillisecond 500
        $script:progressDisplay = New-HDTFakeProgressHost

        $script:newProgressContext = {
            param([object] $ImageService)

            $catalog = New-HDTServiceCatalog -FileSystem $script:progressFs -Clock $script:progressClock `
                -Disk (New-HDTFakeDiskService) -Image $ImageService -Progress $script:progressDisplay

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:progressFs -Clock $script:progressClock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'

            return (New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot $script:workspaceRoot `
                    -Variable $live -Service $catalog -Log $log)
        }

        $script:progressStep = & $script:newStep ([ordered] @{ os = 'Win11-LTSC-2024'; index = 1 })
    }

    It 'writes a step.progress record every five points, and one at a hundred' {
        # THE CAPTURED RUN JUMPS 85 TO 100 and this expectation says so rather
        # than smoothing it: dism stops printing while it applies the last of
        # the image and then prints the solid bar. A step that only reported on
        # a five-point stride would have said 85% and then nothing at all about
        # an apply that finished - which is why 100 is reported unconditionally.
        $context = & $script:newProgressContext (New-HDTFakeImageService -ApplyOutput $script:progressLine)

        (Invoke-HDTApplyImageStep -Step $script:progressStep -Context $context).Status | Should -BeExactly 'Completed'

        $percent = @(Get-HDTLogRecord -FileSystem $script:progressFs -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress' |
                ForEach-Object { [int] $_.data.percent })

        $percent | Should -Be @(5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 100)
    }

    It 'names the image and the target in the progress record' {
        $context = & $script:newProgressContext (New-HDTFakeImageService -ApplyOutput $script:progressLine)

        Invoke-HDTApplyImageStep -Step $script:progressStep -Context $context | Out-Null

        $record = @(Get-HDTLogRecord -FileSystem $script:progressFs -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress')

        [string] $record[0].component | Should -BeExactly 'ApplyImage'
        [string] $record[0].data.target | Should -BeExactly 'W:\'
        [string] $record[0].data.imagePath | Should -BeLike '*install.wim'
    }

    It 'writes nothing when the tool prints no meter at all' {
        # A dism build that prints only its banner, and the reason the parser is
        # asked rather than the line count: a record per line of output would be
        # a progress bar driven by how chatty a tool is.
        $context = & $script:newProgressContext (New-HDTFakeImageService -ApplyOutput @(
                'Deployment Image Servicing and Management tool', 'Version: 10.0.26100.8521', '', 'Applying image'))

        Invoke-HDTApplyImageStep -Step $script:progressStep -Context $context | Out-Null

        @(Get-HDTLogRecord -FileSystem $script:progressFs -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress') |
            Should -BeNullOrEmpty
    }

    It 'still applies exactly one image with the same three arguments' {
        # The progress channel is an addition, not a change: what the step asks
        # the service to do is what it always asked.
        $image = New-HDTFakeImageService -ApplyOutput $script:progressLine
        $context = & $script:newProgressContext $image

        Invoke-HDTApplyImageStep -Step $script:progressStep -Context $context | Out-Null

        $apply = @($image.Operations | Where-Object { $_.Operation -eq 'ApplyImage' })

        $apply.Count | Should -Be 1
        @($apply[0].Arguments).Count | Should -Be 3
        [string] $apply[0].Arguments[2] | Should -BeExactly 'W:\'
    }

    It 'keeps the progress it made when the apply then fails' {
        # THE LAST PERCENTAGE IS THE EVIDENCE. An apply that dies at 60% died
        # somewhere different from one that never started, and the log is the
        # only place a technician can tell them apart afterwards.
        $image = New-HDTFakeImageService -ApplyOutput $script:progressLine[0..80] `
            -Failure @{ ApplyImage = 'Error: 0x80070070 - There is not enough space on the disk.' }
        $context = & $script:newProgressContext $image

        $result = Invoke-HDTApplyImageStep -Step $script:progressStep -Context $context

        $result.Status | Should -BeExactly 'Failed'

        $percent = @(Get-HDTLogRecord -FileSystem $script:progressFs -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress' |
                ForEach-Object { [int] $_.data.percent })

        $percent | Should -Not -BeNullOrEmpty
        $percent[-1] | Should -BeLessThan 100
    }

    It 'drives the progress display while the apply is still running' {
        # THE WHOLE POINT, ASSERTED END TO END: the step logs, the display reads
        # the log back, and the number on the screen is the number dism printed.
        # Nothing here is a second channel (DESIGN 11.1).
        $context = & $script:newProgressContext (New-HDTFakeImageService -ApplyOutput $script:progressLine)

        Invoke-HDTApplyImageStep -Step $script:progressStep -Context $context | Out-Null

        # THE DISPLAY THE STEP ACTUALLY DROVE, read off the context rather than
        # off a variable a test believes is the same object.
        # IProgressHost's fake records operation NAMES, not operation objects.
        $display = $context.Service.Progress
        $update = @($display.Operations | Where-Object { $_ -eq 'Update' })

        $update.Count | Should -BeGreaterThan 1 -Because 'a display updated only at the end is the bar that never moves'
        [int] $display.LastProgress.StepPercent | Should -Be 100
    }
}
