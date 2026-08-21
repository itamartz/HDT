# MDT'S #...# EXPRESSION, WHICH IS HOW A RULES FILE SHORTENS A NAME.
#
# CustomSettings.ini takes a VBScript expression between hashes:
#
#     OSDComputerName=#Left("PC-" & oEnvironment.Item("SerialNumber"), 15)#
#
# and every MDT deployment that builds a name from a serial number uses it,
# because Windows Setup SILENTLY IGNORES a ComputerName over 15 characters and
# names the machine itself. HDT refused such a name loudly (which is better than
# MDT) but gave an administrator no way to shorten one, so the only answer was a
# setFrom script - a PowerShell file, per naming pattern, for a substring.
#
# Found the hard way on 2026-08-21: a Hyper-V VM whose serial is a 32-character
# GUID produced 'PC-5784-6600-2634-7495-0127-2247-66', 35 characters, and the
# deployment stopped at Apply Windows Settings.
#
# A CLOSED SET OF FUNCTIONS, NOT AN EVALUATOR. MDT runs real VBScript in there.
# A rules file is a document an administrator is handed - by a colleague, by a
# vendor, in a support ticket - and one that can run arbitrary code is a document
# that can do anything the deployment account can. Real logic already has a home:
# setFrom names a script, and the engine runs it through IScriptInvoker.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path (Split-Path -Parent $script:repoRoot) -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:expand = {
        param([string] $Value)
        return (InModuleScope Hephaestus -Parameters @{ v = $Value } { Expand-HDTRuleExpression -Value $v })
    }
}

Describe 'Expand-HDTRuleExpression' {

    Context 'the four MDT deployments actually use' {

        It 'Left shortens a name to what Windows Setup will accept' {
            & $script:expand '#Left(PC-5784-6600-2634-7495-0127-2247-66, 15)#' |
                Should -BeExactly 'PC-5784-6600-26'
        }

        It 'Left leaves a value already short enough alone' {
            & $script:expand '#Left(PC-01, 15)#' | Should -BeExactly 'PC-01'
        }

        It 'Right takes the end, which is the half of a serial that varies' {
            & $script:expand '#Right(0127-2247-66, 8)#' | Should -BeExactly '-2247-66'
        }

        It 'UCase and LCase, because a naming standard is usually one or the other' {
            & $script:expand '#UCase(lt-0042)#' | Should -BeExactly 'LT-0042'
            & $script:expand '#LCase(LT-0042)#' | Should -BeExactly 'lt-0042'
        }

        It 'Mid counts from one, as VBScript does and as MDT users expect' {
            & $script:expand '#Mid(ABCDEF, 2, 3)#' | Should -BeExactly 'BCD'
        }

        It 'Trim, for a fact that arrived with whitespace on it' {
            & $script:expand '#Trim(  LT-0042  )#' | Should -BeExactly 'LT-0042'
        }
    }

    Context 'what it leaves alone' {

        It 'passes ordinary text through untouched' {
            & $script:expand 'PC-0042' | Should -BeExactly 'PC-0042'
        }

        # A HASH IS A COMMON CHARACTER. '#1' in a description, a colour, a
        # comment - a value is only an expression when a hash is followed by a
        # function name and a bracket, which is the same rule %Var% follows for
        # a batch file's %1.
        It 'leaves a hash that is not an expression where it is' {
            & $script:expand 'Bay #3, rack #12' | Should -BeExactly 'Bay #3, rack #12'
            & $script:expand '#not a call#' | Should -BeExactly '#not a call#'
        }

        It 'expands an expression sitting inside other text' {
            & $script:expand 'SITE-#Left(LONDON, 3)#-01' | Should -BeExactly 'SITE-LON-01'
        }

        It 'expands more than one in a value' {
            & $script:expand '#Left(ABCDEF, 2)##Right(123456, 2)#' | Should -BeExactly 'AB56'
        }
    }

    Context 'what it refuses, and how loudly' {

        # SILENTLY EMPTYING IT IS THE ONE UNACCEPTABLE ANSWER. That is how a
        # machine ends up named 'PC-' - which is exactly what the sibling
        # expander refuses to do with an unresolved token.
        It 'refuses a function it does not have' {
            { & $script:expand '#Eval(rm -rf, 1)#' } | Should -Throw -ExpectedMessage '*Eval*'
        }

        It 'names the functions it does have, so the message is actionable' {
            { & $script:expand '#Substring(ABC, 1)#' } | Should -Throw -ExpectedMessage '*Left*'
        }

        It 'refuses the wrong number of arguments' {
            { & $script:expand '#Left(ABC)#' } | Should -Throw -ExpectedMessage '*Left*'
        }

        It 'refuses a length that is not a number' {
            { & $script:expand '#Left(ABC, fifteen)#' } | Should -Throw -ExpectedMessage '*fifteen*'
        }

        It 'refuses a negative length rather than treating it as zero' {
            { & $script:expand '#Left(ABC, -1)#' } | Should -Throw
        }
    }

    Context 'the two together, which is how a rule is actually written' {

        # The % expansion runs first and the expression sees its result, so
        # '#Left(PC-%HDTSerialNumber%, 15)#' is what an administrator types.
        It 'shortens what the token expander produced' {
            $scope = @{ HDTSerialNumber = '5784-6600-2634-7495-0127-2247-66' }

            $answer = InModuleScope Hephaestus -Parameters @{ s = $scope } {
                Expand-HDTVariableToken -Value '#Left(PC-%HDTSerialNumber%, 15)#' -Scope $s
            }

            $answer | Should -BeExactly 'PC-5784-6600-26'
            $answer.Length | Should -BeLessOrEqual 15
        }
    }
}
