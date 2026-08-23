function Install-HDTAdk {
    <#
        .SYNOPSIS
            Installs the Windows ADK and the Windows PE add-on - from Microsoft
            when there is a route out, from staged media when there is not.

        .DESCRIPTION
            The ADK is a precondition for building a boot image, and the rest of
            this toolkit only ever asks whether it is there (Get-HDTAdkPath,
            Test-HDTAdkAvailable in build.ps1). This is the one command that
            puts it there.

            WHAT IT DOES IS DECIDED BY Get-HDTAdkInstallPlan and nothing here.
            This runs the plan: creates the folder, fetches the two installers
            when the plan says Download, then starts them through the injected
            IProcessService. Every branch worth arguing about lives in the
            planner, where a test can reach it.

            IT WRITES THE RUNBOOK RATHER THAN FAILING when it can neither reach
            Microsoft nor find staged media. The instructions name both links,
            the /layout command that produces an offline layout, and the folder
            to copy back - see Get-HDTAdkInstallPlan for why that is an answer
            and not an error. The plan comes back either way, so a caller can
            act on Action without parsing text.

            THE ADK GOES IN BEFORE THE ADD-ON. The Windows PE add-on installs
            into the ADK's own tree and its setup refuses when the ADK is not
            there yet, so the order is a requirement rather than a preference.

        .PARAMETER PayloadPath
            Where staged media is looked for, and where a download is put.

        .PARAMETER Force
            Install even though the ADK already resolves here. Without it a
            machine that already has the ADK is left alone.

        .PARAMETER ProbeAdk
            A scriptblock returning whether the ADK already resolves here.
            Defaults to a real check through Get-HDTAdkPath.

        .PARAMETER ProbeInternet
            A scriptblock returning whether Microsoft is reachable. Defaults to
            a real check.

            BOTH PROBES ARE INJECTED RATHER THAN ASSERTED. They were once plain
            booleans - -AdkPresent, -InternetAvailable - which put two things in
            Get-Help that read like orders ("-AdkPresent $false" as "do not
            install") and made a caller restate what the command could find out.
            A scriptblock named Probe reads as the seam it is, and a test that
            passes { $true } is obviously stubbing a measurement.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .PARAMETER Process
            An IProcessService. Defaults to the real one.

        .PARAMETER Download
            A scriptblock taking a URL and a destination path. Defaults to a
            real download. Injected so a test never fetches 1.5 GB.

        .PARAMETER TimeoutMillisecond
            How long each installer may take. The ADK install is minutes, not
            seconds, so the default is thirty minutes rather than the usual
            step timeout.

        .OUTPUTS
            PSCustomObject - the plan that was run, carrying Action and, when
            Action is Blocked, Instruction.

        .EXAMPLE
            Install-HDTAdk -WhatIf

            Says what it would install and installs nothing. Worth asking first: this
            is a multi-gigabyte download and two separate Microsoft installers.

        .EXAMPLE
            $plan = Install-HDTAdk -PayloadPath 'D:\ADKoffline'
            $plan.Instruction

            From a staged payload instead of from Microsoft, which is what a build host
            with no route out needs. Instruction says what to do when it cannot
            proceed - a machine that can reach neither is told so, not left
            waiting.

    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $PayloadPath = 'C:\HDTPayload\ADK',

        [Parameter()]
        [switch] $Force,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $Process,

        [Parameter()]
        [AllowNull()]
        [scriptblock] $Download,

        [Parameter()]
        [AllowNull()]
        [scriptblock] $ProbeAdk,

        [Parameter()]
        [AllowNull()]
        [scriptblock] $ProbeInternet,

        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $TimeoutMillisecond = 1800000
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $Process) { $Process = New-HDTProcessService }

    # THE UNTESTED LINES, AND THEY ARE DELIBERATELY BRANCH-FREE. Probing a real
    # machine and pulling a real file cannot be faked, so each is one call with
    # an injectable override (CLAUDE.md rule 1's adapter carve-out).
    if ($null -eq $Download) {
        $Download = {
            param([string] $Url, [string] $Destination)
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
        }
    }

    if ($null -eq $ProbeInternet) {
        # THE HOST COMES FROM THE LINK WE WOULD ACTUALLY FETCH, not a literal.
        # A hardcoded hostname can drift from the URL beside it, and reaching
        # some other Microsoft name proves nothing about the download.
        $ProbeInternet = {
            param([string] $Url)
            try {
                return [bool] (Test-NetConnection -ComputerName ([uri] $Url).Host -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop)
            } catch { return $false }
        }
    }

    # ALL THREE FACTS ARE ESTABLISHED HERE, THE SAME WAY. The planner used to
    # probe the payload itself while being told the other two, which left a
    # caller asserting -AdkPresent beside a payload the command could see.
    if ($null -eq $ProbeAdk) {
        # Oscdimg specifically: it is the asset the boot image build needs, and
        # an ADK installed without Deployment Tools would answer yes to a
        # registry check and still be useless here.
        $ProbeAdk = {
            try { [void] (Get-HDTAdkPath -Asset Oscdimg -ErrorAction Stop); return $true } catch { return $false }
        }
    }

    $adkPresent = $false
    if (-not $Force) { $adkPresent = [bool] (& $ProbeAdk) }

    $adkSetup = [System.IO.Path]::Combine($PayloadPath, 'adksetup.exe')
    $winPeSetup = [System.IO.Path]::Combine($PayloadPath, 'adkwinpesetup.exe')
    $payloadStaged = ($FileSystem.TestPath($adkSetup) -and $FileSystem.TestPath($winPeSetup))

    # THE LINK IS ASKED FOR, NOT REPEATED. The plan's URLs do not depend on any
    # of the three facts, so the first call is only there to learn which host we
    # would fetch from. A second copy of the fwlink in this file is a copy that
    # can drift from the one the download actually uses.
    $constant = Get-HDTAdkInstallPlan -AdkPresent $adkPresent -PayloadStaged $payloadStaged `
        -InternetAvailable $false -PayloadPath $PayloadPath

    # THE NETWORK IS ONLY ASKED ABOUT WHEN IT COULD CHANGE THE ANSWER. Staged
    # media wins anyway, so probing first would spend a timeout on a machine
    # that was never going to download.
    $internetAvailable = $false
    if (-not $adkPresent -and -not $payloadStaged) {
        $internetAvailable = [bool] (& $ProbeInternet $constant.AdkUrl)
    }

    $plan = Get-HDTAdkInstallPlan -AdkPresent $adkPresent -PayloadStaged $payloadStaged `
        -InternetAvailable $internetAvailable -PayloadPath $PayloadPath

    if ($plan.Action -eq 'AlreadyInstalled') {
        Write-Verbose ("The Windows ADK {0} already resolves on this machine; nothing to do." -f $plan.Version)
        return $plan
    }

    if ($plan.Action -eq 'Blocked') {
        # NOT AN ERROR RECORD. The caller asked how to get the ADK and this is
        # the answer for their situation; Write-Warning keeps it visible without
        # turning a runbook into a failure a script has to trap.
        foreach ($item in @($plan.Instruction)) { Write-Warning $item }
        return $plan
    }

    if (-not $PSCmdlet.ShouldProcess($PayloadPath,
            ("Install the Windows ADK {0} and the Windows PE add-on" -f $plan.Version))) {
        return $plan
    }

    if ($plan.Action -eq 'Download') {
        if (-not $FileSystem.TestPath($plan.PayloadPath)) {
            [void] $FileSystem.CreateDirectory($plan.PayloadPath)
        }

        & $Download $plan.AdkUrl $plan.AdkSetupPath
        & $Download $plan.WinPeUrl $plan.WinPeSetupPath
    }

    foreach ($step in @(
            @{ Path = $plan.AdkSetupPath; Argument = $plan.AdkArgument; Name = 'Windows ADK' },
            @{ Path = $plan.WinPeSetupPath; Argument = $plan.WinPeArgument; Name = 'Windows PE add-on' })) {

        $result = $Process.Start($step.Path, $step.Argument, $plan.PayloadPath, $TimeoutMillisecond)

        if ($result.TimedOut) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $step.Path `
                        -Message ("the {0} installer did not finish within {1} ms and was stopped. It is a multi-minute install; raise -TimeoutMillisecond." -f $step.Name, $TimeoutMillisecond) `
                        -ErrorId 'HDTAdkInstallTimeout' -Category OperationTimeout))
        }

        # 3010 IS SUCCESS WITH A REBOOT PENDING, which the ADK returns often
        # enough that treating it as failure would fail a working install.
        if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 3010) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $step.Path `
                        -Message ("the {0} installer exited {1}. {2}" -f $step.Name, $result.ExitCode, $result.StandardError) `
                        -ErrorId 'HDTAdkInstallFailed' -Category InvalidResult))
        }
    }

    Write-Verbose ("SECURITY: apply ADK patch KB5079391 or later (CVE-2026-25166) - {0}" -f $plan.PatchUrl)

    return $plan
}
