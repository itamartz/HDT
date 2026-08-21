# W1 of the WPF-first direction (.planning/WPF-FIRST.md).
#
# THE WINDOW IS NOT UNIT TESTED AND MUST NOT BE. Show-HDTWizard holds the logic;
# an injected IWizardHost holds the WPF. That split is what makes these
# assertions possible on a developer machine with no WinPE and no display, and
# it is the same shape as every other service in this engine (DESIGN 12.2.1).
#
# What is asserted here is exactly what can be wrong without a screen:
#   * a XAML file that is not there, or does not parse, is refused BY NAME
#   * the title reaches the host
#   * the host's answer is what comes back
#   * A CLOSED WINDOW IS A CANCEL. That one is not cosmetic: the wizard's Next
#     leads to a task sequence that partitions a disk, so "the technician shut
#     the window" and "the technician approved" must never be the same value.
#     A host that returns nothing at all is the shape that would confuse them.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:xamlPath = 'C:\HDTLab\Share\Boot\HDTWizard.xaml'

    # The real W1 window, read off disk rather than retyped, so the shipped file
    # and the file these tests exercise cannot drift.
    $script:realXaml = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/HDTWizard.xaml'))

    function New-HDTWizardTestFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fake file system; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowEmptyString()]
            [string] $Xaml = $script:realXaml,

            [Parameter()]
            [switch] $Missing,

            [Parameter()]
            [ValidateNotNullOrEmpty()]
            [string] $Path = $script:xamlPath
        )

        $file = @{}
        if (-not $Missing) { $file[$Path] = $Xaml }

        return New-HDTFakeFileSystem -File $file
    }
}

Describe 'Show-HDTWizard and the answer it will admit' {

    # THE ALLOW-LIST IS THE SAFETY PROPERTY, and it gained a fourth entry when
    # the Deployment Summary got MDT's Finish button. The property it protects is
    # unchanged and these assertions are what say so: Next is still the only
    # answer that deploys, and anything unrecognised is still a Cancel.

    It 'admits Finish, so a dismissed summary is not read as a shutdown' {
        $answer = Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
            -FileSystem (New-HDTWizardTestFileSystem) `
            -WizardHost (New-HDTFakeWizardHost -Action 'Finish')

        [string] $answer.Action | Should -BeExactly 'Finish'
    }

    It 'still turns anything it does not know into a Cancel' -ForEach @(
        'finish', 'FINISH', 'Done', 'Ok', 'Yes', '') {

        $answer = Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
            -FileSystem (New-HDTWizardTestFileSystem) `
            -WizardHost (New-HDTFakeWizardHost -Action $PSItem)

        [string] $answer.Action | Should -BeExactly 'Cancel' -Because (
            "'{0}' is not one of the four" -f $PSItem)
    }

    It 'still deploys on Next and nothing else' -ForEach @('Cancel', 'CommandPrompt', 'Finish') {
        $answer = Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
            -FileSystem (New-HDTWizardTestFileSystem) `
            -WizardHost (New-HDTFakeWizardHost -Action $PSItem)

        [string] $answer.Action | Should -Not -BeExactly 'Next'
    }
}

Describe 'Show-HDTWizard' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Show-HDTWizard' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'takes an injected wizard host, so it can run with no display' {
            (Get-Command -Name 'Show-HDTWizard').Parameters.ContainsKey('WizardHost') | Should -BeTrue
        }
    }

    Context 'the XAML it is asked to show' {

        It 'refuses a XAML file that is not there, naming the path' {
            $record = $null
            try {
                Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
                    -WizardHost (New-HDTFakeWizardHost -Action 'Next') `
                    -FileSystem (New-HDTWizardTestFileSystem -Missing)
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:xamlPath)
        }

        It 'refuses XAML that does not parse, before any window is shown' {
            # A broken window must fail while a human is still looking at a build
            # log, not halfway through a deployment in WinPE.
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            $record = $null
            try {
                Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
                    -WizardHost $wizardHost `
                    -FileSystem (New-HDTWizardTestFileSystem -Xaml '<Window><this is not xaml')
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            @($wizardHost.Operations) | Should -BeNullOrEmpty -Because (
                'nothing should have been shown once the XAML was known to be broken')
        }

        It 'hands the host the XAML it read' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
                -WizardHost $wizardHost -FileSystem (New-HDTWizardTestFileSystem) | Out-Null

            [string] $wizardHost.LastXaml | Should -BeLike '*<Window*'
        }

        It 'hands the host the block of the string table that fills this window' {
            # THE MARKUP CARRIES NO TEXT, so something has to bring it, and the
            # block is chosen by the FILE NAME: HDTWelcome.xaml is filled by
            # Welcome. That convention is what stops a second table of
            # file-to-block mappings existing beside the one in the contract.
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizard -XamlPath 'C:\HDTLab\Share\Boot\HDTWizard.xaml' -Title 'HDT' `
                -WizardHost $wizardHost -FileSystem (New-HDTWizardTestFileSystem) | Out-Null

            [string] $wizardHost.LastString['HDTBodyHeading.Text'] | Should -BeExactly 'Welcome'
        }

        It 'shows a window whose name matches no block, rather than refusing it' {
            # A SCRATCH WINDOW IS NOT A DEFECT. Tools and tests load markup that
            # ships with nobody's block, and a wizard that threw on one would
            # make the string table a thing that has to be fed before anything
            # can be drawn at all.
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            { Show-HDTWizard -XamlPath 'C:\HDTLab\Share\Boot\HDTNoSuchWindow.xaml' -Title 'HDT' `
                    -WizardHost $wizardHost `
                    -FileSystem (New-HDTWizardTestFileSystem -Path 'C:\HDTLab\Share\Boot\HDTNoSuchWindow.xaml') } |
                Should -Not -Throw
        }

        It 'hands the host the fields it was given, to apply by name' {
            # THE HOST DOES NOT WORK OUT WHAT GOES IN THE BOXES. Get-HDTWizardField
            # does, and it is unit tested; this command forwards the answer and
            # interprets none of it.
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' -WizardHost $wizardHost `
                -FileSystem (New-HDTWizardTestFileSystem) `
                -Field @([pscustomobject] @{ Name = 'HDTIpAddressBox'; Text = '192.168.2.118' }) | Out-Null

            @($wizardHost.LastField).Count | Should -Be 1
            [string] @($wizardHost.LastField)[0].Name | Should -BeExactly 'HDTIpAddressBox'
            [string] @($wizardHost.LastField)[0].Text | Should -BeExactly '192.168.2.118'
        }

        It 'hands the host the panes it was given, to collapse by name' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' -WizardHost $wizardHost `
                -FileSystem (New-HDTWizardTestFileSystem) `
                -Pane @([pscustomobject] @{ Name = 'HDTCredentialPane'; Visible = $false }) | Out-Null

            @($wizardHost.LastPane).Count | Should -Be 1
            [string] @($wizardHost.LastPane)[0].Name | Should -BeExactly 'HDTCredentialPane'
            [bool] @($wizardHost.LastPane)[0].Visible | Should -BeFalse
        }

        It 'hands the host an empty list, not a null element, when it was given no panes' {
            # THE DESKTOP PREVIEW TOOL DIED ON THIS. @($null) is a one-element
            # array whose element is $null, so a caller that named no panes -
            # tools\Show-HDTWizardOnDesktop.ps1, and every page with nothing to
            # collapse - handed the host one null pane, and the host reads .Name
            # off it under Set-StrictMode: "The property 'Name' cannot be found
            # on this object", thrown while the window is opening.
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' -WizardHost $wizardHost `
                -FileSystem (New-HDTWizardTestFileSystem) `
                -Field @([pscustomobject] @{ Name = 'HDTIpAddressBox'; Text = '192.168.2.118' }) | Out-Null

            @($wizardHost.LastPane).Count | Should -Be 0
        }

        It 'still shows the window when every pane is hidden' {
            # HDTSkipWelcome is what suppresses the WINDOW, and it is the
            # caller's decision - not this command's. A Show-HDTWizard that
            # sometimes showed nothing would return an Action for a window
            # nobody saw.
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            $result = Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' -WizardHost $wizardHost `
                -FileSystem (New-HDTWizardTestFileSystem) `
                -Pane @(
                [pscustomobject] @{ Name = 'HDTNetworkPane'; Visible = $false },
                [pscustomobject] @{ Name = 'HDTDeployRootPane'; Visible = $false },
                [pscustomobject] @{ Name = 'HDTCredentialPane'; Visible = $false })

            @($wizardHost.Operations | Where-Object { $_ -like 'Show*' }).Count | Should -Be 1
            [string] $result.Action | Should -BeExactly 'Next'
        }

        It 'shows a window with no fields at all, because prefill is optional' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
                -WizardHost $wizardHost -FileSystem (New-HDTWizardTestFileSystem) | Out-Null

            @($wizardHost.LastField) | Should -BeNullOrEmpty
        }

        It 'hands the host the title' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizard -XamlPath $script:xamlPath -Title 'Hephaestus Deployment' `
                -WizardHost $wizardHost -FileSystem (New-HDTWizardTestFileSystem) | Out-Null

            [string] $wizardHost.LastTitle | Should -BeExactly 'Hephaestus Deployment'
        }
    }

    Context 'what it answers' {

        It 'returns Next when the technician chose Next' {
            $result = Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
                -WizardHost (New-HDTFakeWizardHost -Action 'Next') `
                -FileSystem (New-HDTWizardTestFileSystem)

            [string] $result.Action | Should -BeExactly 'Next'
        }

        It 'returns Cancel when the technician chose Cancel' {
            $result = Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
                -WizardHost (New-HDTFakeWizardHost -Action 'Cancel') `
                -FileSystem (New-HDTWizardTestFileSystem)

            [string] $result.Action | Should -BeExactly 'Cancel'
        }

        It 'treats a window that answered nothing as Cancel, never as Next' {
            # THE ONE THAT MATTERS. Next leads to a sequence that partitions a
            # disk. A host that returns $null - a window closed with the X, a
            # dialog dismissed by the shell - must not be read as approval.
            $result = Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
                -WizardHost (New-HDTFakeWizardHost -Action '') `
                -FileSystem (New-HDTWizardTestFileSystem)

            [string] $result.Action | Should -BeExactly 'Cancel' -Because (
                'a dismissed wizard is not consent to deploy')
        }

        It 'returns CommandPrompt when the technician chose Open CMD' {
            # MDT's "Exit to Command Prompt". WinPE offers it on F8, but F8 is
            # folklore and a button is discoverable - and a technician whose
            # network is wrong or whose disk needs diskpart has to be able to
            # get to a prompt without cancelling the deployment.
            $result = Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
                -WizardHost (New-HDTFakeWizardHost -Action 'CommandPrompt') `
                -FileSystem (New-HDTWizardTestFileSystem)

            [string] $result.Action | Should -BeExactly 'CommandPrompt'
        }

        It 'never lets Open CMD be read as consent to deploy' {
            $result = Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
                -WizardHost (New-HDTFakeWizardHost -Action 'CommandPrompt') `
                -FileSystem (New-HDTWizardTestFileSystem)

            [string] $result.Action | Should -Not -BeExactly 'Next'
        }

        It 'reads <_> as Cancel, because it is not on the allow-list' -ForEach @(
            'OpenCmd', 'Deploy', 'Yes', 'Continue', 'Next ', ' Next') {

            # THE ALLOW-LIST IS WHAT KEEPS THIS SAFE. Widening the answers from
            # one to three is where a "recognise more things" reflex quietly
            # turns into "recognise anything that looks close enough", and the
            # thing on the other side of Next partitions a disk.
            $result = Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
                -WizardHost (New-HDTFakeWizardHost -Action $PSItem) `
                -FileSystem (New-HDTWizardTestFileSystem)

            [string] $result.Action | Should -BeExactly 'Cancel'
        }

        It 'reads the case variant <_> as Cancel' -ForEach @('next', 'NEXT', 'commandprompt', 'COMMANDPROMPT') {
            # Matched case-sensitively on purpose: a host answering 'next' is a
            # host that is not the one this command was written against, and
            # guessing what it meant is how the allow-list stops being one.
            $result = Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
                -WizardHost (New-HDTFakeWizardHost -Action $PSItem) `
                -FileSystem (New-HDTWizardTestFileSystem)

            [string] $result.Action | Should -BeExactly 'Cancel'
        }

        It 'returns the allow-list spelling, never the string the host handed back' {
            $result = Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
                -WizardHost (New-HDTFakeWizardHost -Action 'CommandPrompt') `
                -FileSystem (New-HDTWizardTestFileSystem)

            @('Next', 'Cancel', 'CommandPrompt') | Should -Contain ([string] $result.Action)
        }

        It 'records that it showed the window exactly once' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizard -XamlPath $script:xamlPath -Title 'HDT' `
                -WizardHost $wizardHost -FileSystem (New-HDTWizardTestFileSystem) | Out-Null

            @($wizardHost.Operations | Where-Object { $_ -like 'Show*' }).Count | Should -Be 1
        }
    }

    Context 'the shipped W1 window' {

        It 'exists at src/Hephaestus/UI/HDTWizard.xaml' {
            Test-Path -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/HDTWizard.xaml') -PathType Leaf |
                Should -BeTrue
        }

        It 'is parseable XAML' {
            { [xml] $script:realXaml } | Should -Not -Throw
        }

        It 'carries the two buttons W1 promises, by name' {
            # Named so the later increments can find them; W1 only has to show
            # them.
            $script:realXaml | Should -BeLike '*HDTNextButton*'
            $script:realXaml | Should -BeLike '*HDTCancelButton*'
        }

        It 'declares no code-behind, which WinPE could not compile anyway' {
            # ASSERTED ON THE PARSED ROOT, not on the raw text. A raw-text scan
            # for the attribute name also matches the comment in the markup that
            # EXPLAINS why the attribute is absent - so the first version of
            # this test failed against a file that was perfectly correct, which
            # is the same "measured the wrong thing" mistake as SPIKES S9.16.
            $document = [xml] $script:realXaml
            $xamlNamespace = 'http://schemas.microsoft.com/winfx/2006/xaml'

            $document.DocumentElement.GetAttribute('Class', $xamlNamespace) |
                Should -BeNullOrEmpty -Because (
                    'there is no compiler in WinPE to build a partial class against')
        }
    }
}
