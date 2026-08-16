function Invoke-HDTConfigureBootStep {
    <#
        .SYNOPSIS
            Makes the machine boot the Windows it was just given.

        .DESCRIPTION
            The post-apply work, as a step:

              - name: Prepare Boot
                type: ConfigureBoot
                firmware: auto        # auto | UEFI | BIOS
                recovery: true        # optional; default true where R: exists
                setBootOrder: true    # optional; default true

            Three things, in this order:

              1. InstallBootFile(<W>:\, <S>:, UEFI|BIOS) - bcdboot. 'auto' reads
                 HDTIsUEFI.
              2. the recovery image: create <R>:\Recovery\WindowsRE, copy
                 <W>:\Windows\System32\Recovery\Winre.wim into it, then
                 SetRecoveryImage.
              3. SetBootOrderFirst().

            STEP 3 CAME OUT OF A LAB TEST AND IT IS NOT OPTIONAL POLISH.
            After apply, a machine whose firmware still lists the installation
            media first simply reboots into WinPE - and the deployment appears to
            loop, forever, with every log saying it succeeded. bcdboot does not
            fix that; the firmware boot order does.

            TWO FAILURES WARN AND CONTINUE, DELIBERATELY:

              * anything about the recovery image - a missing Winre.wim, or
                SetRecoveryImage itself throwing. An image with no registered
                WinRE still boots. Failing a whole deployment over it trades a
                working machine for a detail nobody asked for. And this is the
                one call nobody has ever made in anger: it runs the APPLIED
                IMAGE's own Reagentc.exe against an offline target from inside
                WinPE (WinPE ships no reagentc, and reagentc has no /setosimage
                verb - 04-01's verified facts), and 04-04 is the first thing to
                try it.
              * the firmware reorder. A machine whose firmware refuses is still
                deployed. The technician needs to be told to remove or demote the
                media, not to lose the build.

            bcdboot FAILING IS NOT ONE OF THEM. A machine with no boot files does
            not boot, so that is a failed step.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry
            Image and FileSystem services.

        .OUTPUTS
            A New-HDTStepResult. Data carries osVolume, systemVolume, firmware,
            recoveryVolume and bootOrder.

        .EXAMPLE
            Invoke-HDTConfigureBootStep -Step $step -Context $context
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

    $fail = {
        param([string] $Message, [string] $ErrorId)

        $data = [ordered] @{}
        if (-not [string]::IsNullOrWhiteSpace($ErrorId)) { $data['errorId'] = $ErrorId }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component 'ConfigureBoot' -Data $data

        return (New-HDTStepResult -Status Failed -Message $Message -Data $data)
    }

    $letterOf = {
        param([string] $Value)

        $text = ([string] $Value).Trim().TrimEnd(':')
        if ($text.Length -eq 0) { return '' }

        return $text.Substring(0, 1).ToUpperInvariant()
    }

    try {
        $firmware = Get-HDTStepProperty -Step $Step -Name 'firmware' -Default 'auto' -Context $Context -Expand -As String
        $recovery = Get-HDTStepProperty -Step $Step -Name 'recovery' -Default $true -Context $Context -Expand -As Bool
        $setBootOrder = Get-HDTStepProperty -Step $Step -Name 'setBootOrder' -Default $true -Context $Context -Expand -As Bool
    } catch {
        return (& $fail ([string] $_.Exception.Message) 'HDTConfigurationError')
    }

    $osVolume = & $letterOf ([string] $Context.Variable['HDTOSVolume'])
    if ($osVolume.Length -eq 0) {
        return (& $fail ("step '{0}' makes the Windows volume bootable and HDTOSVolume is not set. The partition step publishes it." -f $Step.Name) 'HDTConfigurationError')
    }

    $systemVolume = & $letterOf ([string] $Context.Variable['HDTSystemVolume'])
    if ($systemVolume.Length -eq 0) {
        return (& $fail ("step '{0}' writes the boot files to the system partition and HDTSystemVolume is not set. The partition step publishes it." -f $Step.Name) 'HDTConfigurationError')
    }

    $recoveryVolume = & $letterOf ([string] $Context.Variable['HDTRecoveryVolume'])

    if ($firmware -eq 'auto') {
        $gathered = $Context.Variable['HDTIsUEFI']

        $isUefi = $false
        if ($gathered -is [bool]) {
            $isUefi = [bool] $gathered
        } elseif ($null -ne $gathered) {
            $isUefi = ([string] $gathered).Trim() -eq 'True'
        }

        $firmware = 'BIOS'
        if ($isUefi) { $firmware = 'UEFI' }
    }

    $firmware = $firmware.ToUpperInvariant()

    try {
        $imageService = $Context.Service.GetRequired('Image', 'ConfigureBoot')
        $fileSystem = $Context.Service.GetRequired('FileSystem', 'ConfigureBoot')
    } catch {
        return (& $fail ([string] $_.Exception.Message) '')
    }

    $osRoot = '{0}:\' -f $osVolume
    $systemRoot = '{0}:' -f $systemVolume

    $data = [ordered] @{
        osVolume     = $osVolume
        systemVolume = $systemVolume
        firmware     = $firmware
    }

    # -- 1. the boot files -------------------------------------------------

    Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component 'ConfigureBoot' `
        -Message ('installing {0} boot files from {1} to {2}' -f $firmware, $osRoot, $systemRoot) -Data $data

    try {
        $imageService.InstallBootFile($osRoot, $systemRoot, $firmware)
    } catch {
        return (& $fail ("the boot files could not be written from {0} to {1}: {2}" -f
                $osRoot, $systemRoot, [string] $_.Exception.Message) '')
    }

    # -- 2. the recovery image, warn and continue --------------------------

    $recoveryRegistered = $false

    if ($recovery -and $recoveryVolume.Length -gt 0) {
        $recoveryDirectory = '{0}:\Recovery\WindowsRE' -f $recoveryVolume
        $sourceWim = '{0}Windows\System32\Recovery\Winre.wim' -f $osRoot
        $data['recoveryVolume'] = $recoveryVolume

        if (-not $fileSystem.TestPath($sourceWim)) {
            Write-HDTLog -Context $Context.Log -Severity Warning -Component 'ConfigureBoot' `
                -Message ("the applied image carries no {0}, so no recovery environment was registered. The machine still boots; Reset This PC and the recovery options will not be available." -f $sourceWim) `
                -Data ([ordered] @{ winre = $sourceWim; recovery = $recoveryDirectory })
        } else {
            try {
                $fileSystem.CreateDirectory($recoveryDirectory)
                $fileSystem.CopyItem($sourceWim, ('{0}\Winre.wim' -f $recoveryDirectory))

                # The applied image's OWN Reagentc.exe, run against an offline
                # target. 04-04 is the first thing to try it for real.
                $imageService.SetRecoveryImage($osRoot, $recoveryDirectory)

                $recoveryRegistered = $true
            } catch {
                Write-HDTLog -Context $Context.Log -Severity Warning -Component 'ConfigureBoot' `
                    -Message ("the recovery environment at {0} could not be registered: {1}. The machine still boots, so the deployment continues." -f
                        $recoveryDirectory, [string] $_.Exception.Message) `
                    -Data ([ordered] @{ recovery = $recoveryDirectory })
            }
        }
    }

    $data['recoveryRegistered'] = $recoveryRegistered

    # -- 3. the firmware boot order, warn and continue ---------------------

    $bootOrderSet = $false

    if ($setBootOrder) {
        try {
            # SPIKES S6: without this the machine reboots into the installation
            # media and the deployment appears to loop.
            $imageService.SetBootOrderFirst()
            $bootOrderSet = $true
        } catch {
            Write-HDTLog -Context $Context.Log -Severity Warning -Component 'ConfigureBoot' `
                -Message ("the firmware boot order could not be changed: {0}. Windows is installed and bootable, but this machine will boot the installation media again unless it is removed or demoted by hand." -f
                    [string] $_.Exception.Message)
        }
    }

    $data['bootOrder'] = $bootOrderSet

    $message = '{0} boot files were written from {1} to {2}.' -f $firmware, $osRoot, $systemRoot
    if ($bootOrderSet) {
        $message = '{0} The Windows Boot Manager is now first in the firmware boot order.' -f $message
    }

    Write-HDTLog -Context $Context.Log -Message $message -Component 'ConfigureBoot' -Data $data

    return (New-HDTStepResult -Status Completed -Message $message -Data $data)
}
