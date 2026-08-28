# A VALIDATION RULE, AGAINST EVERY SURFACE THAT HAS TO KNOW ABOUT IT.
#
# CLAUDE.md RULE 8, FOR THE ONE THING THE DOCUMENT VALIDATOR IS NAMED IN: "a new
# rule name is REJECTED until it is listed there". There are four lists, they are
# in four files, and all four have to say the same thing:
#
#   the shipped wizard.yaml        what a page actually declares
#   Assert-HDTWizardDocument       what runs in WinPE, where Test-Json does not
#   schemas/wizard.schema.json     the published contract a console or CI drives
#   Show-HDTWizardShell            the only place a rule name becomes a validator
#
# THEY HAD DRIFTED APART THREE WAYS AT ONCE. The schema's enum still read
# ["ComputerName"] alone while the shipped AdminPassword page had been declaring
# rule: AdminPassword for a release, and TaskSequence was added to the document
# and the engine in the same change. A page whose rule is missing from the
# engine's list is refused outright and the wizard does not open; a page whose
# rule is missing from the SCHEMA is accepted by the engine and refused by
# everything else, which is worse, because the file is on a share by then.
#
# NOTHING HERE HOLDS A LIST. The rules are read out of the shipped document, out
# of the schema's own enum, and out of the two engine refusals - both of which
# name their known set in the message, which is what makes the set enumerable
# from behaviour rather than from a copy of it written down in a test.

$script:HDTRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# DISCOVERY TIME, because the rules a shipped page declares become one test case
# each and Pester builds those before any BeforeAll has run.
Import-Module -Name powershell-yaml -ErrorAction Stop

$script:HDTWizardPath = Join-Path -Path $script:HDTRepoRoot -ChildPath 'src/Hephaestus/Templates/Wizard/wizard.yaml'
$script:HDTSchemaPath = Join-Path -Path $script:HDTRepoRoot -ChildPath 'schemas/wizard.schema.json'

$script:HDTWizardDocument = ConvertFrom-Yaml -Yaml ([System.IO.File]::ReadAllText($script:HDTWizardPath)) -Ordered

# WHAT THE SHIPPED PAGES ACTUALLY DECLARE, off the parsed document.
$script:HDTDeclaredRule = @(@($script:HDTWizardDocument['pages']) | ForEach-Object {
        if ($null -eq $_) { return }
        if (-not $_.Contains('validate')) { return }
        if ($null -eq $_['validate']) { return }
        if (-not $_['validate'].Contains('rule')) { return }

        [string] $_['validate']['rule']
    } | Sort-Object -Unique)

$script:HDTDeclaredRuleCase = @($script:HDTDeclaredRule | ForEach-Object { @{ Rule = $_ } })

$script:HDTSchemaRule = @(([System.IO.File]::ReadAllText($script:HDTSchemaPath) |
            ConvertFrom-Json).properties.pages.items.properties.validate.properties.rule.enum |
        ForEach-Object { [string] $_ } | Sort-Object -Unique)

# WHAT DISCOVERY READ, CARRIED INTO THE TESTS AS DATA. A $script: variable
# assigned while Pester is DISCOVERING is $null by the time a test RUNS, and
# @($null).Count is 1 - so a guard written the obvious way passes without ever
# seeing the list it claims to guard. Anything read off the shipped files here
# reaches an It through -ForEach or not at all.
$script:HDTSetCase = @(@{
        DeclaredRule = $script:HDTDeclaredRule
        SchemaRule   = $script:HDTSchemaRule
    })

Describe 'wizard validation rules, across every surface that names them' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

        # THE ENGINE'S OWN SET, READ OFF ITS REFUSAL. Assert-HDTWizardDocument
        # names every rule it implements in the message it throws, so the list
        # comes from the behaviour rather than from a second copy of it here.
        $script:HDTAssertRule = @(InModuleScope Hephaestus {

                $yaml = "schemaVersion: 1`npages:`n  - id: Probe`n    reference: probe.xaml`n    validate:`n      control: HDTProbeBox`n      rule: HDTNoSuchRuleExists`n"

                $message = ''
                try {
                    $document = ConvertFrom-HDTYaml -Yaml $yaml -Path 'C:\ws\Scripts\UI\wizard.yaml'
                    Assert-HDTWizardDocument -Document $document -Path 'C:\ws\Scripts\UI\wizard.yaml'
                } catch {
                    $message = [string] $_.Exception.Message
                }

                if ($message -notmatch 'The rules are (?<set>[^.]+)\.') { return @() }

                return @($Matches['set'] -split ',\s*')
            } | Sort-Object -Unique)

        # AND THE SHELL'S, THE SAME WAY. This is the list that decides whether a
        # rule name becomes a validator at all; a name only the document knows
        # is a control that silently never validates.
        $file = @{
            'X:\HDT\UI\HDTWizardShell.xaml' = [System.IO.File]::ReadAllText(
                (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/HDTWizardShell.xaml'))
            'X:\HDT\UI\Probe.xaml'          = '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" />'
        }

        $probePage = @([pscustomobject] @{
                Id       = 'Probe'
                Title    = 'Probe'
                XamlPath = 'X:\HDT\UI\Probe.xaml'
                Validate = [pscustomobject] @{ Control = 'HDTProbeBox'; Rule = 'HDTNoSuchRuleExists' }
            })

        $shellMessage = ''
        try {
            Show-HDTWizardShell -ShellXamlPath 'X:\HDT\UI\HDTWizardShell.xaml' -Page $probePage `
                -WizardHost (New-HDTFakeWizardHost -Action 'Cancel') `
                -FileSystem (New-HDTFakeFileSystem -File $file) | Out-Null
        } catch {
            $shellMessage = [string] $_.Exception.Message
        }

        $script:HDTShellRule = @()
        if ($shellMessage -match 'Known rules: (?<set>[^.]+)\.') {
            $script:HDTShellRule = @($Matches['set'] -split ',\s*' | Sort-Object -Unique)
        }
    }

    Context 'the sets are enumerable at all' -ForEach $script:HDTSetCase {

        # EVERY ASSERTION BELOW IS VACUOUS IF ONE OF THESE IS EMPTY - a refusal
        # message that stopped naming its set would turn this whole file green.
        It 'reads the rules the shipped pages declare' {
            @($DeclaredRule).Count | Should -BeGreaterThan 0
        }

        It 'reads the rules the schema allows' {
            @($SchemaRule).Count | Should -BeGreaterThan 0
        }

        It 'reads the rules Assert-HDTWizardDocument implements' {
            @($script:HDTAssertRule).Count | Should -BeGreaterThan 0
        }

        It 'reads the rules Show-HDTWizardShell can turn into a validator' {
            @($script:HDTShellRule).Count | Should -BeGreaterThan 0
        }
    }

    Context 'the four lists say the same thing' -ForEach $script:HDTSetCase {

        It 'lets the engine and the schema allow exactly the same rules' {
            (@($SchemaRule) -join ', ') | Should -BeExactly (@($script:HDTAssertRule) -join ', ')
        }

        It 'gives every rule the engine accepts a validator to run' {
            (@($script:HDTShellRule) -join ', ') | Should -BeExactly (@($script:HDTAssertRule) -join ', ')
        }

        It 'declares nothing on a shipped page that the other three do not carry' {
            @($DeclaredRule | Where-Object { @($SchemaRule) -notcontains $_ }) | Should -BeNullOrEmpty
            @($DeclaredRule | Where-Object { @($script:HDTAssertRule) -notcontains $_ }) | Should -BeNullOrEmpty
            @($DeclaredRule | Where-Object { @($script:HDTShellRule) -notcontains $_ }) | Should -BeNullOrEmpty
        }
    }

    Context 'and each one is really accepted, not merely listed' {

        It 'accepts a shipped page declaring the rule <Rule>' -ForEach $script:HDTDeclaredRuleCase {

            $record = InModuleScope Hephaestus -Parameters @{ Rule = $Rule } {
                param($Rule)

                # A CONFIRM CONTROL IS ONLY MEANINGFUL TO A RULE THAT COMPARES
                # TWO, and the shipped AdminPassword page declares one - so the
                # probe declares it for exactly that rule and no other, or the
                # validator's own refusal would fire instead of the rule being
                # judged.
                $confirm = ''
                if ($Rule -eq 'AdminPassword') { $confirm = "      confirm: HDTProbeConfirmBox`n" }

                $yaml = "schemaVersion: 1`npages:`n  - id: Probe`n    reference: probe.xaml`n    validate:`n      control: HDTProbeBox`n{0}      rule: {1}`n" -f $confirm, $Rule

                try {
                    $document = ConvertFrom-HDTYaml -Yaml $yaml -Path 'C:\ws\Scripts\UI\wizard.yaml'
                    Assert-HDTWizardDocument -Document $document -Path 'C:\ws\Scripts\UI\wizard.yaml'
                    return $null
                } catch {
                    return $_
                }
            }

            $record | Should -BeNullOrEmpty
        }
    }
}
