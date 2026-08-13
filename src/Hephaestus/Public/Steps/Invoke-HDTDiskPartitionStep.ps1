function Invoke-HDTDiskPartitionStep {
    <#
        .SYNOPSIS
            Clears, initialises and partitions the one disk this deployment may
            wipe.

        .DESCRIPTION
            The destructive step, and the one DESIGN 9.1 was written about:
            "wiping the wrong disk is the single most destructive failure mode in
            this class of tool."

              - name: Format and Partition
                type: DiskPartition
                layout: "%HDTDiskLayout%"   # optional; firmware decides otherwise
                wipe: true                  # required for a disk that is not RAW
                diskNumber: 0               # optional; the ambiguity override
                minDiskGB: 60               # optional; default 60

            THREE GUARDS, AND EACH ONE HAS A TEST THAT PROVES NOTHING WAS
            WRITTEN WHEN IT FIRED:

              1. SupportsShouldProcess. Under -WhatIf the step plans, logs the
                 plan and returns Completed having called no write method.
              2. The ambiguity refusal. It never selects a disk itself -
                 Select-HDTTargetDisk does, and returns one row or refuses.
              3. The protected drive letters. The letters of the workspace root
                 and of the log path are ALWAYS passed, so HDT cannot wipe the
                 disk it is reading its own instructions from or writing its log
                 to. That guard is not conditional on anything an author typed.

            THE ORDER IS SPIKES S6's VERIFIED RECIPE, and it is asserted from the
            fake's journal rather than described here and hoped for:

              GetDisk / GetPartition / GetVolume
              Select-HDTTargetDisk
              ClearDisk                    Clear-Disk -RemoveData -RemoveOEM
              InitializeDisk               and NO MSR is created by hand
              per partition: NewPartition -> SetPartitionDriveLetter ->
                             FormatVolume -> SetPartitionType where it differs

            NO MICROSOFT RESERVED PARTITION IS EVER CREATED HERE. SPIKES S6:
            Initialize-Disk -PartitionStyle GPT creates the MSR itself.
            PSD's PSDPartition.ps1 (line 116) initialises GPT and then creates an
            MSR by hand a few lines later, which is how the spike ended up with a
            duplicate 16 MB partition. HDT carries the 16 MB as an allowance on
            the layout, subtracts it from the space Windows can have, and creates
            nothing for it.

            THE ESP IS CREATED AS BASIC DATA AND RETYPED AFTER FORMATTING. A
            partition created directly as an EFI System partition cannot readily
            be given a drive letter to format through, so the layout carries both
            CreateGptType and GptType and this step creates, letters, formats,
            then retypes. That is the field recipe; 04-04 is where it first runs
            against a real disk.

            A REFUSAL IS RETURNED, NOT THROWN, and carries its errorId in the
            result's Data, where Get-HDTFailureClass reads it and classes it
            Configuration - so a refusal to wipe ends the run instead of being
            retried three times.

            IT DOES NOT MOVE THE LOG. DESIGN 4.4.1 says _HDTLogPath moves to
            <target>\HDT\Logs once the target volume is formatted. Relocating a
            live log context mid-run touches New-HDTLogContext, Copy-HDTLog and
            the state document's mirror, and it belongs with phase 05's
            Start-HDTDeployment. What phase 04 does instead is leave the log
            where the leg started it and let the caller pass -LogDestination.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry a
            Disk service.

        .OUTPUTS
            A New-HDTStepResult. Data carries diskNumber and plan, or errorId on
            a refusal.

        .EXAMPLE
            Invoke-HDTDiskPartitionStep -Step $step -Context $context

        .EXAMPLE
            Invoke-HDTDiskPartitionStep -Step $step -Context $context -WhatIf

            The plan, logged, with nothing written to any disk.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
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

    $fail = {
        param([string] $Message, [string] $ErrorId)

        $data = [ordered] @{}
        if (-not [string]::IsNullOrWhiteSpace($ErrorId)) { $data['errorId'] = $ErrorId }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component 'DiskPartition' -Data $data

        return (New-HDTStepResult -Status Failed -Message $Message -Data $data)
    }

    # -- what the step asked for ------------------------------------------

    try {
        $layoutName = Get-HDTStepProperty -Step $Step -Name 'layout'
        $allowExistingData = Get-HDTStepProperty -Step $Step -Name 'wipe' -Default $false -Context $Context -Expand -As Bool
        $minimumDiskGb = Get-HDTStepProperty -Step $Step -Name 'minDiskGB' -Default 60 -Context $Context -Expand -As Long
        $diskNumber = Get-HDTStepProperty -Step $Step -Name 'diskNumber' -Context $Context -Expand -As Int
    } catch {
        return (& $fail ([string] $_.Exception.Message) 'HDTConfigurationError')
    }

    # -- the target -------------------------------------------------------

    try {
        $diskService = $Context.Service.GetRequired('Disk', 'DiskPartition')

        $diskRow = @($diskService.GetDisk())
        $partitionRow = @($diskService.GetPartition())
        $volumeRow = @($diskService.GetVolume())
    } catch {
        return (& $fail ([string] $_.Exception.Message) '')
    }

    $selectArgument = @{
        Disk               = $diskRow
        Partition          = $partitionRow
        Volume             = $volumeRow
        MinimumSizeByte    = [long] $minimumDiskGb * 1073741824
        # NEVER CONDITIONAL: the disk carrying the workspace and the disk
        # carrying the log are out of range whatever the sequence says.
        ProtectDriveLetter = [string[]] @(
            [string] $Context.WorkspaceRoot
            [string] $Context.Log.LogPath
        )
    }

    if ($allowExistingData) { $selectArgument['AllowExistingData'] = $true }
    if ($null -ne $diskNumber) { $selectArgument['DiskNumber'] = [int] $diskNumber }

    try {
        $target = Select-HDTTargetDisk @selectArgument
    } catch {
        return (& $fail ([string] $_.Exception.Message) (([string] $_.FullyQualifiedErrorId).Split(',')[0]))
    }

    $number = [int] $target.Number

    # -- the plan ---------------------------------------------------------

    try {
        $resolvedName = Resolve-HDTDiskLayoutName -Variable $Context.Variable -Layout ([string] $layoutName)
        $layout = Get-HDTDiskLayout -Name $resolvedName
        $plan = @(New-HDTDiskLayoutPlan -Layout $layout -DiskSizeByte ([long] $target.SizeBytes))
    } catch {
        return (& $fail ([string] $_.Exception.Message) (([string] $_.FullyQualifiedErrorId).Split(',')[0]))
    }

    $sizeGb = [math]::Round([long] $target.SizeBytes / 1073741824, 1)

    $planLine = @($plan | ForEach-Object {
            '  {0}. {1} {2} bytes {3} {4}: as {5}' -f $_.Order, $_.Role, $_.SizeByte, $_.FileSystem, $_.DriveLetter, $_.Label
        })

    Write-HDTLog -Context $Context.Log -Component 'DiskPartition' `
        -Message ("disk {0} ({1}, {2} GB) will be cleared and repartitioned as {3}:{4}{5}" -f
            $number, [string] $target.FriendlyName, $sizeGb, $resolvedName,
            [System.Environment]::NewLine, ($planLine -join [System.Environment]::NewLine)) `
        -Data ([ordered] @{
            diskNumber     = $number
            friendlyName   = [string] $target.FriendlyName
            sizeBytes      = [long] $target.SizeBytes
            layout         = $resolvedName
            partitionStyle = [string] $layout.PartitionStyle
        })

    # -- the volumes this step publishes ----------------------------------
    #
    # Written whether or not the writes happen, so a -WhatIf run of the whole
    # sequence stays coherent: the steps after this one plan against the volumes
    # this one would have created.

    $Context.Variable['HDTTargetDisk'] = $number
    $Context.Variable['HDTSystemVolume'] = ''
    $Context.Variable['HDTOSVolume'] = ''
    $Context.Variable['HDTRecoveryVolume'] = ''

    foreach ($row in $plan) {
        $letter = [string] $row.DriveLetter

        if ($row.Role -eq 'System') { $Context.Variable['HDTSystemVolume'] = $letter }
        if ($row.Role -eq 'Windows') { $Context.Variable['HDTOSVolume'] = $letter }
        if ($row.Role -eq 'Recovery') { $Context.Variable['HDTRecoveryVolume'] = $letter }
    }

    $data = [ordered] @{
        diskNumber     = $number
        layout         = $resolvedName
        partitionStyle = [string] $layout.PartitionStyle
        plan           = [object[]] $plan
    }

    if (-not $PSCmdlet.ShouldProcess(
            ('disk {0} ({1}, {2} GB)' -f $number, [string] $target.FriendlyName, $sizeGb),
            'Clear and repartition')) {

        return (New-HDTStepResult -Status Completed -Data $data `
                -Message ('disk {0} would have been cleared and repartitioned as {1}.' -f $number, $resolvedName))
    }

    # -- the writes, in SPIKES S6's verified order ------------------------

    $stage = 'clearing'

    try {
        # Clear-Disk -RemoveData -RemoveOEM, which is what leaves the disk RAW.
        $diskService.ClearDisk($number)

        # THIS is what creates the Microsoft Reserved partition on GPT. Nothing
        # below creates one - SPIKES S6, PSDPartition.ps1 line 116.
        $stage = 'initialising'
        $diskService.InitializeDisk($number, [string] $layout.PartitionStyle)

        foreach ($row in $plan) {
            $stage = ('creating the {0} partition' -f $row.Role)

            # Created as CreateGptType where the layout has one - basic data for
            # the ESP, so it can take a drive letter to format through - and
            # retyped after the format.
            $createType = [string] $row.CreateGptType
            if ([string]::IsNullOrWhiteSpace($createType)) { $createType = '' }

            $created = $diskService.NewPartition($number, [long] $row.SizeByte,
                [bool] $row.UseMaximumSize, $createType, [bool] $row.IsActive)

            $partitionNumber = [int] $created.PartitionNumber

            $stage = ('lettering the {0} partition' -f $row.Role)
            $diskService.SetPartitionDriveLetter($number, $partitionNumber, [string] $row.DriveLetter)

            $stage = ('formatting the {0} partition' -f $row.Role)
            $diskService.FormatVolume([string] $row.DriveLetter, [string] $row.FileSystem, [string] $row.Label)

            $finalType = [string] $row.GptType
            if (-not [string]::IsNullOrWhiteSpace($finalType) -and $finalType -ne $createType) {
                $stage = ('setting the type of the {0} partition' -f $row.Role)
                $diskService.SetPartitionType($number, $partitionNumber, $finalType)
            }
        }
    } catch {
        return (& $fail ("disk {0} failed while {1}: {2}" -f $number, $stage, [string] $_.Exception.Message) '')
    }

    $message = 'disk {0} was cleared and repartitioned as {1}: {2}.' -f $number, $resolvedName,
    (@($plan | ForEach-Object { '{0} on {1}:' -f $_.Role, $_.DriveLetter }) -join ', ')

    Write-HDTLog -Context $Context.Log -Message $message -Component 'DiskPartition' -Data $data

    return (New-HDTStepResult -Status Completed -Message $message -Data $data)
}
