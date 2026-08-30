# A REAL WINDOWS 11 APPLY, THE FIRST TIME HDT's OWN CODE DOES ONE.
#
# SPIKES S6 applied a 4 GB WIM over SMB by hand in 95 seconds and then ran
# bcdboot. This file is where HDT's IImageService adapter does the same thing to
# a scratch VHDX, so the numbers and the mechanisms stop being a spike log and
# become a test.
#
# IT IS THE SLOW FILE. The apply alone takes minutes, which is why every
# Describe here is tagged Slow and why the whole thing runs against ONE disk
# built once in a BeforeAll rather than a fresh one per test.
#
# SetBootOrderFirst IS NOT TESTED HERE, DELIBERATELY. It runs
#
#   bcdedit /set {fwbootmgr} displayorder {bootmgr} /addfirst
#
# which edits the FIRMWARE BOOT ORDER OF THE MACHINE IT RUNS ON - and that
# machine is the developer's. It is exercised for the first time inside the VM
# in tests/e2e, and this comment is here so the gap is named rather than silent.

BeforeDiscovery {
    $script:driveLetterInUse = @(@('S', 'W', 'R') | Where-Object { Test-Path -LiteralPath ('{0}:\' -f $_) })
    $script:mediaPath = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
    $script:skipSlow = ($script:driveLetterInUse.Count -gt 0) -or (-not (Test-Path -LiteralPath $script:mediaPath -PathType Leaf))

    # READING the media needs only the media - no free drive letters, no VHDX.
    # It was unconditional until 05-02, when a run on a machine whose staged
    # media had gone reported two failures for an absent 4 GB file rather than
    # skipping and saying so. CI has no media either.
    $script:skipMedia = -not (Test-Path -LiteralPath $script:mediaPath -PathType Leaf)

    if ($script:skipMedia) {
        Write-Warning ("ImageService.Integration.Tests.ps1: the staged media at '{0}' is not on this machine, so the two tests that read a real WIM are skipped. PROJECT.md lists it under 'Test media - already staged locally'." -f $script:mediaPath)
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:wimPath = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
    $script:fixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/image/win11-ltsc-2024-install.json'

    $script:inUse = @(@('S', 'W', 'R') | Where-Object { Test-Path -LiteralPath ('{0}:\' -f $_) })
    if ($script:inUse.Count -gt 0) {
        Write-Warning ("ImageService.Integration.Tests.ps1 skipped: the uefi-standard layout needs S:, W: and R: free on this host and {0}: is in use." -f ($script:inUse -join ':, '))
    }

    # BeforeDiscovery and BeforeAll run in DIFFERENT script scopes in Pester 5,
    # so the $script:skipSlow set at discovery time is NOT visible here - reading
    # it threw "cannot be retrieved because it has not been set" and took the
    # whole file, and its 18 tests, down with it. Recompute from the same two
    # conditions rather than reaching across the phase boundary. Discovery still
    # needs its own copy for -Skip: on the Describe, which is evaluated there.
    $script:skipSlow = ($script:inUse.Count -gt 0) -or
        (-not (Test-Path -LiteralPath $script:wimPath -PathType Leaf))

    $script:image = New-HDTImageService

    $script:scratchRoot = 'C:\HDTLab\scratch\integration'
    $script:scratchPath = Join-Path -Path $script:scratchRoot -ChildPath 'imageservice.vhdx'
    $script:workspaceRoot = Join-Path -Path $script:scratchRoot -ChildPath 'workspace'
    $script:logRoot = Join-Path -Path $script:scratchRoot -ChildPath 'imagelogs'

    # 64 GB, because uefi-standard leaves Windows the remainder and a real
    # Windows 11 apply expands to about 20 GB.
    $script:scratchSizeByte = 68719476736

    $script:applySecond = 0
    $script:scratchNumber = -1
    $script:applyLine = [string[]] @()

    if (-not $script:skipSlow) {
        $scratch = New-HDTLabScratchDisk -Path $script:scratchPath -SizeByte $script:scratchSizeByte -Dynamic -Confirm:$false
        $script:scratchNumber = [int] $scratch.DiskNumber

        # Partitioned by the same code the deployment uses, so this file starts
        # from the machine DiskPartition would have left behind.
        $disk = New-HDTDiskService
        $disk.InitializeDisk($script:scratchNumber, 'GPT')

        $layout = Get-HDTDiskLayout -Name 'uefi-standard'
        foreach ($row in @(New-HDTDiskLayoutPlan -Layout $layout -DiskSizeByte $script:scratchSizeByte)) {
            $createType = [string] $row.CreateGptType

            $created = $disk.NewPartition($script:scratchNumber, [long] $row.SizeByte,
                [bool] $row.UseMaximumSize, $createType, [bool] $row.IsActive)

            $number = [int] $created.PartitionNumber

            $disk.SetPartitionDriveLetter($script:scratchNumber, $number, [string] $row.DriveLetter)
            $disk.FormatVolume([string] $row.DriveLetter, [string] $row.FileSystem, [string] $row.Label)

            $finalType = [string] $row.GptType
            if (-not [string]::IsNullOrWhiteSpace($finalType) -and $finalType -ne $createType) {
                $disk.SetPartitionType($script:scratchNumber, $number, $finalType)
            }
        }

        # THE APPLY. Timed, so the local-disk number exists beside SPIKES S6's
        # 95 seconds over SMB for M4 to compare against.
        #
        # EVERY LINE THE TOOL PRINTS IS KEPT, because the percentage a technician
        # watches during the nine minutes this takes comes from dism's own
        # stdout, and this is the only place in the suite where the real tool
        # prints it. The unit tests replay a captured transcript; here the
        # transcript is made.
        $line = New-Object System.Collections.ArrayList
        $collect = { param([string] $Text) [void] $line.Add($Text) }.GetNewClosure()

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $script:image.ApplyImage($script:wimPath, 1, 'W:\', $collect)
        $stopwatch.Stop()

        $script:applyLine = [string[]] @($line)
        $script:applySecond = [int] $stopwatch.Elapsed.TotalSeconds

        Write-Information ("apply of index 1 to W:\ took {0}s" -f $script:applySecond) -InformationAction Continue
    }
}

AfterAll {
    if (Get-Command -Name 'Remove-HDTLabScratchDisk' -ErrorAction SilentlyContinue) {
        Remove-HDTLabScratchDisk -Path $script:scratchPath -Confirm:$false
    }

    foreach ($path in @($script:workspaceRoot, $script:logRoot)) {
        if ($path -like 'C:\HDTLab\scratch\*' -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'IImageService reading the real media' -Skip:$skipMedia {

    It 'reports index 1 as Windows 11 Enterprise LTSC' {
        $info = @($script:image.GetImageInfo($script:wimPath))

        $first = @($info | Where-Object { $_.Index -eq 1 })
        $first.Count | Should -Be 1
        $first[0].Name | Should -BeExactly 'Windows 11 Enterprise LTSC'
        $first[0].Edition | Should -BeExactly 'EnterpriseS'
    }

    It 'matches the captured fixture row for row' {
        # So the fixture 04-02's index resolution is proven against cannot go
        # stale without this failing.
        $info = @($script:image.GetImageInfo($script:wimPath) | Sort-Object Index)

        # Assigned first, wrapped second: under Windows PowerShell 5.1
        # ConvertFrom-Json does not enumerate a top-level array (helpers README F12).
        $captured = ConvertFrom-Json ([System.IO.File]::ReadAllText($script:fixturePath))
        $fixture = @($captured | Sort-Object Index)

        $info.Count | Should -Be $fixture.Count

        for ($i = 0; $i -lt $fixture.Count; $i++) {
            $info[$i].Index | Should -Be $fixture[$i].Index
            $info[$i].Name | Should -BeExactly ([string] $fixture[$i].Name)
            $info[$i].Edition | Should -BeExactly ([string] $fixture[$i].Edition)
            $info[$i].Version | Should -BeExactly ([string] $fixture[$i].Version)
            $info[$i].SizeBytes | Should -Be ([long] $fixture[$i].SizeBytes)
        }
    }

    It 'throws for a WIM path that does not exist' {
        # The existence guard, so both implementations fail the same way for the
        # same mistake rather than the real one reporting a DISM error that does
        # not say plainly that the file is missing.
        $record = $null
        try { $script:image.GetImageInfo('C:\HDTLab\media\no-such-media\install.wim') } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.Exception.GetBaseException() | Should -BeOfType ([System.IO.FileNotFoundException])
    }
}

Describe 'IImageService applying Windows 11 for real' -Tag 'Slow' -Skip:$skipSlow {

    Context 'what the tool said while it worked' {

        # THE PROGRESS IS THE REASON THE ADAPTER RUNS dism.exe RATHER THAN
        # Expand-WindowsImage, whose progress goes to PowerShell's progress
        # stream and is therefore invisible to a deployment. Every other claim
        # about that choice is asserted against a captured transcript; these
        # three are asserted against the tool itself.

        It 'printed a percentage meter' {
            @($script:applyLine | Where-Object { $_ -match '^\s*\[[=\s]*[0-9]+(\.[0-9]+)?%' }) |
                Should -Not -BeNullOrEmpty -Because 'the step bar is driven by these lines'
        }

        It 'printed more than one of them, as it went' {
            # One line at the end would be a bar that jumps from nothing to done,
            # which is the state this work exists to leave behind.
            @($script:applyLine | Where-Object { $_ -match '%' }).Count | Should -BeGreaterThan 1
        }

        It 'ended at a hundred' {
            $meter = @($script:applyLine | Where-Object { $_ -match '%' })

            $meter[-1] | Should -Match '100(\.0)?%'
        }
    }


    Context 'the applied volume' {

        It 'leaves ntoskrnl.exe on the volume' {
            # SPIKES S6's own check, and the cheapest proof that the apply was
            # an apply rather than a copy of a few files.
            Test-Path -LiteralPath 'W:\Windows\System32\ntoskrnl.exe' | Should -BeTrue
        }

        It 'leaves a Windows\System32\Recovery\Winre.wim' {
            # ConfigureBoot needs this to register a recovery image. If it is
            # absent, 04-03's warn-and-skip path is the one that matters and the
            # summary says so - the assertion stays either way.
            Test-Path -LiteralPath 'W:\Windows\System32\Recovery\Winre.wim' | Should -BeTrue
        }

        It 'reports the elapsed time' {
            # Recorded rather than asserted tightly: the number goes in the
            # summary beside SPIKES S6's 95 s over SMB.
            Write-Information ("apply took {0}s" -f $script:applySecond) -InformationAction Continue

            $script:applySecond | Should -BeGreaterThan 0
        }

        It 'used a realistic amount of the volume' {
            # MEASURED, NOT GUESSED (04-04): Windows 11 Enterprise LTSC 2024
            # index 1 expands to 10047967232 bytes - 9.36 GiB, under the 10 GiB
            # the first draft of this assertion assumed. 8 GiB is the floor that
            # says "an image was applied" without pretending to know the build's
            # size to the byte.
            $volume = Get-Volume -DriveLetter 'W'

            ($volume.Size - $volume.SizeRemaining) | Should -BeGreaterThan 8589934592
        }
    }

    Context 'boot files' {

        It 'writes bootmgfw.efi to the system volume' {
            $script:image.InstallBootFile('W:\', 'S:', 'UEFI')

            Test-Path -LiteralPath 'S:\EFI\Microsoft\Boot\bootmgfw.efi' | Should -BeTrue
        }

        It 'writes a BCD store beside it' {
            Test-Path -LiteralPath 'S:\EFI\Microsoft\Boot\BCD' | Should -BeTrue
        }

        It 'returns a non-zero exit code as an exception naming bcdboot' {
            # Pointed at a volume with no Windows on it. The tool's own sentence
            # has to survive into the message: "bcdboot failed" without it is
            # the log entry that wastes an hour in front of a machine that will
            # not boot.
            $record = $null
            try { $script:image.InstallBootFile('R:\', 'S:', 'UEFI') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            [string] $record.Exception.Message | Should -BeLike '*bcdboot*'
            [string] $record.Exception.Message | Should -BeLike '*exited*'
        }
    }

    Context 'the recovery image' {

        # THE FINDING THIS CONTEXT EXISTS TO RECORD (04-04, SPIKES S9).
        #
        # reagentc /setreimage against an OFFLINE applied image exits 0 and
        # prints "Operation Successful", and then /info on the same target
        # reports
        #
        #     Windows RE status:       Disabled
        #     Recovery image location:
        #     Custom image location:
        #
        # It does not refuse. It reports success and registers nothing
        # observable. So SetRecoveryImage cannot be asserted by its exit code -
        # an exit code is exactly what the adapter checks, and it is exactly
        # what is misleading here.
        #
        # What this means for HDT: the recovery registration ConfigureBoot
        # performs is NOT what makes WinRE work on the deployed machine. Windows
        # Setup enables WinRE itself during specialize/oobe, from the
        # Winre.wim the apply left in Windows\System32\Recovery. That is why
        # 04-03 wrote ConfigureBoot's recovery leg to warn and continue, and it
        # is why a green run of this file does not prove WinRE was configured.
        #
        # The assertion is therefore about what CAN be observed - the call is
        # made, it does not throw, and the recovery partition holds the image -
        # and the misleading part is written down rather than asserted away.

        BeforeAll {
            $script:recoveryDirectory = 'R:\Recovery\WindowsRE'
            New-Item -Path $script:recoveryDirectory -ItemType Directory -Force | Out-Null
            Copy-Item -LiteralPath 'W:\Windows\System32\Recovery\Winre.wim' `
                -Destination $script:recoveryDirectory -Force

            $script:recoveryError = $null
            try {
                # Reagentc.exe comes from the APPLIED IMAGE, by full path: WinPE
                # has none and there is no WinPE-Recovery optional component.
                $script:image.SetRecoveryImage('W:\', $script:recoveryDirectory)
            } catch {
                $script:recoveryError = $_
            }

            $script:recoveryInfo = ''
            try {
                $script:recoveryInfo = (@(& 'W:\Windows\System32\Reagentc.exe' '/info' '/target' 'W:\Windows' 2>&1) -join "`n")
            } catch {
                $script:recoveryInfo = [string] $_.Exception.Message
            }

            Write-Information ("reagentc /info after /setreimage:`n{0}" -f $script:recoveryInfo) -InformationAction Continue
        }

        It 'runs the applied image own reagentc without refusing the offline target' {
            $script:recoveryError | Should -BeNullOrEmpty -Because (
                'a refusal would be a finding for SPIKES.md, not a reason to delete this: ' +
                [string] $script:recoveryError)
        }

        It 'reports Operation Successful' {
            $script:recoveryInfo | Should -BeLike '*Operation Successful*'
        }

        It 'leaves the recovery image on the recovery partition' {
            Test-Path -LiteralPath (Join-Path -Path $script:recoveryDirectory -ChildPath 'Winre.wim') |
                Should -BeTrue
        }

        It 'does NOT actually enable WinRE on the offline image' {
            # Recorded as an assertion so that the day this changes - a newer
            # reagentc, a different image - somebody is told, rather than the
            # phase quietly carrying a belief nobody has rechecked.
            $script:recoveryInfo | Should -BeLike '*Windows RE status:*Disabled*'
        }
    }

    Context 'the unattend Setup will consume' {

        BeforeAll {
            # A real workspace, on the scratch disk, so ApplyUnattend resolves
            # its template through Get-HDTWorkspacePath exactly as it would in
            # WinPE. The sample's own unattend, copied rather than retyped.
            $sequenceDirectory = Join-Path -Path $script:workspaceRoot -ChildPath 'TaskSequences\DEMO-M3'
            New-Item -Path $sequenceDirectory -ItemType Directory -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/TaskSequences/DEMO-M3/unattend.xml') `
                -Destination $sequenceDirectory -Force

            $fileSystem = New-HDTFileSystem
            $clock = New-HDTClock
            $fileSystem.CreateDirectory($script:logRoot)

            $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Image $script:image

            $log = New-HDTLogContext -RunId 'run-integration' -Phase 'WinPE' -LogPath $script:logRoot `
                -FileSystem $fileSystem -Clock $clock

            $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $variable['HDTOSVolume'] = 'W'
            $variable['HDTComputerName'] = 'HDT-INTEG-01'
            $variable['HDTTaskSequenceID'] = 'DEMO-M3'

            # THE THREE TESTS BELOW WERE RED BEFORE THIS LINE EXISTED, and not
            # for anything to do with imaging. The sample's unattend asks for
            # %HDTAdminPassword%, and DESIGN 4.5.2 settled that nothing
            # supplying it FAILS THE STEP rather than minting one - so the step
            # refused, nothing was staged, and all three assertions read an
            # answer file that was never written. The refusal grew after this
            # context was authored and its variable bag was never caught up.
            #
            # A FIXTURE VALUE, NOT A REAL SECRET, and the last test in this
            # context is the one that proves it never reaches the log.
            $variable['HDTAdminPassword'] = 'Fixture-P@ssw0rd'

            $context = New-HDTExecutionContext -RunId 'run-integration' -Phase 'WinPE' `
                -WorkspaceRoot $script:workspaceRoot -Variable $variable -Service $catalog -Log $log

            $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $bag['template'] = 'unattend.xml'

            $step = [pscustomobject] @{
                Index = 4; Name = 'Apply Unattend'; Type = 'ApplyUnattend'
                TimeoutMinutes = 0; Log = $null; Property = $bag
            }

            $script:unattendResult = Invoke-HDTApplyUnattendStep -Step $step -Context $context
        }

        It 'stages an unattend Setup would consume' {
            $script:unattendResult.Status | Should -BeExactly 'Completed'

            # SPIKES S7's verified location, on a real applied Windows.
            Test-Path -LiteralPath 'W:\Windows\Panther\unattend.xml' | Should -BeTrue
        }

        It 'stages one that still parses as XML' {
            { [xml] (Get-Content -LiteralPath 'W:\Windows\Panther\unattend.xml' -Raw) } | Should -Not -Throw
        }

        It 'expanded the computer name into it' {
            (Get-Content -LiteralPath 'W:\Windows\Panther\unattend.xml' -Raw) |
                Should -BeLike '*<ComputerName>HDT-INTEG-01</ComputerName>*'
        }

        It 'left the deployment password out of the log' {
            $password = [string] ([regex]::Match(
                    (Get-Content -LiteralPath 'W:\Windows\Panther\unattend.xml' -Raw),
                    '<AdministratorPassword>\s*<Value>([^<]+)</Value>').Groups[1].Value)

            $password | Should -Not -BeNullOrEmpty

            $log = Get-Content -LiteralPath (Join-Path -Path $script:logRoot -ChildPath 'HDT.jsonl') -Raw
            $log | Should -Not -BeLike ('*{0}*' -f $password)
        }
    }
}

# THE POLLED DISM CALL, AGAINST A REAL dism.exe AND NO IMAGE AT ALL.
#
# ApplyUnattend stopped being a pipeline and became a polled process, because
# dism prints no percentage meter for /Apply-Unattend and a pipeline cannot tick
# a heartbeat while a tool is silent (see New-HDTImageService). That conversion
# moved the command line from PowerShell's native argument passing, which is
# proven, to a hand-built ProcessStartInfo.Arguments STRING, which is not - and
# the paths involved end in a backslash.
#
# THE TRAP THIS FILE EXISTS TO CATCH. Quoted the obvious way, "/Image:W:\"
# escapes its own closing quote and CommandLineToArgvW hands dism ONE argument
# containing the whole rest of the line. Measured on this machine before the
# code was written. ConvertTo-HDTNativeArgument's unit tests assert the STRING;
# this asserts what dism.exe itself did with it, which is the only authority.
#
# IT NEEDS NO MEDIA, NO VHDX AND NO FREE DRIVE LETTERS, and it finishes in about
# a second: dism refuses an image root that is not there, and refusing correctly
# is exactly the evidence wanted. Every path is under the scratch root, created
# and removed by this file.
Describe 'IImageService running dism as a polled process' {

    BeforeAll {
        $script:pollRoot = Join-Path -Path 'C:\HDTLab\scratch' -ChildPath ('HDT-poll-{0}' -f [guid]::NewGuid().ToString('N'))
        $script:pollScratch = Join-Path -Path $script:pollRoot -ChildPath 'Scratch'

        # A ROOT THAT IS NOT AN OFFLINE WINDOWS INSTALLATION. dism reads the
        # path, cannot service it, and says so - which proves it received the
        # path rather than a mangled switch.
        $script:pollImage = '{0}\' -f $script:pollRoot
        $null = New-Item -ItemType Directory -Path $script:pollRoot -Force

        $script:pollLine = New-Object -TypeName System.Collections.ArrayList
        $script:pollTick = 0

        $service = New-HDTImageService

        try {
            $service.ApplyUnattend($script:pollImage,
                (Join-Path -Path $script:pollRoot -ChildPath 'unattend.xml'),
                $script:pollScratch,
                { param([string] $Line) [void] $script:pollLine.Add($Line) },
                { $script:pollTick++ })

            $script:pollError = ''
        } catch {
            $script:pollError = [string] $_.Exception.Message
        }
    }

    AfterAll {
        # By explicit -LiteralPath, to a directory this file created in this run.
        if ($script:pollRoot -like 'C:\HDTLab\scratch\HDT-poll-*' -and
            (Test-Path -LiteralPath $script:pollRoot)) {

            Remove-Item -LiteralPath $script:pollRoot -Recurse -Force
        }
    }

    It 'gave dism the image root as its own argument' {
        # THE ASSERTION THAT CATCHES THE QUOTING TRAP. dism complaining that it
        # cannot access THIS image means it parsed /Image: and read the path.
        # A mangled command line produces an unrecognised-option error instead,
        # and never mentions the image at all.
        $script:pollError | Should -BeLike '*Unable to access the image*'
    }

    It 'attached dism own words to the failure rather than a bare exit code' {
        $script:pollError | Should -BeLike '*dism.exe exited*'
        $script:pollError | Should -BeLike '*Deployment Image Servicing and Management tool*'
    }

    It 'streamed the tool output to the callback as it arrived' {
        # The pipeline form did this and the polled form has to keep doing it:
        # a dism that DOES print a meter is still read line by line.
        @($script:pollLine).Count | Should -BeGreaterThan 1
        @($script:pollLine) -join "`n" | Should -BeLike '*Deployment Image Servicing and Management tool*'
    }

    It 'created the scratch directory dism was told to use' {
        # WinPE runs from an X: RAM disk and dism left to itself expands into
        # TEMP there and runs out of room, so the scratch path is not optional -
        # and it has to exist before dism is handed it.
        Test-Path -LiteralPath $script:pollScratch | Should -BeTrue
    }

    It 'did not tick for a call that returned before the first poll' {
        # THE RATION, FROM THE OTHER SIDE. dism refuses a bad image in about
        # forty milliseconds; the wait returns first, so the tick never fires.
        # That is what keeps a fast call costing the log nothing - the same rule
        # New-HDTProcessService.Start follows.
        $script:pollTick | Should -Be 0
    }
}

# THE CAPTURE, AGAINST A REAL dism.exe AND A REAL WIM IT WRITES.
#
# CaptureImage is the one method here whose PATH ARGUMENT IS AN OUTPUT, and that
# is the whole reason it needs a test of its own rather than a line in the
# ceremony above. Every other method that takes an image path is guarded by
# AssertImage, which throws when the file is absent; for a capture an absent
# destination is the ORDINARY case, so the guard moved to the source volume and
# the destination is left alone. A test that only ever captured over an existing
# WIM would never notice if that came back.
#
# IT ROUND-TRIPS. The WIM this writes is read back with GetImageInfo, and the
# Name and Description that come out are the ones that went in - which is how
# /Name: and /Description: are proven to have reached dism as their own
# arguments rather than being folded into the path before them. Nothing short of
# reading the WIM proves that; an exit code of zero does not.
#
# IT NEEDS NO MEDIA, NO VHDX AND NO FREE DRIVE LETTERS, exactly as the polled
# dism Describe above does not, and it finishes in about a second: a capture of
# three small files is the same dism code path as a capture of a Windows volume,
# and paying ten minutes for a second copy of the apply Describe's disk would buy
# nothing this does not already say. Every path is under the scratch root,
# created and removed by this file.
#
# THE SOURCE DIRECTORY HAS A SPACE IN ITS NAME ON PURPOSE. The adapter passes
# '/CaptureDir:<path>' as a single native argument, and a path with a space in it
# is where that either holds or hands dism two arguments - the same class of trap
# the polled Describe above exists to catch on the other verb.
Describe 'IImageService capturing an image for real' {

    BeforeAll {
        $script:captureRoot = Join-Path -Path 'C:\HDTLab\scratch' -ChildPath ('HDT-capture-{0}' -f [guid]::NewGuid().ToString('N'))
        $script:captureSource = Join-Path -Path $script:captureRoot -ChildPath 'Source Files'
        $script:captureScratch = Join-Path -Path $script:captureRoot -ChildPath 'Scratch'
        $script:capturedWim = Join-Path -Path $script:captureRoot -ChildPath 'REF-01.wim'

        $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:captureSource -ChildPath 'sub') -Force
        Set-Content -LiteralPath (Join-Path -Path $script:captureSource -ChildPath 'marker.txt') `
            -Value 'captured by HDT' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path -Path $script:captureSource -ChildPath 'sub\second.txt') `
            -Value 'x' -Encoding Ascii

        # THE EXCLUSION LIST THE MODULE SHIPS, which is what a capture is handed
        # when the share carries no Control\wimscript.ini of its own. Passing the
        # real file rather than a stub is the point: /ConfigFile: has to reach
        # dism as its own argument and be readable by it.
        $script:captureConfig = Join-Path -Path $script:repoRoot `
            -ChildPath 'src/Hephaestus/Templates/Capture/wimscript.ini'

        $script:captureService = New-HDTImageService
        $script:captureLine = New-Object -TypeName System.Collections.ArrayList
        $script:captureError = ''

        try {
            $script:captureService.CaptureImage($script:captureSource, $script:capturedWim,
                'HDT-REF-01', 'HDT integration capture', 'fast', $script:captureScratch,
                $script:captureConfig,
                { param([string] $Line) [void] $script:captureLine.Add($Line) })
        } catch {
            $script:captureError = [string] $_.Exception.Message
        }

        $script:captureInfo = @()
        if (Test-Path -LiteralPath $script:capturedWim -PathType Leaf) {
            $script:captureInfo = @($script:captureService.GetImageInfo($script:capturedWim))
        }

        # THE GUARD, FROM THE SIDE THAT IS SUPPOSED TO REFUSE. A capture source
        # that is not there is a real mistake and dism's own message for it does
        # not say plainly that the source is missing.
        $script:missingSourceWim = Join-Path -Path $script:captureRoot -ChildPath 'never-written.wim'
        $script:missingSourceError = $null
        try {
            $script:captureService.CaptureImage(
                (Join-Path -Path $script:captureRoot -ChildPath 'no-such-volume'),
                $script:missingSourceWim, 'X', '', 'fast', $script:captureScratch,
                $script:captureConfig)
        } catch {
            $script:missingSourceError = $_
        }

        # AND THE GUARD ON THE EXCLUSION LIST. dism warns about a /ConfigFile:
        # that is not there and captures the whole volume anyway, so the only
        # place this can be caught is before it runs.
        $script:missingConfigError = $null
        try {
            $script:captureService.CaptureImage($script:captureSource,
                (Join-Path -Path $script:captureRoot -ChildPath 'no-config.wim'),
                'X', '', 'fast', $script:captureScratch,
                (Join-Path -Path $script:captureRoot -ChildPath 'no-such-wimscript.ini'))
        } catch {
            $script:missingConfigError = $_
        }
    }

    AfterAll {
        # By explicit -LiteralPath, to a directory this file created in this run.
        if ($script:captureRoot -like 'C:\HDTLab\scratch\HDT-capture-*' -and
            (Test-Path -LiteralPath $script:captureRoot)) {

            Remove-Item -LiteralPath $script:captureRoot -Recurse -Force
        }
    }

    It 'refuses a capture whose exclusion list is not there' {
        # A CAPTURE WITHOUT EXCLUSIONS IS NOT A FAILURE dism REPORTS. It warns,
        # captures pagefile.sys and \HDT along with everything else, and exits 0 -
        # so the reference image is wrong and the run is green (DESIGN 9.3 note 7).
        $script:missingConfigError | Should -Not -BeNullOrEmpty
        [string] $script:missingConfigError.Exception.Message | Should -BeLike '*no-such-wimscript.ini*'
    }

    It 'captured without throwing, into a WIM that was not there' {
        # THE POINT OF NOT GUARDING THE DESTINATION. AssertImage on this path
        # would have refused before dism ever ran.
        $script:captureError | Should -BeNullOrEmpty
    }

    It 'wrote the WIM it was told to write' {
        Test-Path -LiteralPath $script:capturedWim -PathType Leaf | Should -BeTrue
    }

    It 'gave dism the name as its own argument' {
        # Read back off the WIM, not off the command line. A /Name: that had been
        # folded into the argument before it would produce a nameless image or no
        # image at all.
        $script:captureInfo.Count | Should -Be 1
        $script:captureInfo[0].Index | Should -Be 1
        $script:captureInfo[0].Name | Should -BeExactly 'HDT-REF-01'
    }

    It 'gave dism the description as its own argument' {
        $script:captureInfo[0].Description | Should -BeExactly 'HDT integration capture'
    }

    It 'printed a percentage meter to the callback' {
        # THE REASON THE ADAPTER SHELLS dism.exe RATHER THAN New-WindowsImage,
        # and the reason this method is a pipeline rather than a poll: unlike
        # /Apply-Unattend, /Capture-Image has a real meter to read.
        @($script:captureLine | Where-Object { $_ -match '%' }) |
            Should -Not -BeNullOrEmpty -Because 'the step bar is driven by these lines'
    }

    It 'ended at a hundred' {
        $meter = @($script:captureLine | Where-Object { $_ -match '%' })

        $meter[-1] | Should -Match '100(\.0)?%'
    }

    It 'created the scratch directory dism was told to use' {
        # WinPE runs from an X: RAM disk and dism left to itself expands into
        # TEMP there and runs out of room, so the scratch path is not optional -
        # and it has to exist before dism is handed it.
        Test-Path -LiteralPath $script:captureScratch | Should -BeTrue
    }

    It 'refuses a capture source that is not there, naming it' {
        $script:missingSourceError | Should -Not -BeNullOrEmpty
        $script:missingSourceError.Exception.GetBaseException() |
            Should -BeOfType ([System.IO.DirectoryNotFoundException])
        [string] $script:missingSourceError.Exception.Message | Should -BeLike '*no-such-volume*'
    }

    It 'writes no WIM for a capture it refused' {
        Test-Path -LiteralPath $script:missingSourceWim | Should -BeFalse
    }
}
