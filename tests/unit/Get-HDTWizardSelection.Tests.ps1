# WHAT A COLUMN OF TICK BOXES ANSWERS WITH.
#
# wizard.yaml's collect declarations read ONE property off ONE control - Text,
# SelectedValue, Password, IsChecked - and "every ticked row, joined" is none of
# them. That is why the Applications page shipped collecting nothing: rather
# than bend a single-value declaration into a multi-value one from the markup
# side, the page went out honest and the shape it needed came next.
#
# THIS IS THAT SHAPE, AND IT IS A COMMAND RATHER THAN A BRANCH IN THE ADAPTER.
# New-HDTWizardHost is exempt from TDD only for as long as it decides nothing;
# joining, ordering and what to do with a row that carries no id are decisions.
#
# IT READS THE ROWS, NOT THE VISUAL TREE. The page's CheckBox is bound TwoWay to
# the row's IsSelected, so the answer is on the objects the host handed the
# control - which is why this needs no window, no desktop and no WinPE.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:row = {
        param([string] $Id, [bool] $Selected)

        return [pscustomobject] @{ Id = $Id; Text = $Id; IsSelected = $Selected }
    }
}

Describe 'Get-HDTWizardSelection' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTWizardSelection' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'joins the ticked ids with the separator the step splits on' {
        # Invoke-HDTInstallApplicationsStep splits HDTApplications on [,;\r\n].
        # A separator it does not split on would arrive as one very long id.
        $row = @((& $script:row '7Zip-24.09' $true), (& $script:row 'VSCode-1.96' $false), (& $script:row 'Firefox-ESR-128' $true))

        Get-HDTWizardSelection -Row $row | Should -Be '7Zip-24.09, Firefox-ESR-128'
    }

    It 'keeps the order the rows were in, not the order they were ticked' {
        # The rows arrive sorted by id and the technician ticks them in whatever
        # order they read the page. A variable that came back in click order
        # would differ between two identical deployments, and the report would
        # show a difference nobody made.
        $row = @((& $script:row 'Alpha' $false), (& $script:row 'Bravo' $true), (& $script:row 'Charlie' $true))

        Get-HDTWizardSelection -Row $row | Should -Be 'Bravo, Charlie'
    }

    It 'answers with an empty string when nothing is ticked' {
        # TICKING NOTHING IS A NORMAL ANSWER - a base image with no applications
        # is most of what a lab deploys - so this is empty rather than absent or
        # an error.
        $row = @((& $script:row 'Alpha' $false), (& $script:row 'Bravo' $false))

        Get-HDTWizardSelection -Row $row | Should -Be ''
    }

    It 'answers with an empty string for a page whose list never got any rows' {
        Get-HDTWizardSelection -Row @() | Should -Be ''
    }

    It 'survives a null row list, because a page may declare a list it never fills' {
        Get-HDTWizardSelection -Row $null | Should -Be ''
    }

    It 'ignores a row with no id rather than joining an empty one in' {
        # A blank between two commas is an id the installer would look up and
        # fail on. A row without an id is a row this page cannot act on.
        $row = @((& $script:row 'Alpha' $true), (& $script:row '' $true), (& $script:row 'Charlie' $true))

        Get-HDTWizardSelection -Row $row | Should -Be 'Alpha, Charlie'
    }

    It 'reads a row that carries no IsSelected as unticked rather than throwing' {
        # Set-StrictMode -Version Latest makes a missing property an exception,
        # and the rows come from a command a site could replace. An unticked
        # default is the safe reading: it installs nothing nobody asked for.
        $row = @([pscustomobject] @{ Id = 'Alpha'; Text = 'Alpha' }, (& $script:row 'Bravo' $true))

        Get-HDTWizardSelection -Row $row | Should -Be 'Bravo'
    }

    It 'accepts a different property name, so a list of something else can use it' {
        # Nothing here knows the word "application". A later page collecting
        # ticks over a different kind of row names its own id property.
        $row = @(
            [pscustomobject] @{ Name = 'Alpha'; IsSelected = $true },
            [pscustomobject] @{ Name = 'Bravo'; IsSelected = $false })

        Get-HDTWizardSelection -Row $row -Property 'Name' | Should -Be 'Alpha'
    }
}
