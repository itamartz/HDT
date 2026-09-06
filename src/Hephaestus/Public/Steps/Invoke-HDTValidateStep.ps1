function Invoke-HDTValidateStep {
    <#
        .SYNOPSIS
            Pre-flights a machine before anything destructive runs on it.

        .DESCRIPTION
            Checks the machine against what the sequence is about to do to it.
            The checks are declared on the step:

              - name: Validate
                type: Validate
                minRamMB: 2048
                minDiskGB: 60
                requireUefi: true                    # optional
                diskNumber: 0                        # optional
                requireVariable: [HDTComputerName]   # optional
                imageVersion: '10.0.26100'           # optional, REFRESH only
                imageSizeMB: 5200                    # optional, REFRESH only
                allowOtherPartition: false           # optional, REFRESH only

            THREE OF THEM RUN ONLY ON A REFRESH, and they are MDT's
            ZTIValidate.wsf guards under HDT's own names: the downgrade refusal
            (:138-146), the partition-match refusal (:151-154) and the free-space
            refusal (:231-256). On a NEWCOMPUTER run every one is reported
            'skipped' with the reason, because a bare-metal deployment
            repartitions the disk - the volume they measure does not survive to
            be measured - and it lays Windows onto a machine that may carry none.
            MDT draws the line in the same place and skips the same three. The
            block near the end of this function says what each refuses and why it
            has to refuse HERE rather than later.

            IT RUNS Select-HDTTargetDisk WITH THE ARGUMENTS DiskPartition WILL
            USE, and that is the reason the step exists. A deployment that is
            going to refuse to choose a disk refuses HERE, in the first step,
            while the machine is still intact - rather than after the technician
            has watched two minutes of progress bar. The protected drive letters
            are built the same way too, so the pre-flight cannot pass a machine
            the real step would then refuse.

            IT REPORTS EVERY FAILED CHECK, NOT THE FIRST. 'not enough RAM',
            followed twenty minutes later by 'no disk large enough', is two trips
            to the bench.

            AND IT REPORTS EVERY PASSED CHECK TOO, WITH ITS THRESHOLD. This
            step's whole content is its checks, so "this machine passed the
            pre-flight" on its own is unfalsifiable: a reader cannot tell whether
            eight checks ran or one, and a check weakened next month leaves the
            log looking identical. Worse, it was ASYMMETRIC - the failure path
            printed every check and its bound, so the only way to learn what HDT
            checks was to fail it, and an administrator qualifying a new hardware
            model had to break a machine to read the rules.

            THE THRESHOLD IS THE PART THAT WAS UNKNOWABLE, and it is what the
            Debug enumeration exists to publish. MDT does the same thing with two
            adjacent lines - "Disk Size : ..." then "Min Size : ..." - and says
            so on the pass path as well ("Computer has sufficient memory.").
            Here it is one line per check, with the observed value, the bound it
            was measured against, and the verdict.

            INFO IS TWO LINES AND NO MORE. A technician reads the verdict and the
            warning count at a glance; the enumeration is at Debug, where it does
            not cost anything to have. Where HDT departs from MDT is that the
            CHOSEN DISK IS NAMED AT INFO - ZTIUtility logs its answer at Verbose,
            so on a default-verbosity MDT run the disk it picked never appears
            and has to be inferred from the free-space messages.

            THE DISK DECISION CARRIES ITS REASON. "disk 0 is the deployment
            target" is a CHOICE: on a laptop with an NVMe, an SD reader and the
            stick it booted from, picking disk 0 excluded two disks. DESIGN 9.1
            and the DiskPartition rule say HDT must not guess which disk to wipe,
            and wiping the wrong one is the most destructive thing this class of
            tool does - so every disk considered is logged with the rule that
            excluded it. The reasons come from Get-HDTTargetDiskAssessment, which
            is the same evaluation Select-HDTTargetDisk decides with, because two
            copies of that judgement would eventually disagree.

            WARNINGS EXIST BECAUSE PASS/FAIL BINARY HAD NOWHERE TO PUT THEM. A
            disk that clears the minimum by less than Windows Setup itself needs,
            or an exclusion rule overridden by naming a disk, should not stop a
            deployment and should not vanish either. MDT's convention is copied:
            a warning states the assumption it is proceeding on. The COUNT is on
            the Info line so it is visible without opening Debug.

            EVERY CHECK IS OPT-IN except the target disk. A Validate step that
            declares no bound imposes none; what it always does is prove that
            exactly one disk of a usable size is present. An undeclared check is
            still REPORTED, as 'skipped' - a check absent from the log and a
            check that passed look identical, and the reader needs to know it
            exists.

            IT DOES NOT ASK WHETHER THE DISK IS EMPTY, and it used to. Mirroring
            DiskPartition's `wipe` guard meant a machine carrying C: and D: -
            every machine that has ever been deployed - failed step 1 with "the
            step did not declare that it may be replaced", and the fix was to
            repeat `wipe: true` on a step that wipes nothing. A rebuild is the
            normal case. Whether the target may be erased is DiskPartition's
            question, because DiskPartition is what erases it, and that step
            still refuses without `wipe: true`.

            IT READS FACTS OUT OF THE CONTEXT VARIABLES, NEVER CIM. HDTMemory and
            HDTIsUEFI were gathered by phase 02 before the sequence began; a step
            that re-gathered would be a second answer to the same question, and
            PROJECT constraint 4 forbids it reaching CIM at all.

            A REFUSAL IS RETURNED, NOT THROWN. The step contract requires a
            result whose Status is in the closed set, so the refusal's errorId
            travels in the result's Data, where Get-HDTFailureClass reads it and
            classes it Configuration - which is what stops a refusal being
            retried.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry a
            Disk service, and an Environment service on a REFRESH run - that is
            where SystemDrive is read from, which is how the partition-match
            guard knows which volume the machine is running from without touching
            hardware.

        .OUTPUTS
            A New-HDTStepResult. Data carries check - one structured row per
            check, with its observed value, threshold and verdict - plus warning,
            warningCount, diskNumber on success and errorId on a refusal.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'Validate' })[0]

            Invoke-HDTValidateStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTValidateStep -Step $step -Context $context
            $result.Data.check | Format-Table check, observed, threshold, result

            Every pre-flight check with its verdict, including the ones the
            sequence did not ask for and every disk that was not chosen. A
            failure here is meant to stop the sequence before the partition step
            runs.
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

    $failure = New-Object -TypeName System.Collections.ArrayList
    $advisory = New-Object -TypeName System.Collections.ArrayList
    $check = New-Object -TypeName System.Collections.ArrayList
    $data = [ordered] @{}

    $lookup = {
        param([string] $Name)

        foreach ($key in @($Context.Variable.Keys)) {
            if ([string] $key -eq $Name) { return $Context.Variable[$key] }
        }

        return $null
    }

    # ONE ROW PER CHECK, SIX FIELDS, ALWAYS THE SAME SIX. The Debug line and the
    # structured payload are the same information rendered twice, so the summary
    # window never has to parse the prose back apart.
    $addCheck = {
        param([string] $Name, [string] $Key, [string] $Observed, [string] $Threshold,
            [string] $Result, [string] $Reason)

        [void] $check.Add([ordered] @{
                check     = $Name
                key       = $Key
                observed  = $Observed
                threshold = $Threshold
                result    = $Result
                reason    = $Reason
            })
    }

    # Bytes are what the services report and gigabytes are what an author typed,
    # so the log says both in the units the reader is holding.
    $sizeText = {
        param([long] $Byte)

        return ('{0:N1} GB' -f ([double] $Byte / 1073741824))
    }

    try {
        $minimumRamMb = Get-HDTStepProperty -Step $Step -Name 'minRamMB' -Context $Context -Expand -As Long
        $minimumDiskGb = Get-HDTStepProperty -Step $Step -Name 'minDiskGB' -Context $Context -Expand -As Long
        $requireUefi = Get-HDTStepProperty -Step $Step -Name 'requireUefi' -Default $false -Context $Context -Expand -As Bool
        $requireVariable = Get-HDTStepProperty -Step $Step -Name 'requireVariable'
        $minimumTpmVersion = Get-HDTStepProperty -Step $Step -Name 'minTpmVersion' -Context $Context -Expand

        # THE THREE A REFRESH RUNS. See the block near the end of this function
        # for what each one refuses and why it has to refuse here.
        $imageVersion = Get-HDTStepProperty -Step $Step -Name 'imageVersion' -Context $Context -Expand
        $imageSizeMb = Get-HDTStepProperty -Step $Step -Name 'imageSizeMB' -Context $Context -Expand -As Long
        $allowOtherPartition = Get-HDTStepProperty -Step $Step -Name 'allowOtherPartition' -Default $false `
            -Context $Context -Expand -As Bool
    } catch {
        $message = [string] $_.Exception.Message

        Write-HDTLog -Context $Context.Log -Message $message -Severity Error -Event step.fail -Component 'Validate'

        return (New-HDTStepResult -Status Failed -Message $message `
                -Data ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    # -- memory -----------------------------------------------------------

    $memory = & $lookup 'HDTMemory'
    $memoryText = 'not reported'
    if ($null -ne $memory -and -not [string]::IsNullOrWhiteSpace([string] $memory)) {
        $memoryText = '{0} MB' -f ([string] $memory).Trim()
    }

    if ($null -ne $minimumRamMb -and $minimumRamMb -gt 0) {
        $memoryThreshold = 'minimum {0} MB' -f $minimumRamMb
        $memoryReason = ''
        $memoryResult = 'pass'

        if ($null -eq $memory -or [string]::IsNullOrWhiteSpace([string] $memory)) {
            $memoryResult = 'fail'
            $memoryReason = 'the machine reports no HDTMemory, so the minimum of {0} MB cannot be checked. Gather the machine facts before this step.' -f $minimumRamMb
        } else {
            $actual = [long] 0
            if (-not [long]::TryParse(([string] $memory).Trim(), [ref] $actual)) {
                $memoryResult = 'fail'
                $memoryReason = "HDTMemory is '{0}', which is not a number of megabytes." -f $memory
            } elseif ($actual -lt $minimumRamMb) {
                $memoryResult = 'fail'
                $memoryReason = 'this machine has {0} MB of memory and the sequence requires {1} MB.' -f $actual, $minimumRamMb
            }
        }

        if ($memoryResult -eq 'fail') { [void] $failure.Add($memoryReason) }

        & $addCheck 'memory' 'minRamMB' $memoryText $memoryThreshold $memoryResult $memoryReason
    } else {
        & $addCheck 'memory' 'minRamMB' $memoryText 'not declared' 'skipped' ''
    }

    # -- firmware ---------------------------------------------------------

    $firmware = & $lookup 'HDTIsUEFI'

    $isUefi = $false
    if ($firmware -is [bool]) {
        $isUefi = [bool] $firmware
    } elseif ($null -ne $firmware) {
        # A rules.yaml value arrives as text, so 'True' counts and '0' does not.
        $isUefi = ([string] $firmware).Trim() -eq 'True'
    }

    $firmwareText = 'BIOS'
    if ($isUefi) { $firmwareText = 'UEFI' }
    if ($null -eq $firmware -or [string]::IsNullOrWhiteSpace([string] $firmware)) { $firmwareText = 'not reported' }

    if ($requireUefi) {
        $firmwareReason = ''
        $firmwareResult = 'pass'

        if (-not $isUefi) {
            $firmwareResult = 'fail'
            $firmwareReason = 'this sequence requires UEFI firmware and HDTIsUEFI is not true for this machine.'
            [void] $failure.Add($firmwareReason)
        }

        & $addCheck 'firmware' 'requireUefi' $firmwareText 'required: UEFI' $firmwareResult $firmwareReason
    } else {
        & $addCheck 'firmware' 'requireUefi' $firmwareText 'not declared' 'skipped' ''
    }

    # -- TPM ---------------------------------------------------------------
    #
    # WINDOWS 11 REQUIRES TPM 2.0, and a machine without one gets all the way
    # through partitioning and imaging before Setup says so - on a disk that has
    # already been wiped. Checking it here costs nothing and is the difference
    # between a refusal and a rebuild.
    #
    # HDTTPMVersion IS Win32_Tpm.SpecVersion'S FIRST COMPONENT, gathered before
    # the sequence began. SpecVersion is '2.0, 0, 1.38'; only the first part is
    # the spec, and Get-HDTMachineFact has already taken it.

    $reported = & $lookup 'HDTTPMVersion'

    $tpmText = 'no TPM'
    if ($null -ne $reported -and -not [string]::IsNullOrWhiteSpace([string] $reported)) {
        $tpmText = ([string] $reported).Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace([string] $minimumTpmVersion)) {
        $wanted = $null
        $tpmReason = ''
        $tpmResult = 'pass'
        $tpmThreshold = 'minimum {0}' -f ([string] $minimumTpmVersion).Trim()

        if (-not [version]::TryParse(([string] $minimumTpmVersion).Trim(), [ref] $wanted)) {
            $tpmResult = 'fail'
            $tpmReason = "minTpmVersion is '{0}', which is not a version number." -f $minimumTpmVersion
        } else {
            # NO TPM IS ITS OWN MESSAGE. 'this machine reports TPM version ' with
            # nothing after it is the kind of sentence that sends a technician to
            # look for a setting that is not the problem.
            if ($null -eq $reported -or [string]::IsNullOrWhiteSpace([string] $reported)) {
                $tpmResult = 'fail'
                $tpmReason = 'this machine reports no TPM, and the sequence requires version {0} or later. On a virtual machine, a TPM has to be added to the VM.' -f $wanted
            } else {
                $actualVersion = $null

                if (-not [version]::TryParse(([string] $reported).Trim(), [ref] $actualVersion)) {
                    $tpmResult = 'fail'
                    $tpmReason = "HDTTPMVersion is '{0}', which is not a version number." -f $reported
                } elseif ($actualVersion -lt $wanted) {
                    $tpmResult = 'fail'
                    $tpmReason = 'this machine has TPM {0} and the sequence requires {1} or later.' -f $actualVersion, $wanted
                }
            }
        }

        if ($tpmResult -eq 'fail') { [void] $failure.Add($tpmReason) }

        & $addCheck 'TPM' 'minTpmVersion' $tpmText $tpmThreshold $tpmResult $tpmReason
    } else {
        & $addCheck 'TPM' 'minTpmVersion' $tpmText 'not declared' 'skipped' ''
    }

    # -- authored variables -----------------------------------------------

    $declaredVariable = New-Object -TypeName System.Collections.ArrayList

    foreach ($name in @($requireVariable)) {
        $text = ([string] $name).Trim()
        if ($text.Length -eq 0) { continue }

        [void] $declaredVariable.Add($text)

        $value = & $lookup $text

        $variableReason = ''
        $variableResult = 'pass'
        $variableText = [string] $value

        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string] $value)) {
            $variableResult = 'fail'
            $variableText = 'not resolved'
            $variableReason = 'the variable {0} is required by this sequence and was never resolved.' -f $text
            [void] $failure.Add($variableReason)
        }

        & $addCheck ('variable {0}' -f $text) 'requireVariable' $variableText 'must be resolved' `
            $variableResult $variableReason
    }

    if ($declaredVariable.Count -eq 0) {
        & $addCheck 'required variables' 'requireVariable' 'none declared' 'not declared' 'skipped' ''
    }

    # -- what kind of run this is, and it decides the whole disk block -------
    #
    # READ BEFORE THE DISKS RATHER THAN BESIDE THE THREE REFRESH GUARDS FURTHER
    # DOWN, because the disk-size check is the FIRST thing that has to know.
    $deploymentType = ([string] (& $lookup 'HDTDeploymentType')).Trim()
    $isRefresh = ($deploymentType -eq 'REFRESH')

    $deploymentTypeText = $deploymentType
    if ([string]::IsNullOrWhiteSpace($deploymentTypeText)) { $deploymentTypeText = 'not recorded' }

    # A REFRESH DOES NOT CHOOSE A DISK, AND ASKING IT TO REFUSED EVERY REFRESH
    # THERE HAS EVER BEEN.
    #
    # Get-HDTTargetDiskAssessment's first rule is absolute and not overridable:
    # "disk N is the disk this machine booted from". That is exactly right for a
    # bare-metal run, where the boot disk is the WinPE stick somebody plugged in
    # and putting Windows on it is never the intent - and exactly backwards for a
    # Refresh, where the disk this machine booted from IS the one being replaced.
    # A Refresh reuses the partition table Windows was already booting from; it
    # has no DiskPartition step and nothing to select a disk FOR.
    #
    # SO THE ROWS ARE REPORTED SKIPPED WITH THE REASON rather than passed
    # quietly, which is the mirror image of what the three Refresh-only guards
    # below do on a NEWCOMPUTER run - and for the mirror-image cause. A check
    # absent from the log and a check that passed look identical a week later, on
    # a machine nobody can touch.
    #
    # minDiskGB IS ONE OF THOSE ROWS, and it is here rather than left to pass
    # because it is the same question in a different sentence: it is the SIZE
    # FLOOR the disk choice applies, so on a run that chooses no disk it is a
    # bound on nothing. Left live it refuses a Refresh of a machine whose disk is
    # smaller than a floor that was never going to select anything - a refusal
    # about a disk the run was never going to use. refresh.yaml omits the key and
    # says why, which protects the template and nobody else: the console's
    # Validate page offers every check on every sequence, so an administrator can
    # tick "Ensure minimum disk size" onto a Refresh in two clicks and the ENGINE
    # is what has to be right about it.
    #
    # WHICH RUN EACH CHECK BELONGS TO IS THE Scope COLUMN on
    # Get-HDTValidateCheckDefinition - 'NEWCOMPUTER' for these two, 'REFRESH' for
    # the three guards below - so the table that declares the checks is the table
    # that says who runs them, and the two cannot disagree.
    #
    # WHAT GOVERNS A REFRESH'S TARGET INSTEAD IS ALREADY IN THIS STEP: the
    # partition-match guard, which refuses any volume that is not the one this
    # machine is running from unless allowOtherPartition says the difference is
    # deliberate, and the free-space guard, which measures the volume being
    # replaced. The target is not chosen here; it is CHECKED there.
    $notATargetChoice = ('this run is a REFRESH, which reuses the disk this machine was already booting from rather than choosing one. The volume it replaces is checked by the Refresh partition-match and free-space guards instead.')

    # -- the disks --------------------------------------------------------

    # THE 60 GB FLOOR IS IN FORCE WHETHER OR NOT THE SEQUENCE ASKED FOR IT,
    # because Select-HDTTargetDisk applies it to the choice. A log that reported
    # minDiskGB as 'not declared' and said nothing else would hide the bound that
    # actually excluded a disk.
    $minimumSizeByte = [long] 64424509440
    $sizeIsDeclared = ($null -ne $minimumDiskGb -and $minimumDiskGb -gt 0)
    if ($sizeIsDeclared) {
        $minimumSizeByte = [long] $minimumDiskGb * 1073741824
    }

    $minimumText = & $sizeText $minimumSizeByte

    try {
        $diskService = $Context.Service.GetRequired('Disk', 'Validate')

        $diskRow = @($diskService.GetDisk())
        $partitionRow = @($diskService.GetPartition())
        $volumeRow = @($diskService.GetVolume())
    } catch {
        $message = [string] $_.Exception.Message

        Write-HDTLog -Context $Context.Log -Message $message -Severity Error -Event step.fail -Component 'Validate'

        return (New-HDTStepResult -Status Failed -Message $message)
    }

    $largest = [long] 0
    foreach ($one in $diskRow) {
        if ([long] $one.SizeBytes -gt $largest) { $largest = [long] $one.SizeBytes }
    }

    $largestText = 'no disk'
    if ($diskRow.Count -gt 0) { $largestText = 'largest is {0}' -f (& $sizeText $largest) }

    if ($isRefresh) {
        # SKIPPED WITH THE REASON, LIKE ITS NEIGHBOURS. See the block above for
        # why a size floor on the disk CHOICE is a bound on nothing here.
        & $addCheck 'disk size' 'minDiskGB' $largestText 'not applicable' 'skipped' $notATargetChoice
    } elseif ($sizeIsDeclared) {
        $bigEnough = @($diskRow | Where-Object { [long] $_.SizeBytes -ge $minimumSizeByte })

        $sizeReason = ''
        $sizeResult = 'pass'

        if ($bigEnough.Count -eq 0) {
            $present = 'none'
            if ($diskRow.Count -gt 0) {
                $present = (@($diskRow | ForEach-Object { 'disk {0} = {1} bytes' -f [int] $_.Number, [long] $_.SizeBytes }) -join ', ')
            }

            $sizeResult = 'fail'
            $sizeReason = 'no disk on this machine holds at least {0} GB ({1}).' -f $minimumDiskGb, $present
            [void] $failure.Add($sizeReason)
        }

        & $addCheck 'disk size' 'minDiskGB' $largestText ('minimum {0}' -f $minimumText) $sizeResult $sizeReason
    } else {
        & $addCheck 'disk size' 'minDiskGB' $largestText ('minimum {0} (default)' -f $minimumText) 'skipped' ''
    }

    # THE PER-DISK ROWS AND THE TARGET-DISK ROW, on the same terms as the
    # disk-size row above. $isRefresh, $deploymentTypeText and $notATargetChoice
    # are derived ahead of the disk block, because that block is now the first
    # thing that has to know.
    if ($isRefresh) {
        foreach ($row in @($diskRow)) {
            $descriptor = @(
                (& $sizeText ([long] $row.SizeBytes))
                ([string] $row.BusType).Trim()
                ([string] $row.PartitionStyle).Trim()
            )

            & $addCheck ('disk {0}' -f [int] $row.Number) '' `
                (($descriptor | Where-Object { $_.Length -gt 0 }) -join ', ') `
                'not applicable' 'skipped' $notATargetChoice
        }

        & $addCheck 'target disk' 'diskNumber' 'not applicable' 'not applicable' 'skipped' $notATargetChoice
    }

    # The same call DiskPartition will make, with the same guards, so a machine
    # that passes here cannot be refused by the step that follows.
    $selectArgument = @{
        Disk               = $diskRow
        Partition          = $partitionRow
        Volume             = $volumeRow
        MinimumSizeByte    = $minimumSizeByte
        ProtectDriveLetter = [string[]] @(
            [string] $Context.WorkspaceRoot
            [string] $Context.Log.LogPath
        )
    }

    # THE PRE-FLIGHT NEVER REFUSES A DISK FOR HAVING DATA ON IT, and a real VM
    # is why. This step used to mirror DiskPartition's `wipe` guard, so a
    # machine carrying C: and D: - which is every machine that has ever been
    # deployed - failed step 1 with "the step did not declare that it may be
    # replaced". A rebuild is the normal case, and the answer was to repeat
    # `wipe: true` on a step that wipes nothing.
    #
    # WHETHER THE TARGET MAY BE ERASED IS DiskPartition'S QUESTION, because
    # DiskPartition is what erases it, and that step still refuses without
    # `wipe: true`. What the pre-flight asks is whether a usable disk of the
    # right size is present at all - and it asks it BEFORE anything is touched,
    # which is the whole point of asking early.
    $selectArgument['AllowExistingData'] = $true

    $diskNumber = Get-HDTStepProperty -Step $Step -Name 'diskNumber' -Context $Context -Expand -As Int
    if ($null -ne $diskNumber) {
        $selectArgument['DiskNumber'] = [int] $diskNumber
    }

    # THE SAME EVALUATION Select-HDTTargetDisk DECIDES WITH, so the table below
    # cannot drift from the decision it explains. Recomputing the seven rules
    # here would have been a second source of truth for which disk may be wiped.
    $assessmentArgument = @{
        Disk               = $diskRow
        Partition          = $partitionRow
        Volume             = $volumeRow
        MinimumSizeByte    = $minimumSizeByte
        ProtectDriveLetter = $selectArgument['ProtectDriveLetter']
        AllowExistingData  = $true
    }

    # ON A REFRESH THE WHOLE EVALUATION IS SKIPPED, rows and all - the block
    # above has already reported why. Running it and discarding the answer would
    # still put "disk 0 is the disk this machine booted from" into the log of a
    # run for which that is not an exclusion but the target.
    $assessment = @()
    if (-not $isRefresh) {
        $assessment = @(Get-HDTTargetDiskAssessment @assessmentArgument)
    }

    $selected = $null
    $selectWarning = $null

    # ON A REFRESH THERE IS NOTHING TO SELECT AND NOTHING TO REFUSE. The block
    # above has already reported the rows as skipped, and the Refresh
    # partition-match guard further down is what checks this run's target.
    if (-not $isRefresh) {
        try {
            # THE WARNING IS CAPTURED, NOT DISCARDED. Select-HDTTargetDisk warns
            # when naming a disk overrode a rule that would have excluded it -
            # "disk 1 is a USB disk, and was used anyway because the sequence
            # named it" - and this step used to swallow it whole with
            # -WarningAction alone. An overridden safety rule is the definition
            # of worth recording.
            $target = Select-HDTTargetDisk @selectArgument -WarningVariable selectWarning -WarningAction SilentlyContinue
            $selected = [int] $target.Number
            $data['diskNumber'] = $selected
        } catch {
            $errorId = ([string] $_.FullyQualifiedErrorId).Split(',')[0]
            $data['errorId'] = $errorId

            [void] $failure.Add([string] $_.Exception.Message)
        }

        foreach ($record in @($selectWarning)) {
            if ($null -eq $record) { continue }

            [void] $advisory.Add([string] $record)
        }
    }

    # -- one row per disk, and the rule that excluded each ------------------
    #
    # RULE 6 EVIDENCE, ON THE RUN THAT DID NOT REFUSE. A refusal already prints
    # this table; a pass printed nothing, so "disk 0 is the deployment target"
    # arrived without the two exclusions that made it the only answer.

    foreach ($entry in $assessment) {
        $row = $entry.Row

        $descriptor = @(
            (& $sizeText ([long] $row.SizeBytes))
            ([string] $row.BusType).Trim()
            ([string] $row.PartitionStyle).Trim()
        )

        $volumeText = 'no volumes'
        if (@($entry.Data).Count -gt 0) { $volumeText = (@($entry.Data) -join ', ') }
        $descriptor += $volumeText

        $reasonText = (@($entry.Reason | ForEach-Object { [string] $_.Text }) -join '; ')

        if ($null -ne $selected -and $entry.Number -eq $selected) {
            $diskResult = 'pass'
            $diskReason = 'selected as the deployment target'

            if ($reasonText.Length -gt 0) {
                $diskResult = 'warn'
                $diskReason = '{0}, despite: {1}' -f $diskReason, $reasonText
            }
        } elseif ($reasonText.Length -gt 0) {
            $diskResult = 'excluded'
            $diskReason = $reasonText
        } else {
            $diskResult = 'pass'
            $diskReason = ''
        }

        & $addCheck ('disk {0}' -f $entry.Number) '' (($descriptor | Where-Object { $_.Length -gt 0 }) -join ', ') `
            ('minimum {0}' -f $minimumText) $diskResult $diskReason
    }

    # -- the target disk itself ---------------------------------------------

    $targetThreshold = 'exactly one usable disk'
    if ($null -ne $diskNumber) {
        $targetThreshold = 'disk {0}, named by the sequence' -f [int] $diskNumber
    }

    # THE REFRESH ROW WAS ALREADY WRITTEN, further up and as a skip. Writing a
    # second one here would put two verdicts for one check into the log, and the
    # later of them would say 'fail' about a choice this run never made.
    if (-not $isRefresh) {
        if ($null -ne $selected) {
            & $addCheck 'target disk' 'diskNumber' ('disk {0}' -f $selected) $targetThreshold 'pass' ''
        } else {
            & $addCheck 'target disk' 'diskNumber' 'none' $targetThreshold 'fail' `
                'no disk on this machine could be chosen as the deployment target'
        }
    }

    # -- headroom, which is a warning and never a refusal -------------------
    #
    # MDT'S OWN ARITHMETIC. ZTIValidate needs the image plus 150 MB for WinPE and
    # logs plus 3 GB for Setup - so a disk that clears the declared minimum by
    # less than Setup's own overhead clears it on paper only, and the run finds
    # out while applying the image. It is not a refusal: the minimum is what the
    # sequence author asked for, and overruling it here would make the setting a
    # suggestion.

    if ($null -ne $selected) {
        $selectedRow = @($assessment | Where-Object { $_.Number -eq $selected })

        if ($selectedRow.Count -eq 1) {
            $headroom = [long] $selectedRow[0].Row.SizeBytes - $minimumSizeByte

            if ($headroom -lt 3378511872) {
                [void] $advisory.Add(('the deployment target, disk {0}, clears the {1} minimum by only {2} of headroom - less than Windows Setup itself needs (3 GB, plus 150 MB for WinPE and logs). The deployment will proceed and may run out of space while the image is applied.' -f
                        $selected, $minimumText, (& $sizeText $headroom)))
            }
        }
    }

    # -- the three guards a Refresh runs, and a NEWCOMPUTER never does -------
    #
    # MDT'S ZTIValidate REFRESH CHECKS, UNDER HDT'S OWN NAMES: the downgrade
    # refusal (:138-146, 9808), the partition-match refusal (:151-154, 9809) and
    # the free-space refusal (:231-256, 9807). All three are REFRESH-only there
    # and all three are REFRESH-only here.
    #
    # THEY ARE IN THE PRE-FLIGHT BECAUSE THE PRE-FLIGHT IS WHAT RUNS FIRST, and
    # every one of them is worthless a moment later. A Refresh empties the OS
    # volume before it applies the image (CleanVolume), so a machine that cannot
    # fit the image, or is about to be rolled back to an older Windows, or is
    # about to have its image written to a volume it is not booting from, has to
    # be told while its installation is still there. That is the same argument
    # this step already makes for the target-disk check, and it is why these are
    # three more checks here rather than a step type of their own - a guard in a
    # step an author can leave out of a sequence is a guard that is not there.
    #
    # WHY NONE OF THEM MAY FIRE ON A NEWCOMPUTER RUN, which MDT states as
    # `Case "NEWCOMPUTER"` doing nothing but logging "Assuming that the drive has
    # enough disk space (once cleaned)": a bare-metal run REPARTITIONS the disk,
    # so the volume the free-space check measures does not survive to be
    # measured and the partition it is asked to match is about to stop existing;
    # and it lays Windows onto a machine that may carry no Windows at all, so
    # there is no current version for an image to be older than.
    #
    # THE SCOPE COMES OUT OF Get-HDTValidateCheckDefinition rather than being
    # decided here, so the table that declares the checks is also the table that
    # says which run they belong to, and the two cannot disagree.

    # DERIVED FURTHER UP NOW, because the target-disk block above needs it too.
    # Left here as a comment rather than deleted, so a reader looking for where
    # the Refresh guards get their answer finds the trail.

    # THE MDT CITATION STAYS IN THE COMMENT ABOVE AND OUT OF THIS SENTENCE. The
    # no-MDT contract scans strings and not comments, which is exactly the right
    # line: a comment is where this code came from, a string is something HDT
    # SAYS - and an administrator reading a Refresh log does not need the name of
    # a script from the product this one replaces.
    $notARefresh = ('this run is a {0} deployment and this check belongs to a REFRESH. A NEWCOMPUTER run repartitions the disk, so the volume this measures does not survive to be measured, and it lays Windows onto a machine that may carry none at all.' -f
        $deploymentTypeText)

    # -- which volume, and which volume this machine is running from ---------
    #
    # BOTH GUARDS RESOLVE THE TARGET ONCE, HERE, so the partition check and the
    # free-space check cannot end up talking about different volumes.
    #
    # A REFRESH HAS NO DiskPartition STEP - M9 keeps it out deliberately, because
    # repartitioning would destroy the staged WinPE the second leg boots from -
    # so nothing has published HDTOSVolume by the time this runs. MDT has the
    # same gap and fills it the same way: GetOSDDestinationDrive pins the
    # destination to SystemDrive for a Refresh (ZTIUtility.vbs:3586-3593). So an
    # unset HDTOSVolume is not a refusal; it is the ordinary case, and it
    # resolves to the volume the engine is running from.
    #
    # SystemDrive COMES OFF IEnvironmentProvider, never off $env:. That is the
    # same read Assert-HDTCleanVolumeTarget makes for the same fact, so the
    # pre-flight and the step that empties the volume cannot disagree about which
    # volume this machine is on - and it is why all of this is provable against
    # a hand-written fake with no machine attached.

    $runningLetter = ''
    $targetLetter = ''
    $targetRefusal = ''

    if ($isRefresh) {
        try {
            $environmentService = $Context.Service.GetRequired('Environment', 'Validate')
            $runningLetter = ([string] $environmentService.GetVariable('SystemDrive')).Trim().TrimEnd('\', '/').TrimEnd(':')
        } catch {
            $runningLetter = ''
            $targetRefusal = [string] $_.Exception.Message
        }

        $named = ([string] (& $lookup 'HDTOSVolume')).Trim().TrimEnd('\', '/').TrimEnd(':')

        $targetLetter = $named
        if ($targetLetter.Length -eq 0) { $targetLetter = $runningLetter }
    }

    $targetText = 'not resolved'
    if ($targetLetter -match '^[A-Za-z]$') { $targetText = '{0}:\' -f $targetLetter.ToUpperInvariant() }

    $runningText = 'not reported'
    if ($runningLetter -match '^[A-Za-z]$') { $runningText = '{0}:\' -f $runningLetter.ToUpperInvariant() }

    # -- the downgrade refusal (ZTIValidate.wsf:138-146, MDT 9808) -----------
    #
    # HDT COMPARES THE BUILD AND MDT DOES NOT, AND THAT IS A DELIBERATE
    # DIVERGENCE FROM A CHECK THAT NO LONGER WORKS. ZTIValidate runs
    # GetMajorMinorVersion over both sides and compares major and minor only -
    # and every Windows since Windows 10 reports 10.0, Windows 11 included. So
    # MDT's downgrade refusal cannot fire on any supported operating system and
    # has not been able to since 2015. The build is the only component that
    # moves, so the build is what this compares.

    $currentVersionText = ([string] (& $lookup 'HDTOSCurrentVersion')).Trim()
    $imageVersionText = ([string] $imageVersion).Trim()

    $observedVersion = $imageVersionText
    if ($observedVersion.Length -eq 0) { $observedVersion = 'not declared' }

    $versionThreshold = 'not declared'
    if ($currentVersionText.Length -gt 0) {
        $versionThreshold = 'not older than {0}, which is on the machine now' -f $currentVersionText
    }

    if (-not $isRefresh) {
        & $addCheck 'Refresh downgrade' 'imageVersion' $observedVersion $versionThreshold 'skipped' $notARefresh
    } elseif ($imageVersionText.Length -eq 0) {
        # MDT'S OWN BEHAVIOUR, AND ITS OWN WORDS: "ImageBuild could not be
        # determined, assuming ConfigMgr deployment", and it carries on. A
        # sequence that has not said what it is applying cannot be told that the
        # answer is wrong, and refusing here would refuse every sequence that
        # simply does not declare it.
        & $addCheck 'Refresh downgrade' 'imageVersion' 'not declared' $versionThreshold 'skipped' `
            'this sequence does not declare imageVersion, so there is nothing to compare the running Windows against. Declare the version this sequence applies - 10.0.26100, say - to have a Refresh onto an older build refused.'
    } else {
        $versionReason = ''
        $versionResult = 'pass'
        $onMachine = $null
        $inImage = $null

        if ($currentVersionText.Length -eq 0) {
            $versionResult = 'fail'
            $versionReason = 'this machine did not report which Windows it is running, so a Refresh onto {0} cannot be shown not to be a downgrade. HDTOSCurrentVersion is gathered from Win32_OperatingSystem before the sequence begins; run the Gather step ahead of this one, or deploy this machine as a NEWCOMPUTER run, which does not ask the question.' -f $imageVersionText
        } elseif (-not [version]::TryParse($currentVersionText, [ref] $onMachine)) {
            $versionResult = 'fail'
            $versionReason = "HDTOSCurrentVersion is '{0}', which is not a version number, so it cannot be compared with the image's {1}." -f $currentVersionText, $imageVersionText
        } elseif (-not [version]::TryParse($imageVersionText, [ref] $inImage)) {
            $versionResult = 'fail'
            $versionReason = "imageVersion is '{0}', which is not a version number. Declare the version the image carries, such as 10.0.26100." -f $imageVersionText
        } elseif ($inImage -lt $onMachine) {
            $versionResult = 'fail'
            $versionReason = 'this machine is running Windows {0} and this sequence applies {1}, which is older. A Refresh cannot roll an installation back to an earlier build of Windows - Setup refuses the downgrade, and the machine has already had its volume emptied by the time it does. Point the sequence at an image of {0} or later, or deploy this machine as a NEWCOMPUTER run from boot media or PXE, which replaces the installation outright.' -f
            $currentVersionText, $imageVersionText
        }

        if ($versionResult -eq 'fail') { [void] $failure.Add($versionReason) }

        & $addCheck 'Refresh downgrade' 'imageVersion' $observedVersion $versionThreshold $versionResult $versionReason
    }

    # -- the partition-match refusal (ZTIValidate.wsf:151-154, MDT 9809) -----
    #
    # A REFRESH REPLACES THE INSTALLATION IT STARTED FROM. Applying the image to
    # a different volume leaves the machine still booting the old Windows with a
    # second, unreferenced installation beside it - which looks like a deployment
    # that worked until somebody reboots.
    #
    # THE OVERRIDE IS A DECLARATION ON THE STEP, NOT A MAGIC STRING IN A
    # VARIABLE. MDT spells it DestinationOSRefresh=OKTOUSEOTHERDISKANDPARTITION;
    # that literal is an MDT artefact and PROJECT rule 4 keeps it out. The
    # CAPABILITY is real, so it survives as `allowOtherPartition: true` on the
    # step that enforces it - the same shape as DiskPartition's `wipe: true`,
    # where a step that may do something irreversible has to say so out loud. It
    # still expands a %Variable%, so a site that wants the decision made
    # per-machine by a rule can still have that.
    #
    # AND AN OVERRIDDEN SAFETY RULE IS NEVER SILENT. Select-HDTTargetDisk warns
    # when naming a disk overrode a rule that would have excluded it; this warns
    # for the same reason and in the same place.

    $partitionThreshold = 'the volume this machine is running from'
    if ($runningText -ne 'not reported') {
        $partitionThreshold = 'the volume this machine is running from ({0})' -f $runningText
    }

    if (-not $isRefresh) {
        & $addCheck 'Refresh target volume' 'allowOtherPartition' 'not applicable' $partitionThreshold 'skipped' $notARefresh
    } else {
        $partitionReason = ''
        $partitionResult = 'pass'

        if ($targetRefusal.Length -gt 0) {
            $partitionResult = 'fail'
            $partitionReason = 'this run cannot say which volume it is running from, so it cannot say that {0} is the installation being replaced: {1}' -f $targetText, $targetRefusal
        } elseif ($runningLetter -notmatch '^[A-Za-z]$') {
            $partitionResult = 'fail'
            $partitionReason = "this run cannot say which volume it is running from - SystemDrive reported '{0}' - so a Refresh cannot establish that it is replacing the installation it started from." -f $runningText
        } elseif ($targetLetter -notmatch '^[A-Za-z]$') {
            $partitionResult = 'fail'
            $partitionReason = "HDTOSVolume is '{0}', which is not a drive letter, so there is no volume for this Refresh to replace." -f (& $lookup 'HDTOSVolume')
        } elseif ($targetLetter -ne $runningLetter) {
            # -eq on strings is case-insensitive in PowerShell, which is the
            # comparison a drive letter wants: 'c' and 'C' are one volume.
            if ($allowOtherPartition) {
                $partitionResult = 'warn'
                $partitionReason = 'this Refresh applies to {0} and this machine is running from {1}. The sequence declares allowOtherPartition, so it proceeds - the machine will be left booting the installation on {1} unless something else changes the boot entry.' -f $targetText, $runningText

                [void] $advisory.Add($partitionReason)
            } else {
                $partitionResult = 'fail'
                $partitionReason = 'this Refresh would apply the image to {0}, and this machine is running Windows from {1}. A Refresh replaces the installation it started from; applying to another volume leaves the machine still booting {1}, with a second unreferenced Windows beside it. Deploy this machine as a NEWCOMPUTER run, which owns the whole disk - or set allowOtherPartition: true on this Validate step if writing to {0} is deliberate.' -f
                $targetText, $runningText
            }
        }

        if ($partitionResult -eq 'fail') { [void] $failure.Add($partitionReason) }

        & $addCheck 'Refresh target volume' 'allowOtherPartition' $targetText $partitionThreshold $partitionResult $partitionReason
    }

    # -- the free-space refusal (ZTIValidate.wsf:231-256, MDT 9807) ----------
    #
    # MDT'S ARITHMETIC, KEPT: the image, plus 150 MB for WinPE and its logs, plus
    # 3 GB for Windows Setup. The same two constants are already in this step's
    # headroom advisory above, which is where they came from.
    #
    # IT MEASURES THE SIZE OF THE VOLUME AND NOT THE SPACE FREE ON IT, and that
    # looks like a bug until you read MDT's own comment: "assuming most of the
    # drive will be cleaned off before calling setup". In HDT that assumption is
    # not an assumption but a step - CleanVolume empties the OS volume
    # immediately before the image is applied - so free space is the wrong
    # measure twice over. A check against it would refuse every machine that is
    # full, which is very nearly the definition of a machine somebody wants to
    # refresh.
    #
    # MDT SUBTRACTS 1 MB AS A ROUNDING GUARD and this does not: it divides
    # integers and floors, so the answer is already the number of whole
    # megabytes the volume holds.

    $winPeReserveMb = [long] 150
    $setupReserveMb = [long] 3072

    $declaredImageMb = [long] 0
    if ($null -ne $imageSizeMb -and $imageSizeMb -gt 0) { $declaredImageMb = [long] $imageSizeMb }

    $neededMb = $declaredImageMb + $winPeReserveMb + $setupReserveMb

    # THE BREAKDOWN IS IN THE THRESHOLD, not only in the refusal. A reader who
    # sees "at least 8422 MB" and nothing else cannot tell which of the three
    # terms to change, and the whole point of this step's enumeration is that the
    # bound is knowable without failing it.
    $spaceThreshold = 'at least {0} MB on the target volume: image {1} MB, plus {2} MB for WinPE and logs, plus {3} MB for Setup' -f
    $neededMb, $declaredImageMb, $winPeReserveMb, $setupReserveMb
    if (-not $isRefresh) {
        & $addCheck 'Refresh free space' 'imageSizeMB' 'not applicable' $spaceThreshold 'skipped' $notARefresh
    } else {
        $spaceReason = ''
        $spaceResult = 'pass'
        $spaceObserved = 'not measured'

        $targetVolume = @($volumeRow | Where-Object {
                ([string] $_.DriveLetter).Trim().TrimEnd('\', '/').TrimEnd(':') -eq $targetLetter
            })

        if ($targetLetter -notmatch '^[A-Za-z]$') {
            $spaceResult = 'fail'
            $spaceReason = 'this Refresh has no target volume to measure, so it cannot be shown to have room for the image, WinPE and Setup.'
        } elseif ($targetVolume.Count -eq 0) {
            # A VOLUME THAT IS NOT THERE MEASURES AS NOTHING, and a check that
            # measured nothing and passed would be the whole guard defeated by a
            # drive letter that had moved.
            $spaceResult = 'fail'
            $present = 'none'
            if (@($volumeRow).Count -gt 0) {
                $present = (@($volumeRow | ForEach-Object { [string] $_.DriveLetter } |
                            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ', ')
            }

            $spaceReason = '{0} is not a volume on this machine, so the {1} MB this Refresh needs cannot be shown to be there. The lettered volumes this machine reports are: {2}.' -f
            $targetText, $neededMb, $present
        } else {
            $totalMb = [long] [math]::Floor([double] ([long] $targetVolume[0].SizeBytes) / 1048576)
            $spaceObserved = '{0} MB on {1}' -f $totalMb, $targetText

            if ($totalMb -le $neededMb) {
                $spaceResult = 'fail'
                $spaceReason = 'insufficient space on {0} for a Refresh: the volume holds {1} MB and {2} MB is required. An additional {3} MB is needed. The requirement is the image ({4} MB), plus {5} MB for WinPE and its logs, plus {6} MB for Windows Setup. This is the SIZE of the volume and not the space free on it - a Refresh empties the volume before applying the image, so what is on it now does not matter. Make the volume larger, apply a smaller image, or deploy this machine as a NEWCOMPUTER run, which repartitions the disk.' -f
                $targetText, $totalMb, $neededMb, ($neededMb - $totalMb), $declaredImageMb, $winPeReserveMb, $setupReserveMb
            }
        }

        if ($spaceResult -eq 'fail') { [void] $failure.Add($spaceReason) }

        & $addCheck 'Refresh free space' 'imageSizeMB' $spaceObserved $spaceThreshold $spaceResult $spaceReason
    }

    # -- the enumeration, one Debug line per row ----------------------------

    foreach ($row in $check) {
        $verdict = [string] $row['result']
        if (-not [string]::IsNullOrWhiteSpace([string] $row['reason'])) {
            $verdict = '{0}: {1}' -f $verdict, [string] $row['reason']
        }

        Write-HDTLog -Context $Context.Log -Severity Debug -Component 'Validate' -Data $row `
            -Message ('{0,-26} {1,-34} {2,-30} {3}' -f
                [string] $row['check'], [string] $row['observed'], [string] $row['threshold'], $verdict)
    }

    foreach ($note in $advisory) {
        Write-HDTLog -Context $Context.Log -Message ([string] $note) -Severity Warning -Component 'Validate'
    }

    $data['check'] = [object[]] @($check)
    $data['warning'] = [string[]] @($advisory)
    $data['warningCount'] = [int] $advisory.Count

    # -- the verdict ------------------------------------------------------

    if ($failure.Count -gt 0) {
        $message = "this machine did not pass the pre-flight:{0}{1}" -f [System.Environment]::NewLine,
        (@($failure | ForEach-Object { '  - {0}' -f $_ }) -join [System.Environment]::NewLine)

        $data['failedCheck'] = [string[]] @($failure)

        Write-HDTLog -Context $Context.Log -Message $message -Severity Error -Event step.fail -Component 'Validate' -Data $data

        return (New-HDTStepResult -Status Failed -Message $message -Data $data)
    }

    $checkWord = 'checks'
    if ($check.Count -eq 1) { $checkWord = 'check' }

    $warningWord = 'warnings'
    if ($advisory.Count -eq 1) { $warningWord = 'warning' }

    $summary = 'pre-flight passed: {0} {1}, {2} {3}.' -f $check.Count, $checkWord, $advisory.Count, $warningWord

    # WHY THIS DISK AND NOT THE OTHERS. Named by the sequence, or the last one
    # standing after the exclusions above - and the count says how many were
    # considered, so "the only disk" on a four-disk machine reads as the
    # elimination it was.
    $selectedRow = @($assessment | Where-Object { $_.Number -eq $selected })
    $selectedText = 'disk {0}' -f $selected

    if ($selectedRow.Count -eq 1) {
        $selectedCheck = @($check | Where-Object { [string] $_['check'] -eq ('disk {0}' -f $selected) })
        if ($selectedCheck.Count -eq 1) { $selectedText = [string] $selectedCheck[0]['observed'] }
    }

    if ($null -ne $diskNumber) {
        $why = 'named by the sequence'
    } elseif ($assessment.Count -eq 1) {
        $why = 'the only disk on this machine'
    } else {
        $why = 'the only disk of {0} that qualified' -f $assessment.Count
    }

    $chosen = 'disk {0} is the deployment target: {1} - {2}.' -f $selected, $selectedText, $why

    Write-HDTLog -Context $Context.Log -Message $summary -Component 'Validate' -Data $data
    Write-HDTLog -Context $Context.Log -Message $chosen -Component 'Validate'

    $message = '{0}{1}{2}' -f $summary, [System.Environment]::NewLine, $chosen

    return (New-HDTStepResult -Status Completed -Message $message -Data $data)
}
