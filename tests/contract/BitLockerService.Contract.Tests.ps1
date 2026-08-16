# The IBitLockerService contract (PROJECT constraint 4, DESIGN 10.3, DESIGN 12.2.1).
#
# Four methods:
#
#   GetVolume(drive)                          -> the volume's status row
#   AddProtector(drive, type, argument)       -> the protector it added
#   BackupProtector(drive, protectorId, target)
#   Enable(drive, method, usedSpaceOnly)
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

            foreach ($name in @('GetVolume', 'AddProtector', 'BackupProtector', 'Enable')) {
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
}
