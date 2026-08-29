function Invoke-HDTEnableBitLockerStep {
    <#
        .SYNOPSIS
            Turns BitLocker on, having first made sure the key can be recovered.

        .DESCRIPTION
            DESIGN 10.3, behind IBitLockerService so the whole step runs under
            Pester against a fake rather than against the developer's own disk.

              - name: Enable BitLocker
                type: EnableBitLocker
                drive: C:
                scope: usedSpaceOnly          # usedSpaceOnly | full
                method: XtsAes256             # Aes128 | Aes256 | XtsAes128 | XtsAes256
                protector: tpm                # tpm | tpmPin | tpmStartupKey
                recoveryPassword: true
                escrow: ad                    # ad | entra | none
                wait: false

            THE ORDER IS THE POINT, AND IT IS NOT NEGOTIABLE:

              1. read the volume; a volume already protected is left alone
              2. add the recovery password protector
              3. ESCROW IT, and fail the step if that does not work
              4. add the TPM protector
              5. enable encryption

            Step 3 comes before step 5 because A MACHINE ENCRYPTED WITH NO
            RECOVERABLE KEY IS WORSE THAN AN UNENCRYPTED ONE. It is a machine
            nobody can get into, and nobody finds out until the day the TPM is
            cleared or the board is replaced. An escrow that fails therefore stops
            the step with the disk still readable, which is a problem an
            administrator can fix.

            escrow: none IS ALLOWED AND WARNS. Some fleets genuinely manage keys
            another way. The warning is so that "we never escrowed anything" is a
            decision in the log rather than a discovery.

            scope: usedSpaceOnly IS THE DEFAULT AND IS NOT A COMPROMISE. HDT only
            ever deploys to a volume it just created (DESIGN 1, wipe-and-load), so
            the free space has never held plaintext - the one scenario where
            used-space-only is unambiguously right, and dramatically faster on a
            large disk. full: is for a disk that was not freshly wiped, or a
            compliance rule that says so regardless.

            THE RECOVERY PASSWORD NEVER REACHES A LOG LINE, at any level. The
            protector's ID is logged, because that is what an administrator needs
            to find the key in the directory; the key itself is what the directory
            is for.

            THE DRIVE IS NOT GUESSED. It comes from drive: or from HDTOSVolume,
            and with neither the step refuses naming the variable - rule 6.

            wait: false RETURNS ONCE ENCRYPTION IS UNDERWAY, which is the default
            because encrypting a large disk takes longer than the rest of the
            deployment put together and nothing after it needs to wait. wait: true
            polls until the volume reports FullyEncrypted, bounded by
            timeoutMinutes - a wait with no bound is a hung sequence.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry a
            BitLocker service.

        .OUTPUTS
            A New-HDTStepResult. Data carries drive, method, scope, protector,
            escrow and the escrowed protector's id - never the key.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'EnableBitLocker' })[0]

            Invoke-HDTEnableBitLockerStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTEnableBitLockerStep -Step $step -Context $context
            $result.Status

            Failed rather than thrown when the key cannot be escrowed - a volume
            encrypted with a key nobody can recover is the outcome this refuses.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE SAME FOUR LISTS THE CONSOLE OFFERS, read from the one place that
    # holds them. Written out here as well, they were four literals in a file
    # changed for engine reasons and four more in a file changed for window
    # reasons - and the way that goes wrong is a drop-down offering a value this
    # step refuses, four hours into a deployment.
    $allowedScope = @(Get-HDTStepPropertyChoice -Type 'EnableBitLocker' -Key 'scope')
    $allowedMethod = @(Get-HDTStepPropertyChoice -Type 'EnableBitLocker' -Key 'method')
    $allowedProtector = @(Get-HDTStepPropertyChoice -Type 'EnableBitLocker' -Key 'protector')
    $allowedEscrow = @(Get-HDTStepPropertyChoice -Type 'EnableBitLocker' -Key 'escrow')

    $fail = {
        param([string] $Message, [System.Collections.IDictionary] $Data)

        $payload = $Data
        if ($null -eq $payload) { $payload = [ordered] @{} }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component 'EnableBitLocker' -Data $payload

        return (New-HDTStepResult -Status Failed -Message $Message -Data $payload)
    }

    $property = $Step.Property

    # %VARIABLE% IS EXPANDED, and this step used to be the one that did not.
    # Its OWN template writes drive: '%HDTOSVolume%' - so the commonest possible
    # BitLocker step read the token literally, found it was not whitespace,
    # skipped the HDTOSVolume fallback below it, and took Substring(0, 1) of a
    # percent sign. The result was a step that tried to encrypt the drive '%:'
    # and failed at the machine saying so.
    #
    # NOTHING PRE-EXPANDS Property. Invoke-HDTStepAttempt does not touch it, so
    # every step that wants a token resolved asks for it - which is what
    # Get-HDTStepProperty -Expand does and what Invoke-HDTInstallCertificateStep
    # already did with the identical '%HDTOSVolume%' default.
    #
    # EVERY KEY, NOT JUST drive. A scope or an escrow target chosen per machine
    # by a rule is the same request, and a closed-set check against an
    # unexpanded token would refuse it with a message about a spelling.
    $read = {
        param([string] $Name, [string] $Default)

        if ($null -eq $property -or -not $property.Contains($Name)) { return $Default }

        $written = ([string] $property[$Name]).Trim()
        if ($written.Length -eq 0) { return $Default }

        return ([string] (Expand-HDTVariableToken -Value $written -Scope $Context.Variable)).Trim()
    }

    $readSwitch = {
        param([string] $Name, [bool] $Default)

        if ($null -eq $property -or -not $property.Contains($Name)) { return $Default }
        return [bool] $property[$Name]
    }

    # -- the options ----------------------------------------------------------

    $scope = & $read 'scope' 'usedSpaceOnly'
    if ($allowedScope -notcontains $scope) {
        return (& $fail ("scope '{0}' is not an encryption scope. The scopes are {1}: usedSpaceOnly encrypts the blocks in use, which is right for a volume HDT just created, and full encrypts the free space too." -f
                $scope, ($allowedScope -join ', ')) ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    $method = & $read 'method' 'XtsAes256'
    if ($allowedMethod -notcontains $method) {
        return (& $fail ("method '{0}' is not an encryption method BitLocker offers. The methods are {1}." -f
                $method, ($allowedMethod -join ', ')) ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    $protector = & $read 'protector' 'tpm'
    if ($allowedProtector -notcontains $protector) {
        return (& $fail ("protector '{0}' is not a protector HDT configures. The protectors are {1}." -f
                $protector, ($allowedProtector -join ', ')) ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    $escrow = & $read 'escrow' 'ad'
    if ($allowedEscrow -notcontains $escrow) {
        return (& $fail ("escrow '{0}' is not an escrow target. The targets are {1}." -f
                $escrow, ($allowedEscrow -join ', ')) ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    $recoveryPassword = & $readSwitch 'recoveryPassword' $true
    $wait = & $readSwitch 'wait' $false

    if ($escrow -ne 'none' -and -not $recoveryPassword) {
        return (& $fail ("this step escrows to '{0}' but declares recoveryPassword: false, so there would be no key to escrow. Either add a recovery password or set escrow: none." -f $escrow) `
            ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    $pin = & $read 'pin' ''
    if ($protector -eq 'tpmPin' -and [string]::IsNullOrWhiteSpace($pin)) {
        return (& $fail "protector: tpmPin needs a pin, and this step declares none." `
            ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    $startupKey = & $read 'startupKey' ''
    if ($protector -eq 'tpmStartupKey' -and [string]::IsNullOrWhiteSpace($startupKey)) {
        return (& $fail "protector: tpmStartupKey needs a startupKey path, and this step declares none." `
            ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    # -- the volume -----------------------------------------------------------

    # AS WRITTEN, so a refusal can quote it. '%HDTOSVolume%' resolving to
    # nothing and the step naming no drive at all are different mistakes, and
    # "names no drive" said about a step that plainly names one reads as a bug
    # in the console rather than as a variable nobody set.
    $driveWritten = ''
    if ($null -ne $property -and $property.Contains('drive')) {
        $driveWritten = ([string] $property['drive']).Trim()
    }

    $drive = & $read 'drive' ''

    if ([string]::IsNullOrWhiteSpace($drive)) {
        $drive = [string] $Context.Variable['HDTOSVolume']
    }

    # A TOKEN NOBODY SET IS LEFT STANDING, not blanked - Expand-HDTVariableToken
    # returns '%HDTOSVolume%' unchanged so a caller can say which name failed.
    # Refusing here is the whole point: without it the next line takes
    # Substring(0, 1) of a percent sign and the step goes to the machine asking
    # to encrypt the volume '%:'.
    if ($driveWritten.Length -gt 0) {
        $unresolved = New-Object -TypeName System.Collections.ArrayList
        [void] (Expand-HDTVariableToken -Value $driveWritten -Scope $Context.Variable -Unresolved $unresolved)

        if (@($unresolved).Count -gt 0) {
            return (& $fail ("step '{0}' names the drive '{1}' and {2} is not set. The partition step publishes HDTOSVolume; HDT will not guess which volume to encrypt." -f
                    $Step.Name, $driveWritten, ((@($unresolved) | ForEach-Object { [string] $_ }) -join ', ')) `
                ([ordered] @{ errorId = 'HDTConfigurationError' }))
        }
    }

    if ([string]::IsNullOrWhiteSpace($drive)) {
        return (& $fail ("step '{0}' names no drive and HDTOSVolume is not set. The partition step publishes it; HDT will not guess which volume to encrypt." -f $Step.Name) `
            ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    $drive = '{0}:' -f $drive.Trim().TrimEnd(':').Substring(0, 1).ToUpperInvariant()

    try {
        $bitlocker = $Context.Service.GetRequired('BitLocker', 'EnableBitLocker')
    } catch {
        return (& $fail ([string] $_.Exception.Message) $null)
    }

    $data = [ordered] @{
        drive     = $drive
        method    = $method
        scope     = $scope
        protector = $protector
        escrow    = $escrow
    }

    try {
        $volume = $bitlocker.GetVolume($drive)
    } catch {
        return (& $fail ("the BitLocker state of {0} could not be read: {1}" -f $drive, [string] $_.Exception.Message) $data)
    }

    if ([string] $volume.ProtectionStatus -eq 'On') {
        $message = '{0} is already protected by BitLocker; leaving it alone.' -f $drive

        Write-HDTLog -Context $Context.Log -Message $message -Component 'EnableBitLocker' -Data $data

        return (New-HDTStepResult -Status Completed -Message $message -Data $data)
    }

    # -- the recovery key, and getting it somewhere safe ----------------------

    if ($recoveryPassword) {
        try {
            $recovery = $bitlocker.AddProtector($drive, 'RecoveryPassword', '')
        } catch {
            return (& $fail ("the recovery password protector could not be added to {0}: {1}" -f
                    $drive, [string] $_.Exception.Message) $data)
        }

        $data['recoveryProtectorId'] = [string] $recovery.KeyProtectorId

        # The ID, never the key. An administrator finds the key in the directory
        # with this; anyone reading the log finds nothing they could unlock a disk
        # with.
        Write-HDTLog -Context $Context.Log -Component 'EnableBitLocker' `
            -Message ('added a recovery password protector {0} to {1}' -f $recovery.KeyProtectorId, $drive) `
            -Data ([ordered] @{ drive = $drive; recoveryProtectorId = [string] $recovery.KeyProtectorId })

        if ($escrow -eq 'none') {
            Write-HDTLog -Context $Context.Log -Severity Warning -Component 'EnableBitLocker' `
                -Message ("{0} will be encrypted with escrow: none, so the recovery key exists only on this machine. If the TPM is cleared or the board is replaced, the data is gone." -f $drive) `
                -Data $data
        } else {
            # BEFORE Enable, and the step stops here if it does not work.
            try {
                $bitlocker.BackupProtector($drive, [string] $recovery.KeyProtectorId, $escrow)
            } catch {
                return (& $fail ("the recovery key for {0} could not be escrowed to {1}: {2}. Encryption has NOT been started - a machine encrypted with no recoverable key is worse than one left unencrypted." -f
                        $drive, $escrow, [string] $_.Exception.Message) $data)
            }

            Write-HDTLog -Context $Context.Log -Component 'EnableBitLocker' `
                -Message ('escrowed the recovery key for {0} to {1}' -f $drive, $escrow) -Data $data
        }
    }

    # -- the protector the machine unlocks with -------------------------------

    $protectorType = 'Tpm'
    $protectorArgument = ''

    if ($protector -eq 'tpmPin') {
        $protectorType = 'TpmPin'
        $protectorArgument = $pin
    }

    if ($protector -eq 'tpmStartupKey') {
        $protectorType = 'TpmStartupKey'
        $protectorArgument = $startupKey
    }

    try {
        $null = $bitlocker.AddProtector($drive, $protectorType, $protectorArgument)
    } catch {
        return (& $fail ("the {0} protector could not be added to {1}: {2}" -f
                $protectorType, $drive, [string] $_.Exception.Message) $data)
    }

    # -- encryption -----------------------------------------------------------

    $usedSpaceOnly = ($scope -eq 'usedSpaceOnly')

    Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component 'EnableBitLocker' `
        -Message ('encrypting {0} with {1} ({2})' -f $drive, $method, $scope) -Data $data

    try {
        $bitlocker.Enable($drive, $method, $usedSpaceOnly)
    } catch {
        return (& $fail ("encryption of {0} could not be started: {1}" -f $drive, [string] $_.Exception.Message) $data)
    }

    if (-not $wait) {
        $message = 'encryption of {0} is underway ({1}, {2}).' -f $drive, $method, $scope

        Write-HDTLog -Context $Context.Log -Message $message -Event 'native.exec' `
            -Component 'EnableBitLocker' -Data $data

        return (New-HDTStepResult -Status Completed -Message $message -Data $data)
    }

    # -- waiting for it, bounded ----------------------------------------------

    $clock = $Context.Service.Clock
    $startedUtc = $clock.GetUtcNow()

    $timeoutMinute = 60
    if ([int] $Step.TimeoutMinutes -gt 0) { $timeoutMinute = [int] $Step.TimeoutMinutes }

    while ($true) {
        $clock.Sleep(15000)

        try {
            $volume = $bitlocker.GetVolume($drive)
        } catch {
            return (& $fail ("the BitLocker state of {0} could not be read while waiting: {1}" -f
                    $drive, [string] $_.Exception.Message) $data)
        }

        if ([string] $volume.VolumeStatus -eq 'FullyEncrypted') {
            $message = '{0} is fully encrypted ({1}, {2}).' -f $drive, $method, $scope

            Write-HDTLog -Context $Context.Log -Message $message -Event 'native.exec' `
                -Component 'EnableBitLocker' -Data $data

            return (New-HDTStepResult -Status Completed -Message $message -Data $data)
        }

        $elapsedMinute = ($clock.GetUtcNow() - $startedUtc).TotalMinutes

        # STILL ENCRYPTING, AND SAYING SO. This loop can run for the better part
        # of an hour and used to write nothing at all until it finished, so the
        # progress card showed a motionless "Enable BitLocker" - and because
        # elapsed on that card is derived from the first and last record in the
        # log, its clock stopped too. A machine encrypting a disk looked
        # identical to a machine that had died doing it.
        #
        # NO PERCENTAGE, AND THAT IS DELIBERATE. The volume shape this step
        # reads carries VolumeStatus and no completion figure, and inventing one
        # from the elapsed time would be a bar that lied about a disk. A
        # step.progress with no percent leaves the step bar collapsed and still
        # moves the clock, which is the fact that was missing - see
        # Get-HDTDeploymentProgress, which reads the percentage only when there
        # is one.
        #
        # ONCE PER POLL IS ONCE EVERY FIFTEEN SECONDS, which is the interval the
        # step already sleeps for. It adds no round trips of its own.
        Write-HDTLog -Context $Context.Log -Event 'step.progress' -Component 'EnableBitLocker' `
            -Message ('{0} is still encrypting ({1}), {2:0} minute(s) so far.' -f
                $drive, [string] $volume.VolumeStatus, $elapsedMinute) `
            -Data ([ordered] @{
                drive         = $drive
                volumeStatus  = [string] $volume.VolumeStatus
                elapsedMinute = [int] $elapsedMinute
            })

        Update-HDTProgressDisplay -Context $Context

        if ($elapsedMinute -ge $timeoutMinute) {
            # A bounded wait that gives up is a step an administrator can
            # diagnose; an unbounded one is a deployment that never ends. The disk
            # is still encrypting, and that is said plainly.
            return (& $fail ("{0} did not finish encrypting within {1} minute(s); it reports {2}. Encryption is still running - this step waited and gave up, it did not stop the disk." -f
                    $drive, $timeoutMinute, [string] $volume.VolumeStatus) $data)
        }
    }
}
