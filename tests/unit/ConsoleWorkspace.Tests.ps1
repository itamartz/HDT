# C1 of the WPF-first direction, backend half: what the admin console SHOWS,
# asserted with no window and no share.
#
# THE CONSOLE IS A THIN CLIENT OVER THE MODULE (DESIGN 12). Get-HDTConsoleWorkspace
# owns every decision the window makes about what is on the share, and it makes
# them through the SAME commands an administrator would type -
# Import-HDTWorkspaceDocument, Get-HDTWorkspacePath, Import-HDTSequenceDocument,
# Get-HDTOperatingSystem. Nothing here re-parses YAML the engine already parses.
#
# WHAT IS ASSERTED IS WHAT CAN BE WRONG WITHOUT A SCREEN:
#   * the share is opened, and the deployRoot it DECLARES is not assumed to be
#     the path it was opened THROUGH - the lab share is C:\HDTLab\Share on the
#     host and \\192.168.2.108\HDTShare to a booted client, and a console that
#     conflates the two tells an admin the wrong thing about their own share
#   * a folder without a sequence.yaml is not a task sequence, and a stray file
#     beside the folders is not one either
#   * ONE UNREADABLE DOCUMENT DOES NOT EMPTY THE CONSOLE. Deployment Workbench
#     shows the broken item and complains about it; a console that throws on the
#     first bad file shows an administrator nothing at all, on exactly the day
#     something is broken
#   * a share whose boot image has never been built says so, by name, instead of
#     reporting an image with empty hashes
#   * DESIGN 6.1.1's claim - the WIM inside the ISO hashes equal to the
#     standalone WIM - is surfaced rather than assumed

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\ws'

    $script:workspaceYaml = @'
schemaVersion: 1
id: HDT-LAB-SMB
name: HDT deployment share
deployRoot: \\192.168.2.108\HDTShare
logLevel: Debug
credential:
  username: LAP-AMMSO01\svc-hdt-deploy
bootImage:
  name: HDTPE_x64
  architecture: amd64
  language: en-us
  scratchSpaceMB: 512
'@

    $script:demoSequenceYaml = @'
schemaVersion: 1
id: DEMO-M4
name: Deploy Windows 11 LTSC
description: The M4 exit criterion, as a sequence.
steps:
  - name: Validate
    type: Validate
  - name: Format and Partition
    type: DiskPartition
    diskNumber: 0
    layout: UEFI
  - name: Apply OS
    type: ApplyImage
    operatingSystem: Win11-LTSC-2024
'@

    $script:clientSequenceYaml = @'
schemaVersion: 1
id: STD-CLIENT
name: Standard client
steps:
  - name: First
    type: NoOp
'@

    $script:osYaml = @'
schemaVersion: 1
id: Win11-LTSC-2024
name: Windows 11 Enterprise LTSC 2024
description: Staged from the volume licence media
type: wim
architecture: x64
sourcePath: sources\install.wim
importedUtc: '2026-08-13T09:14:22.0000000Z'
defaultIndex: 1
images:
  - index: 1
    name: Windows 11 Enterprise LTSC
    edition: EnterpriseS
    sizeBytes: 18356832906
    version: 10.0.26100.1742
  - index: 2
    name: Windows 11 Enterprise N LTSC
    edition: EnterpriseSN
    sizeBytes: 17928774068
    version: 10.0.26100.1742
'@

    # The shape Update-HDTBootImage writes, trimmed to what the console reads.
    # The hashes are the real ones off C:\HDTLab\Share\Boot\HDTPE_x64.manifest.json
    # so the console is exercised against a manifest it will actually meet.
    $script:wimHash = '901369F6F7B4A1D0C7AAA2DCE05B7FB89E5BF5AB51C5FDC0FFF40BD18D1B3507'
    $script:isoHash = 'D2B59F9615F91C00BB234C98CF558C06DF01EEDD06F0A8D2F4073BC2CA3792FA'

    function New-HDTConsoleTestManifest {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a JSON string in memory; it changes no state.')]
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter()]
            [string] $IsoBootWimSha256 = $script:wimHash
        )

        $template = @'
{
  "schemaVersion": 1,
  "buildId": "a9931133-89d9-4784-824c-c96f5519805e",
  "builtUtc": "2026-08-14T07:13:25Z",
  "builtOn": "LAP-AMMSO01",
  "engineVersion": "0.1.0",
  "workspaceId": "HDT-LAB-SMB",
  "architecture": "amd64",
  "language": "en-us",
  "artifacts": {
    "wim": {
      "path": "C:\\ws\\Boot\\HDTPE_x64.wim",
      "sha256": "__WIM__",
      "sizeBytes": 495334205
    },
    "iso": {
      "path": "C:\\ws\\Boot\\HDTPE_x64.iso",
      "sha256": "__ISO__",
      "sizeBytes": 550909952
    },
    "isoBootWimSha256": "__ISOWIM__"
  }
}
'@

        $text = $template.Replace('__WIM__', $script:wimHash)
        $text = $text.Replace('__ISO__', $script:isoHash)

        return $text.Replace('__ISOWIM__', $IsoBootWimSha256)
    }

    function New-HDTConsoleTestFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fake file system; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter()]
            [hashtable] $Override = @{},

            [Parameter()]
            [string[]] $Omit = @(),

            [Parameter()]
            [string[]] $Directory = @('C:\ws\TaskSequences\NotASequence')
        )

        $file = @{
            'C:\ws\workspace.yaml'                             = $script:workspaceYaml
            'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'        = $script:demoSequenceYaml
            'C:\ws\TaskSequences\STD-CLIENT\sequence.yaml'     = $script:clientSequenceYaml
            'C:\ws\TaskSequences\readme.txt'                   = 'not a task sequence'
            'C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml'   = $script:osYaml
            'C:\ws\Boot\HDTPE_x64.manifest.json'               = (New-HDTConsoleTestManifest)
        }

        foreach ($key in @($Omit)) { [void] $file.Remove($key) }
        foreach ($key in @($Override.Keys)) { $file[$key] = [string] $Override[$key] }

        return New-HDTFakeFileSystem -File $file -Directory $Directory
    }
}

Describe 'Get-HDTConsoleWorkspace' {

    Context 'the command is shaped like the rest of the toolkit' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTConsoleWorkspace' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'takes an injected file system, so it can run with no share' {
            (Get-Command -Name 'Get-HDTConsoleWorkspace').Parameters.ContainsKey('FileSystem') | Should -BeTrue
        }

        It 'has comment-based help' {
            (Get-Help -Name 'Get-HDTConsoleWorkspace').Synopsis | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the share itself' {

        BeforeAll {
            $script:model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem (New-HDTConsoleTestFileSystem)
        }

        It 'reports the path it was opened through' {
            $script:model.Root | Should -BeExactly 'C:\ws'
            $script:model.WorkspacePath | Should -BeExactly 'C:\ws\workspace.yaml'
        }

        It 'reports the deployRoot the share DECLARES, which is not the path it was opened through' {
            # The lab share is C:\HDTLab\Share on the host and
            # \\192.168.2.108\HDTShare to a booted client. Both belong on screen.
            $script:model.DeployRoot | Should -BeExactly '\\192.168.2.108\HDTShare'
            $script:model.DeployRoot | Should -Not -BeExactly $script:model.Root
        }

        It 'carries the identity an administrator recognises' {
            $script:model.Id | Should -BeExactly 'HDT-LAB-SMB'
            $script:model.Name | Should -BeExactly 'HDT deployment share'
            $script:model.LogLevel | Should -BeExactly 'Debug'
            $script:model.CredentialUser | Should -BeExactly 'LAP-AMMSO01\svc-hdt-deploy'
        }
    }

    Context 'task sequences' {

        BeforeAll {
            $script:model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem (New-HDTConsoleTestFileSystem)
        }

        It 'lists one row per folder that holds a sequence.yaml, in id order' {
            @($script:model.TaskSequence | ForEach-Object { $_.Id }) | Should -Be @('DEMO-M4', 'STD-CLIENT')
        }

        It 'does not mistake a folder without a sequence.yaml for a task sequence' {
            @($script:model.TaskSequence | Where-Object { $_.Id -eq 'NotASequence' }).Count | Should -Be 0
        }

        It 'does not mistake a loose file beside the folders for a task sequence' {
            @($script:model.TaskSequence | Where-Object { $_.Id -like '*readme*' }).Count | Should -Be 0
        }

        It 'reads the name, the description and the step count out of the document' {
            $row = @($script:model.TaskSequence | Where-Object { $_.Id -eq 'DEMO-M4' })[0]

            $row.Name | Should -BeExactly 'Deploy Windows 11 LTSC'
            $row.Description | Should -BeExactly 'The M4 exit criterion, as a sequence.'
            $row.StepCount | Should -Be 3
            $row.Status | Should -BeExactly 'Ok'
            $row.Path | Should -BeExactly 'C:\ws\TaskSequences\DEMO-M4\sequence.yaml'
        }
    }

    Context 'operating systems' {

        BeforeAll {
            $script:model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem (New-HDTConsoleTestFileSystem)
        }

        It 'lists one row per folder that holds an os.yaml' {
            @($script:model.OperatingSystem | ForEach-Object { $_.Id }) | Should -Be @('Win11-LTSC-2024')
        }

        It 'reads the catalog, including how many images the media carries' {
            $row = @($script:model.OperatingSystem)[0]

            $row.Name | Should -BeExactly 'Windows 11 Enterprise LTSC 2024'
            $row.Type | Should -BeExactly 'wim'
            $row.Architecture | Should -BeExactly 'x64'
            $row.DefaultIndex | Should -Be 1
            $row.ImageCount | Should -Be 2
            $row.Status | Should -BeExactly 'Ok'
        }

        It 'keeps each image, so the console can name the edition that will be applied' {
            $row = @($script:model.OperatingSystem)[0]

            @($row.Image | ForEach-Object { $_.Edition }) | Should -Be @('EnterpriseS', 'EnterpriseSN')
        }
    }

    Context 'the boot image' {

        BeforeAll {
            $script:model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem (New-HDTConsoleTestFileSystem)
        }

        It 'finds the manifest beside the artifacts it describes' {
            $script:model.BootImage.Status | Should -BeExactly 'Ok'
            $script:model.BootImage.ManifestPath | Should -BeExactly 'C:\ws\Boot\HDTPE_x64.manifest.json'
        }

        It 'reports when it was built, as a real date rather than a string' {
            $script:model.BootImage.BuiltUtc | Should -BeOfType ([datetime])
            $script:model.BootImage.BuiltUtc.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') |
                Should -BeExactly '2026-08-14 07:13:25'
            $script:model.BootImage.BuiltOn | Should -BeExactly 'LAP-AMMSO01'
            $script:model.BootImage.EngineVersion | Should -BeExactly '0.1.0'
        }

        It 'reports both hashes and both sizes' {
            $script:model.BootImage.WimSha256 | Should -BeExactly $script:wimHash
            $script:model.BootImage.IsoSha256 | Should -BeExactly $script:isoHash
            $script:model.BootImage.WimSizeBytes | Should -Be 495334205
            $script:model.BootImage.IsoSizeBytes | Should -Be 550909952
        }

        It 'answers DESIGN 6.1.1 rather than leaving it to be assumed' {
            # "the WIM inside the ISO and the standalone WIM have identical hashes"
            $script:model.BootImage.HashMatch | Should -BeTrue
        }

        It 'says so when the ISO carries a different boot.wim from the standalone one' {
            $manifest = New-HDTConsoleTestManifest -IsoBootWimSha256 '0000000000000000000000000000000000000000000000000000000000000000'
            $fs = New-HDTConsoleTestFileSystem -Override @{ 'C:\ws\Boot\HDTPE_x64.manifest.json' = $manifest }

            $model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem $fs

            $model.BootImage.HashMatch | Should -BeFalse
        }

        It 'says a share whose image has never been built has no image, by name' {
            $fs = New-HDTConsoleTestFileSystem -Omit @('C:\ws\Boot\HDTPE_x64.manifest.json')

            $model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem $fs

            $model.BootImage.Status | Should -BeExactly 'Missing'
            $model.BootImage.Name | Should -BeExactly 'HDTPE_x64'
            $model.BootImage.Error | Should -Match 'Update-HDTBootImage'
        }

        It 'reports a manifest that is not JSON as an error rather than throwing' {
            $fs = New-HDTConsoleTestFileSystem -Override @{ 'C:\ws\Boot\HDTPE_x64.manifest.json' = '{ this is not json' }

            $model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem $fs

            $model.BootImage.Status | Should -BeExactly 'Error'
            $model.BootImage.Error | Should -Not -BeNullOrEmpty
        }
    }

    Context 'one broken document does not empty the console' {

        It 'lists the unreadable sequence as an error and still lists the good one' {
            $fs = New-HDTConsoleTestFileSystem -Override @{
                'C:\ws\TaskSequences\DEMO-M4\sequence.yaml' = "schemaVersion: 1`nid: DEMO-M4`n  name: badly indented`n"
            }

            $model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem $fs

            @($model.TaskSequence | ForEach-Object { $_.Id }) | Should -Be @('DEMO-M4', 'STD-CLIENT')

            $broken = @($model.TaskSequence | Where-Object { $_.Id -eq 'DEMO-M4' })[0]
            $broken.Status | Should -BeExactly 'Error'
            $broken.Error | Should -Not -BeNullOrEmpty
            $broken.StepCount | Should -Be 0

            $good = @($model.TaskSequence | Where-Object { $_.Id -eq 'STD-CLIENT' })[0]
            $good.Status | Should -BeExactly 'Ok'
        }

        It 'lists an unreadable operating system as an error and does not throw' {
            $fs = New-HDTConsoleTestFileSystem -Override @{
                'C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml' = "schemaVersion: 1`nid: Win11-LTSC-2024`n"
            }

            $model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem $fs

            $row = @($model.OperatingSystem)[0]
            $row.Id | Should -BeExactly 'Win11-LTSC-2024'
            $row.Status | Should -BeExactly 'Error'
            $row.ImageCount | Should -Be 0
        }
    }

    Context 'a share that is not one' {

        It 'refuses a root with no workspace.yaml, naming the path' {
            $fs = New-HDTFakeFileSystem -Directory @('C:\ws')

            { Get-HDTConsoleWorkspace -Path $script:root -FileSystem $fs } |
                Should -Throw -ExpectedMessage '*C:\ws\workspace.yaml*'
        }

        It 'shows an empty share as empty rather than failing on the missing folders' {
            $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\workspace.yaml' = $script:workspaceYaml }

            $model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem $fs

            @($model.TaskSequence).Count | Should -Be 0
            @($model.OperatingSystem).Count | Should -Be 0
            $model.BootImage.Status | Should -BeExactly 'Missing'
        }
    }
}


}
