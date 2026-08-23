# What the Options tab can offer instead of a blank box.
#
# THE CONDITION GRAMMAR IS CLOSED AND TINY - %Var% then == / != / -like /
# -notlike then a value - so the set of legal conditions is enumerable, and a
# free-text box is the worst possible way to enter one. It accepts
# '%HDTIsUEFI% = true', which is not the grammar, and Assert-HDTSequenceDocument
# refuses the document at import: the mistake is found at the far end, by
# somebody who did not make it.
#
# A picker cannot spell it wrong. This is the list it picks from.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    $script:option = Get-HDTConsoleConditionOption
}

Describe 'Get-HDTConsoleConditionOption' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTConsoleConditionOption' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'the variables' {

        It 'offers every variable the engine knows about' {
            # Get-HDTVariableMap IS THE SOURCE, not a second list. A picker with
            # its own idea of what exists is a picker that goes stale the first
            # time a variable is added.
            @($script:option.Variable).Count | Should -Be @(Get-HDTVariableMap).Count
        }

        It 'gives each one the token a condition actually contains' {
            # %HDTIsUEFI%, not HDTIsUEFI. The percent signs are the substitution;
            # a condition without them compares the literal text 'HDTIsUEFI' to
            # 'True' and is quietly always false.
            $row = @($script:option.Variable | Where-Object { $_.Name -eq 'HDTIsUEFI' })[0]

            $row.Token | Should -BeExactly '%HDTIsUEFI%'
        }

        It 'carries the description, so a picker is not a list of 50 names' {
            @($script:option.Variable | Where-Object { $_.Name -eq 'HDTIsUEFI' })[0].Description |
                Should -BeLike '*UEFI*'
        }
    }

    Context 'the operators' {

        It 'offers exactly what the grammar accepts' {
            # THE CLOSED SET, from Test-HDTStepCondition: == != -like -notlike.
            # Offering '=' or '-contains' would produce a document the importer
            # refuses, which is the failure this list exists to prevent.
            @($script:option.Operator | ForEach-Object { $_.Token }) |
                Should -Be @('==', '!=', '-like', '-notlike')
        }

        It 'says what each one means in words' {
            @($script:option.Operator | Where-Object { $_.Token -eq '!=' })[0].Display |
                Should -BeLike '*not*'
        }
    }

    Context 'the values worth suggesting' {

        It 'suggests True and False for <_>' -ForEach @('HDTIsUEFI', 'HDTIsVM', 'HDTIsLaptop',
            'HDTIsDesktop', 'HDTIsServer', 'HDTSecureBootEnabled') {

            # THE ONES AN ADMIN ACTUALLY BRANCHES ON. A boolean fact compared
            # against a typed 'yes' is a step that never runs, and nothing says
            # so - the condition is legal, it is simply never true.
            #
            # THE WANTED NAME IS COPIED OUT OF $_ FIRST. Inside Where-Object,
            # $_ is the pipeline item, not the -ForEach one - so `$_.Name -eq $_`
            # compares a row to itself, matches nothing, and the test passes
            # having asserted nothing at all. It did exactly that here.
            $wanted = $_

            $row = @($script:option.Variable | Where-Object { $_.Name -eq $wanted })

            @($row).Count | Should -Be 1
            @($row[0].Suggested) | Should -Be @('True', 'False')
        }

        It 'suggests PXE and Media for the boot mode' {
            $row = @($script:option.Variable | Where-Object { $_.Name -eq 'HDTBootMode' })[0]

            @($row.Suggested) | Should -Be @('PXE', 'Media')
        }

        It 'suggests nothing for a variable with no fixed set' {
            # A computer name has no list. An empty Suggested is what tells the
            # window to leave the value box free rather than offering a wrong
            # menu.
            $row = @($script:option.Variable | Where-Object { $_.Name -eq 'HDTComputerName' })[0]

            @($row.Suggested).Count | Should -Be 0
        }
    }

    Context 'composing one' {

        It 'writes the condition the engine will read' {
            $script:option.Format | Should -BeExactly '{0} {1} {2}'
        }

        It 'produces something Test-HDTStepCondition agrees with' {
            # THE ROUND TRIP, AND THE ONLY ASSERTION HERE THAT MATTERS. A picker
            # whose output the engine does not accept is worse than a text box,
            # because it looks authoritative.
            $token = @($script:option.Variable | Where-Object { $_.Name -eq 'HDTIsUEFI' })[0].Token
            $condition = $script:option.Format -f $token, '==', 'True'

            $condition | Should -BeExactly '%HDTIsUEFI% == True'

            Test-HDTStepCondition -Condition $condition -Variable @{ HDTIsUEFI = $true } |
                Should -BeTrue

            Test-HDTStepCondition -Condition $condition -Variable @{ HDTIsUEFI = $false } |
                Should -BeFalse
        }

        It 'produces a working condition for every operator it offers' {
            $token = '%HDTModel%'

            foreach ($operator in @($script:option.Operator)) {
                $condition = $script:option.Format -f $token, $operator.Token, 'Virtual*'

                # The point is that the engine PARSES each one - what it answers
                # depends on the operator, and both answers are legitimate.
                { Test-HDTStepCondition -Condition $condition -Variable @{ HDTModel = 'Virtual Machine' } } |
                    Should -Not -Throw
            }
        }
    }
}


}
