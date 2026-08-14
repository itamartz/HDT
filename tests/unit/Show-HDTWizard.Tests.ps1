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
            [switch] $Missing
        )

        $file = @{}
        if (-not $Missing) { $file[$script:xamlPath] = $Xaml }

        return New-HDTFakeFileSystem -File $file
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
