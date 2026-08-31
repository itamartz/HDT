# The hand-written IImageService double (PROJECT constraint 4, DESIGN 9.2,
# DESIGN 12.2.1, DESIGN 12.2.3).
#
# The methods this file drives:
#
#   GetImageInfo(imagePath) -> object[]  Index, Name, Description, Edition,
#                                        SizeBytes, Architecture, Version
#   ApplyImage(imagePath, index, applyPath)
#   CaptureImage(capturePath, imagePath, name, description, compress, scratchPath,
#                configPath)
#   InstallBootFile(osRoot, systemVolume, firmware)
#   SetRecoveryImage(osRoot, recoveryPath)
#   SetBootOrderFirst()
#   AddRamdiskBootEntry(store, id, description, ramdiskVolume, wimDevicePath,
#                       sdiDevicePath, loaderPath)
#   SetBootSequenceOnce(store, id)
#   RemoveBootEntry(store, id)
#
# SetBootOrderFirst is SPIKES.md S6's fourth finding as an API: after apply, a
# machine that still has the boot media first in the firmware order simply
# reboots into WinPE.
#
# The seeded rows come from tests/fixtures/image/, captured with Get-WindowsImage
# against the staged media, so "index 1 is Windows 11 Enterprise LTSC" is a
# fixture rather than a sentence in a document.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:imageFixture = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/image'
    $script:win11Wim = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'

    # Assigned first, wrapped second: under Windows PowerShell 5.1
    # ConvertFrom-Json does not enumerate a top-level array (F12).
    $script:win11Row = ConvertFrom-Json ([System.IO.File]::ReadAllText(
        (Join-Path -Path $script:imageFixture -ChildPath 'win11-ltsc-2024-install.json')))
}

Describe 'New-HDTFakeImageService' {

    Context 'reading image information' {

        BeforeEach {
            $script:image = New-HDTFakeImageService -Image @{ $script:win11Wim = @($script:win11Row) }
        }

        It 'returns the images seeded for a path' {
            $info = @($script:image.GetImageInfo($script:win11Wim))

            $info.Count | Should -Be 2
            $info[0].Index | Should -Be 1
            $info[0].Name | Should -BeExactly 'Windows 11 Enterprise LTSC'
        }

        It 'matches the image path case-insensitively' {
            $info = @($script:image.GetImageInfo($script:win11Wim.ToUpperInvariant()))

            $info.Count | Should -Be 2
        }

        It 'folds a backslash to a forward slash in the seed key' {
            # The same normalisation New-HDTFakeScriptInvoker already does, so
            # one key serves both and a test is not a test of which separator
            # the author happened to type.
            $info = @($script:image.GetImageInfo($script:win11Wim.Replace('\', '/')))

            $info.Count | Should -Be 2
        }

        It 'returns an array even for a single image' {
            $image = New-HDTFakeImageService -Image @{
                'Z:\OperatingSystems\Custom\install.wim' = @([pscustomobject] @{ Index = 1; Name = 'Custom' })
            }

            $image.GetImageInfo('Z:\OperatingSystems\Custom\install.wim') -is [System.Array] | Should -BeTrue
        }

        It 'throws FileNotFoundException for an image path that was not seeded' {
            # Parity: a fake that returned an empty list for a typo'd WIM would
            # make a missing image look like an image with no indices.
            { $script:image.GetImageInfo('Z:\OperatingSystems\Nope\install.wim') } |
                Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
        }

        It 'records GetImageInfo before it throws' {
            try { $script:image.GetImageInfo('Z:\OperatingSystems\Nope\install.wim') } catch { $null = $_ }

            @($script:image.GetOperationName()) | Should -Be @('GetImageInfo')
        }

        It 'reads a seeded fixture directory' {
            $image = New-HDTFakeImageService -FixturePath $script:imageFixture

            $info = @($image.GetImageInfo('ws2025-std-install'))
            $info.Count | Should -Be 4
            $info[1].Name | Should -BeExactly 'Windows Server 2025 Standard (Desktop Experience)'
        }

        It 'gives every seeded row the seven documented properties' {
            foreach ($row in @($script:image.GetImageInfo($script:win11Wim))) {
                $name = @($row.PSObject.Properties.Name)
                foreach ($expected in @('Index', 'Name', 'Description', 'Edition', 'SizeBytes', 'Architecture', 'Version')) {
                    $name | Should -Contain $expected
                }
            }
        }
    }

    Context 'recording what a step asked for' {

        BeforeEach {
            $script:image = New-HDTFakeImageService -Image @{ $script:win11Wim = @($script:win11Row) }
        }

        It 'records ApplyImage with the path, the index and the apply path' {
            $script:image.ApplyImage($script:win11Wim, 1, 'W:\')

            @($script:image.GetOperationName()) | Should -Be @('ApplyImage')
            @($script:image.Operations[0].Arguments) | Should -Be @($script:win11Wim, 1, 'W:\')
        }

        It 'records CaptureImage with all seven arguments the tool is given' {
            # THE ARGUMENT ORDER IS THE CONTRACT. A capture that recorded its
            # source and destination the wrong way round would still be green
            # against a fake that only counted calls - and would overwrite the
            # machine it was asked to capture.
            $script:image.CaptureImage('C:\', 'Z:\Captures\REF-01.wim', 'REF-01',
                'Reference build', 'max', 'C:\HDTLab\scratch\dism', 'Z:\Control\wimscript.ini')

            @($script:image.GetOperationName()) | Should -Be @('CaptureImage')
            @($script:image.Operations[0].Arguments) |
                Should -Be @('C:\', 'Z:\Captures\REF-01.wim', 'REF-01', 'Reference build', 'max', 'C:\HDTLab\scratch\dism', 'Z:\Control\wimscript.ini')
        }

        It 'records InstallBootFile with the OS root, the system volume and the firmware' {
            $script:image.InstallBootFile('W:\', 'S:', 'UEFI')

            @($script:image.GetOperationName()) | Should -Be @('InstallBootFile')
            @($script:image.Operations[0].Arguments) | Should -Be @('W:\', 'S:', 'UEFI')
        }

        It 'records SetRecoveryImage' {
            $script:image.SetRecoveryImage('W:\', 'R:\Recovery\WindowsRE')

            @($script:image.GetOperationName()) | Should -Be @('SetRecoveryImage')
            @($script:image.Operations[0].Arguments) | Should -Be @('W:\', 'R:\Recovery\WindowsRE')
        }

        It 'records SetBootOrderFirst' {
            $script:image.SetBootOrderFirst()

            @($script:image.GetOperationName()) | Should -Be @('SetBootOrderFirst')
        }

        It 'records AddRamdiskBootEntry with every argument the BCD entry needs' {
            $script:image.AddRamdiskBootEntry('', '{7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}', 'HDT Windows PE',
                'C:', '\HDT\Bootoot.wim', '\HDT\Bootoot.sdi', '\windows\system32oot\winload.efi')

            @($script:image.GetOperationName()) | Should -Be @('AddRamdiskBootEntry')
            @($script:image.Operations[0].Arguments) | Should -Be @('', '{7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}',
                'HDT Windows PE', 'C:', '\HDT\Bootoot.wim', '\HDT\Bootoot.sdi',
                '\windows\system32oot\winload.efi')
        }

        It 'records SetBootSequenceOnce with the store and the entry' {
            $script:image.SetBootSequenceOnce('', '{7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}')

            @($script:image.GetOperationName()) | Should -Be @('SetBootSequenceOnce')
            @($script:image.Operations[0].Arguments) | Should -Be @('', '{7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}')
        }

        It 'records RemoveBootEntry with the store the teardown leg has to name' {
            $script:image.RemoveBootEntry('S:\EFI\Microsoft\Boot\BCD', '{7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}')

            @($script:image.GetOperationName()) | Should -Be @('RemoveBootEntry')
            @($script:image.Operations[0].Arguments) |
                Should -Be @('S:\EFI\Microsoft\Boot\BCD', '{7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}')
        }

        # THE ORDER IS THE MECHANISM. Creating the entry and pointing
        # /bootsequence at it are two bcdedit invocations and the second is
        # meaningless without the first, so a step that ran them the other way
        # round would arm a boot into an entry that does not exist yet.
        It 'records the transport in the order that makes it work' {
            $script:image.AddRamdiskBootEntry('', '{7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}', 'HDT Windows PE',
                'C:', '\HDT\Bootoot.wim', '\HDT\Bootoot.sdi', '\windows\system32oot\winload.efi')
            $script:image.SetBootSequenceOnce('', '{7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}')

            @($script:image.GetOperationName()) | Should -Be @('AddRamdiskBootEntry', 'SetBootSequenceOnce')
        }

        It 'records the whole apply ceremony in order' {
            $script:image.ApplyImage($script:win11Wim, 1, 'W:\')
            $script:image.InstallBootFile('W:\', 'S:', 'UEFI')
            $script:image.SetRecoveryImage('W:\', 'R:\Recovery\WindowsRE')
            $script:image.SetBootOrderFirst()

            @($script:image.GetOperationName()) |
                Should -Be @('ApplyImage', 'InstallBootFile', 'SetRecoveryImage', 'SetBootOrderFirst')
        }
    }

    Context 'seeded failures' {

        It 'throws the seeded failure from ApplyImage' {
            $image = New-HDTFakeImageService -Image @{ $script:win11Wim = @($script:win11Row) } `
                -Failure @{ ApplyImage = 'The system cannot find the file specified. Error: 0x80070002' }

            { $image.ApplyImage($script:win11Wim, 1, 'W:\') } |
                Should -Throw -ExpectedMessage '*0x80070002*'
        }

        It 'records ApplyImage before it throws' {
            $image = New-HDTFakeImageService -Image @{ $script:win11Wim = @($script:win11Row) } `
                -Failure @{ ApplyImage = 'boom' }

            try { $image.ApplyImage($script:win11Wim, 1, 'W:\') } catch { $null = $_ }

            @($image.GetOperationName()) | Should -Be @('ApplyImage')
        }

        It 'throws the seeded failure from CaptureImage' {
            # 0x8007000D is what dism returns for a capture whose destination
            # WIM already exists, which is the failure this method will meet
            # first in the field: the adapter takes no /Append-Image decision.
            $image = New-HDTFakeImageService -Failure @{ CaptureImage = 'Error: 0x8007000D' }

            { $image.CaptureImage('C:\', 'Z:\Captures\REF-01.wim', 'REF-01', '', 'max', 'C:\scratch', 'Z:\Control\wimscript.ini') } |
                Should -Throw -ExpectedMessage '*0x8007000D*'
        }

        It 'throws the seeded failure from InstallBootFile' {
            $image = New-HDTFakeImageService -Failure @{ InstallBootFile = 'BFSVC: Failed to copy boot files' }

            { $image.InstallBootFile('W:\', 'S:', 'UEFI') } | Should -Throw -ExpectedMessage '*BFSVC*'
        }

        It 'leaves an unseeded method working' {
            $image = New-HDTFakeImageService -Failure @{ ApplyImage = 'boom' }

            { $image.SetBootOrderFirst() } | Should -Not -Throw
        }
    }

    Context 'it never touches the real machine' {

        It 'applies nothing' {
            $applyPath = 'C:\HDTLab\does-not-exist\apply'
            $image = New-HDTFakeImageService -Image @{ $script:win11Wim = @($script:win11Row) }

            $image.ApplyImage($script:win11Wim, 1, $applyPath)

            Test-Path -LiteralPath $applyPath | Should -BeFalse
        }

        It 'captures nothing' {
            # The one method whose path argument is an OUTPUT. A fake that let
            # it through to dism would write a multi-gigabyte WIM into the
            # developer's tree on every run of this suite.
            $imagePath = 'C:\HDTLab\does-not-exist\REF-01.wim'
            $image = New-HDTFakeImageService

            $image.CaptureImage('C:\', $imagePath, 'REF-01', '', 'max', 'C:\HDTLab\does-not-exist\scratch', 'Z:\Control\wimscript.ini')

            Test-Path -LiteralPath $imagePath | Should -BeFalse
        }

        It 'runs no native tool' {
            $image = New-HDTFakeImageService
            $image.InstallBootFile('W:\', 'S:', 'UEFI')
            $image.SetRecoveryImage('W:\', 'R:\Recovery\WindowsRE')
            $image.SetBootOrderFirst()

            @(Get-Process -Name bcdboot, bcdedit, reagentc -ErrorAction SilentlyContinue).Count | Should -Be 0
        }
    }

    Context 'journal' {

        It 'records into a shared journal as ImageService' {
            $journal = [System.Collections.ArrayList]::new()
            $image = New-HDTFakeImageService -Image @{ $script:win11Wim = @($script:win11Row) } -Journal $journal

            $image.GetImageInfo($script:win11Wim) | Out-Null
            $image.SetBootOrderFirst()

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('ImageService.GetImageInfo', 'ImageService.SetBootOrderFirst')
        }

        It 'does not record seeding' {
            $journal = [System.Collections.ArrayList]::new()
            $image = New-HDTFakeImageService -FixturePath $script:imageFixture -Journal $journal

            @($journal).Count | Should -Be 0
            @($image.Operations).Count | Should -Be 0
        }
    }
}

Describe 'the apply that talks back' {

    # THE REAL ADAPTER HANDS EVERY LINE dism.exe PRINTS TO A CALLBACK as it
    # arrives, which is where a step's progress percentage comes from. A fake
    # that swallowed the callback would leave the only interesting behaviour of
    # the longest step in a deployment untested, so it replays what it was
    # seeded with - normally the captured transcript in tests/fixtures/image/.

    BeforeAll {
        $script:meter = @(
            '[                           1.0%                           ] '
            '[==============             50.0%                          ] '
            '[==========================100.0%==========================] '
        )
    }

    It 'replays the seeded lines to the callback, in order' {
        $image = New-HDTFakeImageService -ApplyOutput $script:meter
        $seen = New-Object System.Collections.ArrayList

        $image.ApplyImage('Z:\install.wim', 1, 'W:\', { param([string] $Text) [void] $seen.Add($Text) })

        @($seen) | Should -Be $script:meter
    }

    It 'replays nothing when it was seeded with nothing' {
        $image = New-HDTFakeImageService
        $seen = New-Object System.Collections.ArrayList

        $image.ApplyImage('Z:\install.wim', 1, 'W:\', { param([string] $Text) [void] $seen.Add($Text) })

        @($seen) | Should -BeNullOrEmpty
    }

    It 'still takes three arguments, for every caller that has no use for the output' {
        $image = New-HDTFakeImageService -ApplyOutput $script:meter

        { $image.ApplyImage('Z:\install.wim', 1, 'W:\') } | Should -Not -Throw
    }

    It 'records the same three arguments whether or not a callback was given' {
        $image = New-HDTFakeImageService -ApplyOutput $script:meter

        # THE CALLBACK TAKES A LINE AND DOES NOTHING WITH IT, which is the point
        # of this test - but a parameter declared and never read is an analyzer
        # warning, so it is discarded out loud.
        $image.ApplyImage('Z:\install.wim', 1, 'W:\', { param([string] $Text) [void] $Text })

        @($image.Operations[0].Arguments) | Should -Be @('Z:\install.wim', 1, 'W:\')
    }

    It 'says what it printed before it fails' {
        # AN APPLY THAT DIED AT 50% DIED SOMEWHERE DIFFERENT from one that never
        # started, and the lines are the only evidence of which happened.
        $image = New-HDTFakeImageService -ApplyOutput $script:meter -Failure @{ ApplyImage = 'Error: 0x80070070' }
        $seen = New-Object System.Collections.ArrayList

        { $image.ApplyImage('Z:\install.wim', 1, 'W:\', { param([string] $Text) [void] $seen.Add($Text) }) } |
            Should -Throw

        @($seen).Count | Should -Be 3
    }
}

Describe 'the capture that talks back' {

    # /Capture-Image PRINTS THE SAME METER /Apply-Image DOES - it is the same
    # verb run backwards - so the fake replays lines for it exactly as it does
    # for the apply, and a step's throttling is provable with no reference
    # machine and no nine-minute wait.
    #
    # THE LIST IS ITS OWN, NOT $ApplyOutput. A capture task sequence applies an
    # image and later captures one against the SAME fake; one shared list would
    # replay the apply's meter through the capture and leave each step's
    # throttling unprovable in the presence of the other. That is the argument
    # $UnattendOutput was split out for, and it holds here for the same reason.

    BeforeAll {
        $script:captureMeter = @(
            '[                           1.0%                           ] '
            '[==============             50.0%                          ] '
            '[==========================100.0%==========================] '
        )
    }

    It 'replays the seeded lines to the callback, in order' {
        $image = New-HDTFakeImageService -CaptureOutput $script:captureMeter
        $seen = New-Object System.Collections.ArrayList

        $image.CaptureImage('C:\', 'Z:\Captures\REF-01.wim', 'REF-01', '', 'max', 'C:\scratch', 'Z:\Control\wimscript.ini',
            { param([string] $Text) [void] $seen.Add($Text) })

        @($seen) | Should -Be $script:captureMeter
    }

    It 'replays nothing when it was seeded with nothing' {
        $image = New-HDTFakeImageService
        $seen = New-Object System.Collections.ArrayList

        $image.CaptureImage('C:\', 'Z:\Captures\REF-01.wim', 'REF-01', '', 'max', 'C:\scratch', 'Z:\Control\wimscript.ini',
            { param([string] $Text) [void] $seen.Add($Text) })

        @($seen) | Should -BeNullOrEmpty
    }

    It 'does not replay the apply transcript through the capture' {
        # THE WHOLE REASON THE LISTS ARE SEPARATE, asserted rather than trusted.
        $image = New-HDTFakeImageService -ApplyOutput $script:captureMeter
        $seen = New-Object System.Collections.ArrayList

        $image.CaptureImage('C:\', 'Z:\Captures\REF-01.wim', 'REF-01', '', 'max', 'C:\scratch', 'Z:\Control\wimscript.ini',
            { param([string] $Text) [void] $seen.Add($Text) })

        @($seen) | Should -BeNullOrEmpty
    }

    It 'still takes seven arguments, for every caller that has no use for the output' {
        $image = New-HDTFakeImageService -CaptureOutput $script:captureMeter

        { $image.CaptureImage('C:\', 'Z:\Captures\REF-01.wim', 'REF-01', '', 'max', 'C:\scratch', 'Z:\Control\wimscript.ini') } |
            Should -Not -Throw
    }

    It 'records the same seven arguments whether or not a callback was given' {
        $image = New-HDTFakeImageService -CaptureOutput $script:captureMeter

        # THE CALLBACK TAKES A LINE AND DOES NOTHING WITH IT, which is the point
        # of this test - but a parameter declared and never read is an analyzer
        # warning, so it is discarded out loud.
        $image.CaptureImage('C:\', 'Z:\Captures\REF-01.wim', 'REF-01', '', 'max', 'C:\scratch', 'Z:\Control\wimscript.ini',
            { param([string] $Text) [void] $Text })

        @($image.Operations[0].Arguments) |
            Should -Be @('C:\', 'Z:\Captures\REF-01.wim', 'REF-01', '', 'max', 'C:\scratch', 'Z:\Control\wimscript.ini')
    }

    It 'says what it printed before it fails' {
        # A CAPTURE THAT DIED AT 50% DIED SOMEWHERE DIFFERENT from one that never
        # started, and the lines are the only evidence of which happened - on a
        # step that runs for a quarter of an hour against a reference machine
        # somebody has spent a day building.
        $image = New-HDTFakeImageService -CaptureOutput $script:captureMeter `
            -Failure @{ CaptureImage = 'Error: 0x80070070' }
        $seen = New-Object System.Collections.ArrayList

        { $image.CaptureImage('C:\', 'Z:\Captures\REF-01.wim', 'REF-01', '', 'max', 'C:\scratch', 'Z:\Control\wimscript.ini',
                { param([string] $Text) [void] $seen.Add($Text) }) } | Should -Throw

        @($seen).Count | Should -Be 3
    }
}
