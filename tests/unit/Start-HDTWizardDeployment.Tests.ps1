# W5 OF .planning/WPF-FIRST.md: "summary, and a Deploy button - the wizard hands
# the engine a resolved variable set".
#
# THE HANDOFF WAS SITTING IN THE ENTRY POINT. Start-HDTDeployment.ps1 read the
# answer, decided whether it was consent, put the typed values back through
# Resolve-HDTVariable and copied the result into a case-insensitive dictionary -
# four decisions in a file whose own test asserts it contains no deployment
# logic. This is that handoff, where it can be asserted.
#
# THE SECOND RESOLUTION IS THE WHOLE POINT AND IS NOT A PATCH. A typed name
# cannot be written over the resolved set afterwards: that would set values with
# no provenance and no precedence, which is what DESIGN 3.1 exists to prevent.
# It goes back through the resolver as the Wizard source, so a typed name beats
# the rule that guessed one, a rule still wins where a box was left empty, and
# the provenance says which happened.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # A rules document that names a machine and a sequence, so the second
    # resolution has something to be beaten by.
    $script:rulesYaml = @'
schemaVersion: 1
rules:
  - name: Everything
    set:
      HDTComputerName: RULE-NAME
      HDTTaskSequenceID: RULE-TS
      HDTTimeZoneName: GMT Standard Time
'@

    $script:newArgument = {
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\rules.yaml' = $script:rulesYaml }
        $document = Import-HDTRuleDocument -Path 'C:\ws\rules.yaml' -FileSystem $fs

        return @{
            RuleDocument  = $document
            Fact          = ([ordered] @{ HDTSerialNumber = '8CG2401XYZ' })
            ScriptInvoker = (New-HDTFakeScriptInvoker)
        }
    }

    $script:newAnswer = {
        param([string] $Action, [System.Collections.IDictionary] $Value)

        $bag = @{}
        if ($null -ne $Value) {
            foreach ($key in @($Value.Keys)) { $bag[[string] $key] = $Value[$key] }
        }

        return [pscustomobject] @{ Action = $Action; Value = $bag }
    }
}

Describe 'Start-HDTWizardDeployment' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Start-HDTWizardDeployment' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'what the technician pressed' {

        It 'reports Deploy for Next' {
            $answer = Start-HDTWizardDeployment -Answer (& $script:newAnswer 'Next' $null) `
                -ResolveArgument (& $script:newArgument)

            [string] $answer.Action | Should -BeExactly 'Deploy'
        }

        It 'reports Cancel for Cancel' {
            $answer = Start-HDTWizardDeployment -Answer (& $script:newAnswer 'Cancel' $null) `
                -ResolveArgument (& $script:newArgument)

            [string] $answer.Action | Should -BeExactly 'Cancel'
        }

        It 'reports CommandPrompt for CommandPrompt' {
            # The caller opens the prompt and decides what the machine does
            # next; this only says what was asked for.
            $answer = Start-HDTWizardDeployment -Answer (& $script:newAnswer 'CommandPrompt' $null) `
                -ResolveArgument (& $script:newArgument)

            [string] $answer.Action | Should -BeExactly 'CommandPrompt'
        }

        It 'treats anything else as a cancel' {
            # A DISMISSED WINDOW IS NOT CONSENT TO PARTITION A DISK, and the
            # same allow-list the shell holds is held again here: this is the
            # last gate before a disk is wiped.
            $answer = Start-HDTWizardDeployment -Answer (& $script:newAnswer 'Closed' $null) `
                -ResolveArgument (& $script:newArgument)

            [string] $answer.Action | Should -BeExactly 'Cancel'
        }

        It 'resolves nothing at all when it was not consent' {
            $answer = Start-HDTWizardDeployment -Answer (& $script:newAnswer 'Cancel' ([ordered] @{ HDTComputerName = 'TYPED' })) `
                -ResolveArgument (& $script:newArgument)

            @($answer.Variable.Keys) | Should -BeNullOrEmpty
        }
    }

    Context 'the variable set it hands over' {

        It 'carries what the rules resolved when the wizard typed nothing' {
            $answer = Start-HDTWizardDeployment -Answer (& $script:newAnswer 'Next' $null) `
                -ResolveArgument (& $script:newArgument)

            [string] $answer.Variable['HDTComputerName'] | Should -BeExactly 'RULE-NAME'
        }

        It 'lets a typed value beat the rule that guessed one' {
            $answer = Start-HDTWizardDeployment `
                -Answer (& $script:newAnswer 'Next' ([ordered] @{ HDTComputerName = 'TYPED-NAME' })) `
                -ResolveArgument (& $script:newArgument)

            [string] $answer.Variable['HDTComputerName'] | Should -BeExactly 'TYPED-NAME'
        }

        It 'leaves the rule alone where the box was empty' {
            $answer = Start-HDTWizardDeployment `
                -Answer (& $script:newAnswer 'Next' ([ordered] @{ HDTComputerName = 'TYPED-NAME' })) `
                -ResolveArgument (& $script:newArgument)

            [string] $answer.Variable['HDTTaskSequenceID'] | Should -BeExactly 'RULE-TS'
        }

        It 'says a wizard value was applied, and which' {
            $answer = Start-HDTWizardDeployment `
                -Answer (& $script:newAnswer 'Next' ([ordered] @{ HDTComputerName = 'TYPED-NAME' })) `
                -ResolveArgument (& $script:newArgument)

            @($answer.Applied) | Should -Be @('HDTComputerName')
        }

        It 'reads back case-insensitively, as every variable bag in this engine does' {
            $answer = Start-HDTWizardDeployment -Answer (& $script:newAnswer 'Next' $null) `
                -ResolveArgument (& $script:newArgument)

            [string] $answer.Variable['hdtcomputername'] | Should -BeExactly 'RULE-NAME'
        }

        It 'keeps the provenance, because the summary and the log both need it' {
            $answer = Start-HDTWizardDeployment `
                -Answer (& $script:newAnswer 'Next' ([ordered] @{ HDTComputerName = 'TYPED-NAME' })) `
                -ResolveArgument (& $script:newArgument)

            $answer.Resolved | Should -Not -BeNullOrEmpty
            [string] $answer.Resolved.Provenance['HDTComputerName'].Source | Should -BeExactly 'Wizard'
        }

        It 'does not modify the argument it was handed' {
            # The caller's hashtable is reused for logging and for a retry, and
            # a command that quietly added Wizard to it would resolve the second
            # attempt with the first attempt's answers.
            $argument = & $script:newArgument

            Start-HDTWizardDeployment -Answer (& $script:newAnswer 'Next' ([ordered] @{ HDTComputerName = 'TYPED' })) `
                -ResolveArgument $argument | Out-Null

            $argument.ContainsKey('Wizard') | Should -BeFalse
        }
    }
}
