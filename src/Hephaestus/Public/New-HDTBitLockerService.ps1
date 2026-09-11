function New-HDTBitLockerService {
    <#
        .SYNOPSIS
            The real IBitLockerService: a thin adapter over the BitLocker module.

        .DESCRIPTION
            DESIGN 10.3's encryption service. Rule 5 forbids engine logic from
            calling Enable-BitLocker directly, so the EnableBitLocker step
            receives this object and can be handed New-HDTFakeBitLockerService in
            a test.

            IT IS BRANCH-FREE, WHICH IS WHY IT IS NOT UNIT TESTED (rule 1's
            adapter exception) - AND THERE IS NO SAFE WAY TO TEST IT ANYWAY. Four
            of its five methods change the encryption state of a physical disk,
            and the disk in front of this code during development is the
            developer's own. The contract file runs the real row for SHAPE ONLY
            and never calls a method on it; the fake carries the behaviour.

            Every decision - which protector, whether escrow succeeded, whether to
            encrypt at all, how many reboots a suspend lasts - is made by the
            step. This projects five cmdlets and nothing else.

            THE PROTECTOR TYPE IS A STRING THE STEP CHOOSES, mapping to the switch
            Add-BitLockerKeyProtector wants. The mapping is here rather than in the
            step because it is the adapter's job to know the cmdlet's shape, and
            the step's job to know DESIGN 10.3's vocabulary.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every call
            is appended to it as well as to $Operations.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject carrying GetVolume,
            AddProtector, BackupProtector, Enable and Suspend, plus Operations,
            GetOperationName and ServiceName.

        .EXAMPLE
            $bitLocker = New-HDTBitLockerService
            $bitLocker.GetVolume('C:')

            The volume's protection state, read before anything is turned on.

        .EXAMPLE
            @($bitLocker.GetOperationName())

            The order it was asked to work in, which is the thing worth asserting:
            Enable must never come before the protector is backed up. A volume
            encrypted with a key nobody can recover is the outcome that matters.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds the service object; encrypting is done by the caller through it, and the step that calls it refuses an ambiguous target.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'The TPM PIN is authored in sequence.yaml as readable text, exactly as HDTAdminPassword is (DESIGN 4.5.2): a value WinPE must use with no human present cannot be protected by a key that also ships in the boot image. Add-BitLockerKeyProtector requires a SecureString, so the conversion happens here, at the last possible moment, rather than the interface pretending the value was ever secret. The real control is the one DESIGN 4.5.2 names - treat the workspace and the boot media as credentials.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'BitLockerService'
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetVolume -Value {
        param([string] $Drive)

        $this.Record('GetVolume', @($Drive))

        $volume = Get-BitLockerVolume -MountPoint $Drive

        # THE PERCENTAGE AND THE METHOD COME BACK TOO, AND THEY USED NOT TO.
        #
        # Get-BitLockerVolume hands both over for nothing and this projection
        # dropped them, so the one thing a step could say while it waited was
        # how many minutes it had been waiting: "C: is still encrypting
        # (EncryptionInProgress), 10 minute(s) so far", ten times over. An
        # administrator watching a machine they cannot touch wants the number
        # that is MOVING - 95.7% is the difference between "nearly done" and
        # "stuck" - and CLAUDE.md's logging rule asks for the value, not just
        # the fact that there was one.
        #
        # THE METHOD MATTERS FOR THE SAME REASON. A volume Windows started
        # encrypting keeps the cipher Windows chose, so a sequence that asked
        # for XtsAes256 can finish as XTS-AES 128 - and the only honest way to
        # say so in the log is to read what the volume actually has.
        return [pscustomobject] @{
            VolumeStatus         = [string] $volume.VolumeStatus
            ProtectionStatus     = [string] $volume.ProtectionStatus
            EncryptionPercentage = [double] $volume.EncryptionPercentage
            EncryptionMethod     = [string] $volume.EncryptionMethod
            KeyProtector     = [object[]] @($volume.KeyProtector | ForEach-Object {
                    [pscustomobject] @{
                        KeyProtectorId   = [string] $_.KeyProtectorId
                        KeyProtectorType = [string] $_.KeyProtectorType
                        RecoveryPassword = [string] $_.RecoveryPassword
                    }
                })
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name AddProtector -Value {
        param([string] $Drive, [string] $Type, [string] $Argument)

        $this.Record('AddProtector', @($Drive, $Type, $Argument))

        $parameter = @{ MountPoint = $Drive }

        # The vocabulary is DESIGN 10.3's; the switch names are the cmdlet's.
        if ($Type -eq 'RecoveryPassword') { $parameter['RecoveryPasswordProtector'] = $true }
        if ($Type -eq 'Tpm') { $parameter['TpmProtector'] = $true }
        if ($Type -eq 'TpmPin') {
            $parameter['TpmAndPinProtector'] = $true
            $parameter['Pin'] = ConvertTo-SecureString -String $Argument -AsPlainText -Force
        }
        if ($Type -eq 'TpmStartupKey') {
            $parameter['TpmAndStartupKeyProtector'] = $true
            $parameter['StartupKeyPath'] = $Argument
        }

        $volume = Add-BitLockerKeyProtector @parameter

        $added = @($volume.KeyProtector)[-1]

        return [pscustomobject] @{
            KeyProtectorId   = [string] $added.KeyProtectorId
            KeyProtectorType = [string] $added.KeyProtectorType
            RecoveryPassword = [string] $added.RecoveryPassword
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name BackupProtector -Value {
        param([string] $Drive, [string] $KeyProtectorId, [string] $Target)

        $this.Record('BackupProtector', @($Drive, $KeyProtectorId, $Target))

        if ($Target -eq 'ad') {
            Backup-BitLockerKeyProtector -MountPoint $Drive -KeyProtectorId $KeyProtectorId | Out-Null
        }

        if ($Target -eq 'entra') {
            BackupToAAD-BitLockerKeyProtector -MountPoint $Drive -KeyProtectorId $KeyProtectorId | Out-Null
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name Enable -Value {
        param([string] $Drive, [string] $Method, [bool] $UsedSpaceOnly)

        $this.Record('Enable', @($Drive, $Method, $UsedSpaceOnly))

        # manage-bde AND NOT Enable-BitLocker, AND THE REASON IS THE CMDLET'S OWN
        # PARAMETER SETS.
        #
        # Enable-BitLocker HAS NO "JUST START ENCRYPTING" FORM. Every one of its
        # nine sets requires a protector switch - TpmProtector,
        # PasswordProtector, RecoveryPasswordProtector and so on - so a call
        # carrying MountPoint, EncryptionMethod, SkipHardwareTest and
        # UsedSpaceOnly binds to nothing at all and fails with "Parameter set
        # cannot be resolved using the specified named parameters."
        #
        # THAT IS WHAT THIS METHOD USED TO DO, AND IT COULD NEVER HAVE WORKED ON
        # ANY MACHINE. It was never unit tested - rule 1 exempts a branch-free
        # adapter - and no full-OS leg had ever reached it, so it sat here from
        # M6 until the first real Refresh ran it on 2026-09-10.
        #
        # THE PROTECTORS ALREADY EXIST BY THE TIME THIS IS CALLED, which is the
        # whole shape of DESIGN 10.3: the step adds the recovery password
        # protector FIRST so it can be escrowed BEFORE any data is encrypted,
        # then adds the real protector, then starts encryption. What starts
        # encryption on a volume whose protectors are already in place is
        # manage-bde -on, and that is precisely what MDT does at the same point
        # for the same reason (ZTIBde.wsf:139, "manage-bde.exe -on <drive>
        # -used").
        #
        # THE MAP IS DATA, NOT A BRANCH. manage-bde spells the methods in lower
        # case with an underscore; the module spells them in Pascal case. An
        # adapter translating a name into the exact argument a native tool takes
        # is the job CLAUDE.md gives adapters.
        $native = @{
            'Aes128'    = 'aes128'
            'Aes256'    = 'aes256'
            'XtsAes128' = 'xts_aes128'
            'XtsAes256' = 'xts_aes256'
        }

        # AN EMPTY METHOD MEANS "WHATEVER THE VOLUME IS ALREADY USING", AND IT
        # IS NOT A CONVENIENCE.
        #
        # manage-bde REFUSES -EncryptionMethod ON A VOLUME THAT IS ALREADY
        # CONVERTING - "ERROR: An error occurred (code 0x80070057): The
        # parameter is incorrect" - because the method is chosen when encryption
        # starts and cannot be changed half way through. Windows 11 starts
        # automatic device encryption itself during OOBE, so by the time a
        # State Restore step runs, a freshly deployed machine is routinely part
        # way through an XTS-AES 128 pass that nobody asked for. Proven on the
        # machine on 2026-09-10: with -em it failed, without it the same call
        # answered "BitLocker protection will be on when encryption completes".
        #
        # THE STEP DECIDES, NOT THIS METHOD. It has already read the volume, so
        # it knows whether the method is still HDT's to choose, and it says so
        # in the log when it is not. An adapter branching on volume state would
        # be making that decision somewhere no test can reach it.
        # SPIKES S13.5: under 5.1 the 2>&1 below wraps every stderr line in an
        # ErrorRecord, and the ErrorActionPreference of Stop that engine code
        # sets makes the FIRST one terminating - so manage-bde printing a
        # warning would kill this call before its exit code is ever read, and
        # the message an administrator got would be the warning rather than the
        # refusal. Local to this method scope, exactly as GrantAccess and
        # TakeOwnership do it on the file system adapter.
        $ErrorActionPreference = 'Continue'

        $argument = [System.Collections.ArrayList]::new()
        [void] $argument.AddRange(@('-on', $Drive, '-SkipHardwareTest'))

        if (-not [string]::IsNullOrWhiteSpace($Method)) {
            [void] $argument.AddRange(@('-EncryptionMethod', [string] $native[$Method]))
        }

        if ($UsedSpaceOnly) { [void] $argument.Add('-UsedSpaceOnly') }

        $output = & "$env:SystemRoot\System32\manage-bde.exe" @argument 2>&1
        $code = $LASTEXITCODE

        # THE TOOL'S OWN WORDS, because they are the ones worth reading. 0x80310030
        # ("remove the bootable media") is a sentence a technician can act on and
        # "manage-bde failed" is not.
        if ($code -ne 0) {
            throw ("manage-bde -on {0} failed with exit code {1}: {2}" -f
                $Drive, $code, ((@($output) | ForEach-Object { [string] $_ }) -join ' '))
        }
    }

    # A SUSPEND, AND NEVER A DECRYPT. DESIGN 3.2: a Refresh arms a one-shot
    # ramdisk boot entry on a machine that is very likely encrypted, which
    # changes the boot configuration the TPM measured - and the next boot then
    # lands in BitLocker recovery, on a machine nobody is standing in front of,
    # wanting a key the technician did not bring.
    #
    # MDT does exactly this, immediately before it arms, and it does it through
    # WMI rather than manage-bde: ZTIDisableBDEProtectors.wsf:88 selects
    # "Select * from Win32_EncryptableVolume where ProtectionStatus<>0" and :96
    # calls objEncVol.DisableKeyProtectors(0). Suspend-BitLocker is the same
    # operation through the module the rest of this adapter already uses; the
    # BitLocker cmdlets are that WMI class's own projection.
    #
    # THE DECRYPT BRANCH IN THAT SCRIPT (:104) IS NOT PORTED AND WILL NOT BE.
    # It exists for Vista and Server 2008/2008R2 combinations HDT does not
    # support, and decrypting a volume in order to deploy over it costs hours on
    # a large disk and buys nothing: the volume is about to be emptied by
    # CleanVolume and overwritten by ApplyImage, so the plaintext underneath the
    # ciphertext has no value to anybody. A suspend costs seconds and leaves the
    # ciphertext exactly where it was.
    #
    # RebootCount IS THE CALLER'S, not this adapter's. MDT passes 0, which is
    # "stay suspended until protection is explicitly resumed" rather than "until
    # the next boot" - a Refresh reboots more than once, and a suspend that
    # expired on the first of them would put the second into recovery.
    $service | Add-Member -MemberType ScriptMethod -Name Suspend -Value {
        param([string] $Drive, [int] $RebootCount)

        $this.Record('Suspend', @($Drive, $RebootCount))

        Suspend-BitLocker -MountPoint $Drive -RebootCount $RebootCount | Out-Null
    }

    return $service
}
