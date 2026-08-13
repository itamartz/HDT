function Invoke-HDTValidateStep {
    <#
        .SYNOPSIS
            Pre-flights a machine before anything destructive runs on it.

        .DESCRIPTION
            MDT's Validate, rebuilt as a step that checks the machine against
            what the sequence is about to do to it:

              - name: Validate
                type: Validate
                minRamMB: 2048
                minDiskGB: 60
                requireUefi: true                    # optional
                diskNumber: 0                        # optional
                wipe: true                           # optional, mirrors DiskPartition
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
            exactly one disk can be wiped.

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
            Invoke-HDTValidateStep -Step $step -Context $context
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
        $allowExistingData = Get-HDTStepProperty -Step $Step -Name 'wipe' -Default $false -Context $Context -Expand -As Bool
        $requireVariable = Get-HDTStepProperty -Step $Step -Name 'requireVariable'
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

    if ($allowExistingData) {
        $selectArgument['AllowExistingData'] = $true
    }

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
