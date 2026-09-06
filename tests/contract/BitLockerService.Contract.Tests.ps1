# The IBitLockerService contract (PROJECT constraint 4, DESIGN 10.3, DESIGN 12.2.1).
#
# Five methods:
#
#   GetVolume(drive)                          -> the volume's status row
#   AddProtector(drive, type, argument)       -> the protector it added
#   BackupProtector(drive, protectorId, target)
#   Enable(drive, method, usedSpaceOnly)
#   Suspend(drive, rebootCount)
#
# SUSPEND IS THE FIFTH, AND IT IS A SUSPEND AND NEVER A DECRYPT. DESIGN 3.2: a
# Refresh arms a one-shot ramdisk boot entry on a machine that is very likely
# encrypted, which changes the boot configuration the TPM measured, and the next
# boot then lands in BitLocker recovery on a machine nobody is standing in front
# of. MDT suspends immediately before it arms (Client.xml:85-90) through
# Win32_EncryptableVolume.DisableKeyProtectors(0)
# (ZTIDisableBDEProtectors.wsf:88-96) - the volume stays encrypted and the work
# costs seconds. Its decrypt branch (:104) is for OS combinations HDT does not
# support, so HDT never decrypts: decrypting a volume in order to deploy over it
# costs hours and buys nothing, because the volume is about to be emptied anyway.
#
# THE REAL ROW IS SHAPE-ONLY AND NEVER RUNS A SINGLE ONE OF THEM. Every method
# here except GetVolume changes the encryption state of a real disk, and the disk
# most likely to be in front of this code is the developer's own. There is no
# environment variable that turns the behavioural half on, because there is no
# safe way to run it against a physical machine - the fake carries all of it, and
# the real adapter is branch-free by rule 1.
#
# The skip goes on a Context INSIDE the Describe, never on the -ForEach Describe
# itself: -Skip: there is bound before -ForEach binds the row's keys, so it does
# not skip (tests/helpers/README.md F9).

$script:HDTImplementation = @(
    @{
        Name    = 'FakeBitLockerService'
        Factory = { New-HDTFakeBitLockerService -Volume @{
                'C:' = @{ VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off' }
            } }
        IsReal  = $false
    }
    @{
        Name    = 'BitLockerService'
        Factory = { New-HDTBitLockerService }
        IsReal  = $true
    }
)

Describe 'IBitLockerService contract: <Name>' -ForEach $script:HDTImplementation {

    # The imports live in the DESCRIBE's BeforeAll: a Factory scriptblock is
    # created in the discovery-time script scope, and a module imported inside a
    # Context is invisible to it.
    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    }

    Context 'the shape' {

        BeforeAll {
            $script:service = & $Factory
        }

        It 'exposes every method the contract requires' {
            $method = @($script:service | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('GetVolume', 'AddProtector', 'BackupProtector', 'Enable', 'Suspend')) {
                $method | Should -Contain $name -Because "IBitLockerService requires $name"
            }
        }

        It 'exposes the operation journal every service carries' {
            $member = @($script:service | Get-Member | ForEach-Object { $_.Name })

            $member | Should -Contain 'Operations'
            $member | Should -Contain 'GetOperationName'
        }

        It 'names itself for the cross-service journal' {
            $script:service.ServiceName | Should -BeExactly 'BitLockerService'
        }
    }

    Context 'the behaviour' -Skip:$IsReal {

        BeforeEach {
            $script:bl = & $Factory
        }

        It 'reports a volume status and a protection status' {
            $volume = $script:bl.GetVolume('C:')

            $volume.VolumeStatus | Should -Not -BeNullOrEmpty
            $volume.ProtectionStatus | Should -Not -BeNullOrEmpty
        }

        It 'lists the key protectors on a volume' {
            # An empty list is the answer for a volume that has none, and the step
            # reads it under Set-StrictMode - so the property is always there.
            @($script:bl.GetVolume('C:').KeyProtector).Count | Should -Be 0
        }

        It 'returns the protector it added, with an id' {
            $protector = $script:bl.AddProtector('C:', 'RecoveryPassword', '')

            $protector.KeyProtectorId | Should -Not -BeNullOrEmpty
            $protector.KeyProtectorType | Should -BeExactly 'RecoveryPassword'
        }

        It 'shows an added protector on the next GetVolume' {
            $null = $script:bl.AddProtector('C:', 'Tpm', '')

            @($script:bl.GetVolume('C:').KeyProtector | ForEach-Object { $_.KeyProtectorType }) |
                Should -Contain 'Tpm'
        }

        It 'records every call' {
            $protector = $script:bl.AddProtector('C:', 'RecoveryPassword', '')
            $script:bl.BackupProtector('C:', $protector.KeyProtectorId, 'ad')
            $script:bl.Enable('C:', 'XtsAes256', $true)

            $script:bl.GetOperationName() | Should -Be @('AddProtector', 'BackupProtector', 'Enable')
        }

        It 'records the arguments Enable was given' {
            $script:bl.Enable('C:', 'XtsAes256', $true)

            @($script:bl.Operations)[0].Arguments[0] | Should -BeExactly 'C:'
            @($script:bl.Operations)[0].Arguments[1] | Should -BeExactly 'XtsAes256'
            @($script:bl.Operations)[0].Arguments[2] | Should -BeTrue
        }

        It 'turns protection on' {
            $script:bl.Enable('C:', 'XtsAes256', $true)

            $script:bl.GetVolume('C:').ProtectionStatus | Should -BeExactly 'On'
        }
    }

    # THE SUSPEND, WHICH IS THE OPERATION A REFRESH NEEDS AND THE ONE MOST EASILY
    # MODELLED WRONG. CLAUDE.md records the trap in the words "the fake was wrong,
    # not the caller": a fake that cannot refuse, or that reports success on a
    # volume with nothing to suspend, proves the caller correct against behaviour
    # Windows does not have.
    Context 'suspending' -Skip:$IsReal {

        BeforeEach {
            $script:bl = & $Factory

            # An encrypted, protected volume - which is what a Refresh finds on a
            # production machine, and the only state MDT's own query selects:
            # "Select * from Win32_EncryptableVolume where ProtectionStatus<>0"
            # (ZTIDisableBDEProtectors.wsf:88).
            $script:bl.SeedVolume('C:', @{ VolumeStatus = 'FullyEncrypted'; ProtectionStatus = 'On' })
        }

        It 'records the call and the reboot count it was given' {
            $script:bl.Suspend('C:', 0)

            $script:bl.GetOperationName() | Should -Be @('Suspend')
            @($script:bl.Operations)[0].Arguments[0] | Should -BeExactly 'C:'
            # MDT passes DisableKeyProtectors(0) at ZTIDisableBDEProtectors.wsf:96.
            # The citation is in this comment and not in the -Because string: the
            # no-MDT contract scans strings, and a -Because is one.
            @($script:bl.Operations)[0].Arguments[1] | Should -Be 0 -Because (
                'the suspend count is the caller''s decision and not the adapter''s, and 0 is what a one-boot suspend passes')
        }

        It 'turns protection off' {
            $script:bl.Suspend('C:', 0)

            $script:bl.GetVolume('C:').ProtectionStatus | Should -BeExactly 'Off'
        }

        # THE ASSERTION THE WHOLE OPERATION EXISTS FOR. A decrypt would take
        # hours on a volume that is about to be emptied anyway; a suspend costs
        # seconds and leaves the ciphertext exactly where it was.
        It 'leaves the volume encrypted, because this is a suspend and not a decrypt' {
            $script:bl.Suspend('C:', 0)

            $script:bl.GetVolume('C:').VolumeStatus | Should -BeExactly 'FullyEncrypted'
        }

        # THE MESSAGE IS ASSERTED, NOT MERELY THE THROW. A bare -Throw is
        # satisfied by "does not contain a method named 'Suspend'", so it goes
        # green on the run where the operation does not exist at all.
        It 'refuses a volume it has never heard of' {
            { $script:bl.Suspend('Q:', 0) } | Should -Throw '*No BitLocker volume*'
        }

        # A SUSPEND THE FAKE CANNOT REFUSE IS A FAKE THAT PROVES NOTHING.
        # Suspend-BitLocker on a volume with no encryption on it errors; a double
        # that shrugged would let a step ship that reported success on every
        # unencrypted machine in the estate.
        It 'refuses a volume with nothing to suspend' {
            $script:bl.SeedVolume('D:', @{ VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off' })

            { $script:bl.Suspend('D:', 0) } | Should -Throw '*nothing to suspend*'
        }

        It 'records the refusal it made, so the attempt is not invisible' {
            $script:bl.SeedVolume('D:', @{ VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off' })

            try { $script:bl.Suspend('D:', 0) } catch { $null = $_ }

            $script:bl.GetOperationName() | Should -Contain 'Suspend'
        }

        It 'can be made to fail the way every other operation can' {
            $failing = New-HDTFakeBitLockerService `
                -Volume @{ 'C:' = @{ VolumeStatus = 'FullyEncrypted'; ProtectionStatus = 'On' } } `
                -Failure @{ Suspend = 'the TPM refused' }

            { $failing.Suspend('C:', 0) } | Should -Throw '*the TPM refused*'
        }
    }
}
