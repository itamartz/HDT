# WHAT A TECHNICIAN TYPED, AND THE FACT THAT THEY TYPED IT.
#
# DESIGN 11.2: "Every value the wizard collects enters the variable engine as the
# command-line/wizard source - the highest precedence in 3.1 - and is recorded in
# provenance like any other, so the report can say a name was TYPED rather than
# DERIVED."
#
# It could not, until now. The closed set of sources was CommandLine,
# MachineOverride, Rule, RuleScript, GatheredFact and SequenceDefault, so a
# wizard value had nowhere to enter that said where it came from.
#
# WHY NOT REUSE CommandLine. They arrive the same way and win over the same
# things, but they answer different questions afterwards. "Somebody typed this
# at the bench" and "the media was launched with this on its command line" are
# different explanations for a machine's name, and DESIGN 3.1's whole purpose is
# that provenance answers "why did HDTComputerName end up like that" - the single
# biggest debugging pain in MDT.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # Through the real importer and a fake file system, so the document is the
    # shape Resolve-HDTVariable actually consumes rather than a hand-built one.
    $script:rulesPath = 'C:\HDTLab\does-not-exist\ws\rules.yaml'
    $script:rules = Import-HDTRuleDocument -Path $script:rulesPath -FileSystem (New-HDTFakeFileSystem -File @{
            $script:rulesPath = @'
schemaVersion: 1
rules:
  - name: Fallback
    set:
      HDTComputerName: PC-FROM-A-RULE
      HDTTaskSequenceID: STD-CLIENT
'@
        })
}

Describe 'the wizard as a variable source' {

    Context 'it exists at all' {

        It 'is a source Resolve-HDTVariable accepts' {
            (Get-Command -Name 'Resolve-HDTVariable').Parameters.ContainsKey('Wizard') | Should -BeTrue
        }
    }

    Context 'what it beats' {

        It 'beats a rule, because a technician standing at the machine outranks a guess' {
            $resolution = Resolve-HDTVariable -RuleDocument $script:rules -Wizard @{ HDTComputerName = 'HDT-LAB-01' }

            [string] $resolution.Variable['HDTComputerName'] | Should -BeExactly 'HDT-LAB-01'
        }

        It 'beats a per-machine override' {
            $resolution = Resolve-HDTVariable -RuleDocument $script:rules `
                -MachineOverride @{ HDTComputerName = 'PC-FROM-THE-OVERRIDE' } `
                -Wizard @{ HDTComputerName = 'HDT-LAB-01' }

            [string] $resolution.Variable['HDTComputerName'] | Should -BeExactly 'HDT-LAB-01'
        }

        It 'leaves alone what it did not collect' {
            $resolution = Resolve-HDTVariable -RuleDocument $script:rules -Wizard @{ HDTComputerName = 'HDT-LAB-01' }

            [string] $resolution.Variable['HDTTaskSequenceID'] | Should -BeExactly 'STD-CLIENT'
        }
    }

    Context 'what beats it' {

        It 'loses to the command line, because a wizard cannot have run before the media was launched' {
            # THE ORDER IS NOT ARBITRARY. A command line is set before the
            # machine booted; the wizard answers a question that was still open
            # after it did. Where both speak, the one that could not have known
            # about the other yields.
            $resolution = Resolve-HDTVariable -RuleDocument $script:rules `
                -CommandLine @{ HDTComputerName = 'PC-FROM-THE-COMMAND-LINE' } `
                -Wizard @{ HDTComputerName = 'HDT-LAB-01' }

            [string] $resolution.Variable['HDTComputerName'] | Should -BeExactly 'PC-FROM-THE-COMMAND-LINE'
        }
    }

    Context 'the provenance, which is the whole point' {

        It 'records that the value was typed rather than derived' {
            $resolution = Resolve-HDTVariable -RuleDocument $script:rules -Wizard @{ HDTComputerName = 'HDT-LAB-01' }

            # Provenance is keyed by variable name, not a list.
            $record = $resolution.Provenance['HDTComputerName']

            $record | Should -Not -BeNullOrEmpty
            [string] $record.Name | Should -BeExactly 'HDTComputerName'
            [string] $record.Source | Should -BeExactly 'Wizard'
        }

        It 'is a source of its own, not the command line wearing a disguise' {
            $resolution = Resolve-HDTVariable -RuleDocument $script:rules -Wizard @{ HDTComputerName = 'HDT-LAB-01' }

            [string] $resolution.Provenance['HDTComputerName'].Source |
                Should -Not -BeExactly 'CommandLine'
        }

        It 'still records the rule that would have supplied it, for the variable it did not touch' {
            $resolution = Resolve-HDTVariable -RuleDocument $script:rules -Wizard @{ HDTComputerName = 'HDT-LAB-01' }

            [string] $resolution.Provenance['HDTTaskSequenceID'].Source |
                Should -BeExactly 'Rule'
        }
    }

    Context 'nothing collected' {

        It 'changes nothing when the wizard was never shown' {
            $resolution = Resolve-HDTVariable -RuleDocument $script:rules -Wizard @{}

            [string] $resolution.Variable['HDTComputerName'] | Should -BeExactly 'PC-FROM-A-RULE'
        }

        It 'changes nothing when there is no wizard at all' {
            $resolution = Resolve-HDTVariable -RuleDocument $script:rules

            [string] $resolution.Variable['HDTComputerName'] | Should -BeExactly 'PC-FROM-A-RULE'
        }

        It 'ignores a value the technician left empty, so a blank box does not beat a rule' {
            # AN EMPTY BOX IS NOT AN ANSWER. Collected as '', it would RESOLVE
            # the variable and stop the rule that would have supplied a real one -
            # the same trap the summary snippet refuses to write.
            $resolution = Resolve-HDTVariable -RuleDocument $script:rules -Wizard @{ HDTComputerName = '' }

            [string] $resolution.Variable['HDTComputerName'] | Should -BeExactly 'PC-FROM-A-RULE'
        }

        It 'ignores a value that is only whitespace' {
            $resolution = Resolve-HDTVariable -RuleDocument $script:rules -Wizard @{ HDTComputerName = '   ' }

            [string] $resolution.Variable['HDTComputerName'] | Should -BeExactly 'PC-FROM-A-RULE'
        }

        It 'keeps a deliberate false, which is a value and not a blank' {
            $resolution = Resolve-HDTVariable -RuleDocument $script:rules -Wizard @{ HDTSkipSummary = $false }

            $resolution.Variable['HDTSkipSummary'] | Should -BeFalse
        }
    }
}
