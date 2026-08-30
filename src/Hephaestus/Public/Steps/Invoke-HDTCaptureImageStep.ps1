function Invoke-HDTCaptureImageStep {
    <#
        .SYNOPSIS
            Reads the sysprepped reference machine into a WIM the share can
            deploy.

        .DESCRIPTION
            The second half of DESIGN 9.3's reference-image loop, and
            ApplyImage's mirror - the same service, the same dism meter, the
            same throttling, the inverse operation:

              - name: Capture the reference image
                type: CaptureImage
                runIn: WinPE
                image: "%HDTTaskSequenceID%.wim"
                name: Windows 11 reference build
                description: built by HDT
                compress: max
                source: "%HDTOSVolume%"       # optional
                configFile: ""                # optional

            THE SOURCE IS THE APPLIED OS VOLUME ROOT, W:\ and not a folder that
            merely contains an OS tree. A capture of the wrong directory
            produces a WIM that applies and does not boot, and nothing about the
            run says so.

            AND A SOURCE THAT RESOLVED TO NOTHING IS A REFUSAL NAMING THE
            VARIABLE, NEVER A GUESS AT C:. This is ApplyImage's refusal read
            backwards: in WinPE a capture of C:\ is a capture of the boot media
            or of nothing at all, and either way it is not the machine anybody
            asked about.

            THE DESTINATION IS Captures\, resolved through Get-HDTWorkspacePath,
            because that is the folder the share is set up to let the deployment
            account write (DESIGN 2.1, Test-HDTShareAcl). A rooted path is taken
            as written, for a capture onto a second disk.

            THREE REFUSALS, ALL OF THEM BEFORE dism IS ASKED TO DO ANYTHING.

              THE Local PROVIDER IS REFUSED OUTRIGHT. Under it the deploy root
              is a read-only disc: Captures\ cannot be written at all, and there
              is no correction a technician standing at the machine could make.
              Attempting the write and reporting whatever the disc said would
              describe the symptom and none of the cause (DESIGN 9.3 note 6).

              Captures\ IS PROVED WRITABLE FIRST, with a probe file this step
              writes and removes. DESIGN 9.3 note 5: a reference build is hours
              of installing and customizing, and discovering at the END that the
              account cannot write Captures\ costs the whole run - after the
              machine has been generalized and can no longer be picked up where
              it left off. The probe is named from the run id rather than a
              guid, so the one path that must fail is a path a test can seed.

              AND NO CAPTURE RUNS WITHOUT AN EXCLUSION LIST. dism takes
              /ConfigFile:, MDT passes one on every capture (ZTIBackup.wsf:427),
              and without one a capture swallows pagefile.sys, hiberfil.sys,
              System Volume Information - and, because HDT put them there, the
              resume agent at <osvolume>\HDT and this machine's own deployment
              log. An image carrying those re-runs somebody else's deployment
              state on every machine ever built from it.

              THE LIST IS RESOLVED, NOT ASSUMED: the share's
              Control\wimscript.ini when it has one, otherwise the module's
              Templates\Capture\wimscript.ini, which travels into every boot
              image because Update-HDTBootImage copies Templates\ whole. A share
              created before this existed still captures correctly, and a shop
              with its own folder to exclude edits one file rather than the
              module every machine boots. A named list that is not there is a
              REFUSAL and never a silent capture without exclusions - dism
              merely warns and captures everything, exit code zero, and the
              image is wrong while the run is green.

            THE SCRATCH DIRECTORY GOES ON THE VOLUME BEING CAPTURED, NEVER ON
            X:. WinPE runs from a RAM disk and dism left to itself expands into
            TEMP there and runs out of room - the same line ApplyUnattend
            carries, for the same reason (New-HDTImageService).

            max COMPRESSION BY DEFAULT, because a reference image is stored,
            copied and read for years and is written once. none and fast are
            offered for a lab turning one round quickly, and a fourth value is
            refused here rather than by dism four hours in - the closed set is
            Get-HDTStepPropertyChoice's, which is the same list the console
            offers.

            THE METER IS dism's OWN. /Capture-Image prints a percentage on
            stdout exactly as /Apply-Image does, the adapter hands every line to
            this step as it arrives, and ConvertFrom-HDTDismProgressLine turns it
            into a step.progress every five points and always at a hundred.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry
            Image and FileSystem services.

        .OUTPUTS
            A New-HDTStepResult. Data carries capturePath, imagePath, name,
            compress, configFile and durationMs, or errorId on a refusal.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock `
                -Image (New-HDTImageService) `
                -Content (New-HDTContentProvider -Provider Smb -Root '\hdtserver\HdtShare')
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\REF-WIN11\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'CaptureImage' })[0]

            Invoke-HDTCaptureImageStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what
            the engine does before the first step; a step cannot be run without
            one.

        .EXAMPLE
            $result = Invoke-HDTCaptureImageStep -Step $step -Context $context
            $result.Data.imagePath

            Where the WIM was written. It is also published as HDTCapturePath, so
            a later step - or Import-HDTOperatingSystem, which promotes a capture
            into the OS catalog - can name it without being told twice.
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

    $component = 'CaptureImage'

    $fail = {
        param([string] $Message, [string] $ErrorId)

        $data = [ordered] @{}
        if (-not [string]::IsNullOrWhiteSpace($ErrorId)) { $data['errorId'] = $ErrorId }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component $component -Data $data

        return (New-HDTStepResult -Status Failed -Message $Message -Data $data)
    }

    try {
        $imageService = $Context.Service.GetRequired('Image', $component)
        $fileSystem = $Context.Service.GetRequired('FileSystem', $component)
    } catch {
        return (& $fail ([string] $_.Exception.Message) '')
    }

    try {
        $imageProperty = Get-HDTStepProperty -Step $Step -Name 'image' -Default '' -Context $Context -Expand -As String
        $imageName = Get-HDTStepProperty -Step $Step -Name 'name' -Default '' -Context $Context -Expand -As String
        $description = Get-HDTStepProperty -Step $Step -Name 'description' -Default '' -Context $Context -Expand -As String
        $compress = Get-HDTStepProperty -Step $Step -Name 'compress' -Default 'max' -Context $Context -Expand -As String
        $sourceProperty = Get-HDTStepProperty -Step $Step -Name 'source' -Default '' -Context $Context -Expand -As String
        $configProperty = Get-HDTStepProperty -Step $Step -Name 'configFile' -Default '' -Context $Context -Expand -As String

        # AND WHAT THE AUTHOR WROTE, unexpanded, for the same reason ApplyImage
        # keeps it: a source of %HDTOSVolume% that nothing published arrives here
        # as an empty string, and the refusal has to name the variable that was
        # meant to fill it.
        #
        # THE DEFAULT IS READ FROM THE SCOPE, NOT WRITTEN AS A TOKEN.
        # Get-HDTStepProperty returns -Default AS IT IS: expansion runs over a
        # value the document supplied, never over the fallback. A default of
        # '%HDTOSVolume%' therefore arrived here as the literal seven characters
        # and refused every capture with "is not a drive letter" - on the one
        # step whose whole job is to read the volume the partition step
        # published. ApplyImage has the same shape and spells it 'primary'.
        $sourceWritten = Get-HDTStepProperty -Step $Step -Name 'source' -Default '%HDTOSVolume%' -As String
    } catch {
        return (& $fail ([string] $_.Exception.Message) 'HDTConfigurationError')
    }

    # -- can this deployment write a capture at all ------------------------
    #
    # THE SAME QUESTION Invoke-HDTSysprepStep ALREADY ASKED, and asked at the
    # only moment the answer was still cheap. This is the useless-but-necessary
    # end of it: by the time this step runs the machine has been built,
    # generalized and restarted, so a refusal here costs the build. It is
    # repeated anyway because a capture must not attempt a write it has been
    # told will fail, and because a sequence may reach this step without having
    # gone through a Sysprep step at all.
    #
    # ONE FUNCTION, NOT TWO COPIES: Test-HDTCaptureTarget owns the media refusal
    # and the write probe, so the answer cannot differ between the step that
    # checks early and the step that checks late.
    $target = Test-HDTCaptureTarget -Context $Context -FileSystem $fileSystem

    if (-not $target.Ok) {
        return (& $fail ([string] $target.Message) ([string] $target.ErrorId))
    }

    # -- which volume ------------------------------------------------------

    $letter = $sourceProperty

    if ([string]::IsNullOrWhiteSpace($letter)) {
        $letter = [string] $Context.Variable['HDTOSVolume']
    }

    if ([string]::IsNullOrWhiteSpace($letter)) {
        $said = "step '{0}': source '{1}' resolved to nothing." -f $Step.Name, $sourceProperty

        if ($sourceWritten -match '^\s*%([^%]+)%\s*$') {
            $said = ("step '{0}' captures %{1}%, which is not set. The partition step publishes it; HDT will not guess a drive letter to read an operating system out of." -f
                $Step.Name, [string] $Matches[1])
        }

        return (& $fail $said 'HDTConfigurationError')
    }

    $letter = $letter.Trim().TrimEnd('\').TrimEnd(':')

    # ONE LETTER IS ONE LETTER, which is ApplyImage's refusal exactly: taking
    # the first character of whatever arrived would make 'source: the big disk'
    # capture T:\ and report success.
    if ($letter -notmatch '^[A-Za-z]$') {
        return (& $fail ("step '{0}': source '{1}' is not a drive letter." -f $Step.Name, $sourceProperty) 'HDTConfigurationError')
    }

    $volume = $letter.Substring(0, 1).ToUpperInvariant()
    $capturePath = '{0}:\' -f $volume

    # -- which compression -------------------------------------------------
    #
    # THE CONSOLE'S OWN LIST, READ BY BOTH ENDS. Spelling the set again here
    # would be two lists to drift apart, and the way that goes wrong is a
    # drop-down offering a value dism rejects four hours into a capture.
    $allowedCompress = @(Get-HDTStepPropertyChoice -Type 'CaptureImage' -Key 'compress')

    if ($allowedCompress -notcontains $compress) {
        return (& $fail ("step '{0}': compress '{1}' is not one dism has. The values are {2}." -f
                $Step.Name, $compress, ($allowedCompress -join ', ')) 'HDTConfigurationError')
    }

    # -- where the WIM goes ------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($imageProperty)) {
        return (& $fail ("step '{0}' names no image to write. A CaptureImage step names the WIM it creates, which is what the share will offer afterwards." -f
                $Step.Name) 'HDTConfigurationError')
    }

    $imageLeaf = $imageProperty

    # A CAPTURE WITH NO EXTENSION IS STILL A WIM, and dism will happily write
    # one called 'REF-WIN11'. Import-HDTOperatingSystem and every picker after
    # it look for .wim, so the file is named the way the rest of the toolkit
    # reads it rather than the way it happened to be typed.
    if ([string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($imageLeaf))) {
        $imageLeaf = '{0}.wim' -f $imageLeaf
    }

    if ([System.IO.Path]::IsPathRooted($imageLeaf)) {
        $imagePath = $imageLeaf
    } else {
        $imagePath = Get-HDTWorkspacePath -Root ([string] $Context.WorkspaceRoot) -Kind Captures -ChildPath $imageLeaf
    }

    # AN UNNAMED IMAGE IS AN UNSELECTABLE ONE. Resolve-HDTImageIndex matches on
    # Name, so a WIM whose only index is called '' cannot be asked for by name -
    # and the file's own name is what an administrator would have typed anyway.
    if ([string]::IsNullOrWhiteSpace($imageName)) {
        $imageName = [System.IO.Path]::GetFileNameWithoutExtension($imagePath)
    }

    # -- the exclusion list ------------------------------------------------

    $configPath = ''
    $configSource = ''

    if (-not [string]::IsNullOrWhiteSpace($configProperty)) {
        $configPath = $configProperty
        $configSource = 'the sequence'

        if (-not [System.IO.Path]::IsPathRooted($configPath)) {
            $configPath = [System.IO.Path]::Combine([string] $Context.WorkspaceRoot, $configPath)
        }
    } else {
        $shareConfig = Get-HDTWorkspacePath -Root ([string] $Context.WorkspaceRoot) -Kind Control -ChildPath 'wimscript.ini'

        if ($fileSystem.TestPath($shareConfig)) {
            $configPath = $shareConfig
            $configSource = 'the share'
        } else {
            # THE MODULE'S OWN, WHICH TRAVELS INTO EVERY BOOT IMAGE because
            # Update-HDTBootImage copies Templates\ whole. [IO.Path]::Combine and
            # never Join-Path: the module root may be on a drive this session has
            # not mounted, and Join-Path resolves the qualifier and throws.
            $configPath = [System.IO.Path]::Combine($script:HDTModuleRoot, 'Templates', 'Capture', 'wimscript.ini')
            $configSource = 'this module'
        }
    }

    if (-not $fileSystem.TestPath($configPath)) {
        return (& $fail ("the capture exclusion list named by {0}, '{1}', is not there. A capture without one writes pagefile.sys, hiberfil.sys and HDT's own working folder into the reference image, and dism reports that as success." -f
                $configSource, $configPath) 'HDTConfigurationError')
    }

    # -- the capture -------------------------------------------------------
    #
    # OFF THE RAM DISK. X: is WinPE's, and dism expanding into TEMP there runs
    # out of room on a volume of any size.
    $scratchPath = '{0}:\HDT\Scratch' -f $volume

    $data = [ordered] @{
        capturePath = $capturePath
        imagePath   = $imagePath
        imageName   = $imageName
        compress    = $compress
        configFile  = $configPath
        scratch     = $scratchPath
    }

    Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component $component `
        -Message ("capturing {0} into {1} as '{2}', compress {3}, excluding what {4}'s wimscript.ini names" -f
            $capturePath, $imagePath, $imageName, $compress, $configSource) `
        -Data $data

    $clock = $Context.Service.Clock
    $startedUtc = $clock.GetUtcNow()

    # EVERY FIVE POINTS, AND ALWAYS AT A HUNDRED - ApplyImage's stride and its
    # reasons. dism prints about a hundred meter lines; five is the granularity
    # a bar on a wall is read at, and the last thing the log says about a
    # capture should be that it finished.
    $progressState = @{ Percent = 0 }

    # RESOLVED HERE AND CAPTURED, NOT LOOKED UP IN THE CALLBACK. The callback is
    # invoked from inside the image service, and the fake is a PowerShell CLASS
    # in HDTFakes - a scriptblock invoked from a class method resolves its
    # commands in THAT module, where these private functions do not exist. The
    # trap is documented at length on Invoke-HDTApplyImageStep; a CommandInfo
    # invoked with & does not care whose scope it is called from.
    $parseProgress = Get-Command -Name 'ConvertFrom-HDTDismProgressLine'
    $writeLog = Get-Command -Name 'Write-HDTLog'
    $updateDisplay = Get-Command -Name 'Update-HDTProgressDisplay'

    $onOutput = {
        param([string] $Line)

        # A BAR DOES NOT GET TO FAIL A DEPLOYMENT, and this one runs part-way
        # through reading a day's work into a WIM.
        try {
            $percent = & $parseProgress -Line $Line
            if ($null -eq $percent) { return }

            $reported = [int] $progressState['Percent']
            if ([int] $percent -le $reported) { return }
            if ([int] $percent -lt ($reported + 5) -and [int] $percent -lt 100) { return }

            $progressState['Percent'] = [int] $percent

            & $writeLog -Context $Context.Log -Event 'step.progress' -Component 'CaptureImage' `
                -Message ('capturing {0} into {1}: {2}%' -f $capturePath, $imagePath, [int] $percent) `
                -Data ([ordered] @{
                    capturePath = $capturePath
                    imagePath   = $imagePath
                    percent     = [int] $percent
                })

            & $updateDisplay -Context $Context
        } catch {
            # Kept where a debugger can reach it rather than thrown away: an
            # empty catch is how a percentage that never appeared stays a mystery.
            $progressState['Error'] = [string] $_.Exception.Message
        }
    }.GetNewClosure()

    try {
        $imageService.CaptureImage($capturePath, $imagePath, $imageName, $description, $compress,
            $scratchPath, $configPath, $onOutput)
    } catch {
        return (& $fail ("capturing {0} into {1} failed: {2}" -f
                $capturePath, $imagePath, [string] $_.Exception.Message) '')
    }

    $durationMillisecond = [long] (($clock.GetUtcNow()) - $startedUtc).TotalMilliseconds
    $data['durationMs'] = $durationMillisecond

    # SO THE NEXT THING DOES NOT HAVE TO BE TOLD TWICE. Import-HDTOperatingSystem
    # promotes a capture into the OS catalog, and this is where it was put.
    $Context.Variable['HDTCapturePath'] = $imagePath

    $message = 'captured {0} into {1} in {2} ms.' -f $capturePath, $imagePath, $durationMillisecond

    Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component $component -Message $message -Data $data

    return (New-HDTStepResult -Status Completed -Message $message -Data $data)
}
