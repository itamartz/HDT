# WHAT IS ACTUALLY IN Boot\, WHICH IS NOT THE SAME AS WHAT THE SHARE DECLARES.
#
# A workspace declares one boot image - bootImage is an object in the schema,
# not an array - and Update-HDTBootImage writes <name>.wim, <name>.iso and
# <name>.manifest.json for it. Rename the image and the next build writes a new
# trio beside the old one, which nothing then references and nothing reports.
# The lab share reached three names and about two gigabytes of them that way.
#
# READ-ONLY, AND DELIBERATELY SO. This command names the orphans; it does not
# remove them. Half a gigabyte a file on somebody's deployment share is not a
# thing a Get- command should decide about, and the artifacts of a build are
# exactly the kind of file a technician wants to look at before it goes.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:workspaceYaml = @'
schemaVersion: 1
id: HDT-LAB-SMB
name: HDT deployment share
deployRoot: \\host\HDTShare
logLevel: Info
bootImage:
  name: HDTPE_wiz_x64
  architecture: amd64
  language: en-us
'@

    # TWO BUILDS AND A HALF. wiz is what the share declares; smb is a name it
    # used to carry; broken is a manifest that is there and will not parse,
    # which is a different answer from one that is not there at all.
    function New-HDTBootInventoryFake {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fake; it changes no state.')]
        [CmdletBinding()]
        param([switch] $Empty)

        $file = @{ 'C:\ws\workspace.yaml' = $script:workspaceYaml }

        if (-not $Empty) {
            $file['C:\ws\Boot\HDTPE_wiz_x64.manifest.json'] = @'
{
  "buildId": "b-wiz-001",
  "builtUtc": "2026-08-18T08:14:00Z",
  "builtOn": "LAP-AMMSO01",
  "engineVersion": "0.2.0",
  "architecture": "amd64",
  "language": "en-us",
  "artifacts": {
    "wim": { "path": "C:\\ws\\Boot\\HDTPE_wiz_x64.wim", "sha256": "aaa", "sizeBytes": 498432171 },
    "iso": { "path": "C:\\ws\\Boot\\HDTPE_wiz_x64.iso", "sha256": "bbb", "sizeBytes": 554008576 }
  }
}
'@
            $file['C:\ws\Boot\HDTPE_smb_x64.manifest.json'] = @'
{
  "buildId": "b-smb-001",
  "builtUtc": "2026-08-14T09:04:00Z",
  "builtOn": "LAP-AMMSO01",
  "engineVersion": "0.1.0",
  "architecture": "amd64",
  "language": "en-us",
  "artifacts": {
    "wim": { "path": "C:\\ws\\Boot\\HDTPE_smb_x64.wim", "sha256": "ccc", "sizeBytes": 495212932 },
    "iso": { "path": "C:\\ws\\Boot\\HDTPE_smb_x64.iso", "sha256": "ddd", "sizeBytes": 550789120 }
  }
}
'@
            $file['C:\ws\Boot\HDTPE_broken_x64.manifest.json'] = '{ this is not json'

            $file['C:\ws\Boot\HDTPE_wiz_x64.wim'] = 'wim'
            $file['C:\ws\Boot\HDTPE_wiz_x64.iso'] = 'iso'
            $file['C:\ws\Boot\HDTPE_smb_x64.wim'] = 'wim'
            $file['C:\ws\Boot\HDTPE_smb_x64.iso'] = 'iso'
        }

        return New-HDTFakeFileSystem -File $file
    }
}

Describe 'Get-HDTBootImage' {

    Context 'the command is shaped like the rest of the toolkit' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTBootImage' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'has comment-based help' {
            (Get-Help -Name 'Get-HDTBootImage').Synopsis | Should -Not -BeNullOrEmpty
        }

        It 'takes an injected filesystem, so nothing here touches a disk' {
            (Get-Command -Name 'Get-HDTBootImage' -Module 'Hephaestus').Parameters.Keys |
                Should -Contain 'FileSystem'
        }
    }

    Context 'what a share has actually built' {

        BeforeAll {
            $script:row = @(Get-HDTBootImage -Root 'C:\ws' -FileSystem (New-HDTBootInventoryFake))
        }

        It 'finds one row per manifest, newest build first' {
            # NEWEST FIRST because the interesting one is almost always the last
            # build, and the orphans are what has been sitting there since.
            @($script:row | ForEach-Object { $_.Name }) |
                Should -Be @('HDTPE_broken_x64', 'HDTPE_wiz_x64', 'HDTPE_smb_x64')
        }

        It 'marks the one the workspace declares' {
            @($script:row | Where-Object { $_.Declared } | ForEach-Object { $_.Name }) |
                Should -Be @('HDTPE_wiz_x64')
        }

        It 'marks every other build an orphan' {
            # AN ORPHAN IS NOT A FAULT. It is a build under a name the share no
            # longer declares - which is what renaming the image leaves behind.
            @($script:row | Where-Object { -not $_.Declared } | ForEach-Object { $_.Name }) |
                Should -Be @('HDTPE_broken_x64', 'HDTPE_smb_x64')
        }

        It 'reports what each build cost on the share' {
            $wiz = @($script:row | Where-Object { $_.Name -eq 'HDTPE_wiz_x64' })[0]

            $wiz.WimSizeBytes | Should -Be 498432171
            $wiz.IsoSizeBytes | Should -Be 554008576
            $wiz.SizeBytes | Should -Be (498432171 + 554008576)
        }

        It 'carries the build facts the manifest recorded' {
            $wiz = @($script:row | Where-Object { $_.Name -eq 'HDTPE_wiz_x64' })[0]

            [string] $wiz.BuildId | Should -BeExactly 'b-wiz-001'
            [string] $wiz.EngineVersion | Should -BeExactly '0.2.0'
            $wiz.BuiltUtc.Kind | Should -Be ([System.DateTimeKind]::Utc)
        }

        It 'says a manifest it could not read is an error, not a missing build' {
            # THE THIRD ANSWER. Get-HDTConsoleBootImage already draws this
            # distinction for the declared image and it matters as much here: a
            # truncated file on the share is not the same as never having built.
            $broken = @($script:row | Where-Object { $_.Name -eq 'HDTPE_broken_x64' })[0]

            [string] $broken.Status | Should -BeExactly 'Error'
            [string] $broken.Error | Should -Not -BeNullOrEmpty
        }

        It 'reads a good manifest as Ok' {
            @($script:row | Where-Object { $_.Status -eq 'Ok' } | ForEach-Object { $_.Name }) |
                Should -Be @('HDTPE_wiz_x64', 'HDTPE_smb_x64')
        }

        It 'never throws for one bad file among good ones' {
            { Get-HDTBootImage -Root 'C:\ws' -FileSystem (New-HDTBootInventoryFake) } | Should -Not -Throw
        }
    }

    Context 'a share with nothing built' {

        It 'returns nothing rather than throwing' {
            # A SHARE BEING SET UP HAS NO Boot FOLDER YET, and that is a
            # legitimate state - the console shows it as Missing rather than as
            # a fault, and this command has to agree.
            $answer = @(Get-HDTBootImage -Root 'C:\ws' -FileSystem (New-HDTBootInventoryFake -Empty))

            $answer.Count | Should -Be 0
        }
    }

    Context 'only the orphans' {

        It 'offers a switch for the ones nothing references' {
            $answer = @(Get-HDTBootImage -Root 'C:\ws' -Orphan -FileSystem (New-HDTBootInventoryFake))

            @($answer | ForEach-Object { $_.Name }) | Should -Be @('HDTPE_broken_x64', 'HDTPE_smb_x64')
        }
    }
}
