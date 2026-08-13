# The step that makes the machine boot from its own disk (DESIGN 9.2, SPIKES S6).
#
# SPIKES S6's FOURTH FINDING IS THE WHOLE POINT OF THE LAST CALL IN THIS FILE:
# after apply, a machine whose firmware still lists the installation media first
# simply reboots into WinPE, and the deployment appears to loop. bcdboot alone
# does not fix that; the firmware boot order does.
#
# TWO THINGS WARN AND CONTINUE RATHER THAN FAILING, and both are deliberate:
#
#   * the recovery image. An image with no WinRE still boots. Failing a whole
#     deployment because Winre.wim was missing, or because reagentc was fussy
#     about an offline target, trades a working machine for a detail nobody
#     asked for - and 04-04 is the first thing ever to run the applied image's
#     own Reagentc.exe against an offline target from inside WinPE.
#   * the firmware reorder. A machine whose firmware refuses is still deployed;
#     the technician needs to know, not to lose the build.
#
# bcdboot failing is NOT one of them. A machine with no boot files does not boot.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:winrePath = 'W:\Windows\System32\Recovery\Winre.wim'
    $script:recoveryDirectory = 'R:\Recovery\WindowsRE'

    $script:newStep = {
        param([System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index = 5; Name = 'Prepare Boot'; Type = 'ConfigureBoot'; TimeoutMinutes = 0; Log = $null; Property = $bag
        }
    }
}

Describe 'Invoke-HDTConfigureBootStep' {

    BeforeEach {
        # The applied image's own WinRE, where a real apply leaves it.
        $script:fileSystem = New-HDTFakeFileSystem -File @{ $script:winrePath = 'WIM' }
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, [System.DateTimeKind]::Utc))

        $script:newContextFor = {
            param([object] $ImageService, [System.Collections.IDictionary] $Variable)

            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock -Image $ImageService

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'
            $live['HDTSystemVolume'] = 'S'
            $live['HDTRecoveryVolume'] = 'R'
            $live['HDTIsUEFI'] = $true
            if ($null -ne $Variable) {
                foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
            }

            return (New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
                    -Variable $live -Service $catalog -Log $log)
        }

        $script:image = New-HDTFakeImageService
        $script:context = & $script:newContextFor $script:image $null
        $script:step = & $script:newStep $null
    }

    Context 'boot files' {

        It 'installs boot files from the OS volume to the system volume' {
            $result = Invoke-HDTConfigureBootStep -Step $script:step -Context $script:context

            $result.Status | Should -BeExactly 'Completed'

            $call = @($script:image.Operations | Where-Object { $_.Operation -eq 'InstallBootFile' })[0]

            [string] $call.Arguments[0] | Should -BeExactly 'W:\'
            [string] $call.Arguments[1] | Should -BeExactly 'S:'
        }

        It 'passes UEFI for a UEFI machine' {
            Invoke-HDTConfigureBootStep -Step $script:step -Context $script:context | Out-Null

            [string] @($script:image.Operations | Where-Object { $_.Operation -eq 'InstallBootFile' })[0].Arguments[2] |
                Should -BeExactly 'UEFI'
        }

        It 'passes BIOS for a BIOS machine' {
            $context = & $script:newContextFor $script:image ([ordered] @{ HDTIsUEFI = $false })

            Invoke-HDTConfigureBootStep -Step $script:step -Context $context | Out-Null

            [string] @($script:image.Operations | Where-Object { $_.Operation -eq 'InstallBootFile' })[0].Arguments[2] |
                Should -BeExactly 'BIOS'
        }

        It 'honours an explicit firmware property' {
            $step = & $script:newStep ([ordered] @{ firmware = 'BIOS' })

            Invoke-HDTConfigureBootStep -Step $step -Context $script:context | Out-Null

            [string] @($script:image.Operations | Where-Object { $_.Operation -eq 'InstallBootFile' })[0].Arguments[2] |
                Should -BeExactly 'BIOS'
        }

        It 'fails when HDTOSVolume is unset' {
            $context = & $script:newContextFor $script:image $null
            $context.Variable['HDTOSVolume'] = ''

            $result = Invoke-HDTConfigureBootStep -Step $script:step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*HDTOSVolume*'
            @($script:image.GetOperationName()) | Should -BeNullOrEmpty
        }

        It 'fails when HDTSystemVolume is unset' {
            $context = & $script:newContextFor $script:image $null
            $context.Variable['HDTSystemVolume'] = ''

            $result = Invoke-HDTConfigureBootStep -Step $script:step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*HDTSystemVolume*'
        }

        It 'returns Failed with bcdboot output when it throws' {
            # A machine with no boot files does not boot. This one does not warn.
            $image = New-HDTFakeImageService -Failure @{
                InstallBootFile = 'BFSVC: Failed to copy boot files. Last error = 0x2'
            }

            $context = & $script:newContextFor $image $null
            $result = Invoke-HDTConfigureBootStep -Step $script:step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*BFSVC*'
        }

        It 'does not set the boot order when the boot files failed' {
            $image = New-HDTFakeImageService -Failure @{ InstallBootFile = 'BFSVC: Failed' }
            $context = & $script:newContextFor $image $null

            Invoke-HDTConfigureBootStep -Step $script:step -Context $context | Out-Null

            @($image.GetOperationName() | Where-Object { $_ -eq 'SetBootOrderFirst' }) | Should -BeNullOrEmpty
        }
    }

    Context 'the recovery image' {

        It 'creates the WindowsRE directory on the recovery volume' {
            Invoke-HDTConfigureBootStep -Step $script:step -Context $script:context | Out-Null

            @($script:fileSystem.Operations | Where-Object { $_.Operation -eq 'CreateDirectory' } |
                    ForEach-Object { [string] $_.Arguments[0] }) | Should -Contain $script:recoveryDirectory
        }

        It 'copies Winre.wim out of the applied image' {
            Invoke-HDTConfigureBootStep -Step $script:step -Context $script:context | Out-Null

            $copy = @($script:fileSystem.Operations | Where-Object { $_.Operation -eq 'CopyItem' })[0]

            [string] $copy.Arguments[0] | Should -BeExactly $script:winrePath
            [string] $copy.Arguments[1] | Should -BeExactly ('{0}\Winre.wim' -f $script:recoveryDirectory)
        }

        It 'registers the recovery image after copying it' {
            # The journal order, not just the fact of both calls: registering an
            # image that is not there yet is a call that fails on metal.
            $journal = [System.Collections.ArrayList]::new()
            $script:fileSystem.Journal = $journal
            $script:image.Journal = $journal

            Invoke-HDTConfigureBootStep -Step $script:step -Context $script:context | Out-Null

            $ordered = @($journal |
                    Where-Object { @('CopyItem', 'SetRecoveryImage') -contains $_.Operation } |
                    ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation })

            $ordered | Should -Be @('FileSystem.CopyItem', 'ImageService.SetRecoveryImage')
        }

        It 'registers it against the applied image and the recovery directory' {
            Invoke-HDTConfigureBootStep -Step $script:step -Context $script:context | Out-Null

            $call = @($script:image.Operations | Where-Object { $_.Operation -eq 'SetRecoveryImage' })[0]

            [string] $call.Arguments[0] | Should -BeExactly 'W:\'
            [string] $call.Arguments[1] | Should -BeExactly $script:recoveryDirectory
        }

        It 'skips the recovery setup when there is no recovery volume' {
            $context = & $script:newContextFor $script:image $null
            $context.Variable['HDTRecoveryVolume'] = ''

            $result = Invoke-HDTConfigureBootStep -Step $script:step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($script:image.GetOperationName() | Where-Object { $_ -eq 'SetRecoveryImage' }) | Should -BeNullOrEmpty
        }

        It 'warns and continues when SetRecoveryImage throws' {
            # 04-04 is the first thing ever to run the applied image's own
            # Reagentc.exe against an offline target from inside WinPE. A machine
            # with no registered WinRE boots; a deployment that failed its last
            # step because reagentc was fussy does not.
            $image = New-HDTFakeImageService -Failure @{
                SetRecoveryImage = 'REAGENTC.EXE: Operation failed: 3bc3'
            }

            $context = & $script:newContextFor $image $null
            $result = Invoke-HDTConfigureBootStep -Step $script:step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($image.GetOperationName()) | Should -Contain 'SetBootOrderFirst'
        }

        It 'names the recovery target in that warning' {
            $image = New-HDTFakeImageService -Failure @{ SetRecoveryImage = 'REAGENTC.EXE: Operation failed: 3bc3' }
            $context = & $script:newContextFor $image $null

            Invoke-HDTConfigureBootStep -Step $script:step -Context $context | Out-Null

            $warning = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' |
                    Where-Object { $_.level -eq 'Warning' })

            @($warning | ForEach-Object { [string] $_.message }) -join ' ' | Should -BeLike '*R:\Recovery\WindowsRE*'
        }

        It 'warns and continues when Winre.wim is absent' {
            # An image with no WinRE still boots.
            $script:fileSystem.RemoveItem($script:winrePath, $false)

            $result = Invoke-HDTConfigureBootStep -Step $script:step -Context $script:context

            $result.Status | Should -BeExactly 'Completed'
            @($script:image.GetOperationName() | Where-Object { $_ -eq 'SetRecoveryImage' }) | Should -BeNullOrEmpty

            $warning = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' |
                    Where-Object { $_.level -eq 'Warning' })

            @($warning | ForEach-Object { [string] $_.message }) -join ' ' | Should -BeLike '*Winre.wim*'
        }

        It 'still sets the boot order when Winre.wim is absent' {
            $script:fileSystem.RemoveItem($script:winrePath, $false)

            Invoke-HDTConfigureBootStep -Step $script:step -Context $script:context | Out-Null

            @($script:image.GetOperationName()) | Should -Contain 'SetBootOrderFirst'
        }

        It 'skips the recovery setup when recovery is false' {
            $step = & $script:newStep ([ordered] @{ recovery = $false })

            Invoke-HDTConfigureBootStep -Step $step -Context $script:context | Out-Null

            @($script:image.GetOperationName() | Where-Object { $_ -eq 'SetRecoveryImage' }) | Should -BeNullOrEmpty
            @($script:fileSystem.GetOperationName() | Where-Object { $_ -eq 'CopyItem' }) | Should -BeNullOrEmpty
        }
    }

    Context 'the boot order' {

        It 'puts the Windows Boot Manager first in the firmware order' {
            # SPIKES S6's fourth finding: without it the machine reboots into the
            # installation media and the deployment appears to loop.
            Invoke-HDTConfigureBootStep -Step $script:step -Context $script:context | Out-Null

            @($script:image.GetOperationName() | Where-Object { $_ -eq 'SetBootOrderFirst' }).Count | Should -Be 1
        }

        It 'does so after installing the boot files' {
            Invoke-HDTConfigureBootStep -Step $script:step -Context $script:context | Out-Null

            $names = @($script:image.GetOperationName())

            $names.IndexOf('InstallBootFile') | Should -BeLessThan $names.IndexOf('SetBootOrderFirst')
        }

        It 'skips it when setBootOrder is false' {
            $step = & $script:newStep ([ordered] @{ setBootOrder = $false })

            Invoke-HDTConfigureBootStep -Step $step -Context $script:context | Out-Null

            @($script:image.GetOperationName() | Where-Object { $_ -eq 'SetBootOrderFirst' }) | Should -BeNullOrEmpty
        }

        It 'warns and continues when the firmware reorder fails' {
            # A machine whose firmware refuses is still deployed; the technician
            # needs to know, not to lose the build.
            $image = New-HDTFakeImageService -Failure @{
                SetBootOrderFirst = "The boot configuration data store could not be opened."
            }

            $context = & $script:newContextFor $image $null
            $result = Invoke-HDTConfigureBootStep -Step $script:step -Context $context

            $result.Status | Should -BeExactly 'Completed'

            $warning = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' |
                    Where-Object { $_.level -eq 'Warning' })

            @($warning | ForEach-Object { [string] $_.message }) -join ' ' | Should -BeLike '*boot order*'
        }

        It 'says in that warning that the media must be removed or demoted' {
            $image = New-HDTFakeImageService -Failure @{ SetBootOrderFirst = 'refused' }
            $context = & $script:newContextFor $image $null

            Invoke-HDTConfigureBootStep -Step $script:step -Context $context | Out-Null

            $warning = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' |
                    Where-Object { $_.level -eq 'Warning' })

            @($warning | ForEach-Object { [string] $_.message }) -join ' ' | Should -BeLike '*media*'
        }
    }

    Context 'the step contract' {

        It 'returns Failed rather than throwing for a step with no properties' {
            $context = & $script:newContextFor $script:image $null
            foreach ($name in @('HDTOSVolume', 'HDTSystemVolume', 'HDTRecoveryVolume')) {
                $context.Variable[$name] = ''
            }

            $result = Invoke-HDTConfigureBootStep -Step (& $script:newStep $null) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Not -BeNullOrEmpty
        }

        It 'does not rethrow' {
            $image = New-HDTFakeImageService -Failure @{ InstallBootFile = 'boom' }
            $context = & $script:newContextFor $image $null

            { Invoke-HDTConfigureBootStep -Step $script:step -Context $context } | Should -Not -Throw
        }
    }
}

Describe 'Get-HDTConfigureBootStepDescription' {

    It 'says what it will make bootable' {
        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $bag['firmware'] = 'UEFI'

        $step = [pscustomobject] @{ Index = 5; Name = 'Prepare Boot'; Type = 'ConfigureBoot'; Property = $bag }

        Get-HDTConfigureBootStepDescription -Step $step | Should -BeLike '*UEFI*'
    }

    It 'describes a step that names nothing' {
        $step = [pscustomobject] @{ Index = 5; Name = 'Prepare Boot'; Type = 'ConfigureBoot'
            Property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        }

        Get-HDTConfigureBootStepDescription -Step $step | Should -Not -BeNullOrEmpty
    }
}
