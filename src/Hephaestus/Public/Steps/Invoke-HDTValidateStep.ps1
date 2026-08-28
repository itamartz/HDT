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

            EVERY CHECK IS OPT-IN except the target disk. A Validate step that
            declares no bound imposes none; what it always does is prove that
            exactly one disk of a usable size is present.

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
            A New-HDTStepResult. Data carries diskNumber on success, and errorId
            on a refusal.

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
            $result.Data.Check

            Every pre-flight check with its verdict. A failure here is meant to stop
            the sequence before the partition step runs.
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
    $data = [ordered] @{}

    $lookup = {
        param([string] $Name)

        foreach ($key in @($Context.Variable.Keys)) {
            if ([string] $key -eq $Name) { return $Context.Variable[$key] }
        }

        return $null
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

    if ($null -ne $minimumRamMb -and $minimumRamMb -gt 0) {
        $memory = & $lookup 'HDTMemory'

        if ($null -eq $memory -or [string]::IsNullOrWhiteSpace([string] $memory)) {
            [void] $failure.Add(('the machine reports no HDTMemory, so the minimum of {0} MB cannot be checked. Gather the machine facts before this step.' -f $minimumRamMb))
        } else {
            $actual = [long] 0
            if (-not [long]::TryParse(([string] $memory).Trim(), [ref] $actual)) {
                [void] $failure.Add(("HDTMemory is '{0}', which is not a number of megabytes." -f $memory))
            } elseif ($actual -lt $minimumRamMb) {
                [void] $failure.Add(('this machine has {0} MB of memory and the sequence requires {1} MB.' -f $actual, $minimumRamMb))
            }
        }
    }

    # -- firmware ---------------------------------------------------------

    if ($requireUefi) {
        $firmware = & $lookup 'HDTIsUEFI'

        $isUefi = $false
        if ($firmware -is [bool]) {
            $isUefi = [bool] $firmware
        } elseif ($null -ne $firmware) {
            # A rules.yaml value arrives as text, so 'True' counts and '0' does not.
            $isUefi = ([string] $firmware).Trim() -eq 'True'
        }

        if (-not $isUefi) {
            [void] $failure.Add('this sequence requires UEFI firmware and HDTIsUEFI is not true for this machine.')
        }
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

    if (-not [string]::IsNullOrWhiteSpace([string] $minimumTpmVersion)) {
        $wanted = $null

        if (-not [version]::TryParse(([string] $minimumTpmVersion).Trim(), [ref] $wanted)) {
            [void] $failure.Add(("minTpmVersion is '{0}', which is not a version number." -f $minimumTpmVersion))
        } else {
            $reported = & $lookup 'HDTTPMVersion'

            # NO TPM IS ITS OWN MESSAGE. 'this machine reports TPM version ' with
            # nothing after it is the kind of sentence that sends a technician to
            # look for a setting that is not the problem.
            if ($null -eq $reported -or [string]::IsNullOrWhiteSpace([string] $reported)) {
                [void] $failure.Add(('this machine reports no TPM, and the sequence requires version {0} or later. On a virtual machine, a TPM has to be added to the VM.' -f $wanted))
            } else {
                $actualVersion = $null

                if (-not [version]::TryParse(([string] $reported).Trim(), [ref] $actualVersion)) {
                    [void] $failure.Add(("HDTTPMVersion is '{0}', which is not a version number." -f $reported))
                } elseif ($actualVersion -lt $wanted) {
                    [void] $failure.Add(('this machine has TPM {0} and the sequence requires {1} or later.' -f
                            $actualVersion, $wanted))
                }
            }
        }
    }

    # -- authored variables -----------------------------------------------

    foreach ($name in @($requireVariable)) {
        $text = ([string] $name).Trim()
        if ($text.Length -eq 0) { continue }

        $value = & $lookup $text
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string] $value)) {
            [void] $failure.Add(("the variable {0} is required by this sequence and was never resolved." -f $text))
        }
    }

    # -- the disks --------------------------------------------------------

    $minimumSizeByte = [long] 64424509440
    if ($null -ne $minimumDiskGb -and $minimumDiskGb -gt 0) {
        $minimumSizeByte = [long] $minimumDiskGb * 1073741824
    }

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

    if ($null -ne $minimumDiskGb -and $minimumDiskGb -gt 0) {
        $bigEnough = @($diskRow | Where-Object { [long] $_.SizeBytes -ge $minimumSizeByte })

        if ($bigEnough.Count -eq 0) {
            $present = 'none'
            if ($diskRow.Count -gt 0) {
                $present = (@($diskRow | ForEach-Object { 'disk {0} = {1} bytes' -f [int] $_.Number, [long] $_.SizeBytes }) -join ', ')
            }

            [void] $failure.Add(('no disk on this machine holds at least {0} GB ({1}).' -f $minimumDiskGb, $present))
        }
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

    try {
        $target = Select-HDTTargetDisk @selectArgument -WarningAction SilentlyContinue
        $data['diskNumber'] = [int] $target.Number
    } catch {
        $errorId = ([string] $_.FullyQualifiedErrorId).Split(',')[0]
        $data['errorId'] = $errorId

        [void] $failure.Add([string] $_.Exception.Message)
    }

    # -- the verdict ------------------------------------------------------

    if ($failure.Count -gt 0) {
        $message = "this machine did not pass the pre-flight:{0}{1}" -f [System.Environment]::NewLine,
        (@($failure | ForEach-Object { '  - {0}' -f $_ }) -join [System.Environment]::NewLine)

        $data['failedCheck'] = [string[]] @($failure)

        Write-HDTLog -Context $Context.Log -Message $message -Severity Error -Event step.fail -Component 'Validate' -Data $data

        return (New-HDTStepResult -Status Failed -Message $message -Data $data)
    }

    $message = 'this machine passed the pre-flight; disk {0} is the deployment target.' -f $data['diskNumber']

    Write-HDTLog -Context $Context.Log -Message $message -Component 'Validate' -Data $data

    return (New-HDTStepResult -Status Completed -Message $message -Data $data)
}
