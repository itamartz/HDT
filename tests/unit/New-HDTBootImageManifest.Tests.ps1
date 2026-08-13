# The build manifest - DESIGN 5.1's answer to boot image drift.
#
# "Boot image drift - where nobody remembers what's in the WIM - is a real MDT
# operational problem." The manifest is what ends that argument: it records the
# ADK it was built from, every component in the order they were applied, every
# payload staged, the exact startnet.cmd text, and the hashes of both artifacts.
#
# TWO PROPERTIES OF IT ARE NOT DOCUMENTATION BUT ASSERTIONS AN OPERATOR CAN MAKE
# WITHOUT THIS SUITE:
#
#   isoBootWimSha256 === artifacts.wim.sha256   is DESIGN 6.1.1, written into the
#                                               artifact rather than only tested
#   credential carries a username and NEVER the secret
#
# It is a pure function - handed everything it records - so it can be asserted
# without a fifteen-minute build, and it returns the JSON TEXT rather than
# writing it, so Update-HDTBootImage writes it through IFileSystem like
# everything else.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:secret = 'Sup3rSecret-Deploy-Password!'

    $script:component = @(
        [pscustomobject] @{ Order = 1; Name = 'WinPE-WMI'; Required = $true
            CabPath = 'C:\Adk\WinPE_OCs\WinPE-WMI.cab'; LanguageCabPath = 'C:\Adk\WinPE_OCs\en-us\WinPE-WMI_en-us.cab'
        }
        [pscustomobject] @{ Order = 2; Name = 'WinPE-NetFx'; Required = $true
            CabPath = 'C:\Adk\WinPE_OCs\WinPE-NetFx.cab'; LanguageCabPath = 'C:\Adk\WinPE_OCs\en-us\WinPE-NetFx_en-us.cab'
        }
        [pscustomobject] @{ Order = 3; Name = 'WinPE-FMAPI'; Required = $false
            CabPath = 'C:\Adk\WinPE_OCs\WinPE-FMAPI.cab'; LanguageCabPath = ''
        }
    )

    $script:manifestSplat = @{
        BuildId          = '4d0f5b16-0a1e-4f4b-9a3a-1c9d0a3b7e55'
        BuiltUtc         = '2026-08-14T09:14:22Z'
        BuiltOn          = 'LAP-AMMSO01'
        EngineVersion    = '0.1.0'
        WorkspaceId      = 'HDT-LAB'
        Architecture     = 'amd64'
        Language         = 'en-us'
        Adk              = @{
            Root           = 'C:\Adk'
            Oscdimg        = 'C:\Adk\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
            WinPeWim       = 'C:\Adk\Windows Preinstallation Environment\amd64\en-us\winpe.wim'
            WinPeWimSha256 = 'AAAA1111BBBB2222'
        }
        Component        = $script:component
        Driver           = @(
            [pscustomobject] @{ Inf = 'oem0.inf'; Provider = 'Intel'; Version = '12.19.2.60'; Date = '2024-01-01' }
        )
        Payload          = @(
            [pscustomobject] @{ Destination = '\HDT\Modules\Hephaestus'; Source = 'C:\repo\src\Hephaestus'; FileCount = 112; SizeBytes = 654321 }
            [pscustomobject] @{ Destination = '\HDT\Modules\powershell-yaml'; Source = 'C:\ps\powershell-yaml'; FileCount = 9; SizeBytes = 12345 }
        )
        ExtraContent     = @(
            [pscustomobject] @{ Source = 'C:\ws\Modules\MyVendorTools'; Destination = '\HDT\Modules\MyVendorTools'; FileCount = 3 }
        )
        Startnet         = "@echo off`r`nwpeinit`r`n"
        CredentialRecord = @{ Username = 'CONTOSO\svc-hdt-deploy'; Embedded = $true; PromptForCredential = $false }
        Wim              = @{ Path = 'C:\ws\Boot\HDTPE_x64.wim'; Sha256 = 'DEADBEEF01'; SizeBytes = 503316480 }
        Iso              = @{ Path = 'C:\ws\Boot\HDTPE_x64.iso'; Sha256 = 'CAFEBABE02'; SizeBytes = 558891008
            Firmware = 'UEFI'; NoPromptForKey = $true; Skipped = $false
        }
        IsoBootWimSha256 = 'DEADBEEF01'
    }

    $script:text = InModuleScope Hephaestus -Parameters @{ Splat = $script:manifestSplat } {
        param($Splat)
        New-HDTBootImageManifest @Splat
    }

    $script:manifest = ConvertFrom-Json -InputObject $script:text
}

Describe 'New-HDTBootImageManifest' {

    Context 'the header' {

        It 'declares schemaVersion 1' {
            $script:manifest.schemaVersion | Should -Be 1
        }

        It 'records the build identity' {
            $script:manifest.buildId | Should -BeExactly '4d0f5b16-0a1e-4f4b-9a3a-1c9d0a3b7e55'
            $script:manifest.builtOn | Should -BeExactly 'LAP-AMMSO01'
            $script:manifest.engineVersion | Should -BeExactly '0.1.0'
            $script:manifest.workspaceId | Should -BeExactly 'HDT-LAB'
        }

        It 'records builtUtc as the ISO 8601 string it was handed' {
            # ASSERTED AGAINST THE SERIALISED TEXT, NOT THE PARSED OBJECT, and
            # this is 05-03's bootstrap trap in a second file: under pwsh 7
            # ConvertFrom-Json coerces an ISO 8601 string to [datetime] on the
            # way back IN, so [string] $manifest.builtUtc is the machine-local
            # '08/14/2026 09:14:22' there and the original string under 5.1. The
            # bytes on disk are what an operator reads, so the bytes are what
            # this asserts.
            #
            # \s* rather than a literal space: WINDOWS POWERSHELL 5.1's
            # ConvertTo-Json PUTS TWO SPACES AFTER THE COLON and pwsh 7 puts
            # one. Both are valid JSON and no consumer cares, but an assertion
            # that pinned the formatting would be green on one engine and red on
            # the other - which is exactly what it was, first run.
            $script:text | Should -Match '"builtUtc":\s*"2026-08-14T09:14:22Z"'
        }

        It 'records the architecture and language' {
            $script:manifest.architecture | Should -BeExactly 'amd64'
            $script:manifest.language | Should -BeExactly 'en-us'
        }
    }

    Context 'what went into the image' {

        It 'records the ADK paths it built from' {
            # An operator holding a manifest can tell which ADK produced this
            # WIM, which is the first question when two images differ.
            $script:manifest.adk.root | Should -BeExactly 'C:\Adk'
            $script:manifest.adk.oscdimg | Should -BeLike '*oscdimg.exe'
            $script:manifest.adk.winpeWim | Should -BeLike '*winpe.wim'
            $script:manifest.adk.winpeWimSha256 | Should -BeExactly 'AAAA1111BBBB2222'
        }

        It 'records every component in the order they were applied' {
            @($script:manifest.optionalComponents | ForEach-Object { $_.name }) |
                Should -Be @('WinPE-WMI', 'WinPE-NetFx', 'WinPE-FMAPI')
            @($script:manifest.optionalComponents | ForEach-Object { $_.order }) | Should -Be @(1, 2, 3)
        }

        It 'records the language cab beside its component' {
            $row = @($script:manifest.optionalComponents | Where-Object { $_.name -eq 'WinPE-NetFx' })

            $row.Count | Should -Be 1
            $row[0].languageCab | Should -BeLike '*WinPE-NetFx_en-us.cab'
            $row[0].cab | Should -BeLike '*WinPE-NetFx.cab'
        }

        It 'records an empty language cab for a component that ships none' {
            # WinPE-FMAPI is one of twelve in this ADK with no en-us pack, and a
            # manifest that invented one would be a manifest that lied.
            $row = @($script:manifest.optionalComponents | Where-Object { $_.name -eq 'WinPE-FMAPI' })

            [string] $row[0].languageCab | Should -BeExactly ''
        }

        It 'records whether each component was required' {
            @($script:manifest.optionalComponents | ForEach-Object { $_.required }) |
                Should -Be @($true, $true, $false)
        }

        It 'records the drivers it injected' {
            @($script:manifest.drivers).Count | Should -Be 1
            @($script:manifest.drivers)[0].inf | Should -BeExactly 'oem0.inf'
            @($script:manifest.drivers)[0].provider | Should -BeExactly 'Intel'
        }

        It 'records every payload with its destination inside the image' {
            @($script:manifest.payload | ForEach-Object { $_.destination }) |
                Should -Be @('\HDT\Modules\Hephaestus', '\HDT\Modules\powershell-yaml')
            @($script:manifest.payload)[0].fileCount | Should -Be 112
        }

        It 'records extraContent separately from payload' {
            # They are different promises: payload is what HDT puts there,
            # extraContent is what the administrator asked for.
            @($script:manifest.extraContent).Count | Should -Be 1
            @($script:manifest.extraContent)[0].destination | Should -BeExactly '\HDT\Modules\MyVendorTools'
        }

        It 'records the exact startnet text' {
            $script:manifest.startnet | Should -BeExactly "@echo off`r`nwpeinit`r`n"
        }
    }

    Context 'the credential' {

        It 'records the credential username' {
            $script:manifest.credential.username | Should -BeExactly 'CONTOSO\svc-hdt-deploy'
            $script:manifest.credential.embedded | Should -BeTrue
            $script:manifest.credential.promptForCredential | Should -BeFalse
        }

        It 'never carries the secret' {
            # Greps the SERIALISED text, not the object: DESIGN 6.3 promises the
            # password is not written where an admin can read it by accident, and
            # the manifest sits in Boot\ next to the WIM.
            $text = InModuleScope Hephaestus -Parameters @{ Splat = $script:manifestSplat; Secret = $script:secret } {
                param($Splat, $Secret)
                $local = $Splat.Clone()
                $local.CredentialRecord = @{ Username = 'CONTOSO\svc-hdt-deploy'; Embedded = $true
                    PromptForCredential = $false; Password = $Secret
                }
                New-HDTBootImageManifest @local
            }

            $text | Should -Not -BeLike ('*' + $script:secret + '*')
            $text | Should -BeLike '*CONTOSO\\svc-hdt-deploy*'
        }

        It 'records promptForCredential with no username' {
            $text = InModuleScope Hephaestus -Parameters @{ Splat = $script:manifestSplat } {
                param($Splat)
                $local = $Splat.Clone()
                $local.CredentialRecord = @{ Username = ''; Embedded = $false; PromptForCredential = $true }
                New-HDTBootImageManifest @local
            }

            $manifest = ConvertFrom-Json -InputObject $text
            $manifest.credential.promptForCredential | Should -BeTrue
            $manifest.credential.embedded | Should -BeFalse
        }
    }

    Context 'the artifacts' {

        It 'records the wim path, hash and size' {
            $script:manifest.artifacts.wim.path | Should -BeExactly 'C:\ws\Boot\HDTPE_x64.wim'
            $script:manifest.artifacts.wim.sha256 | Should -BeExactly 'DEADBEEF01'
            $script:manifest.artifacts.wim.sizeBytes | Should -Be 503316480
        }

        It 'records the iso path, hash, size, firmware and no-prompt' {
            $script:manifest.artifacts.iso.path | Should -BeExactly 'C:\ws\Boot\HDTPE_x64.iso'
            $script:manifest.artifacts.iso.sha256 | Should -BeExactly 'CAFEBABE02'
            $script:manifest.artifacts.iso.firmware | Should -BeExactly 'UEFI'
            $script:manifest.artifacts.iso.noPromptForKey | Should -BeTrue
            $script:manifest.artifacts.iso.skipped | Should -BeFalse
        }

        It 'records isoBootWimSha256 equal to the wim sha256' {
            # DESIGN 6.1.1 IN THE ARTIFACT. "Because both artifacts come from one
            # build, a bug reproduced from the ISO is a bug in the PXE path." An
            # operator holding this file can check that themselves.
            $script:manifest.artifacts.isoBootWimSha256 |
                Should -BeExactly $script:manifest.artifacts.wim.sha256
        }

        It 'records skipped true and a null iso under -SkipIso' {
            $text = InModuleScope Hephaestus -Parameters @{ Splat = $script:manifestSplat } {
                param($Splat)
                $local = $Splat.Clone()
                $local.Iso = @{ Skipped = $true }
                $local.IsoBootWimSha256 = ''
                New-HDTBootImageManifest @local
            }

            $manifest = ConvertFrom-Json -InputObject $text
            $manifest.artifacts.iso.skipped | Should -BeTrue
            [string] $manifest.artifacts.iso.path | Should -BeExactly ''
            [string] $manifest.artifacts.iso.sha256 | Should -BeExactly ''
            [string] $manifest.artifacts.isoBootWimSha256 | Should -BeExactly ''
        }
    }

    Context 'the document itself' {

        It 'is valid JSON that round-trips' {
            # Asserted under BOTH engines by the suite running twice: under
            # Windows PowerShell 5.1 ConvertFrom-Json does not enumerate a
            # top-level array, so every list here is read through a property and
            # never through @(ConvertFrom-Json ...) - helpers README F12.
            { ConvertFrom-Json -InputObject $script:text } | Should -Not -Throw

            $again = ConvertFrom-Json -InputObject $script:text
            $again.buildId | Should -BeExactly $script:manifest.buildId
            @($again.optionalComponents).Count | Should -Be 3
        }

        It 'keeps a single component as a JSON array' {
            # A one-component build must not serialise optionalComponents as an
            # object: an operator's jq, and the integration test's own read-back,
            # both index it.
            $text = InModuleScope Hephaestus -Parameters @{ Splat = $script:manifestSplat } {
                param($Splat)
                $local = $Splat.Clone()
                $local.Component = @($Splat.Component[0])
                New-HDTBootImageManifest @local
            }

            # -Match, not -BeLike: '[' is a wildcard metacharacter and -BeLike
            # rejects the pattern outright.
            $text | Should -Match '"optionalComponents":\s*\['
            @((ConvertFrom-Json -InputObject $text).optionalComponents).Count | Should -Be 1
        }

        It 'keeps an empty driver list as a JSON array' {
            $text = InModuleScope Hephaestus -Parameters @{ Splat = $script:manifestSplat } {
                param($Splat)
                $local = $Splat.Clone()
                $local.Driver = @()
                New-HDTBootImageManifest @local
            }

            @((ConvertFrom-Json -InputObject $text).drivers).Count | Should -Be 0
        }

        It 'returns text rather than writing a file' {
            # Update-HDTBootImage writes it through IFileSystem, like everything
            # else, so the write is provable with nothing on disk.
            $script:text | Should -BeOfType ([string])
        }

        It 'is private to the module' {
            InModuleScope Hephaestus {
                Get-Command -Name 'New-HDTBootImageManifest' -ErrorAction SilentlyContinue
            } | Should -Not -BeNullOrEmpty

            Get-Command -Name 'New-HDTBootImageManifest' -Module Hephaestus -ErrorAction SilentlyContinue |
                Should -BeNullOrEmpty
        }
    }
}
