# The EnableBitLocker step (DESIGN 10.3).
#
# THE RULE THAT MATTERS MOST IS AN ORDERING ONE: key escrow is verified BEFORE
# encryption begins. A machine that encrypts with no recoverable key is worse
# than one left unencrypted - it is a machine nobody can get into and nobody
# knew was at risk until the day the TPM is cleared. DESIGN 10.3 gives it a
# dedicated test and so does this file, twice: once asserting the ORDER of the
# operations, and once making the escrow fail and asserting that Enable was
# never called at all.
#
# scope: usedSpaceOnly IS THE DEFAULT AND IT IS NOT A COMPROMISE. HDT only ever
# deploys to a volume it just created, so the free space has never held
# plaintext - the one scenario where used-space-only is unambiguously right.
# full: is for a disk that was not freshly wiped, or a compliance rule that says
# so regardless.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:newStep = {
        param([string] $Name, [System.Collections.IDictionary] $Property, [int] $TimeoutMinutes = 0)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index          = 1
            Name           = $Name
            Type           = 'EnableBitLocker'
            TimeoutMinutes = $TimeoutMinutes
            Log            = $null
            Property       = $bag
        }
    }

    $script:newContext = {
        param($BitLocker, [System.Collections.IDictionary] $Variable, [string] $Level = 'Info')

        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 16, 9, 0, 0, [System.DateTimeKind]::Utc))

        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock -BitLocker $BitLocker

        $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $script:fileSystem -Clock $script:clock -Level $Level

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Variable) {
            foreach ($key in @($Variable.Keys)) { $bag[[string] $key] = $Variable[$key] }
        }

        $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'C:\Deploy' `
            -Variable $bag -Service $catalog -Log $log
        $context.SetStep(1, 'Enable BitLocker', 'EnableBitLocker', 'C:\HDT\Logs\Steps\001-BitLocker.log')

        return $context
    }

    $script:jsonlText = {
        param($FileSystem)

        if ($FileSystem.File.ContainsKey('C:\HDT\Logs\HDT.jsonl')) {
            return [string] $FileSystem.File['C:\HDT\Logs\HDT.jsonl']
        }

        return ''
    }
}

Describe 'Invoke-HDTEnableBitLockerStep' {

    BeforeEach {
        $script:bitlocker = New-HDTFakeBitLockerService -Volume @{
            'C:' = @{ VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off' }
        }
    }

    Context 'escrow before encryption' {

        It 'backs the key up BEFORE it enables encryption' {
            # THE DEDICATED TEST DESIGN 10.3 ASKS FOR. Not "both happened" - the
            # ORDER, read off the operation list.
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ drive = 'C:'; escrow = 'ad' })

            $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            $name = @($script:bitlocker.GetOperationName())
            [array]::IndexOf($name, 'BackupProtector') |
                Should -BeLessThan ([array]::IndexOf($name, 'Enable'))
        }

        It 'does not encrypt at all when the escrow fails' {
            $bitlocker = New-HDTFakeBitLockerService `
                -Volume @{ 'C:' = @{ VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off' } } `
                -Failure @{ BackupProtector = 'the directory refused the key' }

            $context = & $script:newContext $bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ drive = 'C:'; escrow = 'ad' })

            $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            @($bitlocker.GetOperationName()) | Should -Not -Contain 'Enable'
        }

        It 'escrows the recovery password protector, not some other one' {
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ drive = 'C:'; escrow = 'ad' })

            $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            $recovery = @($script:bitlocker.Operations |
                    Where-Object { $_.Operation -eq 'AddProtector' -and $_.Arguments[1] -eq 'RecoveryPassword' })
            $backup = @($script:bitlocker.Operations | Where-Object { $_.Operation -eq 'BackupProtector' })

            $recovery.Count | Should -Be 1
            $backup[0].Arguments[1] | Should -BeExactly '{PROTECTOR-0001}'
        }

        It 'sends the key to Entra when asked' {
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ drive = 'C:'; escrow = 'entra' })

            $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            @($script:bitlocker.Operations | Where-Object { $_.Operation -eq 'BackupProtector' })[0].Arguments[2] |
                Should -BeExactly 'entra'
        }

        It 'warns and encrypts anyway when escrow is none' {
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ drive = 'C:'; escrow = 'none' })

            $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($script:bitlocker.GetOperationName()) | Should -Not -Contain 'BackupProtector'
            (& $script:jsonlText $script:fileSystem) | Should -BeLike '*Warning*'
        }

        It 'refuses escrow with no recovery password to escrow' {
            # recoveryPassword: false and escrow: ad is an author asking for a key
            # to be backed up that was never created.
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{
                    drive            = 'C:'
                    escrow           = 'ad'
                    recoveryPassword = $false
                })

            $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            @($script:bitlocker.GetOperationName()) | Should -Not -Contain 'Enable'
        }

        It 'never writes the recovery password to the log' {
            # The fake's password is shaped like a real one - six groups of six
            # digits - precisely so a step that logged it would be caught here.
            $context = & $script:newContext $script:bitlocker $null 'Debug'
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ drive = 'C:'; escrow = 'ad' })

            $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            (& $script:jsonlText $script:fileSystem) | Should -Not -BeLike '*111111-222222*'
        }
    }

    Context 'the scope' {

        It 'defaults to used space only' {
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ drive = 'C:'; escrow = 'none' })

            $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            @($script:bitlocker.Operations | Where-Object { $_.Operation -eq 'Enable' })[0].Arguments[2] |
                Should -BeTrue
        }

        It 'encrypts the whole volume when scope is full' {
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{
                    drive = 'C:'; escrow = 'none'; scope = 'full'
                })

            $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            @($script:bitlocker.Operations | Where-Object { $_.Operation -eq 'Enable' })[0].Arguments[2] |
                Should -BeFalse
        }

        It 'refuses a scope that is neither' {
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{
                    drive = 'C:'; escrow = 'none'; scope = 'quick'
                })

            $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*quick*'
        }
    }

    Context 'the method and the protector' {

        It 'defaults to XtsAes256' {
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ drive = 'C:'; escrow = 'none' })

            $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            @($script:bitlocker.Operations | Where-Object { $_.Operation -eq 'Enable' })[0].Arguments[1] |
                Should -BeExactly 'XtsAes256'
        }

        It 'uses the method it was given' {
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{
                    drive = 'C:'; escrow = 'none'; method = 'Aes256'
                })

            $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            @($script:bitlocker.Operations | Where-Object { $_.Operation -eq 'Enable' })[0].Arguments[1] |
                Should -BeExactly 'Aes256'
        }

        It 'refuses a method BitLocker does not have' {
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{
                    drive = 'C:'; escrow = 'none'; method = 'Rot13'
                })

            $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*Rot13*'
        }

        It 'defaults to a TPM protector' {
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ drive = 'C:'; escrow = 'none' })

            $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            @($script:bitlocker.Operations |
                    Where-Object { $_.Operation -eq 'AddProtector' } |
                    ForEach-Object { $_.Arguments[1] }) | Should -Contain 'Tpm'
        }

        It 'refuses tpmPin with no pin' {
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{
                    drive = 'C:'; escrow = 'none'; protector = 'tpmPin'
                })

            $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*pin*'
        }

        It 'refuses a protector that is not one of the three' {
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{
                    drive = 'C:'; escrow = 'none'; protector = 'password'
                })

            $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*password*'
        }
    }

    Context 'the volume it encrypts' {

        It 'takes the drive from HDTOSVolume when the step names none' {
            $context = & $script:newContext $script:bitlocker @{ HDTOSVolume = 'C' }
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ escrow = 'none' })

            $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            @($script:bitlocker.Operations | Where-Object { $_.Operation -eq 'Enable' })[0].Arguments[0] |
                Should -BeExactly 'C:'
        }

        It 'refuses to guess when neither the step nor HDTOSVolume names one' {
            # Rule 6: no guessing at a target. Encrypting the wrong volume is not
            # as destructive as wiping it, but it is not recoverable in an
            # afternoon either.
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ escrow = 'none' })

            $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*HDTOSVolume*'
        }

        It 'does nothing to a volume that is already protected' {
            $bitlocker = New-HDTFakeBitLockerService -Volume @{
                'C:' = @{ VolumeStatus = 'FullyEncrypted'; ProtectionStatus = 'On' }
            }
            $context = & $script:newContext $bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ drive = 'C:'; escrow = 'none' })

            $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($bitlocker.GetOperationName()) | Should -Not -Contain 'Enable'
        }
    }

    Context 'waiting, or not' {

        It 'returns without waiting by default' {
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ drive = 'C:'; escrow = 'none' })

            $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($script:clock.GetOperationName()) | Should -Not -Contain 'Sleep'
        }

        It 'polls until the volume is fully encrypted when asked to wait' {
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{
                    drive = 'C:'; escrow = 'none'; wait = $true
                })

            # The fake reports EncryptionInProgress after Enable and never
            # finishes on its own, so the step must give up on its timeout rather
            # than loop forever.
            $step.TimeoutMinutes = 1

            $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            @($script:clock.GetOperationName()) | Should -Contain 'Sleep'
            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*encrypt*'
        }
    }
}
