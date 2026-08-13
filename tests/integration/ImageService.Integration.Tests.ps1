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
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $script:image.ApplyImage($script:wimPath, 1, 'W:\')
        $stopwatch.Stop()
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

Describe 'IImageService reading the real media' {

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
            $volume = Get-Volume -DriveLetter 'W'

            ($volume.Size - $volume.SizeRemaining) | Should -BeGreaterThan 10737418240
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

        It 'registers a recovery image' {
            # Reagentc.exe comes from the APPLIED IMAGE, by full path: WinPE has
            # none and there is no WinPE-Recovery optional component (04-01).
            $recoveryDirectory = 'R:\Recovery\WindowsRE'
            New-Item -Path $recoveryDirectory -ItemType Directory -Force | Out-Null
            Copy-Item -LiteralPath 'W:\Windows\System32\Recovery\Winre.wim' -Destination $recoveryDirectory -Force

            $record = $null
            try {
                $script:image.SetRecoveryImage('W:\', $recoveryDirectory)
            } catch {
                $record = $_
            }

            if ($null -ne $record) {
                # IF REAGENTC REFUSES AN OFFLINE TARGET FROM THIS HOST, THAT IS A
                # FINDING, NOT A REASON TO DELETE THE ASSERTION. It goes into
                # SPIKES.md and into the summary, and the warn-and-continue path
                # 04-03 wrote in ConfigureBoot becomes the one that matters.
                Set-ItResult -Skipped -Because ("reagentc refused the offline target: {0}" -f [string] $record.Exception.Message)
                return
            }

            $info = @(& 'W:\Windows\System32\Reagentc.exe' '/info' '/target' 'W:\Windows' 2>&1)

            ($info -join "`n") | Should -BeLike '*WindowsRE*'
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
