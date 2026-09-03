# MEDIA ON SCREEN, WHICH IS THE HALF THE COMMANDS DID NOT COVER.
#
# Plans 07-01 and 07-02 built the document, the four commands and
# Update-HDTMediaContent. A command an administrator can only reach from a
# prompt is half a feature, and this repository has shipped that one before -
# the Windows Updates feature had a tree node, a detail pane, an import dialog
# and a host method, and right-clicking any of it did nothing.
#
# MDT PUTS Media UNDER Advanced Configuration with Update Media Content on it.
# This is the node, its rows and the three questions somebody opens the branch
# to ask: which selection profile, where the ISO goes, and when it was last
# built.
#
# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope. The
# import sits at file scope because InModuleScope has to resolve the module
# while Pester is still discovering, before any BeforeAll has run.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') `
            -Force -ErrorAction Stop

        # TWO MEDIA DEFINITIONS, ONE OF THEM BUILT. The built one carries a
        # media.manifest.json beside it, which is what Get-HDTMedia reads
        # LastBuildUtc and the ISO size out of - and it is the difference
        # between a row that says when it last built and one that says
        # (never built).
        $script:shareFile = @{
            'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: HDT`nname: HDT share`n"

            'C:\ws\Media\WIN11-FIELD\media.yaml' = @'
schemaVersion: 1
id: WIN11-FIELD
name: Windows 11 field build
description: The engineer's USB stick
selectionProfile: everything
output: Media\WIN11-FIELD\HDT-WIN11-FIELD.iso
enabled: true
'@

            # NEW-HDTMEDIAMANIFEST'S OWN SHAPE, artifacts.iso and all. A
            # hand-invented flat manifest would be a fixture that tests nothing
            # the writer produces - tests/fixtures come from real captured data.
            'C:\ws\Media\WIN11-FIELD\media.manifest.json' = @'
{
  "schemaVersion": 1,
  "id": "WIN11-FIELD",
  "builtUtc": "2026-08-30T09:14:22Z",
  "artifacts": {
    "iso": {
      "path": "C:\\ws\\Media\\WIN11-FIELD\\HDT-WIN11-FIELD.iso",
      "sha256": "9f2b0c1d",
      "sizeBytes": 5825380352
    }
  }
}
'@

            'C:\ws\Media\WS2025-LAB\media.yaml' = @'
schemaVersion: 1
id: WS2025-LAB
name: Server 2025 lab disc
selectionProfile: boot-critical
output: Media\WS2025-LAB\HDT-WS2025-LAB.iso
'@
        }

        $script:share = New-HDTFakeFileSystem -File $script:shareFile

        $script:model = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem $script:share

        $script:header = [pscustomobject] @{ Title = 'HDT share'; Root = 'C:\ws'; DeployRoot = 'C:\ws' }

        $script:category = Get-HDTConsoleMediaNode -Media $script:model.Media `
            -MediaFailure $script:model.MediaFailure -Root 'C:\ws' -Header $script:header

        $script:row = @($script:category.Children)

        # A SHARE WITH NO MEDIA AT ALL, which is every share created before
        # Media\ was part of the layout - New-HDTWorkspace never writes over an
        # existing one.
        $script:emptyModel = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem (
            New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
            })

        $script:emptyCategory = Get-HDTConsoleMediaNode -Media $script:emptyModel.Media `
            -MediaFailure $script:emptyModel.MediaFailure -Root 'C:\ws' -Header $script:header

        $script:fieldOf = {
            param([object] $Node, [string] $Label)
            $found = @($Node.Field) | Where-Object { [string] $_.Label -eq $Label } | Select-Object -First 1
            if ($null -eq $found) { return '' }
            return [string] $found.Value
        }

        $script:rowFor = {
            param([string] $Id)
            return @($script:row) | Where-Object { [string] $_.Name -eq $Id } | Select-Object -First 1
        }
    }

    Describe 'Get-HDTConsoleMediaNode' {

        Context 'the category' {

            It 'is a Category node at depth 2, like every other category under a share' {
                [string] $script:category.Kind | Should -BeExactly 'Category'
                [int] $script:category.Depth | Should -Be 2
            }

            # A WINDOW MATCHES ON Name AND READS Text, and Text carries a count.
            It 'is named Media, so a window can match on it without parsing a label' {
                [string] $script:category.Name | Should -BeExactly 'Media'
            }

            It 'counts what it holds - Media (2)' {
                [string] $script:category.Text | Should -BeExactly 'Media (2)'
            }

            It 'wears the Media glyph and not the plain folder' {
                [string] $script:category.Icon |
                    Should -BeExactly (Get-HDTConsoleIcon -Kind 'Media' -Status 'Ok')

                [string] $script:category.Icon |
                    Should -Not -BeExactly ([char]::ConvertFromUtf32(0x1F4C1))
            }

            It 'carries the Media folder path and the command an administrator would type' {
                (& $script:fieldOf $script:category 'Folder') |
                    Should -BeExactly (Get-HDTWorkspacePath -Root 'C:\ws' -Kind Media)

                [string] $script:category.Command | Should -BeLike '*Get-HDTMedia*'
                [string] $script:category.Command | Should -BeLike "*C:\ws*"
            }
        }

        Context 'the rows' {

            It 'is one row per media definition, at depth 3' {
                @($script:row).Count | Should -Be 2

                foreach ($current in @($script:row)) {
                    [int] $current.Depth | Should -Be 3
                    [string] $current.Kind | Should -BeExactly 'Media'
                }
            }

            It 'shows the media name as the row text' {
                [string] (& $script:rowFor 'WIN11-FIELD').Text |
                    Should -BeExactly 'Windows 11 field build'
            }

            It 'shows the selection profile, the output path and the last build as fields' {
                $built = & $script:rowFor 'WIN11-FIELD'

                (& $script:fieldOf $built 'Selection profile') | Should -BeExactly 'everything'
                (& $script:fieldOf $built 'Output') | Should -BeLike '*HDT-WIN11-FIELD.iso'
                (& $script:fieldOf $built 'Last build') | Should -Not -BeNullOrEmpty
            }

            # THE HONEST ANSWER, and the one that tells an administrator the
            # action on this row is the one they want.
            It 'shows (never built) for a media with no manifest beside it' {
                (& $script:fieldOf (& $script:rowFor 'WS2025-LAB') 'Last build') |
                    Should -BeExactly '(never built)'
            }

            It 'shows the build time and the ISO size for one with a manifest' {
                $value = & $script:fieldOf (& $script:rowFor 'WIN11-FIELD') 'Last build'

                $value | Should -BeLike '*2026-08-30*'
                $value | Should -BeLike '*GB*'
            }

            # THE ID IS WHAT A COMMAND NAMES, and Text is prose for a person.
            It 'shows the media id, because the id is what a command names' {
                (& $script:fieldOf (& $script:rowFor 'WIN11-FIELD') 'Id') |
                    Should -BeExactly 'WIN11-FIELD'
            }

            It 'names Update-HDTMediaContent as the row''s command, the way every row shows what it runs' {
                [string] (& $script:rowFor 'WIN11-FIELD').Command |
                    Should -BeLike '*Update-HDTMediaContent*'

                [string] (& $script:rowFor 'WIN11-FIELD').Command |
                    Should -BeLike "*WIN11-FIELD*"
            }
        }

        Context 'the empty and the broken' {

            # NEVER A MISSING BRANCH, which reads as "this share cannot do
            # media".
            It 'shows a (none) row for a share with no media, not a missing branch' {
                @($script:emptyCategory.Children).Count | Should -Be 1
                [string] @($script:emptyCategory.Children)[0].Kind | Should -BeExactly 'Empty'
                [string] @($script:emptyCategory.Children)[0].Text | Should -BeExactly '(none)'
            }

            It 'shows Media (0) for that share' {
                [string] $script:emptyCategory.Text | Should -BeExactly 'Media (0)'
            }

            It 'shows an error row naming the document when a media.yaml will not parse' {
                $broken = Get-HDTConsoleMediaNode -Media @() `
                    -MediaFailure "C:\ws\Media\WIN11-FIELD\media.yaml: 'colour' is not a key a media document may declare." `
                    -Root 'C:\ws' -Header $script:header

                $failure = @($broken.Children) | Where-Object { [string] $_.Status -eq 'Error' } |
                    Select-Object -First 1

                $failure | Should -Not -BeNullOrEmpty
                (& $script:fieldOf $failure 'Error') | Should -BeLike '*media.yaml*'
            }

            It 'does not fail the whole share when one media document is broken' {
                { Get-HDTConsoleMediaNode -Media @() -MediaFailure 'anything at all' `
                        -Root 'C:\ws' -Header $script:header } | Should -Not -Throw
            }

            # THE OTHER MEDIA ARE STILL WORTH SEEING. A branch that empties
            # itself over one typo is a branch that hides four working discs.
            It 'still shows the media definitions that DO parse alongside the broken one' {
                $mixed = Get-HDTConsoleMediaNode -Media $script:model.Media `
                    -MediaFailure 'C:\ws\Media\BROKEN\media.yaml: the file is empty.' `
                    -Root 'C:\ws' -Header $script:header

                $kept = @(@($mixed.Children) | Where-Object { [string] $_.Kind -eq 'Media' })

                @($kept).Count | Should -Be 2
                @(@($mixed.Children) | Where-Object { [string] $_.Status -eq 'Error' }).Count |
                    Should -Be 1
            }
        }

        Context 'the two shapes, one pass' {

            # BUILDING THEM SEPARATELY IS HOW THE TWO COME TO DISAGREE.
            # Get-HDTConsoleShareNode.ps1 says so in its own comment.
            It 'adds every row to the flat reading and to its parent''s Children' {
                $flat = @(Get-HDTConsoleShareNode -Workspace $script:model)

                $mediaRow = @($flat | Where-Object { [string] $_.Kind -eq 'Media' })
                @($mediaRow).Count | Should -Be 2

                $branch = @($flat | Where-Object {
                        [string] $_.Kind -eq 'Category' -and [string] $_.Name -eq 'Media'
                    })[0]

                @(@($branch.Children) | Where-Object { [string] $_.Kind -eq 'Media' }).Count |
                    Should -Be 2
            }

            It 'draws each row exactly once in the flat reading' {
                $flat = @(Get-HDTConsoleShareNode -Workspace $script:model)

                $name = @(@($flat | Where-Object { [string] $_.Kind -eq 'Media' }) |
                        ForEach-Object { [string] $_.Name })

                @($name | Select-Object -Unique).Count | Should -Be @($name).Count
            }
        }
    }

    Describe 'the share tree' {

        BeforeAll {
            $script:tree = @(Get-HDTConsoleShareNode -Workspace $script:model)

            $script:shareRow = @($script:tree | Where-Object { [string] $_.Kind -eq 'Share' })[0]

            # THE MONITORING CATEGORY NAMES ITSELF FROM ITS OWN COUNT - 'Nothing
            # running', '2 deploying' - so its Name is a caption that changes
            # with the share. It is identified by its Kind here, which is the
            # part that does not move.
            $script:categoryName = @(@($script:shareRow.Children) | ForEach-Object {
                    if ([string] $_.Kind -eq 'MonitorCategory') { 'Monitoring' } else { [string] $_.Name }
                })
        }

        It 'shows a Media category on a share, beside Applications and Operating Systems' {
            $script:categoryName | Should -Contain 'Media'
            $script:categoryName | Should -Contain 'Applications'
            $script:categoryName | Should -Contain 'OperatingSystems'
        }

        # WHERE MDT PUTS IT - among the share's categories, after the content
        # ones. Monitoring stays last because it is the share IN USE rather
        # than another thing to build.
        It 'puts Media where MDT puts it - among the share''s categories, after the content ones' {
            $mediaAt = [array]::IndexOf([string[]] $script:categoryName, 'Media')
            $profileAt = [array]::IndexOf([string[]] $script:categoryName, 'SelectionProfiles')
            $monitorAt = @($script:categoryName).Count - 1

            $mediaAt | Should -BeGreaterThan $profileAt
            $mediaAt | Should -BeLessThan $monitorAt
        }

        # THE SET, NOT THE ONE JUST ADDED. A test naming Media passes for Media
        # and fails nobody after it.
        It 'still shows every category it showed before, so nothing was displaced' {
            $script:categoryName | Should -Be @(
                'BootImage', 'Applications', 'OperatingSystems', 'WindowsUpdates',
                'Drivers', 'TaskSequences', 'SelectionProfiles', 'Media', 'Monitoring')
        }
    }
}
