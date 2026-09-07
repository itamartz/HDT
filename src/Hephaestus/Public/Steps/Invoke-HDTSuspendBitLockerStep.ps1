function Invoke-HDTSuspendBitLockerStep {
    <#
        .SYNOPSIS
            Suspends BitLocker on the volume a Refresh is about to replace, so
            arming a one-shot boot entry does not put the machine into recovery.

        .DESCRIPTION
            THE STEP THAT HAS TO RUN BEFORE THE TRANSPORT IS ARMED. DESIGN 3.2:
            a Refresh runs on a production machine that is very likely
            encrypted, and the BootToWinPE steps after this one change the boot
            configuration the TPM measured. The next boot then lands in
            BitLocker recovery, on a machine nobody is standing in front of,
            wanting a key the technician did not bring - and the deployment
            stops there, on a machine it has already been told to wipe.

              - name: Suspend BitLocker
                type: SuspendBitLocker
                runIn: FullOS
                drive: '%HDTOSVolume%'   # blank is the volume this OS runs from
                rebootCount: 0           # 0 = until protection is resumed

            MDT DOES EXACTLY THIS, IN EXACTLY THIS PLACE. Templates\Client.xml:85
            is a step inside a group conditioned DeploymentType equals REFRESH,
            and the step immediately after it stages the transport. The script
            it runs calls Win32_EncryptableVolume.DisableKeyProtectors(0) -
            through WMI rather than manage-bde, and the BitLocker cmdlets this
            adapter uses are that same class's projection.

            A SUSPEND, AND NEVER A DECRYPT. The volume is about to be emptied by
            CleanVolume and overwritten by ApplyImage, so the plaintext
            underneath the ciphertext has no value to anybody, and a decrypt
            costs hours on a large disk to buy exactly that nothing. MDT's
            decrypt branch is for operating system combinations HDT does not
            support and is not ported. A suspend costs seconds and leaves the
            ciphertext where it was.

            IT RUNS IN THE FULL OS, AND THAT IS NOT AN OPTION. You cannot
            suspend the protectors of a volume from a WinPE that has not
            unlocked it, and by the time WinPE is running the boot that needed
            the suspend has already happened. The template declares
            runIn: FullOS and Test-HDTStepRunInPhase skips it anywhere else.

            REBOOT COUNT 0 IS THE DEFAULT AND THE SECOND REBOOT IS WHY. 1 means
            "until the next boot"; a Refresh boots into the staged WinPE,
            applies an image and boots again, so a suspend that expired on the
            first of those puts the second into recovery - the exact failure
            this step exists to prevent, arriving one reboot later. MDT passes 0
            for the same reason, and the count is the CALLER'S rather than the
            adapter's, as every other decision on IBitLockerService is.

            AN UNENCRYPTED MACHINE IS THE ORDINARY CASE, NOT A FAILURE. Most
            benches have no BitLocker on them at all, and Suspend-BitLocker
            errors on a volume with nothing to suspend. So this reads the volume
            first and asks for nothing when protection is already off - which is
            MDT's own guard restated: ZTIDisableBDEProtectors.wsf:88 selects
            only "where ProtectionStatus<>0". A step that suspended
            unconditionally would fail on every unencrypted machine in an
            estate, and each of those failures would read as a BitLocker fault
            rather than as a step that never looked.

            WHICH VOLUME IS THE SAME QUESTION Validate AND CleanVolume ALREADY
            ANSWER, AND IT IS ANSWERED THE SAME WAY. A Refresh carries no
            DiskPartition step, so nothing has published HDTOSVolume when this
            runs; MDT fills the identical gap identically, pinning the
            destination to SystemDrive (ZTIUtility.vbs:3586-3593). SystemDrive
            comes off IEnvironmentProvider and never off $env:, so the whole
            step is provable against a hand-written fake. Three places reading
            one fact three ways is how they come to suspend one volume and empty
            another.

            THERE IS NO RE-ENABLE HERE, AND THAT IS DELIBERATE. MDT tracks one
            through ISBDE and resumes protection on the machine it started from;
            HDT's Refresh replaces that installation entirely, so there is
            nothing left to resume protection ON. The new installation's
            encryption is client.yaml's EnableBitLocker step, in State Restore,
            which is a different volume's worth of work.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument. It may carry
            'drive' - a letter or a %Variable% - and 'rebootCount'.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry a
            BitLocker and an Environment service.

        .OUTPUTS
            A New-HDTStepResult. Data carries drive, rebootCount and suspended.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock `
                -Environment (New-HDTEnvironmentProvider) -BitLocker (New-HDTBitLockerService)
            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS `
                -WorkspaceRoot '\\srv\HDTShare' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\REFRESH-WIN11\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'SuspendBitLocker' })[0]

            Invoke-HDTSuspendBitLockerStep -Step $step -Context $context

            Suspends protection on the volume this Windows is running from,
            immediately before the sequence stages and arms its WinPE. Building
            the context is what the engine does before the first step; a step
            cannot be run without one.

        .EXAMPLE
            $bitLocker = New-HDTBitLockerService
            @($bitLocker.GetOperationName())

            GetVolume then Suspend, which is the order worth asserting: the read
            is what stops the step asking an unencrypted machine to suspend
            something it does not have.
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

    $component = 'SuspendBitLocker'

    $fail = {
        param([string] $Message, [System.Collections.IDictionary] $Data)

        $payload = $Data
        if ($null -eq $payload) { $payload = [ordered] @{} }
        if (-not $payload.Contains('errorId')) { $payload['errorId'] = 'HDTConfigurationError' }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component $component -Data $payload

        return (New-HDTStepResult -Status Failed -Message $Message -Data $payload)
    }

    # -- the services this step cannot work without ---------------------------

    try {
        $bitLocker = $Context.Service.GetRequired('BitLocker', $component)
        $environment = $Context.Service.GetRequired('Environment', $component)
    } catch {
        return (& $fail ([string] $_.Exception.Message) $null)
    }

    # -- how many reboots the suspend outlives --------------------------------
    #
    # READ BEFORE THE VOLUME IS TOUCHED, so a sequence that mistyped it is
    # refused while the machine is still whole rather than after the read.
    $countWritten = [string] (Get-HDTStepProperty -Step $Step -Name 'rebootCount' -Default '0' -Context $Context -Expand)

    $rebootCount = 0
    if (-not [int]::TryParse($countWritten.Trim(), [ref] $rebootCount)) {
        return (& $fail ("step '{0}': rebootCount is '{1}', which is not a number of reboots. 0 keeps protection suspended until it is explicitly resumed, which is what a Refresh needs - it reboots more than once, and a suspend that expired on the first would put the second into BitLocker recovery." -f
                $Step.Name, $countWritten) $null)
    }

    if ($rebootCount -lt 0) {
        return (& $fail ("step '{0}': rebootCount is {1}, and a suspend cannot last a negative number of reboots. 0 keeps protection suspended until it is explicitly resumed." -f
                $Step.Name, $rebootCount) $null)
    }

    # -- which volume ---------------------------------------------------------
    #
    # AS WRITTEN, so a refusal can quote it. '%HDTOSVolume%' resolving to
    # nothing and a step naming no drive at all are different mistakes.
    $written = [string] (Get-HDTStepProperty -Step $Step -Name 'drive' -Default '')
    $named = [string] (Get-HDTStepProperty -Step $Step -Name 'drive' -Default '' -Context $Context -Expand)

    if (-not [string]::IsNullOrWhiteSpace($written)) {
        $unresolved = New-Object -TypeName System.Collections.ArrayList
        [void] (Expand-HDTVariableToken -Value $written.Trim() -Scope $Context.Variable -Unresolved $unresolved)

        if (@($unresolved).Count -gt 0) { $named = '' }
    }

    $letter = $named.Trim().TrimEnd('\', '/').TrimEnd(':')

    # THE RUN'S OWN VOLUME, THEN THE ONE THIS WINDOWS IS ON. Validate resolves
    # the identical pair in the identical order for the partition-match guard,
    # and Assert-HDTCleanVolumeTarget reads the same SystemDrive off the same
    # service - so the pre-flight, the suspend and the emptying cannot end up
    # talking about three different volumes.
    $source = 'the step'

    if ($letter.Length -eq 0) {
        $letter = ([string] $Context.Variable['HDTOSVolume']).Trim().TrimEnd('\', '/').TrimEnd(':')
        $source = 'HDTOSVolume, published by this run'
    }

    if ($letter.Length -eq 0) {
        try {
            $letter = ([string] $environment.GetVariable('SystemDrive')).Trim().TrimEnd('\', '/').TrimEnd(':')
        } catch {
            $letter = ''
        }

        $source = 'SystemDrive, the volume this Windows is running from'
    }

    if ($letter -notmatch '^[A-Za-z]$') {
        return (& $fail ("step '{0}': there is no volume to suspend. The step named '{1}', HDTOSVolume is '{2}' and SystemDrive did not report a drive letter - and HDT will not guess which volume to unprotect before it changes the machine's boot configuration." -f
                $Step.Name, $written, [string] $Context.Variable['HDTOSVolume']) $null)
    }

    $drive = '{0}:' -f $letter.ToUpperInvariant()

    $data = [ordered] @{
        drive       = $drive
        rebootCount = $rebootCount
        source      = $source
        suspended   = $false
    }

    Write-HDTLog -Context $Context.Log -Component $component `
        -Message ("{0} is the volume this Refresh will replace, taken from {1}. Its BitLocker protectors are suspended before the boot configuration is changed, because arming a one-shot boot entry alters what the TPM measured and the next boot would otherwise ask for a recovery key." -f $drive, $source) `
        -Data $data

    # -- what is actually on it -----------------------------------------------

    try {
        $volume = $bitLocker.GetVolume($drive)
    } catch {
        return (& $fail ("step '{0}': the BitLocker state of {1} could not be read, so this run cannot tell whether changing the boot configuration would send the next boot into recovery: {2}" -f
                $Step.Name, $drive, [string] $_.Exception.Message) $data)
    }

    $data['volumeStatus'] = [string] $volume.VolumeStatus
    $data['protectionStatus'] = [string] $volume.ProtectionStatus

    # MDT'S OWN SELECT, RESTATED. ZTIDisableBDEProtectors.wsf:88 asks only for
    # volumes "where ProtectionStatus<>0", so it never calls the suspend on a
    # volume that has nothing to suspend either - and Suspend-BitLocker errors
    # when it is asked to.
    if ([string] $volume.ProtectionStatus -ne 'On') {
        $message = '{0} is not protected by BitLocker ({1}/{2}), so there is nothing to suspend and the boot entry can be armed as it stands.' -f
        $drive, [string] $volume.VolumeStatus, [string] $volume.ProtectionStatus

        Write-HDTLog -Context $Context.Log -Component $component -Message $message -Data $data

        return (New-HDTStepResult -Status Completed -Message $message -Data $data)
    }

    # -- the suspend ----------------------------------------------------------

    Write-HDTLog -Context $Context.Log -Component $component -Event 'native.exec' `
        -Message ('suspending BitLocker protection on {0} for {1} reboot(s)' -f $drive, $rebootCount) -Data $data

    try {
        $bitLocker.Suspend($drive, $rebootCount)
    } catch {
        $innermost = $_.Exception
        while ($null -ne $innermost.InnerException) { $innermost = $innermost.InnerException }

        $stack = ''
        if ($null -ne $_.ScriptStackTrace) { $stack = [string] $_.ScriptStackTrace }

        $data['errorId'] = 'HDTBitLockerError'
        $data['exception'] = $_.Exception.GetType().FullName
        $data['stackTrace'] = $stack

        return (& $fail ("step '{0}': BitLocker protection on {1} could not be suspended: {2}: {3}. The boot configuration has NOT been changed - a one-shot boot entry armed behind a live protector sends the next boot into recovery, which is a machine nobody can finish deploying without the key.{4}{5}" -f
                $Step.Name, $drive, $_.Exception.GetType().FullName, [string] $innermost.Message,
                [System.Environment]::NewLine, $stack) $data)
    }

    $data['suspended'] = $true

    # STILL ENCRYPTED, AND SAID OUT LOUD. The one question anybody asks about
    # this step afterwards is whether it decrypted the disk, and the answer has
    # to be readable in the log rather than inferred from the absence of an
    # hour.
    $message = 'BitLocker protection on {0} is suspended for {1} reboot(s). The volume is still encrypted ({2}) - this is a suspend, not a decrypt.' -f
    $drive, $rebootCount, [string] $volume.VolumeStatus

    Write-HDTLog -Context $Context.Log -Component $component -Event 'native.exec' -Message $message -Data $data

    return (New-HDTStepResult -Status Completed -Message $message -Data $data)
}
