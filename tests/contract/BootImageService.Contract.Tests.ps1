# The IBootImageService contract (PROJECT constraint 4, DESIGN 5.1, DESIGN 12.2.3).
#
# Nine methods:
#
#   MountImage(imagePath, index, mountPath)
#   DismountImage(mountPath, save)
#   AddPackage(mountPath, packagePath)
#   AddDriver(mountPath, driverPath, recurse)  -> object[] the drivers added
#   GetPackage(mountPath)                      -> object[] { Name, State }
#   GetImageInfo(imagePath)                    -> object[] { Index, Name, SizeBytes }
#   ExportImage(sourcePath, index, destinationPath)
#   SetScratchSpace(mountPath, megabyte)
#   NewIso(mediaRoot, isoPath, argument)
#
# THE REAL ROW CALLS GetImageInfo AND NOTHING ELSE.
#
# The other eight mount a WIM, write into a mounted image, burn an ISO or export
# half a gigabyte. None of those is something a contract test gets to do on a
# developer's machine, and every one of them needs elevation. THEY ARE PROVEN IN
# tests/integration/BootImage.Integration.Tests.ps1, which builds a real image
# and then re-mounts it read-only to read startnet.cmd back out.
#
# The real row is skipped, with a printed warning, when the ADK is not installed:
# CI has no ADK. It reads the ADK's own winpe.wim, so the two rows agree on a
# file this machine actually ships.
#
# The skip goes on a Context INSIDE the Describe, never on the -ForEach Describe
# itself: -Skip: there is bound before -ForEach binds the row's keys, so it does
# not skip (tests/helpers/README.md F9).

# TWO SIZES, AND THEY ARE NOT THE SAME NUMBER. 05-04's <verified_facts> records
# winpe.wim as 340 134 390 bytes, and that is the FILE on disk. What
# Get-WindowsImage reports as ImageSize - which is what SizeBytes carries, for
# both this service and IImageService - is the UNCOMPRESSED size of the image
# inside it: 2 009 251 937 bytes on ADK 10.1.26100.2454. Measured on this machine
# rather than assumed, after the first version of this file asserted the file
# size against the DISM number and went red for exactly the right reason.
#
# Both are worth pinning. The file size is the discriminator for "the build
# applied nothing" (SPIKES S1's finished boot.wim was 480 MB on disk), and the
# integration suite asserts it against the artifact. The DISM number is what this
# interface returns, so it is what this contract asserts.
$script:HDTWinPeWimImageSize = 2009251937
$script:HDTWinPeWimFileSize = 340134390

$script:HDTWinPeWim = ''
try {
    Import-Module -Name (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    $script:HDTWinPeWim = Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop
} catch {
    $script:HDTWinPeWim = ''
}

$script:HDTHasAdk = (-not [string]::IsNullOrWhiteSpace($script:HDTWinPeWim))

if (-not $script:HDTHasAdk) {
    Write-Warning 'IBootImageService: the real adapter row is skipped. It reads the ADK winpe.wim through Get-HDTAdkPath, and no Windows ADK with the Windows PE add-on resolves on this machine. The fake row still runs.'
}

$script:HDTImplementation = @(
    @{
        Name           = 'FakeBootImageService'
        Factory        = {
            # The winpe.wim path first, the repository root second: this factory
            # needs the former and not the latter, and a declared-but-unused
            # parameter is a PSScriptAnalyzer diagnostic that breaks lint.
            param($WinPeWim)

            # Seeded to match what the ADK ships, so the two rows assert the same
            # numbers and the fake cannot drift from the machine.
            New-HDTFakeBootImageService -Image @{
                $WinPeWim = @([pscustomobject] @{
                        Index     = 1
                        Name      = 'Microsoft Windows PE (amd64)'
                        SizeBytes = 2009251937
                    })
            }
        }
        JournalFactory = { param($Journal) New-HDTFakeBootImageService -Journal $Journal }
        Skip           = $false
    }
    @{
        Name           = 'BootImageService'
        Factory        = { New-HDTBootImageService }
        JournalFactory = { param($Journal) New-HDTBootImageService -Journal $Journal }
        Skip           = -not $script:HDTHasAdk
    }
)

Describe 'IBootImageService contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

        # Recomputed here rather than read across the discovery boundary
        # (SPIKES S9.15).
        #
        # A PATH THAT DOES NOT RESOLVE FALLS BACK TO THE ADK'S OWN LAYOUT, and
        # that fallback is what keeps the FAKE row running on a machine with no
        # ADK - CI, for one. The real row is skipped there, so nothing ever
        # opens this file; the fake only needs a key to seed its image table
        # with, exactly as the IImageService contract keys its fake on a literal
        # media path. Handing the fake '' instead cost the CI 5.1 leg ten
        # failures reading 'Path must not be empty'.
        $script:winPeWim = ''
        try { $script:winPeWim = Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop } catch { $script:winPeWim = '' }

        if ([string]::IsNullOrWhiteSpace($script:winPeWim)) {
            $script:winPeWim = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\en-us\winpe.wim'
        }

        $script:winPeWimImageSize = 2009251937
        $script:winPeWimFileSize = 340134390
    }

    Context 'read only' -Skip:$Skip {

        BeforeEach {
            $script:boot = & $Factory $script:winPeWim $script:repoRoot
        }

        It 'exposes every method the contract requires' {
            # Method, ScriptMethod: Get-Member -MemberType Method does NOT list a
            # ScriptMethod, and the real adapter is a pscustomobject carrying
            # ScriptMethod members. Do not "tidy" ScriptMethod away.
            $method = @($script:boot | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('MountImage', 'DismountImage', 'AddPackage', 'AddDriver',
                    'GetPackage', 'GetImageInfo', 'ExportImage', 'SetScratchSpace', 'NewIso')) {
                $method | Should -Contain $name -Because "IBootImageService requires $name"
            }
        }

        It 'names itself BootImageService' {
            $script:boot.ServiceName | Should -BeExactly 'BootImageService'
        }

        It 'returns an array from GetImageInfo' {
            # tests/helpers/README.md F3: without the unary comma a ScriptMethod
            # collapses a one-element array to a scalar, and winpe.wim has
            # exactly one index, so this is the normal case rather than an
            # edge one.
            $script:boot.GetImageInfo($script:winPeWim) -is [System.Array] | Should -BeTrue
        }

        It 'reports one index for winpe.wim' {
            @($script:boot.GetImageInfo($script:winPeWim)).Count | Should -Be 1
        }

        It 'reports the uncompressed winpe.wim size this ADK ships' {
            # 2 009 251 937 bytes on ADK 10.1.26100.2454 - the UNCOMPRESSED size
            # Get-WindowsImage reports, not the 340 134 390 byte file. The two
            # were conflated in the first draft of this file and it went red on
            # the real row, which is the whole reason the real row exists.
            @($script:boot.GetImageInfo($script:winPeWim))[0].SizeBytes | Should -Be $script:winPeWimImageSize
        }

        It 'names the image Microsoft Windows PE (amd64)' {
            @($script:boot.GetImageInfo($script:winPeWim))[0].Name |
                Should -BeExactly 'Microsoft Windows PE (amd64)'
        }

        It 'types Index as an integer and SizeBytes as a long' {
            foreach ($row in @($script:boot.GetImageInfo($script:winPeWim))) {
                $row.Index | Should -BeOfType ([int])
                $row.SizeBytes | Should -BeOfType ([long])
            }
        }

        It 'throws for an image path that does not exist' {
            $record = $null
            try { $script:boot.GetImageInfo('C:\HDTLab\does-not-exist\nosuch.wim') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty

            # Unwrapped to the innermost exception: a fake throws the type
            # directly, a ScriptMethod on a pscustomobject wraps it twice
            # (tests/helpers/README.md section 5).
            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.IO.FileNotFoundException])
        }

        It 'records GetImageInfo before it can throw' {
            try { $script:boot.GetImageInfo('C:\HDTLab\does-not-exist\nosuch.wim') } catch { $null = $_ }

            @($script:boot.GetOperationName()) | Should -Be @('GetImageInfo')
            @($script:boot.Operations[0].Arguments)[0] | Should -BeExactly 'C:\HDTLab\does-not-exist\nosuch.wim'
        }

        It 'honours -Journal' {
            $journal = [System.Collections.ArrayList]::new()
            $service = & $JournalFactory $journal
            try { $service.GetImageInfo('C:\HDTLab\does-not-exist\nosuch.wim') } catch { $null = $_ }

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('BootImageService.GetImageInfo')
        }
    }
}
