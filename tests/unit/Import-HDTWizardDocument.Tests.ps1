# READING THE WIZARD DEFINITION OFF THE SHARE, AND THE PAGES WITH IT.
#
# THROUGH THE CONTENT PROVIDER, NOT THE FILE SYSTEM, and that is the whole
# reason standalone media needs no second code path: media is "a content
# projection of the share with the provider swapped" (CLAUDE.md), so a wizard
# read through IContentProvider works on a UNC share, on a local folder and on a
# USB stick without knowing which it is on.
#
# A SHARE WITH NO wizard.yaml HAS NO WIZARD. Absent is not an error - it is the
# answer that keeps every image built before this existed deploying with nobody
# present. Absent PAGES are a different matter: a definition that names markup
# which is not there is a definition that is wrong, and it is refused before a
# technician is looking at a half-built window.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:deployRoot = 'C:\Share'

    $script:definition = @'
schemaVersion: 1
title: Hephaestus Deployment Toolkit
pages:
  - id: ComputerDetail
    title: Computer details
    heading: Name this computer
    reference: ComputerDetail.xaml
    skip: HDTSkipComputerName
    validate:
      control: HDTComputerNameBox
      rule: ComputerName
    collect:
      - control: HDTComputerNameBox
        variable: HDTComputerName
  - id: Summary
    title: Summary
    reference: Summary.xaml
    skip: HDTSkipSummary
    summary:
      rowControl: HDTSummaryList
      snippetControl: HDTSummarySnippet
'@

    $script:page = '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" />'

    function New-HDTWizardTestProvider {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fake; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [switch] $NoDefinition,

            [Parameter()]
            [AllowEmptyString()]
            [string] $Definition = $script:definition,

            [Parameter()]
            [AllowEmptyString()]
            [string] $MissingPage = ''
        )

        $file = @{}
        if (-not $NoDefinition) { $file['C:\Share\Scripts\UI\wizard.yaml'] = $Definition }

        foreach ($name in @('ComputerDetail.xaml', 'Summary.xaml')) {
            if ($name -eq $MissingPage) { continue }
            $file[('C:\Share\Scripts\UI\{0}' -f $name)] = $script:page
        }

        return New-HDTLocalContentProvider -Root $script:deployRoot -FileSystem (New-HDTFakeFileSystem -File $file)
    }
}

Describe 'Import-HDTWizardDocument' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Import-HDTWizardDocument' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'takes a content provider, so media and a share are the same to it' {
            (Get-Command -Name 'Import-HDTWizardDocument').Parameters.ContainsKey('Provider') | Should -BeTrue
        }
    }

    Context 'a share with no wizard' {

        It 'returns nothing rather than failing' {
            # THE PROPERTY EVERY EXISTING IMAGE DEPENDS ON.
            Import-HDTWizardDocument -Provider (New-HDTWizardTestProvider -NoDefinition) | Should -BeNullOrEmpty
        }

        It 'does not throw' {
            { Import-HDTWizardDocument -Provider (New-HDTWizardTestProvider -NoDefinition) } | Should -Not -Throw
        }
    }

    Context 'a share with one' {

        It 'returns the pages in the order they were declared' {
            $wizard = Import-HDTWizardDocument -Provider (New-HDTWizardTestProvider)

            (@($wizard.Page | ForEach-Object { [string] $_.Id }) -join ',') | Should -BeExactly 'ComputerDetail,Summary'
        }

        It 'carries the title the definition declared' {
            [string] (Import-HDTWizardDocument -Provider (New-HDTWizardTestProvider)).Title |
                Should -BeExactly 'Hephaestus Deployment Toolkit'
        }

        It 'resolves each reference to a path the shell can read' {
            $wizard = Import-HDTWizardDocument -Provider (New-HDTWizardTestProvider)

            [string] @($wizard.Page)[0].XamlPath | Should -BeExactly 'C:\Share\Scripts\UI\ComputerDetail.xaml'
        }

        It 'hands the shell what it expects, key for key' {
            # Show-HDTWizardShell reads Id, Title, Heading, Subheading, XamlPath,
            # Skip, Validate, Collect and Summary. A reader that produced
            # anything else would be a second shape to keep in step.
            $page = @(Import-HDTWizardDocument -Provider (New-HDTWizardTestProvider)).Page[0]

            foreach ($name in @('Id', 'Title', 'Heading', 'Subheading', 'XamlPath', 'Skip', 'Validate', 'Collect')) {
                $page.PSObject.Properties[$name] | Should -Not -BeNullOrEmpty -Because $name
            }
        }

        It 'uses the id when a page declared no title' {
            $definition = "schemaVersion: 1`npages:`n  - id: Summary`n    reference: Summary.xaml`n"

            $wizard = Import-HDTWizardDocument -Provider (New-HDTWizardTestProvider -Definition $definition)

            [string] @($wizard.Page)[0].Title | Should -BeExactly 'Summary'
        }

        It 'carries the validation a page declared' {
            $wizard = Import-HDTWizardDocument -Provider (New-HDTWizardTestProvider)

            [string] @($wizard.Page)[0].Validate.Rule | Should -BeExactly 'ComputerName'
            [string] @($wizard.Page)[0].Validate.Control | Should -BeExactly 'HDTComputerNameBox'
        }

        It 'carries the summary a page declared' {
            $wizard = Import-HDTWizardDocument -Provider (New-HDTWizardTestProvider)

            [string] @($wizard.Page)[1].Summary.RowControl | Should -BeExactly 'HDTSummaryList'
        }

        It 'carries what a page collects' {
            $wizard = Import-HDTWizardDocument -Provider (New-HDTWizardTestProvider)

            [string] @(@($wizard.Page)[0].Collect)[0].Variable | Should -BeExactly 'HDTComputerName'
        }
    }

    Context 'a definition that is wrong' {

        It 'refuses markup that is not there, naming the page and the file' {
            # BEFORE A TECHNICIAN IS LOOKING AT A HALF-BUILT WINDOW. The shell
            # checks every page before showing the first for the same reason;
            # this catches it a step earlier, where the definition is.
            $record = $null
            try {
                Import-HDTWizardDocument -Provider (New-HDTWizardTestProvider -MissingPage 'Summary.xaml')
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*Summary*'
        }

        It 'refuses a definition that does not validate' {
            $definition = "schemaVersion: 1`npages:`n  - id: Summary`n"

            { Import-HDTWizardDocument -Provider (New-HDTWizardTestProvider -Definition $definition) } | Should -Throw
        }

        It 'refuses a definition that is not YAML' {
            { Import-HDTWizardDocument -Provider (New-HDTWizardTestProvider -Definition "pages: [`n") } | Should -Throw
        }

        It 'names the definition file in the message' {
            $definition = "schemaVersion: 1`npages:`n  - id: Summary`n"

            $record = $null
            try {
                Import-HDTWizardDocument -Provider (New-HDTWizardTestProvider -Definition $definition)
            } catch {
                $record = $_
            }

            $record.Exception.Message | Should -BeLike '*wizard.yaml*'
        }
    }
}
