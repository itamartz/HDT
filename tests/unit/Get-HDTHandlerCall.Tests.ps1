# THE DOOR A PRIVATE HELPER COMES THROUGH INTO A WINDOW HANDLER.
#
# Every handler in the console is a closure, and .GetNewClosure() rebinds a
# scriptblock to the session state of whoever called the method it was made in -
# the caller's, not the module's. So a command named inside a handler is resolved
# in the console's scope, and only an exported function resolves there. That is
# the whole reason thirty-three view-model helpers used to sit in
# FunctionsToExport: not a decision about the public surface, a side effect of
# how the handlers are built.
#
# A SCRIPTBLOCK MADE INSIDE THE MODULE KEEPS THE MODULE'S SESSION STATE, and a
# closure that captured it as a variable calls straight through it. That is what
# this returns, and it is the only thing standing between the console's helpers
# and Get-Command.
#
# Rebinding the handler instead - $module.NewBoundScriptBlock() - was tried and
# does not work: it returns a scriptblock with the module's command resolution
# and none of the variables the closure captured, which for a handler is
# everything it had.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTHandlerCall' {

    It 'is not exported' {
        Get-Command -Name Get-HDTHandlerCall -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'answers with a scriptblock' {
        InModuleScope Hephaestus {
            Get-HDTHandlerCall | Should -BeOfType ([scriptblock])
        }
    }

    It 'calls a command that takes no arguments' {
        InModuleScope Hephaestus {
            $call = Get-HDTHandlerCall
            $theme = & $call 'Get-HDTConsoleTheme'

            @($theme.Keys).Count | Should -BeGreaterThan 0
        }
    }

    It 'passes named parameters through' {
        InModuleScope Hephaestus {
            $call = Get-HDTHandlerCall
            $composed = & $call 'New-HDTApplicationName' -Publisher 'Igor Pavlov' -Name '7-Zip' -Version '24.09'

            [string] $composed.Id | Should -BeExactly 'Igor-Pavlov-7-Zip-24.09'
        }
    }

    # THE ONE THAT REACHED A WINDOW. -Dirty:$book.Dirty is parsed against this
    # scriptblock, not against the command, so the name and the value arrived as
    # two loose arguments and the value bound positionally. The editor opened on
    # "a positional parameter cannot be found that accepts argument 'False'".
    It 'binds a switch that arrives in a hashtable' {
        InModuleScope Hephaestus {
            $call = Get-HDTHandlerCall

            $asked = & $call 'Get-HDTConsoleClosePrompt' @{ DocumentPath = 'C:\ws\TaskSequences\DEMO\sequence.yaml'; Dirty = $true }
            $clean = & $call 'Get-HDTConsoleClosePrompt' @{ DocumentPath = 'C:\ws\TaskSequences\DEMO\sequence.yaml'; Dirty = $false }

            [bool] $asked.Ask | Should -BeTrue
            [bool] $clean.Ask | Should -BeFalse
        }
    }

    It 'still takes loose named arguments when no switch is involved' {
        InModuleScope Hephaestus {
            $call = Get-HDTHandlerCall
            $composed = & $call 'New-HDTApplicationName' -Name 'Contoso Suite'

            [string] $composed.Id | Should -BeExactly 'Contoso-Suite'
        }
    }
    # The point of the whole exercise: this has to work from inside a closure
    # that a caller outside the module set running, because that is what a
    # button click is.
    It 'reaches a private command from a closure rebound to the caller' {
        $module = Get-Module -Name Hephaestus
        $service = & $module {
            $service = [pscustomobject] @{}
            $service | Add-Member -MemberType ScriptMethod -Name Compose -Value {
                $call = Get-HDTHandlerCall
                $handler = {
                    [string] (& $call 'New-HDTApplicationName' -Name 'Contoso Suite').Id
                }.GetNewClosure()

                & $handler
            }
            $service
        }

        $service.Compose() | Should -BeExactly 'Contoso-Suite'
    }

    It 'is the only thing that makes that work' {
        # Without the door, the same closure cannot see the same command. This
        # is the failure the console would have shipped with.
        $module = Get-Module -Name Hephaestus
        $service = & $module {
            $service = [pscustomobject] @{}
            $service | Add-Member -MemberType ScriptMethod -Name Compose -Value {
                $handler = {
                    [string] (New-HDTApplicationName -Name 'Contoso Suite').Id
                }.GetNewClosure()

                & $handler
            }
            $service
        }

        { $service.Compose() } | Should -Throw '*New-HDTApplicationName*'
    }
}
