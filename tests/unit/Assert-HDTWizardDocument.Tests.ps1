# THE WIZARD DEFINITION, VALIDATED - MDT'S DeployWiz_Definition_ENU.xml.
#
# MDT lists one <Pane id= reference= /> per screen with a <Condition> deciding
# whether it appears; PSD's Classic_Theme_Definitions_en-US.xml lists the same
# panes the same way. This is that file in HDT's YAML, and the condition is
# reduced to the thing every MDT condition actually tests: a Skip variable.
#
# A SHARE WITH NO wizard.yaml HAS NO WIZARD. That is what keeps every image
# built before this existed deploying with nobody present, and it is why the
# document being absent is never an error - only a document that is THERE and
# WRONG is.
#
# IT IS AUTHORED CONTENT ON A SHARE, so it is validated like one. A reference
# that could name a rooted path or climb out with '..' would be a definition
# file that reads markup from anywhere on the machine.
#
# It is private, so every assertion runs inside InModuleScope, and every
# rejection is asserted to name THE FILE and THE OFFENDING KEY - a validator
# that rejects the right file with the wrong sentence sends an administrator
# looking in the wrong place.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:wizardFixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/wizard'
    $script:wizardPath = 'C:\Share\Scripts\UI\wizard.yaml'

    $script:fixture = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $script:wizardFixtureRoot -Filter '*.yaml' -File)) {
        $script:fixture[$file.Name] = Get-Content -LiteralPath $file.FullName -Raw
    }

    # The rejection, or $null when the document was accepted.
    function Get-HDTWizardRejection {
        [CmdletBinding()]
        [OutputType([System.Management.Automation.ErrorRecord])]
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string] $Yaml
        )

        $record = $null
        try {
            InModuleScope Hephaestus -Parameters @{ Yaml = $Yaml; Path = $script:wizardPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path
                Assert-HDTWizardDocument -Document $document -Path $Path
            }
        } catch {
            $record = $_
        }

        return $record
    }

    # One page, with whatever the test needs bolted on. Written as YAML because
    # that is what an administrator writes and what the parser produces.
    function New-HDTWizardYaml {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a string in a test; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowEmptyString()]
            [string] $Page = "  - id: Summary`n    reference: Summary.xaml`n"
        )

        return "schemaVersion: 1`npages:`n{0}" -f $Page
    }
}

Describe 'Assert-HDTWizardDocument' {

    Context 'what it accepts' {

        It 'accepts <_>' -ForEach @('valid-minimal.yaml', 'valid-full.yaml') {
            Get-HDTWizardRejection -Yaml $script:fixture[$_] | Should -BeNullOrEmpty
        }

        It 'accepts an empty page list, which means no wizard' {
            # A site that wants the file present and the wizard off should not
            # have to delete it.
            Get-HDTWizardRejection -Yaml "schemaVersion: 1`npages: []`n" | Should -BeNullOrEmpty
        }

        It 'accepts a page with no skip, which HDTSkipWizard still hides' {
            Get-HDTWizardRejection -Yaml (New-HDTWizardYaml) | Should -BeNullOrEmpty
        }

        It 'accepts a reference in a subfolder, as PSD themes have' {
            Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page "  - id: Summary`n    reference: Classic\Summary.xaml`n") |
                Should -BeNullOrEmpty
        }
    }

    Context 'the document itself' {

        It 'rejects a missing schemaVersion' {
            (Get-HDTWizardRejection -Yaml "pages: []`n").Exception.Message | Should -BeLike '*schemaVersion*'
        }

        It 'rejects a schemaVersion newer than this engine' {
            Get-HDTWizardRejection -Yaml "schemaVersion: 99`npages: []`n" | Should -Not -BeNullOrEmpty
        }

        It 'rejects a missing pages key' {
            (Get-HDTWizardRejection -Yaml "schemaVersion: 1`n").Exception.Message | Should -BeLike '*pages*'
        }

        It 'rejects an unknown root key and names it' {
            (Get-HDTWizardRejection -Yaml "schemaVersion: 1`npages: []`npanes: []`n").Exception.Message |
                Should -BeLike '*panes*'
        }

        It 'names the file in every message' {
            (Get-HDTWizardRejection -Yaml "pages: []`n").Exception.Message | Should -BeLike ('*{0}*' -f $script:wizardPath)
        }
    }

    Context 'a page' {

        It 'rejects a page with no id' {
            (Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page "  - reference: Summary.xaml`n")).Exception.Message |
                Should -BeLike '*id*'
        }

        It 'rejects a page with no reference, because a page with no markup is not a page' {
            (Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page "  - id: Summary`n")).Exception.Message |
                Should -BeLike '*reference*'
        }

        It 'rejects two pages with the same id' {
            # The id is what a skip variable and a summary row are keyed on.
            $page = "  - id: Summary`n    reference: a.xaml`n  - id: Summary`n    reference: b.xaml`n"

            (Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page $page)).Exception.Message | Should -BeLike '*Summary*'
        }

        It 'rejects an unknown key on a page and names it' {
            $page = "  - id: Summary`n    reference: a.xaml`n    condition: yes`n"

            (Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page $page)).Exception.Message | Should -BeLike '*condition*'
        }
    }

    Context 'the reference, which names a file on a share' {

        It 'rejects <_>, because a definition must not read markup from anywhere on the machine' -ForEach @(
            'C:\Windows\evil.xaml', '..\..\evil.xaml', '\rooted.xaml', 'sub\..\..\evil.xaml') {

            $page = "  - id: Summary`n    reference: '{0}'`n" -f $PSItem

            Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page $page) | Should -Not -BeNullOrEmpty
        }

        It 'rejects a reference that is not markup' {
            # The engine parses it as XAML; a .ps1 here would be a definition
            # file naming a script to run.
            $page = "  - id: Summary`n    reference: Summary.ps1`n"

            Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page $page) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'what a page collects' {

        It 'rejects a collect entry with no variable' {
            $page = "  - id: A`n    reference: a.xaml`n    collect:`n      - control: HDTNameBox`n"

            (Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page $page)).Exception.Message | Should -BeLike '*variable*'
        }

        It 'rejects a variable outside the HDT namespace' {
            # Everything the engine resolves is HDT-prefixed (DESIGN 3), and a
            # definition on a share must not be able to set anything else.
            $page = "  - id: A`n    reference: a.xaml`n    collect:`n      - control: HDTNameBox`n        variable: PATH`n"

            Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page $page) | Should -Not -BeNullOrEmpty
        }

        It 'rejects a property the host cannot read' {
            $page = "  - id: A`n    reference: a.xaml`n    collect:`n      - control: HDTNameBox`n        variable: HDTComputerName`n        property: Content`n"

            Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page $page) | Should -Not -BeNullOrEmpty
        }

        It 'rejects a split with no splitVariable to put the other half in' {
            $page = "  - id: A`n    reference: a.xaml`n    collect:`n      - control: HDTAccountBox`n        variable: HDTDomainAdmin`n        split: AccountName`n"

            (Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page $page)).Exception.Message | Should -BeLike '*splitVariable*'
        }

        It 'rejects a splitter this engine does not implement, and names it' {
            $page = "  - id: A`n    reference: a.xaml`n    collect:`n      - control: HDTAccountBox`n        variable: HDTDomainAdmin`n        split: NoSuchSplit`n        splitVariable: HDTDomainAdminDomain`n"

            (Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page $page)).Exception.Message | Should -BeLike '*NoSuchSplit*'
        }
    }

    Context 'validation and the summary' {

        It 'rejects a rule this engine does not implement, rather than ignoring it' {
            # A control that silently never validates looks, on a bench, like a
            # wizard that accepts anything.
            $page = "  - id: A`n    reference: a.xaml`n    validate:`n      control: HDTNameBox`n      rule: NoSuchRule`n"

            (Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page $page)).Exception.Message | Should -BeLike '*NoSuchRule*'
        }

        It 'rejects a validate block with no control' {
            $page = "  - id: A`n    reference: a.xaml`n    validate:`n      rule: ComputerName`n"

            (Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page $page)).Exception.Message | Should -BeLike '*control*'
        }

        It 'rejects a summary block with no row control to fill' {
            $page = "  - id: A`n    reference: a.xaml`n    summary:`n      snippetControl: HDTSummarySnippet`n"

            (Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page $page)).Exception.Message | Should -BeLike '*rowControl*'
        }

        It 'rejects two summary pages, because there is one file to hand over' {
            $page = "  - id: A`n    reference: a.xaml`n    summary:`n      rowControl: HDTSummaryList`n  - id: B`n    reference: b.xaml`n    summary:`n      rowControl: HDTSummaryList`n"

            Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page $page) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the skip variable' {

        It 'rejects a skip name outside the HDT namespace' {
            # MDT's own property is SkipComputerName; HDT's is HDTSkipComputerName,
            # and a definition that used MDT's spelling would silently never skip.
            $page = "  - id: A`n    reference: a.xaml`n    skip: SkipComputerName`n"

            Get-HDTWizardRejection -Yaml (New-HDTWizardYaml -Page $page) | Should -Not -BeNullOrEmpty
        }
    }
}
