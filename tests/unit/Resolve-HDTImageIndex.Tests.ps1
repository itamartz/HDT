# DESIGN 9.2: "Index selectable by number, name, or edition."
#
# Seeded from 04-01's REAL captures rather than from invented rows, because the
# two traps this function exists to survive are both properties of real media:
#
#   win11-ltsc-2024-install.json  index 1 is 'Windows 11 Enterprise LTSC' and
#                                 index 2 is the N edition, so a loose match on
#                                 the first name must not pick up the second
#   ws2025-std-install.json       four indices, and 'Windows Server 2025
#                                 Standard' is BOTH an exact name (index 1) and
#                                 a prefix of index 2's name. That is the case
#                                 that makes exact-before-wildcard load-bearing,
#                                 and indices 1 and 2 share the edition id
#                                 ServerStandard, which is what makes an
#                                 edition lookup ambiguous on real media.
#
# Two images matching one request is a REFUSAL, not a coin toss - the same rule
# DESIGN 9.1 makes about disks, applied to what gets applied to them.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:imageFixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/image'

    function Get-HDTTestImageFixture {
        <#
            .SYNOPSIS
                Reads one tests/fixtures/image catalogue and returns it as an array.
        #>
        [CmdletBinding()]
        [OutputType([object[]])]
        param(
            [Parameter(Mandatory = $true, Position = 0)]
            [string] $Name
        )

        # F12: assign first, wrap second. Under 5.1 ConvertFrom-Json does not
        # enumerate a top-level array onto the pipeline.
        $text = Get-Content -LiteralPath (Join-Path -Path $script:imageFixtureRoot -ChildPath $Name) -Raw
        $content = ConvertFrom-Json -InputObject $text
        return , ([object[]] @($content))
    }

    $script:win11 = Get-HDTTestImageFixture -Name 'win11-ltsc-2024-install.json'
    $script:ws2025 = Get-HDTTestImageFixture -Name 'ws2025-std-install.json'
    $script:single = @($script:win11[0])
}

Describe 'Resolve-HDTImageIndex' {

    Context 'by number' {

        It 'returns the image with that index' {
            (Resolve-HDTImageIndex -Image $script:win11 -Index 2).Name | Should -BeExactly 'Windows 11 Enterprise N LTSC'
        }

        It 'throws HDTConfigurationError for an index the image does not carry' {
            $record = $null
            try { Resolve-HDTImageIndex -Image $script:win11 -Index 7 } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'lists the indices that exist in that error' {
            $record = $null
            try { Resolve-HDTImageIndex -Image $script:ws2025 -Index 7 } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*1, 2, 3, 4*'
        }
    }

    Context 'by name' {

        It 'returns the image whose name matches exactly' {
            (Resolve-HDTImageIndex -Image $script:win11 -Name 'Windows 11 Enterprise LTSC').Index | Should -Be 1
        }

        It 'matches a name case-insensitively' {
            (Resolve-HDTImageIndex -Image $script:win11 -Name 'windows 11 enterprise ltsc').Index | Should -Be 1
        }

        It 'prefers an exact match over a wildcard match' {
            # 'Windows Server 2025 Standard' is index 1 exactly, and is contained
            # in index 2's 'Windows Server 2025 Standard (Desktop Experience)'.
            # A containment-first implementation refuses here; the exact match is
            # what an administrator meant.
            (Resolve-HDTImageIndex -Image $script:ws2025 -Name 'Windows Server 2025 Standard').Index | Should -Be 1
        }

        It 'matches a wildcard when nothing matches exactly' {
            (Resolve-HDTImageIndex -Image $script:ws2025 -Name 'Standard (Desktop').Index | Should -Be 2
        }

        It 'accepts an explicit wildcard' {
            (Resolve-HDTImageIndex -Image $script:ws2025 -Name '*Datacenter (Desktop*').Index | Should -Be 4
        }

        It 'refuses when two images match one name' {
            $record = $null
            try { Resolve-HDTImageIndex -Image $script:ws2025 -Name 'Desktop Experience' } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTAmbiguousImageError*'
        }

        It 'names both matches in that refusal' {
            $record = $null
            try { Resolve-HDTImageIndex -Image $script:ws2025 -Name 'Desktop Experience' } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*Windows Server 2025 Standard (Desktop Experience)*'
            $record.Exception.Message | Should -BeLike '*Windows Server 2025 Datacenter (Desktop Experience)*'
        }

        It 'throws when no image matches the name' {
            $record = $null
            try { Resolve-HDTImageIndex -Image $script:win11 -Name 'Windows 11 Home' } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Windows 11 Home*'
        }

        It 'does not match the N edition when the LTSC name was asked for' {
            # The real trap in the staged Windows 11 media.
            (Resolve-HDTImageIndex -Image $script:win11 -Name 'Windows 11 Enterprise LTSC').Edition |
                Should -BeExactly 'EnterpriseS'
        }
    }

    Context 'by edition' {

        It 'returns the image with that edition id' {
            (Resolve-HDTImageIndex -Image $script:win11 -Edition 'EnterpriseS').Index | Should -Be 1
        }

        It 'matches an edition case-insensitively' {
            (Resolve-HDTImageIndex -Image $script:win11 -Edition 'enterprises').Index | Should -Be 1
        }

        It 'refuses when two images share an edition' {
            # ServerStandard is indices 1 and 2 of the real Server 2025 media.
            $record = $null
            try { Resolve-HDTImageIndex -Image $script:ws2025 -Edition 'ServerStandard' } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTAmbiguousImageError*'
        }

        It 'throws when no image carries the edition' {
            $record = $null
            try { Resolve-HDTImageIndex -Image $script:win11 -Edition 'Core' } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }

    Context 'combinations' {

        It 'accepts an index and a name that agree' {
            (Resolve-HDTImageIndex -Image $script:win11 -Index 1 -Name 'Windows 11 Enterprise LTSC').Index | Should -Be 1
        }

        It 'refuses an index and a name that disagree' {
            $record = $null
            try { Resolve-HDTImageIndex -Image $script:win11 -Index 1 -Name 'Windows 11 Enterprise N LTSC' } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*1*'
            $record.Exception.Message | Should -BeLike '*Windows 11 Enterprise N LTSC*'
        }

        It 'lets an edition disambiguate a name that matches two images' {
            (Resolve-HDTImageIndex -Image $script:ws2025 -Name 'Desktop Experience' -Edition 'ServerDatacenter').Index |
                Should -Be 4
        }

        It 'lets an index disambiguate an edition that matches two images' {
            (Resolve-HDTImageIndex -Image $script:ws2025 -Edition 'ServerStandard' -Index 2).Index | Should -Be 2
        }
    }

    Context 'nothing specified' {

        It 'returns the only image when the WIM has one' {
            (Resolve-HDTImageIndex -Image $script:single).Index | Should -Be 1
        }

        It 'returns the default index when one is declared' {
            (Resolve-HDTImageIndex -Image $script:ws2025 -DefaultIndex 2).Index | Should -Be 2
        }

        It 'throws when the default index names no image' {
            $record = $null
            try { Resolve-HDTImageIndex -Image $script:ws2025 -DefaultIndex 9 } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'refuses when the WIM has several images and nothing was asked for' {
            $record = $null
            try { Resolve-HDTImageIndex -Image $script:ws2025 } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTAmbiguousImageError*'
        }

        It 'lists every index and name in that refusal' {
            # What an administrator actually sees on the real Server 2025 media.
            $record = $null
            try { Resolve-HDTImageIndex -Image $script:ws2025 } catch { $record = $_ }

            foreach ($row in $script:ws2025) {
                $record.Exception.Message | Should -BeLike ('*{0}*' -f $row.Name)
            }
            $record.Exception.Message | Should -BeLike '*4*'
        }

        It 'prefers an explicit request over the default index' {
            (Resolve-HDTImageIndex -Image $script:ws2025 -DefaultIndex 2 -Index 3).Index | Should -Be 3
        }
    }

    Context 'the row it returns' {

        It 'returns the image row, not its index' {
            $image = Resolve-HDTImageIndex -Image $script:win11 -Index 1

            $image | Should -Not -BeOfType ([int])
            $image.Name | Should -BeExactly 'Windows 11 Enterprise LTSC'
            $image.SizeBytes | Should -Be 18356832906
        }

        It 'returns exactly one row' {
            @(Resolve-HDTImageIndex -Image $script:win11 -Index 1).Count | Should -Be 1
        }

        It 'refuses an empty image list' {
            $record = $null
            try { Resolve-HDTImageIndex -Image @() } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name Resolve-HDTImageIndex -ErrorAction Stop

            $help.Name | Should -BeExactly 'Resolve-HDTImageIndex'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
