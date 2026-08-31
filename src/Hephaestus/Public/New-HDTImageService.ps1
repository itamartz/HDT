function New-HDTImageService {
    <#
        .SYNOPSIS
            Creates the real IImageService adapter over Get-WindowsImage,
            dism.exe, bcdboot, bcdedit and reagentc.

        .DESCRIPTION
            The one place in HDT that names Get-WindowsImage, dism.exe,
            bcdboot.exe, bcdedit.exe or Reagentc.exe. PROJECT constraint 4
            forbids a step from touching hardware directly, so ApplyImage and
            ConfigureBoot receive this object and can be swapped for
            New-HDTFakeImageService in a test with no media, no disk and no
            reboot.

            ELEVEN METHODS, AND THE EXACT MECHANISM EACH WRAPS:

              GetImageInfo(imagePath)
                  Get-WindowsImage -ImagePath, then Get-WindowsImage -Index per
                  index for EditionId, Architecture and Version, which the
                  summary form does not carry.

              ApplyImage(imagePath, index, applyPath[, onOutput])
                  dism.exe /Apply-Image /ImageFile: /Index: /ApplyDir:, with
                  every line the tool prints handed to onOutput as it arrives.
                  That is where the percentage comes from - see the method.

              CaptureImage(capturePath, imagePath, name, description, compress,
                           scratchPath, configPath[, onOutput])
                  dism.exe /Capture-Image /CaptureDir: /ImageFile: /Name:
                      /Description: /Compress: /ScratchDir: /ConfigFile:

                  ApplyImage RUN BACKWARDS, and a pipeline for the same reason:
                  /Capture-Image prints a real percentage meter, so every line
                  goes to onOutput as it arrives and the poll loop below is not
                  needed. THE IMAGE PATH IS THE OUTPUT - alone among the methods
                  that take one, it is not guarded for existence, because the
                  file it names is the file it is about to write. capturePath,
                  the volume being read, is guarded instead.

              ApplyUnattend(imagePath, unattendPath, scratchPath[, onOutput[, onTick]])
                  dism.exe /Image: /Apply-Unattend: /ScratchDir:, run as a
                  POLLED PROCESS rather than a pipeline. Every line the tool
                  prints goes to onOutput as it arrives, and onTick fires every
                  500 ms that it prints nothing - which for this verb is nearly
                  all of them, because dism emits no percentage meter for
                  /Apply-Unattend at all. See the method. THE ONLY
                  THING THAT RUNS THE offlineServicing PASS, which is where the
                  answer file's driver paths live - Setup reading Panther on
                  first boot runs specialize and oobeSystem and not that one.
                  MDT LTIApply.wsf:1021-1043; see NOTICE.md.

              AddDriver(imagePath, driverPath, recurse)
                  Add-WindowsDriver -Path <imagePath> -Driver <driverPath>
                      -Recurse:<recurse>

                  OFFLINE INJECTION INTO THE APPLIED OS, which is DESIGN 7's
                  behaviour: the driver is written into
                  <imagePath>\Windows\System32\DriverStore\FileRepository and
                  staged, and WINDOWS binds it to a device on the first boot.
                  Nothing here installs a driver onto a running machine.

                  imagePath is the applied OS VOLUME - %HDTOSVolume%, W:\ - not
                  a mounted WIM. It is the same DISM verb IBootImageService
                  calls with a mount path, which is why the shape matches; the
                  engine gets its own copy because a deployment in WinPE must
                  not have to carry a boot image builder to inject a NIC driver.

              InstallBootFile(osRoot, systemVolume, firmware)
                  bcdboot.exe "<OsRoot>\Windows" /s <systemVolume> /f <firmware>,
                  where firmware is UEFI, BIOS or ALL.

              SetRecoveryImage(osRoot, recoveryPath)
                  <OsRoot>\Windows\System32\Reagentc.exe /setreimage
                      /path <recoveryPath> /target <OsRoot>\Windows

              SetBootOrderFirst()
                  bcdedit.exe /set "{fwbootmgr}" displayorder "{bootmgr}" /addfirst

              AddRamdiskBootEntry(store, id, description, ramdiskVolume,
                                  wimDevicePath, sdiDevicePath, loaderPath)
              SetBootSequenceOnce(store, id)
              RemoveBootEntry(store, id)
                  bcdedit.exe, driven from the ordered list Get-HDTBcdCommand
                  returns. THE FullOS -> WinPE TRANSPORT: a reference build has
                  to reach WinPE after sysprep to capture itself, and the
                  firmware boot order cannot serve that AND the restart before it
                  that must reach Windows. So a WinPE is staged on the local disk
                  and the Windows Boot Manager hands it exactly one boot.

            SetBootOrderFirst IS SPIKES.md S6's FOURTH FINDING AS AN API. After
            apply, a machine that still has the boot media first in the firmware
            order simply reboots into WinPE and the deployment loops. Putting
            the Windows Boot Manager first is what ends the loop; ConfigureBoot
            owns deciding when to call it.

            SetRecoveryImage CALLS THE APPLIED IMAGE'S OWN Reagentc.exe, BY FULL
            PATH, AND USES /setreimage. Two reasons, both checked on this
            machine rather than remembered. First, THE VERB THIS WAS FIRST
            WRITTEN AGAINST DOES NOT EXIST: reagentc on Windows 11 24H2 lists
            /info, /setreimage, /enable, /disable, /boottore, /setbootshelllink
            and the quick-machine-recovery verbs, and nothing else. The tool
            wins and 04-03 corrects the document. Second, THERE IS NO
            WinPE-Recovery OPTIONAL COMPONENT: reagentc.exe is not in WinPE, and
            WinPE is the only environment this method is ever called from, so a
            bare 'reagentc.exe' would be command-not-found. Microsoft's own
            offline WinRE procedure runs the target image's copy, which exists
            as soon as ApplyImage has finished and is the same 26100 build as
            the WinPE hosting it. Building the path from $OsRoot is argument
            construction, not a branch, so the adapter stays dumb.

            THIS IS AN UNTESTED ADAPTER, and deliberately so: all but one of its
            methods write to a disk or reorder this machine's firmware boot
            entries. Its contract row calls GetImageInfo and nothing else; the
            rest is proven in tests/integration (04-04) against a scratch VHDX.
            The price of not testing it is that it must stay dumb. THE ONLY
            BRANCHES BELOW ARE TWO EXISTENCE GUARDS, SIX EXIT-CODE CHECKS AND
            ApplyUnattend's POLL LOOP, each commented as such. Every decision
            about WHICH index to apply or WHETHER a recovery partition exists
            lives in the steps, which are tested against the fake. Do not add
            logic here.

            THE POLL LOOP IS THE ONE DELIBERATE EXCEPTION TO "BRANCH-FREE", and
            it is the same exception New-HDTProcessService.Start already carries.
            A loop that waits in slices is not a decision about the deployment -
            it takes no branch on an argument, a machine or a result - and there
            is no way to tick a callback while an external tool is silent
            without one. Everything that IS a decision was pushed out to a pure,
            unit-tested function: ConvertTo-HDTNativeArgument for the command
            line, ConvertFrom-HDTDismProgressLine for what a line means, and
            New-HDTStepHeartbeat for when a tick is worth a log record.

            EVERY NATIVE FAILURE CARRIES THE TOOL'S OWN OUTPUT. "bcdboot failed"
            without bcdboot's own sentence is the log entry that wastes an hour
            at three in the morning in front of a machine that will not boot.

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with the eleven
            IImageService ScriptMethods. Note that Get-Member -MemberType Method
            does NOT list a ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $image = New-HDTImageService
            $image.GetImageInfo('C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim') |
                Format-Table Index, Name, Edition, Architecture

            The index catalogue an administrator picks from. Index 1 of the
            staged media is Windows 11 Enterprise LTSC.

        .EXAMPLE
            $image = New-HDTImageService
            $image.ApplyImage('Z:\OperatingSystems\Win11\sources\install.wim', 1, 'W:\')
            $image.InstallBootFile('W:\', 'S:', 'UEFI')
            $image.SetBootOrderFirst()

            The apply ceremony SPIKES.md S6 performed by hand, as three calls.

        .NOTES
            Architecture comes back from Get-WindowsImage as a NUMERIC DISM
            code, not a string: the staged media reports 9, which is amd64. The
            captured fixtures record it as it arrives rather than prettified,
            because a fixture that improved on the tool would be a fixture that
            lied about it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state. The destructive methods it exposes are called by ApplyImage and ConfigureBoot, which carry SupportsShouldProcess.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'ImageService'
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
        return , ([string[]] @($this.Operations | ForEach-Object { $_.Operation }))
    }

    # Existence guard, not logic. It gives this adapter and the fake the same
    # failure for the same mistake - a WIM path that is not there - where
    # Get-WindowsImage would otherwise report a DISM error that does not say
    # plainly that the file is missing.
    $service | Add-Member -MemberType ScriptMethod -Name AssertImage -Value {
        param([string] $ImagePath)

        if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::new(
                "Could not find image '$ImagePath'.", $ImagePath)
        }
    }

    # The whole of the allowed logic in a native call: run it, and if it failed,
    # throw with the tool's own output attached (DESIGN 12.2.3).
    $service | Add-Member -MemberType ScriptMethod -Name AssertExitCode -Value {
        param([int] $ExitCode, [string] $Tool, [string] $CommandLine, [object[]] $Output)

        if ($ExitCode -ne 0) {
            throw [System.InvalidOperationException]::new(
                ("{0} exited {1} for: {2}{3}{4}" -f $Tool, $ExitCode, $CommandLine,
                    [System.Environment]::NewLine, (@($Output) -join [System.Environment]::NewLine)))
        }
    }

    # -- IImageService ------------------------------------------------------

    $service | Add-Member -MemberType ScriptMethod -Name GetImageInfo -Value {
        param([string] $ImagePath)

        $this.Record('GetImageInfo', @($ImagePath))
        $this.AssertImage($ImagePath)

        # A foreach over the indices, no branch. The summary form carries the
        # index, name, description and size; EditionId, Architecture and
        # Version only come back from the per-index form.
        $row = foreach ($image in @(Get-WindowsImage -ImagePath $ImagePath)) {
            $detail = Get-WindowsImage -ImagePath $ImagePath -Index $image.ImageIndex

            [pscustomobject] @{
                Index        = [int] $image.ImageIndex
                Name         = [string] $image.ImageName
                Description  = [string] $image.ImageDescription
                Edition      = [string] $detail.EditionId
                SizeBytes    = [long] $image.ImageSize
                Architecture = [string] $detail.Architecture
                Version      = [string] $detail.Version
            }
        }

        # The unary comma is mandatory: a ScriptMethod returning an array
        # collapses a one-element array to a scalar without it, and a WIM with
        # a single index is the normal case (tests/helpers/README.md F3).
        return , ([object[]] @($row))
    }

    $service | Add-Member -MemberType ScriptMethod -Name ApplyImage -Value {
        param([string] $ImagePath, [int] $Index, [string] $ApplyPath, [scriptblock] $OnOutput = {})

        $this.Record('ApplyImage', @($ImagePath, $Index, $ApplyPath))
        $this.AssertImage($ImagePath)

        # DISM.EXE, NOT Expand-WindowsImage, AND THE REASON IS THE ONE NUMBER A
        # TECHNICIAN WATCHES. Expand-WindowsImage reports progress on
        # PowerShell's progress STREAM, which is a console bar and not data:
        # nothing in WinPE is reading it, and there is no parameter or callback
        # that turns it into one. dism.exe prints a percentage on stdout, which
        # is how MDT's LiteTouch has always driven its bar, and DESIGN 11.1
        # needs the number in the log rather than on a screen nobody is at.
        #
        # It is also one fewer thing the boot image must carry: dism.exe is in
        # WinPE as shipped, where the DISM cmdlets need the WinPE-DismCmdlets
        # optional component.
        #
        # EVERY LINE GOES TO $OnOutput AS IT ARRIVES, RAW. A spike on this
        # machine measured the meter arriving one repaint per pipeline object,
        # about a hundred of them across a 12-second export, so a caller sees
        # the percentage move rather than getting the whole transcript at the
        # end. What a line MEANS is decided by ConvertFrom-HDTDismProgressLine
        # and the step: this adapter is not unit tested and gets no branches.
        #
        # 5.1 TRAP, NOT TIDINESS. Under Windows PowerShell 5.1 the 2>&1 below
        # wraps every stderr line in an ErrorRecord, and the ErrorActionPreference
        # Stop that engine code sets makes the FIRST one terminating - so a tool
        # that merely printed a progress meter kills the call before its exit code
        # is ever consulted. That is exactly how oscdimg's "0% complete" killed the
        # first integration run under powershell.exe (SPIKES S13.5). Local to this
        # method scope, so nothing outside it changes. No branch: rule 1 holds.
        $ErrorActionPreference = 'Continue'

        $commandLine = 'dism /Apply-Image /ImageFile:{0} /Index:{1} /ApplyDir:{2}' -f $ImagePath, $Index, $ApplyPath

        $output = @(& "$env:SystemRoot\System32\dism.exe" '/Apply-Image' "/ImageFile:$ImagePath" `
                "/Index:$Index" "/ApplyDir:$ApplyPath" 2>&1 |
                ForEach-Object {
                    $line = [string] $_
                    $null = $OnOutput.Invoke($line)
                    $line
                })

        # Exit-code check, with dism's own sentence attached.
        $this.AssertExitCode($LASTEXITCODE, 'dism.exe', $commandLine, $output)
    }

    # READS A SYSPREPPED MACHINE INTO A WIM THE SHARE CAN DEPLOY. It is
    # ApplyImage's mirror - the same tool, the same meter, the same shape - and
    # everything ApplyImage's comment says about why it is dism.exe and why it
    # is a pipeline holds here without amendment.
    #
    # dism.exe, NOT New-WindowsImage, AND IT IS ApplyImage'S REASON VERBATIM.
    # New-WindowsImage reports progress on PowerShell's progress STREAM, which
    # is a console bar and not data: nothing in WinPE is reading it, and there
    # is no parameter or callback that turns it into one. dism.exe prints a
    # percentage on stdout, which is what DESIGN 11.1 needs in the log rather
    # than on a screen nobody is at. And it is one fewer thing the boot image
    # must carry: dism.exe is in WinPE as shipped, where the DISM cmdlets need
    # the WinPE-DismCmdlets optional component - and a capture runs from WinPE,
    # which is the whole point of sysprepping first.
    #
    # A PIPELINE, NOT A POLL, AND THE COMMENT ON ApplyUnattend BELOW EXPLAINS
    # WHY THE TWO DIFFER. /Capture-Image prints a real percentage meter, as
    # /Apply-Image does and as /Apply-Unattend does not, so the pipeline form
    # already delivers liveness and there is nothing for a tick to add.
    # Converting a working meter to a hand-built ProcessStartInfo would put the
    # one number a technician watches at risk of a redirection or encoding
    # regression to buy what it already has.
    #
    # THE IMAGE PATH IS THE OUTPUT, SO IT IS NOT GUARDED. AssertImage throws
    # when the file it is handed is absent, which is right for every other
    # method here and exactly wrong for this one: an absent destination WIM is
    # the ordinary case. The GUARD GOES ON capturePath, the volume being read,
    # where a missing directory is a real mistake - and dism's own message for
    # it does not say plainly that the source is not there.
    #
    # NO /Append-Image FALLBACK, AND THAT IS DELIBERATE. MDT decides between
    # capture and append by looking at whether the destination exists; deciding
    # is exactly what this adapter is forbidden to do (rule 1, and the
    # branch-free note above). If append is ever wanted it is a SECOND METHOD
    # and the STEP chooses between them, where the choice can be unit tested.
    $service | Add-Member -MemberType ScriptMethod -Name CaptureImage -Value {
        param([string] $CapturePath, [string] $ImagePath, [string] $Name, [string] $Description,
            [string] $Compress, [string] $ScratchPath, [string] $ConfigPath, [scriptblock] $OnOutput = {})

        $this.Record('CaptureImage', @($CapturePath, $ImagePath, $Name, $Description, $Compress, $ScratchPath, $ConfigPath))

        # Existence guard on the SOURCE, not the destination. See above.
        if (-not (Test-Path -LiteralPath $CapturePath -PathType Container)) {
            throw [System.IO.DirectoryNotFoundException]::new(
                "Could not find the directory to capture, '$CapturePath'.")
        }

        # AND AN EXISTENCE GUARD ON THE EXCLUSION LIST, WHICH IS THE THIRD AND
        # LAST BRANCH IN THIS METHOD. dism does not refuse a /ConfigFile: that is
        # not there in a way anybody reads: it warns and captures the whole
        # volume, so a typo in the path is a reference image with pagefile.sys,
        # the deployment's own \HDT folder and one machine's log inside it - and
        # nothing about the run looks wrong. DESIGN 9.3 note 7 is what this
        # protects; a silent capture without exclusions is the failure it names.
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::new(
                "Could not find the capture exclusion list, '$ConfigPath'. A capture without one writes the whole volume into the image.", $ConfigPath)
        }

        # WinPE runs from an X: RAM disk and dism left to itself expands into
        # TEMP there and runs out of room, so the scratch path is not optional -
        # and it has to exist before dism is handed it. The same line
        # ApplyUnattend carries, for the same reason.
        $null = [System.IO.Directory]::CreateDirectory($ScratchPath)

        # 5.1 TRAP, NOT TIDINESS. Under Windows PowerShell 5.1 the 2>&1 below
        # wraps every stderr line in an ErrorRecord, and the ErrorActionPreference
        # Stop that engine code sets makes the FIRST one terminating - so a tool
        # that merely printed a progress meter kills the call before its exit code
        # is ever consulted. That is exactly how oscdimg's "0% complete" killed the
        # first integration run under powershell.exe (SPIKES S13.5). Local to this
        # method scope, so nothing outside it changes. No branch: rule 1 holds.
        $ErrorActionPreference = 'Continue'

        # The quoting rule, so a capture into a share path with a space in it
        # reaches dism as one argument. ConvertTo-HDTNativeArgument is pure and
        # unit tested; a decision about quoting does not belong in the adapter.
        $argument = @(
            ('/CaptureDir:{0}' -f $CapturePath),
            ('/ImageFile:{0}' -f $ImagePath),
            ('/Name:{0}' -f $Name),
            ('/Description:{0}' -f $Description),
            ('/Compress:{0}' -f $Compress),
            ('/ScratchDir:{0}' -f $ScratchPath),
            ('/ConfigFile:{0}' -f $ConfigPath)
        )

        $commandLine = 'dism /Capture-Image {0}' -f (
            @($argument | ForEach-Object { ConvertTo-HDTNativeArgument -Argument $_ }) -join ' ')

        # EVERY LINE GOES TO $OnOutput AS IT ARRIVES, RAW, exactly as ApplyImage
        # does. What a line MEANS is decided by ConvertFrom-HDTDismProgressLine
        # and the step: this adapter is not unit tested and gets no branches.
        $output = @(& "$env:SystemRoot\System32\dism.exe" '/Capture-Image' `
                "/CaptureDir:$CapturePath" "/ImageFile:$ImagePath" "/Name:$Name" `
                "/Description:$Description" "/Compress:$Compress" "/ScratchDir:$ScratchPath" `
                "/ConfigFile:$ConfigPath" 2>&1 |
                ForEach-Object {
                    $line = [string] $_
                    $null = $OnOutput.Invoke($line)
                    $line
                })

        # Exit-code check, with dism's own sentence attached.
        $this.AssertExitCode($LASTEXITCODE, 'dism.exe', $commandLine, $output)
    }

    # APPLIES THE ANSWER FILE TO THE OFFLINE OS, WHICH IS THE ONLY THING THAT
    # RUNS THE offlineServicing PASS.
    #
    # DERIVED FROM MDT, LTIApply.wsf function ApplyUnattend (lines 1021-1043),
    # and PSD does the same through Use-WindowsUnattend (PSDConfigure.ps1:151).
    # See NOTICE.md. The argument shape is MDT's exactly:
    #
    #   dism.exe /Image:<volume>\ /Apply-Unattend:<file> /ScratchDir:<scratch>
    #
    # WHY IT MATTERS AT ALL: Setup reading Windows\Panther on first boot runs
    # specialize and oobeSystem. It does NOT run offlineServicing, which is
    # where Microsoft-Windows-PnpCustomizationsNonWinPE lives - so the driver
    # path the answer file declares is inert until this call is made. MDT's own
    # comment on the line says it "takes care of driver injection and servicing".
    #
    # dism.exe RATHER THAN Use-WindowsUnattend, for the reason ApplyImage above
    # gives: dism.exe is in WinPE as shipped, while the DISM cmdlets need the
    # WinPE-DismCmdlets optional component. PSD can assume the cmdlet; a thin
    # adapter that assumes less is the one to keep.
    #
    # THE SCRATCH DIRECTORY IS NOT OPTIONAL IN PRACTICE. WinPE runs from an X:
    # RAM disk, and left to itself DISM expands packages into TEMP there and
    # runs out of room. Both MDT and PSD hand it a folder on the local disk.
    #
    # AND IT IS RUN AS A POLLED PROCESS, NOT AS A PIPELINE. THIS IS THE ONE
    # PLACE THE TWO DISM VERBS DIFFER, AND THE REASON IS MEASURED RATHER THAN
    # PREFERRED.
    #
    # ApplyImage's meter is real: LT-D5M1NN3 run-20260829-223623 has twenty
    # step.progress records from the apply, scraped out of the pipeline as dism
    # printed them. THE SAME RUN HAS NONE AT ALL FROM THIS CALL, over 153
    # seconds of genuine offlineServicing across 260 .inf packages, on a boot
    # image built AFTER the meter was wired to it. dism.exe prints no percentage
    # for /Apply-Unattend - a banner, then silence, then one sentence - so
    # scraping stdout can never move anything here. MDT reached the same
    # conclusion and hard-codes a flat 99 before the call (LTIApply.wsf:1042)
    # rather than expecting a meter.
    #
    # A PIPELINE CANNOT TICK. '& dism | ForEach-Object' only runs the block when
    # a line arrives, and the engine is Windows PowerShell 5.1 and
    # single-threaded, so between the banner and the final sentence NOTHING in
    # the deployment executes. That is the whole defect: not a bar that moves
    # too slowly, but a step that cannot report at all while it is the only
    # thing running.
    #
    # SO IT IS MDT'S SHAPE, WHICH IS POLL, SCRAPE AND TICK - ZTIUtility.vbs's
    # RunCommandLog launches with WshShell.Exec, spins on oExec.Status with
    # SafeSleep 100, scrapes the tool's percentage out of stdout, AND writes a
    # timed heartbeat of its own (event 41003) for exactly the case where the
    # tool says nothing (lines 2173-2261). See NOTICE.md. HDT does all three:
    # $OnOutput still receives every line as it arrives, so a dism that DOES
    # print a meter is still read; $OnTick fires every 500 ms that dism is
    # silent, which is what actually moves the screen during this pass.
    #
    # ApplyImage KEEPS ITS PIPELINE, DELIBERATELY. Its meter works, on real
    # hardware, and it is that meter's arrival that already proves the step is
    # alive. Converting it would put the one number a technician watches at risk
    # of a redirection or encoding regression to buy liveness it already has.
    #
    # THE BRANCHES BELOW ARE THE POLL LOOP AND NOTHING ELSE, and they are the
    # same loop New-HDTProcessService.Start already carries for the same reason.
    # Everything that could be a decision is not here: the command line's
    # quoting is ConvertTo-HDTNativeArgument, what a line MEANS is
    # ConvertFrom-HDTDismProgressLine, and when a tick is worth a log record is
    # New-HDTStepHeartbeat. All three are pure and unit tested.
    $service | Add-Member -MemberType ScriptMethod -Name ApplyUnattend -Value {
        param([string] $ImagePath, [string] $UnattendPath, [string] $ScratchPath,
            [scriptblock] $OnOutput = {}, [scriptblock] $OnTick = {})

        $this.Record('ApplyUnattend', @($ImagePath, $UnattendPath, $ScratchPath))

        $null = [System.IO.Directory]::CreateDirectory($ScratchPath)

        # MDT'S ARGUMENT SHAPE, UNCHANGED (LTIApply.wsf:1043). What changed is
        # only how the process is started, and the quoting rule keeps the
        # command line byte-identical for the paths this actually passes: none
        # of 'W:\', the Panther path or the scratch path contains a space, so
        # every one of them goes on bare.
        $argument = @(
            ('/Image:{0}' -f $ImagePath),
            ('/Apply-Unattend:{0}' -f $UnattendPath),
            ('/ScratchDir:{0}' -f $ScratchPath)
        )

        $argumentLine = (@($argument | ForEach-Object { ConvertTo-HDTNativeArgument -Argument $_ }) -join ' ')
        $commandLine = 'dism {0}' -f $argumentLine

        $startInfo = New-Object -TypeName System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "$env:SystemRoot\System32\dism.exe"
        $startInfo.Arguments = $argumentLine
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true

        $process = New-Object -TypeName System.Diagnostics.Process
        $process.StartInfo = $startInfo

        $output = New-Object -TypeName System.Collections.ArrayList

        try {
            [void] $process.Start()

            # STDERR IS DRAINED ASYNCHRONOUSLY, and it is not tidiness: reading
            # stdout to its end while the child fills the stderr pipe buffer is
            # the classic redirect deadlock, and a deadlock here would hang a
            # deployment on the servicing pass forever.
            $errorTask = $process.StandardError.ReadToEndAsync()

            # THE POLL. ReadLine would block, and a blocked read is the pipeline
            # again with more code; ReadLineAsync waited on in half-second
            # slices is a read that can be interrupted, which is the whole point.
            $reader = $process.StandardOutput
            $pending = $reader.ReadLineAsync()

            while ($true) {

                # FIVE HUNDRED MILLISECONDS, New-HDTProcessService.Start's
                # stride and for its reasons: the tick is free but not
                # weightless, and New-HDTStepHeartbeat rations records to one
                # every fifteen seconds regardless of how often it is called.
                while (-not $pending.Wait(500)) {
                    $null = $OnTick.Invoke()
                }

                $line = $pending.Result

                # A null line is end of stream, which is the process closing its
                # handle - the only way out of the loop.
                if ($null -eq $line) { break }

                [void] $output.Add([string] $line)
                $null = $OnOutput.Invoke([string] $line)

                $pending = $reader.ReadLineAsync()
            }

            $process.WaitForExit()

            # dism's own sentences, whichever handle it chose to write them on.
            foreach ($errorLine in @([string] $errorTask.Result -split "`r?`n")) {
                [void] $output.Add([string] $errorLine)
            }

            # Exit-code check, with dism's own sentence attached. $LASTEXITCODE
            # is not set by a process started this way; the process object
            # carries it.
            $this.AssertExitCode($process.ExitCode, 'dism.exe', $commandLine, @($output))
        } finally {
            $process.Dispose()
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name AddDriver -Value {
        param([string] $ImagePath, [string] $DriverPath, [bool] $Recurse)

        $this.Record('AddDriver', @($ImagePath, $DriverPath, $Recurse))

        # -Recurse:$Recurse is parameter binding, not a branch.
        $added = @(Add-WindowsDriver -Path $ImagePath -Driver $DriverPath -Recurse:$Recurse)

        $row = foreach ($item in $added) {
            [pscustomobject] @{
                Inf      = [string] $item.Driver
                Provider = [string] $item.ProviderName
                Version  = [string] $item.Version
                Date     = [string] $item.Date
            }
        }

        # The unary comma is mandatory: a ScriptMethod returning an array
        # collapses a one-element array to a scalar without it, and one driver
        # is the ordinary case for a matched injection (tests/helpers/README.md
        # F3).
        return , ([object[]] @($row))
    }

    $service | Add-Member -MemberType ScriptMethod -Name InstallBootFile -Value {
        param([string] $OsRoot, [string] $SystemVolume, [string] $Firmware)

        $this.Record('InstallBootFile', @($OsRoot, $SystemVolume, $Firmware))

        $windows = Join-Path -Path $OsRoot -ChildPath 'Windows'
        # 5.1 TRAP, NOT TIDINESS. Under Windows PowerShell 5.1 the 2>&1 below
        # wraps every stderr line in an ErrorRecord, and the ErrorActionPreference
        # Stop that engine code sets makes the FIRST one terminating - so a tool
        # that merely printed a progress meter kills the call before its exit code
        # is ever consulted. That is exactly how oscdimg's "0% complete" killed the
        # first integration run under powershell.exe (SPIKES S13.5). Local to this
        # method scope, so nothing outside it changes. No branch: rule 1 holds.
        $ErrorActionPreference = 'Continue'

        $output = @(& "$env:SystemRoot\System32\bcdboot.exe" $windows '/s' $SystemVolume '/f' $Firmware 2>&1)

        # Exit-code check, with bcdboot's own sentence attached.
        $this.AssertExitCode($LASTEXITCODE, 'bcdboot.exe',
            ('bcdboot {0} /s {1} /f {2}' -f $windows, $SystemVolume, $Firmware), $output)
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetRecoveryImage -Value {
        param([string] $OsRoot, [string] $RecoveryPath)

        $this.Record('SetRecoveryImage', @($OsRoot, $RecoveryPath))

        # The APPLIED IMAGE'S OWN reagentc, by full path: WinPE has none, and
        # there is no WinPE-Recovery optional component to add one. Argument
        # construction, not a branch.
        $windows = Join-Path -Path $OsRoot -ChildPath 'Windows'
        $reagentc = Join-Path -Path $windows -ChildPath 'System32\Reagentc.exe'

        # /setreimage, NOT the verb DESIGN 9.2 names - reagentc on Windows 11
        # 24H2 has no such verb at all. DESIGN 9.2 is corrected in 04-03.
        # 5.1 TRAP, NOT TIDINESS. Under Windows PowerShell 5.1 the 2>&1 below
        # wraps every stderr line in an ErrorRecord, and the ErrorActionPreference
        # Stop that engine code sets makes the FIRST one terminating - so a tool
        # that merely printed a progress meter kills the call before its exit code
        # is ever consulted. That is exactly how oscdimg's "0% complete" killed the
        # first integration run under powershell.exe (SPIKES S13.5). Local to this
        # method scope, so nothing outside it changes. No branch: rule 1 holds.
        $ErrorActionPreference = 'Continue'

        $output = @(& $reagentc '/setreimage' '/path' $RecoveryPath '/target' $windows 2>&1)

        $this.AssertExitCode($LASTEXITCODE, 'Reagentc.exe',
            ('{0} /setreimage /path {1} /target {2}' -f $reagentc, $RecoveryPath, $windows), $output)
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetBootOrderFirst -Value {
        $this.Record('SetBootOrderFirst', @())

        # SPIKES.md S6: after apply, a machine whose firmware still has the boot
        # media first simply reboots into WinPE and the deployment loops.
        # 5.1 TRAP, NOT TIDINESS. Under Windows PowerShell 5.1 the 2>&1 below
        # wraps every stderr line in an ErrorRecord, and the ErrorActionPreference
        # Stop that engine code sets makes the FIRST one terminating - so a tool
        # that merely printed a progress meter kills the call before its exit code
        # is ever consulted. That is exactly how oscdimg's "0% complete" killed the
        # first integration run under powershell.exe (SPIKES S13.5). Local to this
        # method scope, so nothing outside it changes. No branch: rule 1 holds.
        $ErrorActionPreference = 'Continue'

        $output = @(& "$env:SystemRoot\System32\bcdedit.exe" '/set' '{fwbootmgr}' 'displayorder' '{bootmgr}' '/addfirst' 2>&1)

        $this.AssertExitCode($LASTEXITCODE, 'bcdedit.exe',
            'bcdedit /set {fwbootmgr} displayorder {bootmgr} /addfirst', $output)
    }

    # -- the FullOS -> WinPE transport -------------------------------------
    #
    # DERIVED FROM MDT: ZTIBCDUtility.vbs CreateNewBCDEntryEx / AdjustBCDDefaults,
    # reached from LTIApply.wsf InstallPE. MIT licensed; see NOTICE.md. PSD has
    # no FullOS -> WinPE mechanism at all, so there is no PowerShell prior art.
    #
    # THE THREE METHODS ARE ONE LOOP EACH, AND EVERY DECISION IS SOMEWHERE ELSE.
    # Get-HDTBcdCommand composes the ordered argument lists and is unit tested
    # character by character; Get-HDTLocalWinPePlan decides winload.efi versus
    # winload.exe, which store, and where the files go. This adapter runs what it
    # is handed, which is what keeps rule 1 true of a file nothing executes in a
    # test.
    #
    # NOTHING HERE COPIES A BOOT LOADER, AND THAT IS DELIBERATE. MDT's InstallPE
    # robocopies the ADK's efi\ and Boot\ trees over the boot drive and renames
    # bootx64.efi to BootMgFW.efi - it replaces the machine's boot manager with
    # the ADK's copy. SPIKES S20 measured that exact file at SVN 3.0 against an
    # enforced floor of 7.0, so copying MDT more faithfully here would DOWNGRADE
    # the one binary Secure Boot already refuses. The ramdisk entry these methods
    # create is loaded BY the boot manager bcdboot already installed, as an
    # OSLOADER application, so the Secure Boot chain gains nothing new.

    $service | Add-Member -MemberType ScriptMethod -Name RunBcdEdit -Value {
        param([object[]] $Command)

        # 5.1 TRAP, NOT TIDINESS. Under Windows PowerShell 5.1 the 2>&1 below
        # wraps every stderr line in an ErrorRecord, and the ErrorActionPreference
        # Stop that engine code sets makes the FIRST one terminating - so a tool
        # that merely printed a progress meter kills the call before its exit code
        # is ever consulted. That is exactly how oscdimg's "0% complete" killed the
        # first integration run under powershell.exe (SPIKES S13.5). Local to this
        # method scope, so nothing outside it changes.
        $ErrorActionPreference = 'Continue'

        foreach ($entry in @($Command)) {
            $argument = [string[]] @($entry.Argument)

            $output = @(& "$env:SystemRoot\System32cdedit.exe" @argument 2>&1)

            # THE ONE BRANCH, AND IT IS ON DATA RATHER THAN ON A DEPLOYMENT.
            # Exactly one command in the whole transport is allowed to fail -
            # /create {ramdiskoptions} on a machine that already has one, which
            # a registered WinRE guarantees. Get-HDTBcdCommand marks it and a
            # unit test asserts that it marks only it.
            if ($entry.Tolerate) { continue }

            $this.AssertExitCode($LASTEXITCODE, 'bcdedit.exe',
                ('bcdedit {0}' -f ($argument -join ' ')), $output)
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name AddRamdiskBootEntry -Value {
        param([string] $Store, [string] $Id, [string] $Description, [string] $RamdiskVolume,
            [string] $WimDevicePath, [string] $SdiDevicePath, [string] $LoaderPath)

        $this.Record('AddRamdiskBootEntry', @($Store, $Id, $Description, $RamdiskVolume,
                $WimDevicePath, $SdiDevicePath, $LoaderPath))

        $this.RunBcdEdit(@(Get-HDTBcdCommand -Action Create -Store $Store -Id $Id `
                    -Description $Description -RamdiskVolume $RamdiskVolume `
                    -WimDevicePath $WimDevicePath -SdiDevicePath $SdiDevicePath `
                    -LoaderPath $LoaderPath))
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetBootSequenceOnce -Value {
        param([string] $Store, [string] $Id)

        $this.Record('SetBootSequenceOnce', @($Store, $Id))

        $this.RunBcdEdit(@(Get-HDTBcdCommand -Action Arm -Store $Store -Id $Id))
    }

    $service | Add-Member -MemberType ScriptMethod -Name RemoveBootEntry -Value {
        param([string] $Store, [string] $Id)

        $this.Record('RemoveBootEntry', @($Store, $Id))

        $this.RunBcdEdit(@(Get-HDTBcdCommand -Action Remove -Store $Store -Id $Id))
    }

    return $service
}
