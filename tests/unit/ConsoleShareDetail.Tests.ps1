# THE DEPLOYMENT SHARE'S PROPERTIES SHEET, and the two things a technician
# standing in front of it could not answer.
#
# LOG LEVEL WAS A BOX. Four levels are legal and the box named none of them, so
# the only way to find out was to type something, save, and read the refusal -
# or to open the schema. A list that offers the four is the whole fix: it is
# what the document already allows, spelled where the choice is made.
#
# AND THE ? WAS ALREADY BUILT. New-HDTConsoleField has carried -Hint since the
# application rows needed one, and HDTConsole.xaml renders the dot and collapses
# it where there is no hint. The share's own rows simply passed none. They are
# added here for the rows with a rule that cannot be seen by looking - not for
# all eight, because a dot on every row is a dot that means nothing.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # ONE SHARE AND NOTHING UNDER IT. These assertions are all about the share's
    # own row, so a fixture carrying sequences and images would only add ways to
    # break for reasons that are not the subject.
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

    $script:model = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem (New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml' = $script:workspaceYaml
        })

    $script:node = @(Get-HDTConsoleTreeNode -Workspace $script:model)
    $script:share = @($script:node | Where-Object { $_.Kind -eq 'Share' })[0]

    function Get-HDTShareRow {
        param([string] $Label)
        return @($script:share.Field | Where-Object { [string] $_.Label -eq $Label })[0]
    }

    $script:schemaPath = Join-Path -Path $script:repoRoot -ChildPath 'schemas/workspace.schema.json'
    $script:xamlText = [string] (Get-Content -LiteralPath (Join-Path -Path $script:repoRoot `
                -ChildPath 'src/Hephaestus/UI/Console/HDTConsole.xaml') -Raw)
}

Describe 'a row that offers a list instead of a box' {

    It 'New-HDTConsoleField takes the choices and says it has them' {
        $field = InModuleScope Hephaestus {
            New-HDTConsoleField -Label 'Log level' -Value 'Debug' -Property 'logLevel' `
                -Choice @('Error', 'Warning', 'Info', 'Debug')
        }

        @($field.Choice) | Should -Be @('Error', 'Warning', 'Info', 'Debug')
        $field.HasChoice | Should -BeTrue
    }

    It 'a row nobody gave choices to is still a box' {
        # THE DOT AND THE LIST ARE BOTH RARE, and the template reads a boolean
        # for each rather than asking whether a collection is empty - XamlReader
        # parses markup and nothing else, so there is no converter to count with.
        $field = InModuleScope Hephaestus {
            New-HDTConsoleField -Label 'Id' -Value 'HDT-LAB-SMB'
        }

        $field.HasChoice | Should -BeFalse
        @($field.Choice).Count | Should -Be 0
    }
}

Describe 'the levels a share can log at' {

    It 'are the ones the schema allows, and are not typed twice' {
        # ONE LIST, TWO READERS. The validator refuses anything outside it and
        # the console offers exactly it, so a fifth level cannot be added to the
        # schema and appear in only one of them.
        $schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json

        $allowed = @(InModuleScope Hephaestus { Get-HDTWorkspaceLogLevel })

        $allowed | Should -Be @($schema.properties.logLevel.enum)
    }

    It 'are what the Log level row offers' {
        $row = Get-HDTShareRow -Label 'Log level'

        $row.HasChoice | Should -BeTrue
        @($row.Choice) | Should -Be @(InModuleScope Hephaestus { Get-HDTWorkspaceLogLevel })
    }

    It 'still writes the same key it always did' {
        # THE LIST CHANGED, NOT THE CONTRACT. Apply diffs Value against Original
        # and splices logLevel, and none of that cares which control produced
        # the string.
        $row = Get-HDTShareRow -Label 'Log level'

        [string] $row.Property | Should -BeExactly 'logLevel'
        [bool] $row.Editable | Should -BeTrue
    }
}

Describe 'the ? on the share rows' {

    It 'is on <Label>, which has a rule nothing on the row shows' -ForEach @(
        @{ Label = 'Deploy root' }
        @{ Label = 'Log level' }
        @{ Label = 'Credential' }
    ) {
        (Get-HDTShareRow -Label $Label).HasHint | Should -BeTrue
    }

    It 'is not on <Label>, which says what it is' -ForEach @(
        @{ Label = 'Id' }
        @{ Label = 'Schema version' }
        @{ Label = 'Document' }
    ) {
        # A DOT ON EVERY ROW IS A DOT THAT MEANS NOTHING. The pane is a
        # properties sheet, and CLAUDE.md has written this rule down twice:
        # MDT admins are not reading the manual on the deployment screen.
        (Get-HDTShareRow -Label $Label).HasHint | Should -BeFalse
    }

    It 'tells Deploy root and Opened from apart, which is the confusion' {
        # THE TWO PATHS ARE NOT THE SAME PATH and the rows sit next to each
        # other. Opened from is where this console found the share; Deploy root
        # is what a machine in WinPE connects to, and a local path there is a
        # share that deploys nothing.
        $hint = [string] (Get-HDTShareRow -Label 'Deploy root').Hint

        $hint | Should -Not -BeNullOrEmpty
        $hint | Should -BeLike '*WinPE*'
    }
}

Describe 'the detail pane markup' {

    It 'offers a list for a row that has one' {
        $script:xamlText | Should -BeLike '*HDTDetailChoice*'
        $script:xamlText | Should -BeLike '*ItemsSource="{Binding Choice}"*'
    }

    It 'binds the pick to the same Value the box binds to' {
        # APPLY READS Value AND NOTHING ELSE. A ComboBox that published its pick
        # anywhere else would light Apply and then write the old string.
        $script:xamlText | Should -BeLike '*SelectedItem="{Binding Value*'
    }

    It 'shows one control or the other, never both' {
        $script:xamlText | Should -BeLike '*<DataTrigger Binding="{Binding HasChoice}" Value="True">*'
    }
}
