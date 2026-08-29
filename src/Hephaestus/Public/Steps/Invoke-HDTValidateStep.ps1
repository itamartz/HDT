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
            Disk service.

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

    if ($sizeIsDeclared) {
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

    $assessment = @(Get-HDTTargetDiskAssessment @assessmentArgument)

    $selected = $null
    $selectWarning = $null

    try {
        # THE WARNING IS CAPTURED, NOT DISCARDED. Select-HDTTargetDisk warns when
        # naming a disk overrode a rule that would have excluded it - "disk 1 is
        # a USB disk, and was used anyway because the sequence named it" - and
        # this step used to swallow it whole with -WarningAction alone. An
        # overridden safety rule is the definition of worth recording.
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

    if ($null -ne $selected) {
        & $addCheck 'target disk' 'diskNumber' ('disk {0}' -f $selected) $targetThreshold 'pass' ''
    } else {
        & $addCheck 'target disk' 'diskNumber' 'none' $targetThreshold 'fail' `
            'no disk on this machine could be chosen as the deployment target'
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
