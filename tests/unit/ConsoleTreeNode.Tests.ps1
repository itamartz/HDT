# C1's second half: everything the window puts on the screen, decided in a
# command and asserted with no window.
#
# WHY THIS COMMAND EXISTS AT ALL. Show-HDTConsole hands an injected IConsoleHost
# a list of rows and the host adds them to a control. If the host built those
# rows itself - looping over sequences, formatting a hash, deciding what a share
# with no boot image says - then the only thing that could ever check the
# console's output would be a human looking at a screen. Every one of those
# decisions is here instead, which is what leaves New-HDTConsoleHost branch-free
# and therefore honestly exempt from TDD (CLAUDE.md rule 1).
#
# THE COMMAND LINE IS PART OF THE OUTPUT, NOT DECORATION. DESIGN 12: "the
# console may not do anything the cmdlets can't. Every action it performs maps
# to a cmdlet invocation, and the console shows that invocation - so an admin can
# learn the automation surface by clicking around". Every row therefore carries
# the module call that produced it, and these tests assert the call is the real
# one rather than a plausible-looking string.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/HDT.Console/HDT.Console.psd1') -Force -ErrorAction Stop
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
'@

    $script:sequenceYaml = @'
schemaVersion: 1
id: DEMO-M4
name: Deploy Windows 11 LTSC
description: The M4 exit criterion, as a sequence.
steps:
  - name: Validate
    type: Validate
  - name: Apply OS
    type: ApplyImage
    operatingSystem: Win11-LTSC-2024
'@

    $script:osYaml = @'
schemaVersion: 1
id: Win11-LTSC-2024
name: Windows 11 Enterprise LTSC 2024
type: wim
architecture: x64
sourcePath: sources\install.wim
defaultIndex: 1
images:
  - index: 1
    name: Windows 11 Enterprise LTSC
    edition: EnterpriseS
    version: 10.0.26100.1742
'@

    $script:wimHash = '901369F6F7B4A1D0C7AAA2DCE05B7FB89E5BF5AB51C5FDC0FFF40BD18D1B3507'
    $script:isoHash = 'D2B59F9615F91C00BB234C98CF558C06DF01EEDD06F0A8D2F4073BC2CA3792FA'

    $script:manifestJson = @'
{
  "schemaVersion": 1,
  "buildId": "a9931133-89d9-4784-824c-c96f5519805e",
  "builtUtc": "2026-08-14T07:13:25Z",
  "builtOn": "LAP-AMMSO01",
  "engineVersion": "0.1.0",
  "architecture": "amd64",
  "language": "en-us",
  "artifacts": {
    "wim": { "path": "C:\\ws\\Boot\\HDTPE_x64.wim", "sha256": "901369F6F7B4A1D0C7AAA2DCE05B7FB89E5BF5AB51C5FDC0FFF40BD18D1B3507", "sizeBytes": 495334205 },
    "iso": { "path": "C:\\ws\\Boot\\HDTPE_x64.iso", "sha256": "D2B59F9615F91C00BB234C98CF558C06DF01EEDD06F0A8D2F4073BC2CA3792FA", "sizeBytes": 550909952 },
    "isoBootWimSha256": "901369F6F7B4A1D0C7AAA2DCE05B7FB89E5BF5AB51C5FDC0FFF40BD18D1B3507"
  }
}
'@

    function New-HDTConsoleNodeTestModel {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a projection from an in-memory fake; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter()]
            [switch] $Empty
        )

        $file = @{ 'C:\ws\workspace.yaml' = $script:workspaceYaml }

        if (-not $Empty) {
            $file['C:\ws\TaskSequences\DEMO-M4\sequence.yaml'] = $script:sequenceYaml
            $file['C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml'] = $script:osYaml
            $file['C:\ws\Boot\HDTPE_x64.manifest.json'] = $script:manifestJson
        }

        return Get-HDTConsoleWorkspace -Path $script:root -FileSystem (New-HDTFakeFileSystem -File $file)
    }
}

Describe 'Get-HDTConsoleTreeNode' {

    Context 'the command is shaped like the rest of the toolkit' {

        It 'is exported by HDT.Console' {
            Get-Command -Name 'Get-HDTConsoleTreeNode' -Module 'HDT.Console' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'has comment-based help' {
            (Get-Help -Name 'Get-HDTConsoleTreeNode').Synopsis | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the tree a technician reads' {

        BeforeAll {
            $script:node = @(Get-HDTConsoleTreeNode -Workspace (New-HDTConsoleNodeTestModel))
        }

        It 'opens with the Deployment Shares root, then the share, then the three categories' {
            # Workbench's shape: the root is there with one share as well as with
            # six, so the console does not change layout as shares are added.
            @($script:node | Where-Object { $_.Depth -le 2 } | ForEach-Object { $_.Kind }) |
                Should -Be @('Root', 'Share', 'Category', 'Category', 'Category')
        }

        It 'counts the shares on the root row' {
            @($script:node | Where-Object { $_.Kind -eq 'Root' })[0].Text |
                Should -BeExactly 'Deployment Shares (1)'
        }

        It 'names each category and counts what is under it' {
            $category = @($script:node | Where-Object { $_.Kind -eq 'Category' } | ForEach-Object { $_.Text })

            $category[0] | Should -BeExactly 'Task Sequences (1)'
            $category[1] | Should -BeExactly 'Operating Systems (1)'
            $category[2] | Should -BeExactly 'Boot Image'
        }

        It 'indents by depth, so a flat list reads as a tree' {
            $root = @($script:node | Where-Object { $_.Kind -eq 'Root' })[0]
            $share = @($script:node | Where-Object { $_.Kind -eq 'Share' })[0]
            $sequence = @($script:node | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            $root.Depth | Should -Be 0
            $root.Display | Should -BeExactly $root.Text

            $share.Depth | Should -Be 1
            $share.Display | Should -Match '^\s{4}\S'

            $sequence.Depth | Should -Be 3
            $sequence.Display | Should -Match '^\s{12}\S'
            $sequence.Display.Trim() | Should -BeExactly $sequence.Text
        }

        It 'puts the deployRoot on the share row, because that is the one fact a wrong share looks like' {
            $share = @($script:node | Where-Object { $_.Kind -eq 'Share' })[0]

            $share.Text | Should -Match 'HDT deployment share'
            $share.Detail | Should -Match ([regex]::Escape('\\192.168.2.108\HDTShare'))
            $share.Detail | Should -Match ([regex]::Escape('C:\ws'))
        }

        It 'carries its share banner on every row beneath that share' {
            foreach ($row in @($script:node | Where-Object { $_.Depth -ge 1 })) {
                $row.HeaderTitle | Should -BeExactly 'HDT deployment share'
                $row.HeaderRoot | Should -BeExactly 'C:\ws'
                $row.HeaderDeployRoot | Should -BeExactly '\\192.168.2.108\HDTShare'
            }
        }

        It 'names the task sequence by id and title' {
            $sequence = @($script:node | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            $sequence.Text | Should -BeExactly 'DEMO-M4 - Deploy Windows 11 LTSC'
            $sequence.Detail | Should -Match 'Steps\s*:\s*2'
        }

        It 'names the operating system and the images the media carries' {
            $os = @($script:node | Where-Object { $_.Kind -eq 'OperatingSystem' })[0]

            $os.Text | Should -BeExactly 'Win11-LTSC-2024 - Windows 11 Enterprise LTSC 2024'
            $os.Detail | Should -Match 'EnterpriseS'
            $os.Detail | Should -Match '10\.0\.26100\.1742'
        }
    }

    Context 'the boot image row, which is why this increment names hashes at all' {

        BeforeAll {
            $script:bootNode = @(Get-HDTConsoleTreeNode -Workspace (New-HDTConsoleNodeTestModel) |
                    Where-Object { $_.Kind -eq 'BootImage' })[0]
        }

        It 'carries the build date in the row itself, not only in the detail' {
            $script:bootNode.Text | Should -Match 'HDTPE_x64'
            $script:bootNode.Text | Should -Match '2026-08-14 07:13:25'
        }

        It 'shows both hashes in full, because a truncated hash cannot be compared' {
            $script:bootNode.Detail | Should -Match $script:wimHash
            $script:bootNode.Detail | Should -Match $script:isoHash
        }

        It 'states the DESIGN 6.1.1 verdict in words rather than leaving the reader to compare 64 hex digits' {
            $script:bootNode.Detail | Should -Match 'matches'
        }

        It 'shows both artifact paths and sizes' {
            $script:bootNode.Detail | Should -Match ([regex]::Escape('C:\ws\Boot\HDTPE_x64.wim'))
            $script:bootNode.Detail | Should -Match ([regex]::Escape('C:\ws\Boot\HDTPE_x64.iso'))
            $script:bootNode.Detail | Should -Match '495,334,205'
        }
    }

    Context 'every row shows the command that produced it (DESIGN 12)' {

        BeforeAll {
            $script:node = @(Get-HDTConsoleTreeNode -Workspace (New-HDTConsoleNodeTestModel))
        }

        It 'gives every row a command' {
            @($script:node | Where-Object { [string]::IsNullOrWhiteSpace($_.Command) }).Count | Should -Be 0
        }

        It 'names the real module command for a task sequence' {
            $sequence = @($script:node | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            $sequence.Command | Should -Match '^Import-HDTSequenceDocument '
            $sequence.Command | Should -Match ([regex]::Escape('C:\ws\TaskSequences\DEMO-M4\sequence.yaml'))
        }

        It 'names the real module command for an operating system' {
            $os = @($script:node | Where-Object { $_.Kind -eq 'OperatingSystem' })[0]

            $os.Command | Should -Match '^Get-HDTOperatingSystem '
            $os.Command | Should -Match "-Id 'Win11-LTSC-2024'"
        }

        It 'names a command that actually exists in the engine' {
            # A console that teaches the automation surface must not teach a
            # command nobody can run.
            Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

            $verb = @($script:node |
                    Where-Object { $_.Command -match '^[A-Z][a-z]+-HDT' } |
                    ForEach-Object { ($_.Command -split ' ')[0] } |
                    Sort-Object -Unique)

            @($verb).Count | Should -BeGreaterThan 0

            foreach ($name in $verb) {
                Get-Command -Name $name -Module 'Hephaestus', 'HDT.Console' -ErrorAction SilentlyContinue |
                    Should -Not -BeNullOrEmpty -Because "$name is offered to an administrator as something to type"
            }
        }
    }

    Context 'an empty share' {

        BeforeAll {
            $script:node = @(Get-HDTConsoleTreeNode -Workspace (New-HDTConsoleNodeTestModel -Empty))
        }

        It 'still shows the share and all three categories' {
            @($script:node | Where-Object { $_.Kind -eq 'Category' }).Count | Should -Be 3
        }

        It 'says a category is empty rather than showing nothing under it' {
            @($script:node | Where-Object { $_.Kind -eq 'Empty' }).Count | Should -Be 2
            @($script:node | Where-Object { $_.Kind -eq 'Empty' })[0].Text | Should -BeExactly '(none)'
        }

        It 'says the boot image has never been built, and says what to run' {
            $boot = @($script:node | Where-Object { $_.Kind -eq 'BootImage' })[0]

            $boot.Text | Should -Match 'not built'
            $boot.Detail | Should -Match 'Update-HDTBootImage'
        }
    }

    Context 'more than one deployment share' {

        BeforeAll {
            $second = $script:workspaceYaml.Replace('HDT-LAB-SMB', 'HDT-PROD')
            $second = $second.Replace('HDT deployment share', 'Production share')
            $second = $second.Replace('\\192.168.2.108\HDTShare', '\\prod-01\HDTShare')

            $lab = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem (New-HDTFakeFileSystem -File @{
                    'C:\ws\workspace.yaml' = $script:workspaceYaml
                })
            $prod = Get-HDTConsoleWorkspace -Path 'C:\prod' -FileSystem (New-HDTFakeFileSystem -File @{
                    'C:\prod\workspace.yaml' = $second
                })

            $script:many = @(Get-HDTConsoleTreeNode -Workspace @($lab, $prod))
        }

        It 'roots them together and counts them' {
            @($script:many | Where-Object { $_.Kind -eq 'Root' })[0].Text |
                Should -BeExactly 'Deployment Shares (2)'
        }

        It 'lists both shares, in the order they were given' {
            @($script:many | Where-Object { $_.Kind -eq 'Share' } | ForEach-Object { $_.Text }) |
                Should -Be @('HDT deployment share (HDT-LAB-SMB)', 'Production share (HDT-PROD)')
        }

        It 'gives each share its own categories rather than merging them' {
            @($script:many | Where-Object { $_.Kind -eq 'Category' }).Count | Should -Be 6
        }

        It 'banners each row with ITS OWN share, which is the point of carrying it on the row' {
            $labRow = @($script:many | Where-Object { $_.Kind -eq 'BootImage' })[0]
            $prodRow = @($script:many | Where-Object { $_.Kind -eq 'BootImage' })[1]

            $labRow.HeaderDeployRoot | Should -BeExactly '\\192.168.2.108\HDTShare'
            $prodRow.HeaderDeployRoot | Should -BeExactly '\\prod-01\HDTShare'
        }

        It 'says the root row belongs to no single share' {
            $root = @($script:many | Where-Object { $_.Kind -eq 'Root' })[0]

            $root.HeaderRoot | Should -BeExactly '(select a share)'
            $root.Detail | Should -Match ([regex]::Escape('C:\prod'))
        }
    }

    Context 'a broken document' {

        It 'marks the row rather than hiding it, and puts the reason in the detail' {
            $file = @{
                'C:\ws\workspace.yaml'                      = $script:workspaceYaml
                'C:\ws\TaskSequences\DEMO-M4\sequence.yaml' = "schemaVersion: 1`nid: DEMO-M4`n  name: bad`n"
            }

            $model = Get-HDTConsoleWorkspace -Path $script:root -FileSystem (New-HDTFakeFileSystem -File $file)
            $node = @(Get-HDTConsoleTreeNode -Workspace $model | Where-Object { $_.Kind -eq 'TaskSequence' })[0]

            $node.Status | Should -BeExactly 'Error'
            $node.Text | Should -Match 'DEMO-M4'
            $node.Detail | Should -Not -BeNullOrEmpty
        }
    }
}
