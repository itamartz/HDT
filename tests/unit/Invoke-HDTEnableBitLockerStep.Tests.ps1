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
        param($BitLocker, [System.Collections.IDictionary] $Variable, [string] $Level = 'Info',
            [string] $SystemDrive = '', [string] $Phase = 'FullOS')

        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 16, 9, 0, 0, [System.DateTimeKind]::Utc))

        # THE ENVIRONMENT IS OPTIONAL HERE AND ALWAYS PRESENT IN THE FIELD.
        # Passing none is how every test written before the system-drive
        # fallback existed goes on exercising the HDTOSVolume path unchanged.
        $environment = $null
        if ($SystemDrive.Length -gt 0) {
            $environment = New-HDTFakeEnvironmentProvider -Variable @{ SystemDrive = $SystemDrive }
        }

        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock -BitLocker $BitLocker `
            -Environment $environment

        $log = New-HDTLogContext -RunId 'run-0001' -Phase $Phase -LogPath 'C:\HDT\Logs' `
            -FileSystem $script:fileSystem -Clock $script:clock -Level $Level

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Variable) {
            foreach ($key in @($Variable.Keys)) { $bag[[string] $key] = $Variable[$key] }
        }

        $context = New-HDTExecutionContext -RunId 'run-0001' -Phase $Phase -WorkspaceRoot 'C:\Deploy' `
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

        It 'expands a variable in drive, which is what its own template writes' {
            # Get-HDTEnableBitLockerStepTemplate ships drive: '%HDTOSVolume%'.
            # Read unexpanded, that is not whitespace, so the HDTOSVolume
            # fallback below never fires and the Substring(0, 1) on the next line
            # yields the drive '%:' - a step that encrypts nothing and reports
            # success at doing it. Every other test here passes a literal 'C:',
            # which is exactly why nobody met this.
            $bitlocker = New-HDTFakeBitLockerService -Volume @{
                'D:' = @{ VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off' }
            }

            $context = & $script:newContext $bitlocker @{ HDTOSVolume = 'D' }
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{
                    drive = '%HDTOSVolume%'; escrow = 'none'
                })

            $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            @($bitlocker.Operations | Where-Object { $_.Operation -eq 'Enable' })[0].Arguments[0] |
                Should -BeExactly 'D:'
        }

        It 'still takes a literal drive as written' {
            # HDTOSVolume says D and the step says C. The step wins - the
            # fallback is for a step that names nothing.
            $context = & $script:newContext $script:bitlocker @{ HDTOSVolume = 'D' }
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{
                    drive = 'C:'; escrow = 'none'
                })

            $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            @($script:bitlocker.Operations | Where-Object { $_.Operation -eq 'Enable' })[0].Arguments[0] |
                Should -BeExactly 'C:'
        }

        It 'refuses when the variable the drive names resolves to nothing' {
            # Better than encrypting '%:'. The message has to name the variable,
            # because "no drive" on a step that plainly names one reads as a bug
            # in the console rather than an unset variable.
            $context = & $script:newContext $script:bitlocker
            $step = & $script:newStep 'Enable BitLocker' ([ordered] @{
                    drive = '%HDTOSVolume%'; escrow = 'none'
                })

            $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*HDTOSVolume*'
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

# WHICH VOLUME A STEP THAT NAMES NONE ENCRYPTS - AND IT WAS THE WRONG ONE.
#
# HDTOSVolume is the letter the PARTITION step gave the Windows volume, and the
# partition step runs in WinPE, where the volume is mounted at W:. The moment
# the machine boots, that same volume is C:. EnableBitLocker is a State Restore
# step - DESIGN 10.3, and both shipped templates put it in a runIn: FullOS group
# - so it always ran after the letter had changed underneath it.
#
# ON THE FIRST REAL RUN, 2026-09-10, the seed deployment's step 9 said:
#
#   the BitLocker state of W: could not be read: "W: does not have an
#   associated BitLocker volume."
#   step 9 'Enable BitLocker' failed
#
# and left a machine nobody had encrypted - which is why M9's BitLocker exit
# criterion had no evidence behind it, and why the Refresh that followed found
# "C: is not protected by BitLocker" and suspended nothing. The 88% encryption
# on that disk was Windows 11's own automatic device encryption, with no key
# protector at all; HDT had contributed nothing.
#
# MDT ANSWERS THIS EXACTLY, AND HDT BUILDS MDT'S (ZTIBde.wsf:176-181): an
# explicitly named drive wins, and otherwise the target is sSystemDrive. Its
# WinPE path is a separate branch chosen by testing oEnv("SystemDrive") = "X:"
# (line 118), which is the same discriminator used here - in WinPE the system
# drive is the RAM disk and encrypting it would be nonsense, so there and only
# there HDTOSVolume is still the right answer.
Describe 'the volume a step that names no drive encrypts' {

    BeforeEach {
        $script:bothVolume = New-HDTFakeBitLockerService -Volume @{
            'C:' = @{ VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off' }
            'W:' = @{ VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off' }
        }
    }

    It 'is the system drive in the full OS, not the letter WinPE used' {
        $context = & $script:newContext $script:bothVolume ([ordered] @{ HDTOSVolume = 'W:' }) 'Info' 'C:' 'FullOS'
        $step = & $script:newStep 'Enable BitLocker' ([ordered] @{})

        $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

        @($script:bothVolume.Operations | Where-Object { $_.Operation -eq 'Enable' })[0].Arguments[0] |
            Should -BeExactly 'C:' -Because 'the volume HDTOSVolume named in WinPE is C: once the machine has booted'
    }

    It 'is HDTOSVolume in WinPE, where the system drive is the RAM disk' {
        $context = & $script:newContext $script:bothVolume ([ordered] @{ HDTOSVolume = 'W:' }) 'Info' 'X:' 'WinPE'
        $step = & $script:newStep 'Enable BitLocker' ([ordered] @{})

        $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

        @($script:bothVolume.Operations | Where-Object { $_.Operation -eq 'Enable' })[0].Arguments[0] |
            Should -BeExactly 'W:' -Because 'X: is WinPE itself and encrypting it would be nonsense'
    }

    It 'lets a drive the step names win over both' {
        $context = & $script:newContext $script:bothVolume ([ordered] @{ HDTOSVolume = 'W:' }) 'Info' 'C:' 'FullOS'
        $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ drive = 'W:' })

        $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

        @($script:bothVolume.Operations | Where-Object { $_.Operation -eq 'Enable' })[0].Arguments[0] |
            Should -BeExactly 'W:' -Because 'an author who named a drive meant it'
    }
}

# THE METHOD IS ONLY OURS TO CHOOSE WHILE THE VOLUME IS UNTOUCHED.
#
# Windows 11 starts automatic device encryption during OOBE, so a machine
# deployed minutes ago is routinely already converting - and manage-bde refuses
# -EncryptionMethod on a converting volume with "The parameter is incorrect"
# (0x80070057). Proven on HDT-M9-REF01 on 2026-09-10, which was 87.6% through an
# XTS-AES 128 pass nobody asked for while this step was asking for XTS-AES 256.
#
# ASKING ANYWAY IS NOT THE STRICTER CHOICE. It is the choice that fails the step
# and leaves the machine with no protection at all, which is strictly worse than
# a volume encrypted with the method Windows picked and a TPM protector on it.
Describe 'a volume Windows had already started encrypting' {

    BeforeEach {
        $script:converting = New-HDTFakeBitLockerService -Volume @{
            'C:' = @{ VolumeStatus = 'EncryptionInProgress'; ProtectionStatus = 'Off' }
        }
    }

    It 'asks for no encryption method, so manage-bde is not handed one it will refuse' {
        $context = & $script:newContext $script:converting ([ordered] @{ HDTOSVolume = 'W:' }) 'Info' 'C:' 'FullOS'
        $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ method = 'XtsAes256'; escrow = 'none' })

        $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

        $enable = @($script:converting.Operations | Where-Object { $_.Operation -eq 'Enable' })

        $enable.Count | Should -Be 1
        [string] $enable[0].Arguments[1] | Should -BeExactly '' -Because (
            'the method was fixed when Windows began the conversion and cannot be changed half way')
    }

    It 'warns, naming the method the sequence asked for' {
        $context = & $script:newContext $script:converting ([ordered] @{ HDTOSVolume = 'W:' }) 'Info' 'C:' 'FullOS'
        $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ method = 'XtsAes256'; escrow = 'none' })

        $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

        $text = (& $script:jsonlText $script:fileSystem)

        $text | Should -BeLike '*Warning*'
        $text | Should -BeLike '*XtsAes256*' -Because 'an administrator has to be able to see that the ask and the machine disagreed'
    }

    It 'still turns protection on rather than refusing' {
        $context = & $script:newContext $script:converting ([ordered] @{ HDTOSVolume = 'W:' }) 'Info' 'C:' 'FullOS'
        $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ method = 'XtsAes256'; escrow = 'none' })

        $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

        $result.Status | Should -BeExactly 'Completed'
    }
}

# WINDOWS CAN START ENCRYPTING BETWEEN THE READ AND THE CALL.
#
# The step reads the volume, sees FullyDecrypted, and asks for XtsAes256 - and
# by the time manage-bde runs a second later, Windows 11's automatic device
# encryption has begun a pass of its own, so the method can no longer be chosen
# and the call is refused with 0x80070057 "The parameter is incorrect".
#
# IT IS A RACE AND IT SHOWED AS ONE. Two identical runs an hour apart on the same
# lab: 2026-09-10 21:51 won it and encrypted to XtsAes256; 22:32 lost it and
# failed the step, leaving the machine with a recovery password protector and no
# encryption. A step that fails intermittently on somebody's rollout because
# Windows got there first is not a step, so the refusal is recovered from.
Describe 'Windows winning the race to start encryption' {

    It 'retries without the method when the first attempt is refused' {
        # Enable refuses every time here, which is enough to pin the RETRY and
        # the argument it carries. The fake models no state change, so the
        # condition is deliberately not "is it converting now?" - it is "a
        # method was asked for and refused", which also covers every other
        # reason manage-bde may reject one.
        $bitlocker = New-HDTFakeBitLockerService `
            -Volume @{ 'C:' = @{ VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off' } } `
            -Failure @{ Enable = 'manage-bde -on C: failed with exit code -2147024809: The parameter is incorrect.' }

        $context = & $script:newContext $bitlocker ([ordered] @{ HDTOSVolume = 'W:' }) 'Info' 'C:' 'FullOS'
        $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ method = 'XtsAes256'; escrow = 'none' })

        $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

        $enable = @($bitlocker.Operations | Where-Object { $_.Operation -eq 'Enable' })

        $enable.Count | Should -Be 2 -Because 'the refusal is recovered from by dropping the method'
        [string] $enable[0].Arguments[1] | Should -BeExactly 'XtsAes256'
        [string] $enable[1].Arguments[1] | Should -BeExactly ''

        # Both refused here, so the step still fails - and says so with the
        # tool's own sentence rather than inventing one.
        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*parameter is incorrect*'
    }

    It 'does not retry when the step named no method' {
        $bitlocker = New-HDTFakeBitLockerService `
            -Volume @{ 'C:' = @{ VolumeStatus = 'EncryptionInProgress'; ProtectionStatus = 'Off' } } `
            -Failure @{ Enable = 'something else went wrong' }

        $context = & $script:newContext $bitlocker ([ordered] @{ HDTOSVolume = 'W:' }) 'Info' 'C:' 'FullOS'
        $step = & $script:newStep 'Enable BitLocker' ([ordered] @{ method = 'XtsAes256'; escrow = 'none' })

        $null = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

        # The volume was already converting, so the method was dropped BEFORE
        # the first call - there is nothing left to drop and no second attempt.
        @($bitlocker.Operations | Where-Object { $_.Operation -eq 'Enable' }).Count | Should -Be 1
    }
}

# THE LOG SAYS WHAT THE VOLUME HAS, NOT WHAT THE STEP ASKED FOR.
#
# The completion line was built from $method - the REQUEST - so on 2026-09-10 it
# announced "C: is fully encrypted (XtsAes256, usedSpaceOnly)" about a volume
# carrying XTS-AES 128, because Windows had begun the conversion before the step
# ran and the cipher was fixed by then.
#
# THAT IS WORSE THAN NO LINE AT ALL. Somebody auditing a fleet for XTS-AES 256
# would have read it and believed it.
Describe 'what the completion line reports' {

    It 'names the method the volume actually carries' {
        $bitlocker = New-HDTFakeBitLockerService -Volume @{
            'C:' = @{ VolumeStatus = 'FullyEncrypted'; ProtectionStatus = 'Off'; EncryptionMethod = 'XtsAes128' }
        }

        $context = & $script:newContext $bitlocker ([ordered] @{ HDTOSVolume = 'W:' }) 'Info' 'C:' 'FullOS'
        $step = & $script:newStep 'Enable BitLocker' ([ordered] @{
                drive = 'C:'; method = 'XtsAes256'; escrow = 'none'; wait = $true
            })

        $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

        $result.Message | Should -BeLike '*XtsAes128*'
        $result.Message | Should -BeLike '*NOT the XtsAes256*' -Because (
            'a difference between the ask and the outcome is the whole reason to read this line')
    }

    It 'says it plainly when the volume got what was asked for' {
        $bitlocker = New-HDTFakeBitLockerService -Volume @{
            'C:' = @{ VolumeStatus = 'FullyEncrypted'; ProtectionStatus = 'Off'; EncryptionMethod = 'XtsAes256' }
        }

        $context = & $script:newContext $bitlocker ([ordered] @{ HDTOSVolume = 'W:' }) 'Info' 'C:' 'FullOS'
        $step = & $script:newStep 'Enable BitLocker' ([ordered] @{
                drive = 'C:'; method = 'XtsAes256'; escrow = 'none'; wait = $true
            })

        $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context

        $result.Message | Should -BeLike '*fully encrypted (XtsAes256*'
        $result.Message | Should -Not -BeLike '*NOT the*'
    }
}
