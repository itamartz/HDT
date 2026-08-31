# THE STEP THAT GETS A SYSPREPPED MACHINE BACK INTO WinPE.
#
# ONE FIRMWARE-ORDER SWITCH CANNOT SERVE TWO RESTARTS THAT WANT OPPOSITE THINGS,
# which is the defect reference.yaml carried in its own header. A reference build
# restarts once into WINDOWS - the only way applications get installed and
# Sysprep ever runs - and once into WinPE, to capture. ConfigureBoot's
# setBootOrder picks one and ruins the other, measured on 2026-08-31: with it
# false the machine went straight back into WinPE at restart 1 and the run
# stopped at step 8 of 12.
#
# SO THE MACHINE IS GIVEN A LOCAL WinPE AND THE WINDOWS BOOT MANAGER HANDS IT ONE
# BOOT. The firmware order is left alone entirely, so restart 1 still reaches
# Windows. That is MDT's answer (LTIApply.wsf /PE /STAGE and /PE /BCD, driven by
# ZTIBCDUtility.vbs); PSD has none at all.
#
# THREE ACTIONS, WHICH ARE MDT'S OWN THREE HALVES, AND THE SPLIT IS WHAT MAKES
# THE FAIL-SAFE RULE ENFORCEABLE:
#
#   stage    copy the boot image and boot.sdi onto the local disk
#   arm      create the ramdisk entry and point /bootsequence at it
#   remove   delete the entry and the staged files
#
# NOTHING IS GENERALIZED UNTIL WE KNOW IT CAN COME BACK. Both stage and arm run
# BEFORE Sysprep, and both FAIL the step rather than warning, because a machine
# sealed by sysprep that cannot reach WinPE is stranded - there is no leg left
# that could fix it. remove is the mirror image and warns instead: it runs after
# the capture boot has already happened, so a cleanup that fails costs nothing
# anybody needs.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:entryId = '{7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}'
    $script:sourceWim = 'Z:\Deploy\Boot\HDTPE_x64.wim'
    $script:sourceSdi = 'C:\Windows\Boot\DVD\EFI\boot.sdi'
    $script:stagedWim = 'C:\HDT\Boot\boot.wim'
    $script:stagedSdi = 'C:\HDT\Boot\boot.sdi'

    $script:newStep = {
        param([System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index = 9; Name = 'Boot into WinPE'; Type = 'BootToWinPE'; TimeoutMinutes = 0; Log = $null; Property = $bag
        }
    }
}

Describe 'Invoke-HDTBootToWinPEStep' {

    BeforeEach {
        # A full-OS leg: the boot image is on the share and Windows carries its
        # own boot.sdi, which is where this takes one from.
        $script:file = @{}
        $script:file[$script:sourceWim] = 'WIM'
        $script:file[$script:sourceSdi] = 'SDI'

        $script:fileSystem = New-HDTFakeFileSystem -File $script:file
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 31, 2, 0, 0, [System.DateTimeKind]::Utc))
        $script:image = New-HDTFakeImageService

        # THE RUNNING SYSTEM DRIVE, NOT %HDTOSVolume%. That variable carries the
        # WinPE letter (W:) across the reboot in state.json, and bcdedit resolves
        # a drive letter to a partition at the moment it runs - so a full-OS leg
        # that used it would write a BCD entry naming a volume that is not there.
        $script:environment = New-HDTFakeEnvironmentProvider -Variable @{
            SystemDrive = 'C:'
            SystemRoot  = 'C:\Windows'
        }

        $script:newContext = {
            param([string] $Phase, [object] $ImageService, [object] $FileSystem,
                [System.Collections.IDictionary] $Variable)

            if ($null -eq $ImageService) { $ImageService = $script:image }
            if ($null -eq $FileSystem) { $FileSystem = $script:fileSystem }

            $catalog = New-HDTServiceCatalog -FileSystem $FileSystem -Clock $script:clock `
                -Image $ImageService -Environment $script:environment

            $log = New-HDTLogContext -RunId 'run-0001' -Phase $Phase -LogPath 'C:\HDT\Logs' `
                -FileSystem $FileSystem -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'
            $live['HDTSystemVolume'] = 'S'
            $live['HDTIsUEFI'] = $true
            if ($null -ne $Variable) {
                foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
            }

            return (New-HDTExecutionContext -RunId 'run-0001' -Phase $Phase -WorkspaceRoot 'Z:\Deploy' `
                    -Variable $live -Service $catalog -Log $log)
        }

        $script:context = & $script:newContext 'FullOS' $null $null $null
    }

    Context 'stage' {

        It 'copies the share boot image onto the local disk' {
            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'stage' }) -Context $script:context

            $result.Status | Should -BeExactly 'Completed'
            $script:fileSystem.TestPath($script:stagedWim) | Should -BeTrue
        }

        It 'stages boot.sdi from the running Windows beside it' {
            $null = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'stage' }) -Context $script:context

            $script:fileSystem.TestPath($script:stagedSdi) | Should -BeTrue
        }

        # UNDER \HDT, WHICH IS THE ONLY REASON THE CAPTURE STAYS CLEAN.
        # Templates\Capture\wimscript.ini already excludes \HDT as a tree, so a
        # 500 MB WinPE staged there cannot travel inside the captured image.
        It 'stages inside the tree the capture exclusion list already names' {
            $null = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'stage' }) -Context $script:context

            $result = @($script:fileSystem.GetOperationName())
            $result | Should -Contain 'CreateDirectory'
            $script:stagedWim | Should -BeLike 'C:\HDT\*'
        }

        It 'reads a boot image named by the step rather than only the default' {
            $script:fileSystem = New-HDTFakeFileSystem -File @{
                'Z:\Deploy\Boot\HDTPE_wiz_x64.wim' = 'WIM'
                $script:sourceSdi                  = 'SDI'
            }
            $context = & $script:newContext 'FullOS' $null $script:fileSystem $null

            $result = Invoke-HDTBootToWinPEStep -Context $context `
                -Step (& $script:newStep @{ action = 'stage'; bootImage = 'HDTPE_wiz_x64' })

            $result.Status | Should -BeExactly 'Completed'
        }

        It 'touches no bcdedit at all - staging arms nothing' {
            $null = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'stage' }) -Context $script:context

            @($script:image.GetOperationName()) | Should -Be @()
        }

        # THE FAIL-SAFE RULE, AND IT IS THE WHOLE REASON stage IS ITS OWN ACTION.
        # This step sits BEFORE Sysprep. A machine sealed by sysprep that cannot
        # reach WinPE is stranded, so a share with no boot image on it has to
        # stop the sequence here, while the installation is still bootable.
        It 'fails when the share carries no boot image' {
            $script:fileSystem = New-HDTFakeFileSystem -File @{ $script:sourceSdi = 'SDI' }
            $context = & $script:newContext 'FullOS' $null $script:fileSystem $null

            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'stage' }) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Match 'HDTPE_x64\.wim'
        }

        It 'fails when the running Windows carries no boot.sdi' {
            $script:fileSystem = New-HDTFakeFileSystem -File @{ $script:sourceWim = 'WIM' }
            $context = & $script:newContext 'FullOS' $null $script:fileSystem $null

            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'stage' }) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Match 'boot\.sdi'
        }

        It 'fails when the copy itself fails' {
            $script:fileSystem = New-HDTFakeFileSystem -File $script:file `
                -WriteFailure @{ $script:stagedWim = 'The device is not ready.' }
            $context = & $script:newContext 'FullOS' $null $script:fileSystem $null

            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'stage' }) -Context $context

            $result.Status | Should -BeExactly 'Failed'
        }
    }

    Context 'arm' {

        BeforeEach {
            # A machine that has already been staged.
            $script:file[$script:stagedWim] = 'WIM'
            $script:file[$script:stagedSdi] = 'SDI'
            $script:fileSystem = New-HDTFakeFileSystem -File $script:file
            $script:context = & $script:newContext 'FullOS' $null $script:fileSystem $null
        }

        # THE ORDER IS THE MECHANISM. A stale entry from a previous reference
        # build carries the same fixed id, and bcdedit /create on an id that
        # exists fails - so the removal comes first, and only then the create and
        # the one-shot it points at.
        It 'clears any stale entry, creates the entry, then arms one boot' {
            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'arm' }) -Context $script:context

            $result.Status | Should -BeExactly 'Completed'
            @($script:image.GetOperationName()) |
                Should -Be @('RemoveBootEntry', 'TestRamdiskOptions', 'AddRamdiskBootEntry', 'SetBootSequenceOnce')
        }

        # {ramdiskoptions} IS SHARED, AND WinRE IS THE OTHER OWNER.
        #
        # A machine with a registered WinRE already has one, and HDT used to
        # tolerate the failing /create and then set both of its elements anyway -
        # repointing WinRE's ramdisk options at HDT's staged boot.sdi, which the
        # remove action then DELETES. MEASURED on 2026-08-31 (SPIKES S23.8):
        # reagentc reported WinRE Enabled on a machine whose {ramdiskoptions}
        # named HDT's staged file.
        #
        # So the step ASKS FIRST, the way MDT's CreateRamDiskEntryEx (:86-89)
        # does, and passes the answer down to the command composer.
        It 'asks whether this machine already has ramdisk options, against the store it is about to write' {
            $null = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'arm' }) -Context $script:context

            $probe = @($script:image.Operations | Where-Object { $_.Operation -eq 'TestRamdiskOptions' })
            $probe.Count | Should -Be 1

            $add = @($script:image.Operations | Where-Object { $_.Operation -eq 'AddRamdiskBootEntry' })[0]
            @($probe[0].Arguments)[0] | Should -BeExactly (@($add.Arguments)[0])
        }

        It 'tells the create to leave the ramdisk options alone when the machine already has some' {
            $image = New-HDTFakeImageService
            $image.RamdiskOptionsPresent = $true
            $context = & $script:newContext 'FullOS' $image $script:fileSystem $null

            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'arm' }) -Context $context

            $result.Status | Should -BeExactly 'Completed'
            $add = @($image.Operations | Where-Object { $_.Operation -eq 'AddRamdiskBootEntry' })[0]
            @($add.Arguments)[7] | Should -BeTrue
            $result.Data['ramdiskOptionsPresent'] | Should -BeTrue
        }

        It 'creates the ramdisk options when the machine has none' {
            $null = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'arm' }) -Context $script:context

            $add = @($script:image.Operations | Where-Object { $_.Operation -eq 'AddRamdiskBootEntry' })[0]
            @($add.Arguments)[7] | Should -BeFalse
        }

        # A PROBE THAT CANNOT READ THE STORE MUST NOT STRAND A REFERENCE BUILD.
        # Answering "no" is the behaviour HDT already had, and failing the arm
        # over a question about somebody else's WinRE would cost the whole build.
        It 'arms anyway when the store cannot be read to answer the question' {
            $image = New-HDTFakeImageService -Failure @{ TestRamdiskOptions = 'The boot configuration data store could not be opened.' }
            $context = & $script:newContext 'FullOS' $image $script:fileSystem $null

            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'arm' }) -Context $context

            $result.Status | Should -BeExactly 'Completed'
            $add = @($image.Operations | Where-Object { $_.Operation -eq 'AddRamdiskBootEntry' })[0]
            @($add.Arguments)[7] | Should -BeFalse
        }

        # A MACHINE THAT HAS NEVER BEEN ARMED HAS NO ENTRY TO DELETE, and bcdedit
        # says so with a non-zero exit code. That is the ordinary case, not a
        # failure, so the pre-emptive removal is the one call here that is
        # allowed to fail.
        It 'survives there being no stale entry to clear' {
            $image = New-HDTFakeImageService -Failure @{ RemoveBootEntry = 'The boot configuration data store could not be opened.' }
            $context = & $script:newContext 'FullOS' $image $script:fileSystem $null

            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'arm' }) -Context $context

            $result.Status | Should -BeExactly 'Completed'
        }

        It 'writes to the system store in the full OS, because the ESP has no letter there' {
            $null = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'arm' }) -Context $script:context

            $add = @($script:image.Operations | Where-Object { $_.Operation -eq 'AddRamdiskBootEntry' })[0]
            @($add.Arguments)[0] | Should -BeExactly ''
        }

        It 'names the staged wim on the running system drive, not the WinPE letter' {
            $null = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'arm' }) -Context $script:context

            $add = @($script:image.Operations | Where-Object { $_.Operation -eq 'AddRamdiskBootEntry' })[0]
            @($add.Arguments)[3] | Should -BeExactly 'C:'
            @($add.Arguments)[4] | Should -BeExactly '\HDT\Boot\boot.wim'
        }

        It 'names winload.efi on a UEFI machine and winload.exe on a BIOS one' {
            $null = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'arm' }) -Context $script:context
            $add = @($script:image.Operations | Where-Object { $_.Operation -eq 'AddRamdiskBootEntry' })[0]
            @($add.Arguments)[6] | Should -BeExactly '\windows\system32\boot\winload.efi'

            $bios = New-HDTFakeImageService
            $context = & $script:newContext 'FullOS' $bios $script:fileSystem @{ HDTIsUEFI = $false }
            $null = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'arm' }) -Context $context
            $add = @($bios.Operations | Where-Object { $_.Operation -eq 'AddRamdiskBootEntry' })[0]
            @($add.Arguments)[6] | Should -BeExactly '\windows\system32\boot\winload.exe'
        }

        # THE OTHER HALF OF THE FAIL-SAFE RULE. Arming runs before Sysprep too,
        # so a bcdedit that refuses stops the sequence while the machine is still
        # a working Windows installation somebody can log into.
        It 'fails when the entry cannot be created' {
            $image = New-HDTFakeImageService -Failure @{ AddRamdiskBootEntry = 'The parameter is incorrect.' }
            $context = & $script:newContext 'FullOS' $image $script:fileSystem $null

            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'arm' }) -Context $context

            $result.Status | Should -BeExactly 'Failed'
        }

        It 'fails when the one-shot cannot be armed' {
            $image = New-HDTFakeImageService -Failure @{ SetBootSequenceOnce = 'The parameter is incorrect.' }
            $context = & $script:newContext 'FullOS' $image $script:fileSystem $null

            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'arm' }) -Context $context

            $result.Status | Should -BeExactly 'Failed'
        }

        # ARMING A BOOT INTO A FILE THAT IS NOT THERE IS THE WORST OUTCOME OF
        # ALL: bcdedit accepts it, sysprep seals the machine, and the next boot
        # is a black screen with an 0xc000000f on a generalized installation.
        It 'fails when nothing has been staged for it to boot' {
            $fileSystem = New-HDTFakeFileSystem -File @{ $script:sourceWim = 'WIM'; $script:sourceSdi = 'SDI' }
            $context = & $script:newContext 'FullOS' $null $fileSystem $null

            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'arm' }) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Match 'stage'
            @($script:image.GetOperationName()) | Should -Not -Contain 'SetBootSequenceOnce'
        }
    }

    Context 'remove' {

        BeforeEach {
            # THE TEARDOWN LEG RUNS IN WinPE, WHERE THE OS VOLUME IS W: - the
            # letter the partition step gave it - and NOT C:. SystemDrive in
            # WinPE is X:, the RAM disk, so a teardown that used it would delete
            # nothing and report success.
            $script:fileSystem = New-HDTFakeFileSystem -File @{
                'W:\HDT\Boot\boot.wim' = 'WIM'
                'W:\HDT\Boot\boot.sdi' = 'SDI'
            }
            $script:context = & $script:newContext 'WinPE' $null $script:fileSystem $null
        }

        It 'deletes the boot entry and the staged files' {
            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'remove' }) -Context $script:context

            $result.Status | Should -BeExactly 'Completed'
            @($script:image.GetOperationName()) | Should -Be @('RemoveBootEntry')
            $script:fileSystem.TestPath('W:\HDT\Boot\boot.wim') | Should -BeFalse
            $script:fileSystem.TestPath('W:\HDT\Boot\boot.sdi') | Should -BeFalse
        }

        # IN WinPE THE RUNNING STORE IS THE RAM DISK'S, which is not the store
        # the machine boots from - so the teardown names the store the partition
        # step lettered instead of letting bcdedit choose.
        It 'names the store on the system volume, because WinPE has no system store' {
            $null = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'remove' }) -Context $script:context

            @($script:image.Operations[0].Arguments)[0] | Should -BeExactly 'S:\EFI\Microsoft\Boot\BCD'
        }

        # IN WinPE THE OS VOLUME IS %HDTOSVolume%, not SystemDrive - SystemDrive
        # there is X:, the RAM disk, and deleting C:\HDT\Boot off it would delete
        # nothing while reporting success.
        It 'clears the staged files from the OS volume rather than the RAM disk' {
            $fileSystem = New-HDTFakeFileSystem -File @{ 'W:\HDT\Boot\boot.wim' = 'WIM'; 'W:\HDT\Boot\boot.sdi' = 'SDI' }
            $context = & $script:newContext 'WinPE' $null $fileSystem $null

            $null = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'remove' }) -Context $context

            $fileSystem.TestPath('W:\HDT\Boot\boot.wim') | Should -BeFalse
        }

        # WARN AND CONTINUE, WHICH IS THE OPPOSITE OF stage AND arm AND IS RIGHT
        # FOR THE SAME REASON THEY ARE NOT. This runs after the capture boot has
        # already happened. A cleanup that fails leaves an entry nothing points
        # at on a machine that is about to be torn down; failing here would cost
        # the capture the whole reference build exists to produce.
        It 'warns and continues when the entry cannot be deleted' {
            $image = New-HDTFakeImageService -Failure @{ RemoveBootEntry = 'The boot configuration data store could not be opened.' }
            $context = & $script:newContext 'WinPE' $image $script:fileSystem $null

            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'remove' }) -Context $context

            $result.Status | Should -BeExactly 'Completed'
        }

        It 'is content to find nothing staged, because it may run twice' {
            $fileSystem = New-HDTFakeFileSystem
            $context = & $script:newContext 'WinPE' $null $fileSystem $null

            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'remove' }) -Context $context

            $result.Status | Should -BeExactly 'Completed'
        }
    }

    Context 'what it refuses' {

        It 'refuses an action it does not know, naming the ones it does' {
            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'adjust' }) -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Match 'stage'
            $result.Message | Should -Match 'arm'
            $result.Message | Should -Match 'remove'
        }

        It 'refuses to stage when the WinPE leg has published no OS volume' {
            $context = & $script:newContext 'WinPE' $null $script:fileSystem @{ HDTOSVolume = '' }

            $result = Invoke-HDTBootToWinPEStep -Step (& $script:newStep @{ action = 'remove' }) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Match 'HDTOSVolume'
        }
    }
}
