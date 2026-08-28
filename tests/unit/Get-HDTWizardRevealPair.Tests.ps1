# Which eyes are on a page, and what each one reveals.
#
# THE HOST USED TO ANSWER THIS WITH THREE HARDCODED NAMES. New-HDTWizardHost
# called FindName for HDTPasswordRevealToggle, HDTPasswordBox and
# HDTPasswordRevealBox and wired exactly that trio - so a page could carry ONE
# revealable password and no more, and the administrator password page, which
# has two boxes, could carry none.
#
# THE DECISION MOVED HERE SO IT COULD BE TESTED. What is left in the adapter is
# a foreach over what this returns; which trios exist, and what to do about a
# toggle whose partners are missing, is decided by a command that runs under
# Pester with no desktop.
#
# THE CONVENTION IS THE TOGGLE'S OWN NAME. Strip RevealToggle and what is left
# is the base: HDTPasswordRevealToggle -> HDTPassword -> HDTPasswordBox and
# HDTPasswordRevealBox, which is what the two shipped pages already spell.
#
# A LONE TOGGLE IS SKIPPED, NOT AN ERROR, and that is the same reason the field
# loop skips a name nothing answers to: one host shows every page, Apply runs
# against all of them, and no page has all the controls.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    # HARDWARE RENDERING PAINTS BLANK ON THIS HOST OFTEN ENOUGH TO MATTER, and
    # nothing here is rendered anyway - the logical tree XamlReader parsed is
    # all this command reads.
    [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

    function New-HDTTestRevealRoot {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Parses markup into an in-memory tree; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter(Mandatory = $true)] [string] $Body)

        $xaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <StackPanel>
__BODY__
    </StackPanel>
</Grid>
'@
        $xaml = $xaml.Replace('__BODY__', $Body)

        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $xaml)
        return [System.Windows.Markup.XamlReader]::Load($reader)
    }
}

Describe 'Get-HDTWizardRevealPair' {

    Context 'a page carrying two complete trios and one lone toggle' {

        BeforeAll {
            # BETA IS NESTED, AND DELIBERATELY. A walk that only looked at the
            # root's immediate children would find Alpha and miss it, which is
            # exactly the shape both shipped pages have: the trio sits in a
            # two-column Grid inside the pane, not at the top of the page.
            #
            # DECLARED OUT OF ORDER so the sort has something to do.
            $script:root = New-HDTTestRevealRoot -Body @'
        <PasswordBox x:Name="HDTZuluBox" />
        <TextBox x:Name="HDTZuluRevealBox" />
        <ToggleButton x:Name="HDTZuluRevealToggle" />
        <Grid>
            <PasswordBox x:Name="HDTAlphaBox" />
            <TextBox x:Name="HDTAlphaRevealBox" />
            <ToggleButton x:Name="HDTAlphaRevealToggle" />
        </Grid>
        <ToggleButton x:Name="HDTOrphanRevealToggle" />
        <ToggleButton x:Name="HDTNotAnEyeToggle" />
        <CheckBox x:Name="HDTSomeTickBox" />
'@

            $script:pair = @(Get-HDTWizardRevealPair -Root $script:root)
        }

        It 'returns one row per complete trio and nothing else' {
            $script:pair.Count | Should -Be 2
        }

        It 'orders the rows by the toggle name so a caller can assert the set' {
            @($script:pair | ForEach-Object { [string] $_.Toggle.Name }) |
                Should -Be @('HDTAlphaRevealToggle', 'HDTZuluRevealToggle')
        }

        It 'attaches the password box the toggle belongs to' {
            @($script:pair | ForEach-Object { [string] $_.Password.Name }) |
                Should -Be @('HDTAlphaBox', 'HDTZuluBox')
        }

        It 'attaches the reveal box the toggle belongs to' {
            @($script:pair | ForEach-Object { [string] $_.Reveal.Name }) |
                Should -Be @('HDTAlphaRevealBox', 'HDTZuluRevealBox')
        }

        It 'hands back the controls themselves, not their names' {
            # A row carrying a string would pass every assertion above and wire
            # nothing: the adapter subscribes to these objects.
            $script:pair[0].Toggle -is [System.Windows.Controls.Primitives.ToggleButton] | Should -BeTrue
            $script:pair[0].Password -is [System.Windows.Controls.PasswordBox] | Should -BeTrue
            $script:pair[0].Reveal -is [System.Windows.Controls.TextBox] | Should -BeTrue
        }

        It 'skips a toggle whose two boxes are not there' {
            # THE REASON THIS IS NOT AN ERROR: one host applies every page, and
            # a half-authored page must still open.
            @($script:pair | ForEach-Object { [string] $_.Toggle.Name }) |
                Should -Not -Contain 'HDTOrphanRevealToggle'
        }

        It 'ignores a toggle that is not named for a reveal' {
            @($script:pair | ForEach-Object { [string] $_.Toggle.Name }) |
                Should -Not -Contain 'HDTNotAnEyeToggle'
        }
    }

    Context 'a page whose only toggle has no boxes' {

        It 'returns an empty collection rather than a row that cannot be wired' {
            $root = New-HDTTestRevealRoot -Body '        <ToggleButton x:Name="HDTLonelyRevealToggle" />'

            @(Get-HDTWizardRevealPair -Root $root).Count | Should -Be 0
        }
    }

    Context 'a page with no toggles at all' {

        It 'returns an empty collection and does not throw' {
            $root = New-HDTTestRevealRoot -Body '        <TextBox x:Name="HDTComputerNameBox" />'

            { Get-HDTWizardRevealPair -Root $root } | Should -Not -Throw
            @(Get-HDTWizardRevealPair -Root $root).Count | Should -Be 0
        }
    }

    Context 'the pages this module actually ships' {

        # RUN THE MODULE, NOT JUST THE FAKES. The hand-written markup above
        # proves the walk; this proves the CONVENTION holds on the two real
        # files, which is the thing that would quietly stop being true when
        # somebody names the next pair differently.
        BeforeAll {
            $script:wizardRoot = [System.IO.Path]::Combine(
                (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
                'src', 'Hephaestus', 'Templates', 'Wizard')

            $script:load = {
                param([string] $File)

                $path = [System.IO.Path]::Combine($script:wizardRoot, $File)
                $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList (
                    [xml] ([System.IO.File]::ReadAllText($path)))

                return [System.Windows.Markup.XamlReader]::Load($reader)
            }
        }

        It 'finds the one eye on the computer details page' {
            @(Get-HDTWizardRevealPair -Root (& $script:load 'ComputerDetail.xaml') |
                    ForEach-Object { [string] $_.Toggle.Name }) |
                Should -Be @('HDTPasswordRevealToggle')
        }

        It 'finds an eye on both boxes of the administrator password page' {
            @(Get-HDTWizardRevealPair -Root (& $script:load 'AdminPassword.xaml') |
                    ForEach-Object { [string] $_.Toggle.Name }) |
                Should -Be @('HDTAdminPasswordConfirmRevealToggle', 'HDTAdminPasswordRevealToggle')
        }
    }
}

}
