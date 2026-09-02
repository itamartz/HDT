# The IImageService contract (PROJECT constraint 4, DESIGN 9.2, DESIGN 12.2.1).
#
# Eleven methods:
#
#   GetImageInfo(imagePath) -> object[]  Index, Name, Description, Edition,
#                                        SizeBytes, Architecture, Version
#   ApplyImage(imagePath, index, applyPath)
#   CaptureImage(capturePath, imagePath, name, description, compress, scratchPath)
#   ApplyUnattend(imagePath, unattendPath, scratchPath)
#   AddPackage(imagePath, packagePath[, onOutput]) -> ExitCode, Output
#   GetPackage(imagePath) -> object[]  Name, State
#   AddDriver(imagePath, driverPath, recurse) -> object[]  Inf, Provider,
#                                                          Version, Date
#   InstallBootFile(osRoot, systemVolume, firmware)
#   SetRecoveryImage(osRoot, recoveryPath)
#   SetBootOrderFirst()
#   TestRamdiskOptions(store) -> bool
#   TestBootEntry(store, id) -> bool
#   AddRamdiskBootEntry(store, id, description, ramdiskVolume, wimDevicePath,
#                       sdiDevicePath, loaderPath)
#   SetBootSequenceOnce(store, id)
#   RemoveBootEntry(store, id)
#
# THE LAST THREE ARE THE FullOS -> WinPE TRANSPORT, and they exist because one
# firmware-order switch cannot serve two restarts that want opposite things. A
# reference build restarts once into Windows (to install applications and run
# Sysprep) and once into WinPE (to capture), and SetBootOrderFirst can only
# satisfy one of them. So MDT's answer is copied instead: a WinPE is staged on
# the local disk, a ramdisk BCD entry points at it, and the Windows Boot Manager
# hands that entry exactly ONE boot - leaving the firmware order alone, so the
# restart before it still reaches Windows.
#
# THEY DIVERGE FROM MDT IN ONE MEASURED WAY. AdjustBCDDefaults sets /bootsequence
# AND /default AND /displayorder /addfirst AND /timeout 0, so MDT's is not a
# one-shot and LTICleanup.wsf has to undo it or the machine boots WinPE for ever.
# SetBootSequenceOnce sets /bootsequence and nothing else, so a machine that
# never comes back to be torn down degrades to booting Windows.
#
# CaptureImage IS ApplyImage RUN BACKWARDS, and it is the half of M7 that turns
# a sysprepped machine into a WIM the share can deploy. Its image path is the
# OUTPUT, which is why - alone among the methods that take one - it is not
# guarded for existence: the file it names is the file it is about to write.
#
# AddDriver IS OFFLINE INJECTION INTO THE APPLIED OS, and it is deliberately the
# same shape as IBootImageService.AddDriver because it is the same DISM verb -
# only the path differs: a mounted WIM for a boot image, the applied OS volume
# (%HDTOSVolume%, W:\) for a deployment. It is NOT reached through
# IBootImageService: that service mounts, dismounts and calls oscdimg, and the
# engine running in WinPE has no business carrying a boot image builder.
#
# THE REAL ROW CALLS GetImageInfo AND NOTHING ELSE.
#
# The others write to a disk: dism /Apply-Image lays 4 GB of Windows down
# somewhere, bcdboot writes boot files, reagentc registers a recovery image, and
# bcdedit reorders this machine's own firmware boot entries or adds a boot entry
# to its store. None of those is something a contract test gets to do on a
# developer's box - least of all the three transport methods, which on this
# laptop would arm it to boot a WinPE that is not there. THEY ARE PROVEN IN
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

            foreach ($name in @('GetImageInfo', 'ApplyImage', 'CaptureImage', 'ApplyUnattend', 'AddDriver',
                    'AddPackage', 'GetPackage',
                    'InstallBootFile', 'SetRecoveryImage', 'SetBootOrderFirst',
                    'TestRamdiskOptions', 'AddRamdiskBootEntry', 'TestBootEntry',
                    'SetBootSequenceOnce', 'RemoveBootEntry')) {
                $method | Should -Contain $name -Because "IImageService requires $name"
            }
        }

        It 'takes an output callback on AddPackage, as both implementations must' {
            # THE FAKE DRIFTING FROM THE ADAPTER IS THE FAILURE MODE THIS FILE
            # EXISTS FOR, and it has already shipped once here: the fake
            # MoveItem moved files and not directories while the real one did
            # both. dism /Add-Package prints a percentage meter and a cumulative
            # update is eight to twelve minutes of it, so a fake that swallowed
            # the callback would leave the only thing moving on a technician's
            # screen untested on the slowest step in a servicing pass.
            #
            # A ScriptMethod DOES NOT PUBLISH ITS PARAMETERS - OverloadDefinitions
            # on the real adapter reads 'System.Object AddPackage();' whatever it
            # takes - so the real row is read off the scriptblock's own param
            # block and the fake row off the class's overloads.
            $member = $script:image.PSObject.Methods['AddPackage']

            $arity = @()
            if ($member -is [System.Management.Automation.PSScriptMethod]) {
                $arity = @(@($member.Script.Ast.ParamBlock.Parameters).Count)
            } else {
                $arity = @($member.OverloadDefinitions | ForEach-Object {
                        @([regex]::Matches([string] $_, ',')).Count + 1
                    })
            }

            $arity | Should -Contain 3 -Because (
                'IImageService.AddPackage takes an onOutput callback, so a step can report ' +
                "dism's percentage meter while a cumulative update applies")
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
