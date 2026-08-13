# The IImageService contract (PROJECT constraint 4, DESIGN 9.2, DESIGN 12.2.1).
#
# Five methods:
#
#   GetImageInfo(imagePath) -> object[]  Index, Name, Description, Edition,
#                                        SizeBytes, Architecture, Version
#   ApplyImage(imagePath, index, applyPath)
#   InstallBootFile(osRoot, systemVolume, firmware)
#   SetRecoveryImage(osRoot, recoveryPath)
#   SetBootOrderFirst()
#
# THE REAL ROW CALLS GetImageInfo AND NOTHING ELSE.
#
# The other four write to a disk: Expand-WindowsImage lays 4 GB of Windows down
# somewhere, bcdboot writes boot files, reagentc registers a recovery image and
# bcdedit reorders this machine's own firmware boot entries. None of those is
# something a contract test gets to do on a developer's box. THEY ARE PROVEN IN
# tests/integration (04-04), AGAINST A MOUNTED SCRATCH VHDX - and until that
# plan runs, none of those four tools has ever been executed by this repository.
#
# The real row is skipped, with a printed warning, when the staged media is
# absent: CI has no 4 GB WIM. The fake row is seeded FROM THE FIXTURE CAPTURED
# OFF THAT SAME WIM, so "index 1 is Windows 11 Enterprise LTSC" is asserted
# against both, and the fixture cannot drift from the media without this file
# going red.
#
# The skip goes on a Context INSIDE the Describe, never on the -ForEach Describe
# itself: -Skip: there is bound before -ForEach binds the row's keys, so it does
# not skip (tests/helpers/README.md F9).

$script:HDTWin11Wim = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
$script:HDTHasStagedMedia = Test-Path -LiteralPath $script:HDTWin11Wim -PathType Leaf

if (-not $script:HDTHasStagedMedia) {
    Write-Warning ("IImageService: the real adapter row is skipped. It reads the staged media at '{0}', which is not present on this machine. The fake row still runs against the captured fixture." -f $script:HDTWin11Wim)
}

$script:HDTImplementation = @(
    @{
        Name           = 'FakeImageService'
        Factory        = {
            param($RepositoryRoot)

            # Assigned first, wrapped second: under Windows PowerShell 5.1
            # ConvertFrom-Json does not enumerate a top-level array (F12).
            $row = ConvertFrom-Json ([System.IO.File]::ReadAllText(
                (Join-Path -Path $RepositoryRoot -ChildPath 'tests/fixtures/image/win11-ltsc-2024-install.json')))

            New-HDTFakeImageService -Image @{ 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim' = @($row) }
        }
        JournalFactory = { param($Journal) New-HDTFakeImageService -Journal $Journal }
        Skip           = $false
    }
    @{
        Name           = 'ImageService'
        Factory        = { New-HDTImageService }
        JournalFactory = { param($Journal) New-HDTImageService -Journal $Journal }
        Skip           = -not $script:HDTHasStagedMedia
    }
)

Describe 'IImageService contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

        $script:win11Wim = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
        $script:HDTImageProperty = @('Index', 'Name', 'Description', 'Edition', 'SizeBytes',
            'Architecture', 'Version')
    }

    Context 'read only' -Skip:$Skip {

        BeforeEach {
            $script:image = & $Factory $script:repoRoot
        }

        It 'exposes every method the contract requires' {
            # Get-Member -MemberType Method does NOT list a ScriptMethod, and the
            # real adapter is a pscustomobject carrying ScriptMethod members.
            $method = @($script:image | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('GetImageInfo', 'ApplyImage', 'InstallBootFile', 'SetRecoveryImage', 'SetBootOrderFirst')) {
                $method | Should -Contain $name -Because "IImageService requires $name"
            }
        }

        It 'names itself ImageService' {
            $script:image.ServiceName | Should -BeExactly 'ImageService'
        }

        It 'returns an array from GetImageInfo' {
            # tests/helpers/README.md F3: without the unary comma a ScriptMethod
            # collapses a one-element array to a scalar, and a captured WIM with
            # one index is the normal case.
            $script:image.GetImageInfo($script:win11Wim) -is [System.Array] | Should -BeTrue
        }

        It 'gives every image row the seven documented properties' {
            foreach ($row in @($script:image.GetImageInfo($script:win11Wim))) {
                $name = @($row.PSObject.Properties.Name)
                foreach ($expected in $script:HDTImageProperty) {
                    $name | Should -Contain $expected -Because "an image row carries $expected"
                }
            }
        }

        It 'types Index as an integer and SizeBytes as a long' {
            foreach ($row in @($script:image.GetImageInfo($script:win11Wim))) {
                $row.Index | Should -BeOfType ([int])
                $row.SizeBytes | Should -BeOfType ([long])
            }
        }

        It 'reports index 1 as Windows 11 Enterprise LTSC' {
            # The fake row is seeded from the fixture; the real row reads the
            # WIM. BOTH MUST AGREE, which is what makes the fixture honest and
            # what turns PROJECT.md's "index 1 = Windows 11 Enterprise LTSC"
            # from documentation into something the suite enforces.
            $first = @($script:image.GetImageInfo($script:win11Wim) | Where-Object { $_.Index -eq 1 })

            $first.Count | Should -Be 1
            $first[0].Name | Should -BeExactly 'Windows 11 Enterprise LTSC'
            $first[0].Edition | Should -BeExactly 'EnterpriseS'
        }

        It 'reports two indices for the staged Windows 11 media' {
            @($script:image.GetImageInfo($script:win11Wim)).Count | Should -Be 2
        }

        It 'reports an edition id for every index' {
            foreach ($row in @($script:image.GetImageInfo($script:win11Wim))) {
                $row.Edition | Should -Not -BeNullOrEmpty
            }
        }

        It 'reports a version for every index' {
            foreach ($row in @($script:image.GetImageInfo($script:win11Wim))) {
                $row.Version | Should -Not -BeNullOrEmpty
            }
        }

        It 'throws for an image path that does not exist' {
            $record = $null
            try { $script:image.GetImageInfo('Z:\OperatingSystems\NoSuchImage\install.wim') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty

            # Unwrapped to the innermost exception: a fake throws the type
            # directly, a ScriptMethod on a pscustomobject wraps it twice
            # (tests/helpers/README.md section 5).
            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.IO.FileNotFoundException])
        }

        It 'records GetImageInfo before it can throw' {
            try { $script:image.GetImageInfo('Z:\OperatingSystems\NoSuchImage\install.wim') } catch { $null = $_ }

            @($script:image.GetOperationName()) | Should -Be @('GetImageInfo')
            @($script:image.Operations[0].Arguments)[0] | Should -BeExactly 'Z:\OperatingSystems\NoSuchImage\install.wim'
        }

        It 'honours -Journal' {
            $journal = [System.Collections.ArrayList]::new()
            $service = & $JournalFactory $journal
            try { $service.GetImageInfo('Z:\OperatingSystems\NoSuchImage\install.wim') } catch { $null = $_ }

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('ImageService.GetImageInfo')
        }
    }
}
