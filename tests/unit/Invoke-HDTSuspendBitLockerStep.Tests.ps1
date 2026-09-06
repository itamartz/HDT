# The SuspendBitLocker step, which is what stops a Refresh landing in recovery.
#
# DESIGN 3.2. A Refresh runs on a production machine that is very likely
# encrypted, and the BootToWinPE steps immediately after this one change the
# boot configuration the TPM measured. The next boot then asks for a recovery
# key on a machine nobody is standing in front of, wanting a key the technician
# did not bring - and the deployment stops there, having already been told to
# proceed.
#
# MDT DOES EXACTLY THIS, IN EXACTLY THIS PLACE. Templates\Client.xml:85 is a
# step named "Disable BDE Protectors" inside a group conditioned
# DeploymentType equals REFRESH, and the step immediately after it is
# "Apply Windows PE" - LTIApply.wsf /PE, which is the transport. The script it
# runs calls Win32_EncryptableVolume.DisableKeyProtectors(0).
#
# A SUSPEND, NEVER A DECRYPT, and the file asserts that rather than assuming it.
# The volume is about to be emptied and overwritten, so the plaintext underneath
# the ciphertext has no value to anybody, and a decrypt costs hours on a large
# disk to buy nothing. The double leaves VolumeStatus alone on a suspend, so a
# step that reached for a decrypt would be visible here as a changed status or
# as an operation nobody expected.
#
# AND IT MUST SURVIVE A MACHINE THAT IS NOT ENCRYPTED, which is the case that
# would otherwise ship broken across an entire estate. The hand-written double
# THROWS on a volume with nothing to suspend, because Suspend-BitLocker does -
# and MDT never calls it there either, selecting only ProtectionStatus<>0. A
# step that suspended unconditionally would fail every unencrypted machine in
# the fleet, and every one of them would look like a BitLocker fault.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') `
    -Force -ErrorAction Stop

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:newStep = {
        param([System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index          = 3
            Name           = 'Suspend BitLocker'
            Type           = 'SuspendBitLocker'
            TimeoutMinutes = 0
            Log            = $null
            Property       = $bag
        }
    }

    # A FULL-OS LEG, WHICH IS WHERE THIS STEP RUNS AND THE ONLY PLACE IT CAN.
    # You cannot suspend the protectors of a volume from a WinPE that has not
    # unlocked it, and by the time WinPE is running the boot that needed the
    # suspend has already happened.
    $script:newContext = {
        param($BitLocker, [hashtable] $Variable, [string] $SystemDrive,
            [switch] $NoBitLockerService, [switch] $NoSystemDrive)

        $drive = $SystemDrive
        if ([string]::IsNullOrWhiteSpace($drive)) { $drive = 'C:' }

        $fileSystem = New-HDTFakeFileSystem
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 9, 6, 9, 0, 0, [System.DateTimeKind]::Utc))

        # A MACHINE THAT REPORTED NO SystemDrive AT ALL, which is what the fake's
        # unset-variable answer models - it returns $null, exactly as
        # IEnvironmentProvider does for a name nothing set.
        $seed = @{ SystemDrive = $drive }
        if ($NoSystemDrive) { $seed = @{} }

        $argument = @{
            FileSystem  = $fileSystem
            Clock       = $clock
            Environment = (New-HDTFakeEnvironmentProvider -Variable $seed)
        }
        if (-not $NoBitLockerService) { $argument['BitLocker'] = $BitLocker }

        $catalog = New-HDTServiceCatalog @argument

        $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $fileSystem -Clock $clock -Level Debug

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Variable) {
            foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
        }

        return (New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot '\\srv\HDTShare' `
                -Variable $live -Service $catalog -Log $log)
    }

    # An encrypted machine, which is what a Refresh runs on in any estate that
    # has a BitLocker policy at all.
    $script:newEncrypted = {
        param([string] $Drive, [hashtable] $Failure)

        $letter = $Drive
        if ([string]::IsNullOrWhiteSpace($letter)) { $letter = 'C:' }

        $argument = @{
            Volume = @{ $letter = @{ VolumeStatus = 'FullyEncrypted'; ProtectionStatus = 'On' } }
        }
        if ($null -ne $Failure) { $argument['Failure'] = $Failure }

        return (New-HDTFakeBitLockerService @argument)
    }
}

Describe 'Invoke-HDTSuspendBitLockerStep' {

    Context 'an encrypted machine, which is the case the step exists for' {

        BeforeAll {
            $script:bitLocker = & $script:newEncrypted 'C:'
            $script:context = & $script:newContext $script:bitLocker @{} 'C:'
            $script:result = Invoke-HDTSuspendBitLockerStep -Step (& $script:newStep @{}) -Context $script:context
        }

        It 'completes' {
            $script:result.Status | Should -BeExactly 'Completed'
        }

        It 'reads the volume before it suspends it, which is MDT ProtectionStatus<>0 select' {
            @($script:bitLocker.GetOperationName())[0] | Should -BeExactly 'GetVolume'
        }

        It 'suspends it' {
            @($script:bitLocker.GetOperationName()) | Should -Contain 'Suspend'
        }

        It 'suspends the volume the machine is running from' {
            $suspend = @($script:bitLocker.Operations | Where-Object { $_.Operation -eq 'Suspend' })[0]
            [string] @($suspend.Arguments)[0] | Should -BeExactly 'C:'
        }

        # MDT PASSES 0, AND THE REASON IS THE SECOND REBOOT. RebootCount 1 means
        # "until the next boot", and a Refresh boots into WinPE, applies an
        # image and boots again - so a suspend that expired on the first of them
        # puts the second into recovery, which is the failure this step exists
        # to prevent, arriving one reboot later.
        It 'suspends until protection is explicitly resumed, not until the next boot' {
            $suspend = @($script:bitLocker.Operations | Where-Object { $_.Operation -eq 'Suspend' })[0]
            [int] @($suspend.Arguments)[1] | Should -Be 0
        }

        It 'does not decrypt: the volume is as encrypted afterwards as it was' {
            [string] $script:bitLocker.GetVolume('C:').VolumeStatus | Should -BeExactly 'FullyEncrypted'
        }

        It 'turns protection off, which is what a suspend is' {
            [string] $script:bitLocker.GetVolume('C:').ProtectionStatus | Should -BeExactly 'Off'
        }

        It 'adds no protector and enables nothing' {
            @($script:bitLocker.GetOperationName()) | Should -Not -Contain 'AddProtector'
            @($script:bitLocker.GetOperationName()) | Should -Not -Contain 'Enable'
        }

        It 'names the volume in what it reports' {
            [string] $script:result.Message | Should -Match 'C:'
        }
    }

    Context 'a machine with no BitLocker on it, which most benches are' {

        BeforeAll {
            # THE DOUBLE THROWS HERE, and so does Suspend-BitLocker. A step that
            # asked anyway would fail on every unencrypted machine in the
            # estate, and every one of those failures would read as a BitLocker
            # fault rather than as a step that did not check.
            $script:plainService = New-HDTFakeBitLockerService -Volume @{
                'C:' = @{ VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off' }
            }
            $script:plainContext = & $script:newContext $script:plainService @{} 'C:'
            $script:plainResult = Invoke-HDTSuspendBitLockerStep -Step (& $script:newStep @{}) -Context $script:plainContext
        }

        It 'completes rather than failing' {
            $script:plainResult.Status | Should -BeExactly 'Completed'
        }

        It 'never asks for the suspend' {
            @($script:plainService.GetOperationName()) | Should -Not -Contain 'Suspend'
        }

        It 'says there was nothing to suspend, rather than claiming it suspended something' {
            [string] $script:plainResult.Message | Should -Match 'not (protected|encrypted)|nothing to suspend'
        }
    }

    Context 'which volume' {

        # THE SAME RESOLUTION Invoke-HDTValidateStep AND Assert-HDTCleanVolumeTarget
        # MAKE, AND THAT IS THE POINT. A Refresh carries no DiskPartition step, so
        # nothing has published HDTOSVolume when this runs; MDT fills the same gap
        # the same way, pinning the destination to SystemDrive
        # (ZTIUtility.vbs:3586-3593). Three places reading one fact three ways is
        # how they come to suspend one volume and empty another.
        It 'takes HDTOSVolume when the run has published one' {
            $service = & $script:newEncrypted 'D:'
            $context = & $script:newContext $service @{ HDTOSVolume = 'D' } 'C:'

            Invoke-HDTSuspendBitLockerStep -Step (& $script:newStep @{}) -Context $context | Out-Null

            $suspend = @($service.Operations | Where-Object { $_.Operation -eq 'Suspend' })[0]
            [string] @($suspend.Arguments)[0] | Should -BeExactly 'D:'
        }

        It 'takes the drive the step names, over both' {
            $service = & $script:newEncrypted 'E:'
            $context = & $script:newContext $service @{ HDTOSVolume = 'D' } 'C:'

            Invoke-HDTSuspendBitLockerStep -Step (& $script:newStep @{ drive = 'E:' }) -Context $context | Out-Null

            $suspend = @($service.Operations | Where-Object { $_.Operation -eq 'Suspend' })[0]
            [string] @($suspend.Arguments)[0] | Should -BeExactly 'E:'
        }

        It 'expands a %Variable% in the drive it was given' {
            $service = & $script:newEncrypted 'E:'
            $context = & $script:newContext $service @{ HDTProbeDrive = 'E' } 'C:'

            Invoke-HDTSuspendBitLockerStep -Step (& $script:newStep @{ drive = '%HDTProbeDrive%' }) -Context $context | Out-Null

            $suspend = @($service.Operations | Where-Object { $_.Operation -eq 'Suspend' })[0]
            [string] @($suspend.Arguments)[0] | Should -BeExactly 'E:'
        }

        It 'refuses when nothing says which volume, rather than guessing one' {
            $service = & $script:newEncrypted 'C:'
            $context = & $script:newContext $service @{} 'C:' -NoSystemDrive

            $result = Invoke-HDTSuspendBitLockerStep -Step (& $script:newStep @{}) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            @($service.GetOperationName()) | Should -Not -Contain 'Suspend'
        }
    }

    Context 'the reboot count, when a sequence wants to say' {

        It 'passes the count the step authored' {
            $service = & $script:newEncrypted 'C:'
            $context = & $script:newContext $service @{} 'C:'

            Invoke-HDTSuspendBitLockerStep -Step (& $script:newStep @{ rebootCount = 2 }) -Context $context | Out-Null

            $suspend = @($service.Operations | Where-Object { $_.Operation -eq 'Suspend' })[0]
            [int] @($suspend.Arguments)[1] | Should -Be 2
        }

        It 'refuses a count that is not a number, naming what it was given' {
            $service = & $script:newEncrypted 'C:'
            $context = & $script:newContext $service @{} 'C:'

            $result = Invoke-HDTSuspendBitLockerStep -Step (& $script:newStep @{ rebootCount = 'soon' }) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            [string] $result.Message | Should -Match 'soon'
            @($service.GetOperationName()) | Should -Not -Contain 'Suspend'
        }
    }

    Context 'when the machine will not do it' {

        It 'fails the step rather than arming a boot entry behind a live protector' {
            $service = & $script:newEncrypted 'C:' @{ Suspend = 'the TPM refused' }
            $context = & $script:newContext $service @{} 'C:'

            $result = Invoke-HDTSuspendBitLockerStep -Step (& $script:newStep @{}) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            [string] $result.Message | Should -Match 'the TPM refused'
        }

        It 'fails when the volume cannot be read at all' {
            $service = & $script:newEncrypted 'C:' @{ GetVolume = 'the volume is not there' }
            $context = & $script:newContext $service @{} 'C:'

            $result = Invoke-HDTSuspendBitLockerStep -Step (& $script:newStep @{}) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            @($service.GetOperationName()) | Should -Not -Contain 'Suspend'
        }

        It 'fails when no BitLocker service was injected, naming the step' {
            $context = & $script:newContext $null @{} 'C:' -NoBitLockerService

            $result = Invoke-HDTSuspendBitLockerStep -Step (& $script:newStep @{}) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            [string] $result.Message | Should -Match 'BitLocker'
        }
    }

    Context 'the other two thirds of the step contract' {

        It 'describes itself by the volume it suspends' {
            Get-HDTSuspendBitLockerStepDescription -Step (& $script:newStep @{ drive = 'D:' }) |
                Should -Match 'D:'
        }

        It 'describes itself without a letter when the step names none' {
            $said = Get-HDTSuspendBitLockerStepDescription -Step (& $script:newStep @{})

            $said | Should -Not -BeNullOrEmpty
            $said | Should -Not -Match ':\s*$'
        }

        It 'writes a step a sequence can hold' {
            $line = @(Get-HDTSuspendBitLockerStepTemplate)

            ($line -join "`n") | Should -Match 'type: SuspendBitLocker'
            ($line -join "`n") | Should -Match 'runIn: FullOS'
        }
    }
}
