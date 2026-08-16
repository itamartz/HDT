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
            adapter exception) - AND THERE IS NO SAFE WAY TO TEST IT ANYWAY. Three
            of its four methods change the encryption state of a physical disk,
            and the disk in front of this code during development is the
            developer's own. The contract file runs the real row for SHAPE ONLY
            and never calls a method on it; the fake carries the behaviour.

            Every decision - which protector, whether escrow succeeded, whether to
            encrypt at all - is made by the step. This projects four cmdlets and
            nothing else.

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
            AddProtector, BackupProtector and Enable, plus Operations,
            GetOperationName and ServiceName.

        .EXAMPLE
            $bitlocker = New-HDTBitLockerService
            $bitlocker.GetVolume('C:')
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

        return [pscustomobject] @{
            VolumeStatus     = [string] $volume.VolumeStatus
            ProtectionStatus = [string] $volume.ProtectionStatus
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

        $parameter = @{
            MountPoint       = $Drive
            EncryptionMethod = $Method
            SkipHardwareTest = $true
        }
        if ($UsedSpaceOnly) { $parameter['UsedSpaceOnly'] = $true }

        Enable-BitLocker @parameter | Out-Null
    }

    return $service
}
