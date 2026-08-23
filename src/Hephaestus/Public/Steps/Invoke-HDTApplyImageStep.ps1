function Invoke-HDTApplyImageStep {
    <#
        .SYNOPSIS
            Applies Windows to the volume the partition step created.

        .DESCRIPTION
            Applying an image, as a step:

              - name: Apply OS
                type: ApplyImage
                os: "%HDTOSImage%"      # a catalog id ... or image: a path
                index: 1                # or name: or edition:
                target: primary         # 'primary' = %HDTOSVolume%, or a letter
                timeoutMinutes: 60

            THE INDEX IS RESOLVED, NEVER GUESSED. Get-HDTOperatingSystem reads
            the catalog and Resolve-HDTImageIndex chooses, matching each
            criterion independently and intersecting them - so
            'edition: ServerStandard' with 'index: 2' resolves on the real Server
            2025 media where the edition alone is ambiguous, and two images
            matching one request is an HDTAmbiguousImageError listing both rather
            than a coin toss.

            A TARGET THAT RESOLVES TO NOTHING IS A FAILURE NAMING THE VARIABLE,
            AND NEVER A GUESS AT C:. Applying an image over whatever happens to
            be on C: is the second most destructive thing this toolkit could do,
            and 'target: primary' with no HDTOSVolume means the partition step
            did not run - which is a sequence to fix, not a drive letter to
            invent.

            THE ELAPSED TIME IS LOGGED. A lab test measured 95 seconds for a 4 GB
            WIM applied over SMB, so the duration is the number that tells a
            technician whether a slow deployment was the network or the disk.
            The native.exec record carries the image, the index and
            the target at Info.

            AN EXPLICIT image: PATH BYPASSES THE CATALOG, for media too large to
            bring into the share. The indices are then read through
            IImageService.GetImageInfo, which is the same list Import-HDTOperatingSystem
            would have written into os.yaml. THE CONTENT PROVIDER IS NOT ASKED
            ABOUT IT EITHER: an explicit path is explicit, and a provider must
            not second-guess it.

            THE IMAGE IS RESOLVED THROUGH THE CONTENT PROVIDER when the run was
            started with one - $Context.Service.Content, handed to
            Get-HDTOperatingSystem, which is the whole change this step needed to
            close the seam 04-02 marked. It never learns whether that provider is
            Local or Smb, and the claim that it cannot tell is asserted
            by running this step through both and comparing the ordered list of
            every service call.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry
            Image and FileSystem services.

        .OUTPUTS
            A New-HDTStepResult. Data carries imagePath, index, target and
            durationMs, or errorId on a refusal.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'ApplyImage' })[0]

            Invoke-HDTApplyImageStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTApplyImageStep -Step $step -Context $context
            $result.Status
            $result.Message

            Status is Completed, Failed or Skipped, and Message is what the log line
            will say. Nothing is thrown for a failed apply - the loop decides what a
            failed step means.
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
            -Component 'ApplyImage' -Data $data

        return (New-HDTStepResult -Status Failed -Message $Message -Data $data)
    }

    try {
        $osId = Get-HDTStepProperty -Step $Step -Name 'os' -Context $Context -Expand -As String
        $imageProperty = Get-HDTStepProperty -Step $Step -Name 'image' -Context $Context -Expand -As String
        $index = Get-HDTStepProperty -Step $Step -Name 'index' -Context $Context -Expand -As Int
        $name = Get-HDTStepProperty -Step $Step -Name 'name' -Context $Context -Expand -As String
        $edition = Get-HDTStepProperty -Step $Step -Name 'edition' -Context $Context -Expand -As String
        $target = Get-HDTStepProperty -Step $Step -Name 'target' -Default 'primary' -Context $Context -Expand -As String

        # AND WHAT THE AUTHOR WROTE, unexpanded. A target of %HDTOSVolume% that
        # nothing published arrives here as an empty string, and the refusal has
        # to be able to name the variable that was meant to fill it.
        $targetWritten = Get-HDTStepProperty -Step $Step -Name 'target' -Default 'primary' -As String
    } catch {
        return (& $fail ([string] $_.Exception.Message) 'HDTConfigurationError')
    }

    try {
        $imageService = $Context.Service.GetRequired('Image', 'ApplyImage')
        $fileSystem = $Context.Service.GetRequired('FileSystem', 'ApplyImage')
    } catch {
        return (& $fail ([string] $_.Exception.Message) '')
    }

    # -- which image ------------------------------------------------------

    $imagePath = ''
    $imageRow = @()
    $defaultIndex = 0

    if (-not [string]::IsNullOrWhiteSpace($imageProperty)) {
        $imagePath = $imageProperty

        try {
            $imageRow = @($imageService.GetImageInfo($imagePath))
        } catch {
            return (& $fail ("the image '{0}' could not be read: {1}" -f $imagePath, [string] $_.Exception.Message) '')
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($osId)) {
        try {
            # THE WHOLE OF THIS STEP'S SHARE OF DESIGN 6. The catalog resolves
            # its image through the provider when the run was started with one,
            # and this step does not know or care which provider it is - which is
            # DESIGN 6.2's "a content projection plus a provider swap, not a
            # parallel code path", asserted by the operation-list equality test
            # in tests/unit/Invoke-HDTApplyImageStep.Tests.ps1.
            $catalog = Get-HDTOperatingSystem -WorkspaceRoot ([string] $Context.WorkspaceRoot) -Id $osId `
                -FileSystem $fileSystem -Content $Context.Service.Content
        } catch {
            return (& $fail ([string] $_.Exception.Message) (([string] $_.FullyQualifiedErrorId).Split(',')[0]))
        }

        $imagePath = [string] $catalog.ImagePath
        $imageRow = @($catalog.Images)
        $defaultIndex = [int] $catalog.DefaultIndex
    } else {
        return (& $fail ("step '{0}' declares neither os nor image. An ApplyImage step names a catalog id or an image path." -f $Step.Name) 'HDTConfigurationError')
    }

    # -- which index ------------------------------------------------------

    $resolveArgument = @{ Image = [object[]] $imageRow }

    if ($null -ne $index) { $resolveArgument['Index'] = [int] $index }
    if (-not [string]::IsNullOrWhiteSpace($name)) { $resolveArgument['Name'] = $name }
    if (-not [string]::IsNullOrWhiteSpace($edition)) { $resolveArgument['Edition'] = $edition }
    if ($defaultIndex -gt 0) { $resolveArgument['DefaultIndex'] = $defaultIndex }

    try {
        $resolved = Resolve-HDTImageIndex @resolveArgument
    } catch {
        return (& $fail ([string] $_.Exception.Message) (([string] $_.FullyQualifiedErrorId).Split(',')[0]))
    }

    $resolvedIndex = [int] $resolved.Index

    # -- where ------------------------------------------------------------

    $letter = $target

    if ($target -eq 'primary') {
        $letter = [string] $Context.Variable['HDTOSVolume']

        if ([string]::IsNullOrWhiteSpace($letter)) {
            return (& $fail ("step '{0}' applies to the primary volume and HDTOSVolume is not set. The partition step publishes it; HDT will not guess a drive letter to apply {1} GB of Windows over." -f
                    $Step.Name, [math]::Round([long] $resolved.SizeBytes / 1073741824, 1)) 'HDTConfigurationError')
        }
    }

    $letter = $letter.Trim().TrimEnd('\').TrimEnd(':')

    # A TARGET THAT RESOLVED TO NOTHING IS THE SITUATION 'primary' NAMES, said a
    # different way: the partition step did not publish the volume. It used to
    # report "target '' is not a drive letter", which describes the symptom and
    # none of the cause - on the one step that writes an operating system
    # somewhere.
    if ($letter.Length -eq 0) {
        $said = "step '{0}': target '{1}' resolved to nothing." -f $Step.Name, $target

        if ($targetWritten -match '^\s*%([^%]+)%\s*$') {
            $said = ("step '{0}' applies to %{1}%, which is not set. The partition step publishes it; HDT will not guess a drive letter to apply an operating system over." -f
                $Step.Name, [string] $Matches[1])
        }

        return (& $fail $said 'HDTConfigurationError')
    }

    # AND ONE LETTER IS ONE LETTER. Taking the first character of whatever
    # arrived meant 'target: the big disk' applied Windows to T:\ without a word
    # - a wrong disk, chosen by a typo, and reported as success.
    if ($letter -notmatch '^[A-Za-z]$') {
        return (& $fail ("step '{0}': target '{1}' is not a drive letter." -f $Step.Name, $target) 'HDTConfigurationError')
    }

    $applyPath = '{0}:\' -f $letter.Substring(0, 1).ToUpperInvariant()

    # -- the apply --------------------------------------------------------

    $data = [ordered] @{
        imagePath = $imagePath
        index     = $resolvedIndex
        imageName = [string] $resolved.Name
        target    = $applyPath
    }

    Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component 'ApplyImage' `
        -Message ("applying {0} (index {1}, {2}) to {3}" -f $imagePath, $resolvedIndex, [string] $resolved.Name, $applyPath) `
        -Data $data

    $clock = $Context.Service.Clock
    $startedUtc = $clock.GetUtcNow()

    # THE ONLY NUMBER THAT MOVES FOR THE NEXT NINE MINUTES. Everything else on
    # the screen - the counter, the sequence percentage, the step name - is
    # correct and motionless for the whole of an 18 GB apply, and a motionless
    # screen is indistinguishable from a hung machine to the person standing in
    # front of it. dism prints a percentage as it works; the adapter hands every
    # line it prints to this.
    #
    # STILL NO SECOND CHANNEL (DESIGN 11.1). This writes a record to the JSONL
    # and asks the display to re-read it, exactly as the step loop does between
    # steps. The screen and the log cannot disagree because they are the same
    # facts.
    #
    # EVERY FIVE POINTS, AND ALWAYS AT A HUNDRED. dism prints about a hundred
    # meter lines and each one would otherwise be a log record and a re-read of
    # the log by the display; five is the granularity a bar on a wall is read
    # at. A hundred is reported whether or not it clears the threshold, because
    # the last thing the log says about an apply should be that it finished.
    $progressState = @{ Percent = 0 }

    # THE CALLBACK RUNS IN SOMEBODY ELSE'S MODULE, AND COMMAND RESOLUTION
    # FOLLOWS THE CALLER RATHER THAN THE CLOSURE. The real IImageService is a
    # pscustomobject built in this module, but the fake is a PowerShell CLASS in
    # HDTFakes - and a scriptblock invoked from a class method resolves its
    # commands in the class's module, where ConvertFrom-HDTDismProgressLine,
    # private to Hephaestus, does not exist. That failure landed in the catch
    # below and looked exactly like an apply that printed no percentages: every
    # other assertion still passed.
    #
    # SO THEY ARE RESOLVED HERE, WHERE THIS FUNCTION IS, and captured. A
    # CommandInfo invoked with & does not care whose scope it is called from.
    $parseProgress = Get-Command -Name 'ConvertFrom-HDTDismProgressLine'
    $writeLog = Get-Command -Name 'Write-HDTLog'
    $updateDisplay = Get-Command -Name 'Update-HDTProgressDisplay'

    $onOutput = {
        param([string] $Line)

        # A BAR DOES NOT GET TO FAIL A DEPLOYMENT. This runs inside the apply,
        # on a machine part-way through writing Windows to a disk; a log write
        # that lost its RAM disk or a display whose runspace has died is not a
        # reason to stop building a computer.
        try {
            $percent = & $parseProgress -Line $Line
            if ($null -eq $percent) { return }

            $reported = [int] $progressState['Percent']
            if ([int] $percent -le $reported) { return }
            if ([int] $percent -lt ($reported + 5) -and [int] $percent -lt 100) { return }

            $progressState['Percent'] = [int] $percent

            & $writeLog -Context $Context.Log -Event 'step.progress' -Component 'ApplyImage' `
                -Message ('applying {0} (index {1}) to {2}: {3}%' -f $imagePath, $resolvedIndex, $applyPath, [int] $percent) `
                -Data ([ordered] @{
                    imagePath = $imagePath
                    index     = $resolvedIndex
                    target    = $applyPath
                    percent   = [int] $percent
                })

            & $updateDisplay -Context $Context
        } catch {
            # Kept where a debugger can reach it rather than thrown away: an
            # empty catch is how a percentage that never appeared stays a
            # mystery.
            $progressState['Error'] = [string] $_.Exception.Message
        }
    }.GetNewClosure()

    try {
        $imageService.ApplyImage($imagePath, $resolvedIndex, $applyPath, $onOutput)
    } catch {
        return (& $fail ("applying {0} (index {1}) to {2} failed: {3}" -f
                $imagePath, $resolvedIndex, $applyPath, [string] $_.Exception.Message) '')
    }

    $durationMillisecond = [long] (($clock.GetUtcNow()) - $startedUtc).TotalMilliseconds
    $data['durationMs'] = $durationMillisecond

    $Context.Variable['HDTImageIndex'] = $resolvedIndex

    $message = 'applied {0} (index {1}) to {2} in {3} ms.' -f $imagePath, $resolvedIndex, $applyPath, $durationMillisecond

    Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component 'ApplyImage' -Message $message -Data $data

    return (New-HDTStepResult -Status Completed -Message $message -Data $data)
}
