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

        # THE SHARE'S OWN PROFILES, HANDED IN. Get-HDTConsoleMediaNode does not
        # read selection-profiles.yaml itself - the share node has already read
        # it for the Selection Profiles category, and a second read of the same
        # document is a second answer waiting to disagree with the first. This
        # fake share has no selection-profiles.yaml, so what the model carries
        # is the built-in fallback, which is exactly the collection the console
        # lists beside these rows.
        $script:category = Get-HDTConsoleMediaNode -Media $script:model.Media `
            -MediaFailure $script:model.MediaFailure -Root 'C:\ws' -Header $script:header `
            -SelectionProfile $script:model.SelectionProfile

        $script:row = @($script:category.Children)

        # A SHARE WITH NO MEDIA AT ALL, which is every share created before
        # Media\ was part of the layout - New-HDTWorkspace never writes over an
        # existing one.
        $script:emptyModel = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem (
            New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: HDT`nname: HDT share`n"
            })

        $script:emptyCategory = Get-HDTConsoleMediaNode -Media $script:emptyModel.Media `
            -MediaFailure $script:emptyModel.MediaFailure -Root 'C:\ws' -Header $script:header `
            -SelectionProfile $script:emptyModel.SelectionProfile

        # THE IDS THIS SHARE OFFERS, read off the model rather than written down
        # here: a list typed into the test would go on passing after the
        # built-ins changed underneath it.
        $script:profileId = @(@($script:model.SelectionProfile) | ForEach-Object { [string] $_.Id })

        $script:fieldOf = {
            param([object] $Node, [string] $Label)
            $found = @($Node.Field) | Where-Object { [string] $_.Label -eq $Label } | Select-Object -First 1
            if ($null -eq $found) { return '' }
            return [string] $found.Value
        }

        $script:fieldObjectOf = {
            param([object] $Node, [string] $Label)
            return @($Node.Field) | Where-Object { [string] $_.Label -eq $Label } | Select-Object -First 1
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

        # NEW, RATHER THAN DEFERRED: description, selectionProfile, output and
        # enabled were read-only text until 2026-09-05, and Set-HDTMedia already
        # existed to change every one of them - there was a command with no box
        # to reach it from. This is the set those four fields draw on the row,
        # the same way ConsoleRowDocument.Tests.ps1's "every kind this pane
        # edits" asserts over every KIND rather than the one just added.
        Context 'the fields a technician can type into' {

            # THE SET, NOT THE TWO THAT ARE STILL BOXES. Two of these four are
            # lists now and two are boxes; what every one of them has to be is a
            # ROW THAT WRITES, and that is the assertion. Narrowing this to the
            # boxes would leave the lists covered by nothing.
            It 'wires <Label> for -Property ''<Property>'', so it is a row that writes' -ForEach @(
                @{ Label = 'Description'; Property = 'description' }
                @{ Label = 'Selection profile'; Property = 'selectionProfile' }
                @{ Label = 'Output'; Property = 'output' }
                @{ Label = 'Enabled'; Property = 'enabled' }
            ) {
                $built = & $script:rowFor 'WIN11-FIELD'
                $field = & $script:fieldObjectOf $built $Label

                $field | Should -Not -BeNullOrEmpty -Because ("the row must have a {0} field to type into" -f $Label)
                [string] $field.Property | Should -BeExactly $Property
                [bool] $field.Editable | Should -BeTrue
            }

            It 'shows the description even when it is unset, the same rule every other editable description follows' {
                # NO FALLBACK IN A BOX THAT WRITES. WS2025-LAB's document has no
                # description: key at all - the empty box is what lets an
                # administrator add one by typing, rather than deleting a
                # placeholder phrase first.
                $field = & $script:fieldObjectOf (& $script:rowFor 'WS2025-LAB') 'Description'

                $field | Should -Not -BeNullOrEmpty
                [string] $field.Value | Should -BeExactly ''
            }

            It 'shows Enabled as the one word it is, not the sentence about what happens when it is off' {
                # THE EXPLANATION MOVED TO -Hint. A row that writes has to hold
                # exactly what the document holds, and 'no - Update Media
                # Content refuses it while it is off' was never that.
                $field = & $script:fieldObjectOf (& $script:rowFor 'WIN11-FIELD') 'Enabled'
                [string] $field.Hint | Should -BeLike '*refuses*'
            }
        }

        # THE TWO ROWS THE DOCUMENT CONSTRAINS TO A CLOSED SET, drawn as lists
        # rather than as boxes somebody types a guess into. A wrong-but-legal
        # profile name is not refused by anything a technician can see: it makes
        # a media item whose disc has no content on it.
        Context 'the selection profile is chosen, never typed' {

            It 'offers this share''s profile ids as the row''s Choice, so a wrong-but-legal name cannot be typed into a disc with no content on it' {
                $field = & $script:fieldObjectOf (& $script:rowFor 'WIN11-FIELD') 'Selection profile'

                @($script:profileId).Count | Should -BeGreaterThan 0 -Because 'the fixture must offer some profile or this test is vacuous'

                foreach ($id in @($script:profileId)) {
                    @($field.Choice) | Should -Contain $id
                }
            }

            It 'marks the row HasChoice, which is what swaps the ComboBox in for the box' {
                $field = & $script:fieldObjectOf (& $script:rowFor 'WIN11-FIELD') 'Selection profile'

                [bool] $field.HasChoice | Should -BeTrue
                [string] $field.Kind | Should -BeExactly 'Choice'
            }

            It 'still writes selectionProfile, so a pick reaches the same document key the box did' {
                $field = & $script:fieldObjectOf (& $script:rowFor 'WIN11-FIELD') 'Selection profile'

                [string] $field.Property | Should -BeExactly 'selectionProfile'
                [bool] $field.Editable | Should -BeTrue
            }

            It 'offers the ids and not the display names, because the document stores the id' {
                # New-HDTMedia and Set-HDTMedia both validate against
                # $_.Id -eq $SelectionProfile. A list of Names would be a list
                # every one of whose entries the command refuses.
                #
                # -ceq AND NOT -contains. PowerShell's -contains is
                # case-INSENSITIVE, so a list of Names would satisfy it against
                # the ids and this test would pass on the defect it exists to
                # catch. The combo's own SelectedItem match is case-sensitive,
                # which is the behaviour being pinned.
                $field = & $script:fieldObjectOf (& $script:rowFor 'WIN11-FIELD') 'Selection profile'

                $offered = @($field.Choice)
                @($offered | Where-Object { $_ -ceq 'everything' }).Count | Should -Be 1

                foreach ($profile in @($script:model.SelectionProfile)) {
                    if ([string] $profile.Name -ceq [string] $profile.Id) { continue }

                    @($offered | Where-Object { $_ -ceq [string] $profile.Name }).Count |
                        Should -Be 0 -Because ("'{0}' is the display name; the document stores '{1}'" -f
                            $profile.Name, $profile.Id)
                }
            }

            It 'keeps its Hint, which is the sentence that says what the profile decides' {
                $field = & $script:fieldObjectOf (& $script:rowFor 'WIN11-FIELD') 'Selection profile'

                [string] $field.Hint | Should -BeLike '*disc*'
            }
        }

        # WS2025-LAB'S DOCUMENT NAMES boot-critical, WHICH IS NOT A BUILT-IN AND
        # NOT ON THIS SHARE. That is the stale case, and it is in the fixture
        # rather than invented for the occasion.
        Context 'a media naming a profile the share no longer offers' {

            It 'shows that profile anyway, first on its own list - an empty combo over a document that plainly sets a profile reads as unset' {
                $field = & $script:fieldObjectOf (& $script:rowFor 'WS2025-LAB') 'Selection profile'

                [string] $field.Value | Should -BeExactly 'boot-critical'
                [string] @($field.Choice)[0] | Should -BeExactly 'boot-critical'
            }

            It 'still offers every profile the share does have, after it' {
                $field = & $script:fieldObjectOf (& $script:rowFor 'WS2025-LAB') 'Selection profile'

                foreach ($id in @($script:profileId)) {
                    @($field.Choice) | Should -Contain $id
                }
            }

            It 'adds nothing when the profile IS on the list, so the list is not duplicated' {
                $field = & $script:fieldObjectOf (& $script:rowFor 'WIN11-FIELD') 'Selection profile'

                @($field.Choice).Count | Should -Be @($script:profileId).Count
                @(@($field.Choice) | Select-Object -Unique).Count | Should -Be @($field.Choice).Count
            }
        }

        Context 'a share whose selection profiles could not be read' {

            BeforeAll {
                # $Workspace.SelectionProfileFailure IS A REAL STATE, and the
                # row has to survive it rather than throwing or drawing an empty
                # list nobody can use.
                $script:noProfileCategory = Get-HDTConsoleMediaNode -Media $script:model.Media `
                    -MediaFailure '' -Root 'C:\ws' -Header $script:header -SelectionProfile @()

                $script:noProfileRowFor = {
                    param([string] $Id)
                    return @($script:noProfileCategory.Children) |
                        Where-Object { [string] $_.Name -eq $Id } | Select-Object -First 1
                }
            }

            It 'falls back to the media''s own profile alone, rather than an empty list' {
                $field = & $script:fieldObjectOf (& $script:noProfileRowFor 'WS2025-LAB') 'Selection profile'

                @($field.Choice) | Should -Be @('boot-critical')
            }

            It 'falls back to a plain box when there is no profile on either side' {
                # A COMBO WITH NOTHING IN IT CANNOT BE USED. A box can at least
                # be typed into, and Set-HDTMedia refuses a bad id with a
                # message naming every legal one.
                $bare = Get-HDTConsoleMediaNode -Root 'C:\ws' -Header $script:header -SelectionProfile @() `
                    -Media @([pscustomobject] @{
                            Id = 'BARE'; Name = 'Bare'; Description = ''; SelectionProfile = ''
                            Output = 'Media\BARE\BARE.iso'; OutputPath = 'C:\ws\Media\BARE\BARE.iso'
                            Enabled = $true; LastBuildUtc = $null; IsoSizeBytes = 0
                            DocumentPath = 'C:\ws\Media\BARE\media.yaml'
                        })

                $field = & $script:fieldObjectOf @($bare.Children)[0] 'Selection profile'

                @($field.Choice).Count | Should -Be 0
                [bool] $field.HasChoice | Should -BeFalse
                [string] $field.Kind | Should -BeExactly 'Text'
            }
        }

        Context 'enabled, which the document writes as a bare boolean' {

            It 'shows true or false - the words media.yaml holds, not yes and no' {
                (& $script:fieldOf (& $script:rowFor 'WIN11-FIELD') 'Enabled') | Should -BeExactly 'true'
            }

            It 'offers exactly true and false, in that order' {
                $field = & $script:fieldObjectOf (& $script:rowFor 'WIN11-FIELD') 'Enabled'

                @($field.Choice) | Should -Be @('true', 'false')
            }

            It 'draws it as a list and not a tick box, by explicit instruction rather than by the house pattern' {
                # EVERY OTHER YES-OR-NO IN THIS WINDOW IS -Check. This one is a
                # dropdown because the user asked for a dropdown here
                # specifically - not by oversight, and not to be swept back into
                # line by a later consistency pass.
                $field = & $script:fieldObjectOf (& $script:rowFor 'WIN11-FIELD') 'Enabled'

                [string] $field.Kind | Should -BeExactly 'Choice'
                [bool] $field.HasChoice | Should -BeTrue
            }

            It 'keeps the explanation in the Hint and out of the value, so nothing English can be spliced into the key' {
                $field = & $script:fieldObjectOf (& $script:rowFor 'WIN11-FIELD') 'Enabled'

                [string] $field.Hint | Should -BeLike '*refuses*'
                [string] $field.Value | Should -Not -BeLike '*refuses*'
                [string] $field.Value | Should -Not -BeLike '* *'
            }

            It 'shows false for a disabled media and true for an enabled one' {
                $mixed = Get-HDTConsoleMediaNode -Root 'C:\ws' -Header $script:header `
                    -SelectionProfile $script:model.SelectionProfile `
                    -Media @([pscustomobject] @{
                            Id = 'OFF'; Name = 'Held back'; Description = ''; SelectionProfile = 'everything'
                            Output = 'Media\OFF\OFF.iso'; OutputPath = 'C:\ws\Media\OFF\OFF.iso'
                            Enabled = $false; LastBuildUtc = $null; IsoSizeBytes = 0
                            DocumentPath = 'C:\ws\Media\OFF\media.yaml'
                        })

                (& $script:fieldOf @($mixed.Children)[0] 'Enabled') | Should -BeExactly 'false'
                (& $script:fieldOf (& $script:rowFor 'WIN11-FIELD') 'Enabled') | Should -BeExactly 'true'
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

        # THE WIRING, THROUGH THE REAL SHARE NODE. Get-HDTConsoleMediaNode can
        # take -SelectionProfile and be handed nothing, and every test that
        # calls it directly would still pass - the row would draw a box on a
        # live share and nobody would know until a technician typed a profile
        # name into it.
        It 'feeds the media rows the same selection profiles the Selection Profiles category lists' {
            $offered = @(@($script:model.SelectionProfile) | ForEach-Object { [string] $_.Id })
            @($offered).Count | Should -BeGreaterThan 0

            $mediaBranch = @($script:tree | Where-Object {
                    [string] $_.Kind -eq 'Category' -and [string] $_.Name -eq 'Media'
                })[0]

            $mediaRow = @(@($mediaBranch.Children) | Where-Object { [string] $_.Kind -eq 'Media' })[0]

            $field = @($mediaRow.Field) | Where-Object { [string] $_.Label -eq 'Selection profile' } |
                Select-Object -First 1

            $field | Should -Not -BeNullOrEmpty

            foreach ($id in $offered) {
                @($field.Choice) | Should -Contain $id
            }
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
