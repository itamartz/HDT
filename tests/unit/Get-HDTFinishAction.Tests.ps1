# What the machine does when the deployment is over (DESIGN 3.2, MDT's
# FinishAction).
#
# THE DEPLOYMENT USED TO END ON exit 0 AND STAY WHERE IT WAS. A machine that had
# just finished sat at a desktop, logged in as the local Administrator, until
# somebody walked over to it - which is the opposite of what a technician
# imaging a bench of twenty machines wants, and precisely why MDT has this
# property.
#
# THE DECISION IS PURE AND THE ACTION IS NOT. Everything about which power
# operation a value means is decided here, against no machine at all; the
# payload does nothing but call the service with the answer. That split is what
# lets the odd spellings, the unrecognised value and the WinPE case be asserted
# without a test ever being in a position to reboot the machine running it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTFinishAction' {

    Context 'the values MDT uses' {

        It 'reads REBOOT as a restart' {
            $action = Get-HDTFinishAction -Value 'REBOOT' -Environment FullOS

            $action.Action | Should -BeExactly 'Restart'
            $action.IsRecognised | Should -BeTrue
        }

        It 'reads SHUTDOWN as a stop' {
            (Get-HDTFinishAction -Value 'SHUTDOWN' -Environment FullOS).Action | Should -BeExactly 'Stop'
        }

        It 'reads LOGOFF as a logoff' {
            (Get-HDTFinishAction -Value 'LOGOFF' -Environment FullOS).Action | Should -BeExactly 'Logoff'
        }

        It 'reads an unset value as doing nothing' {
            # MDT's default, and the behaviour of every deployment that ran
            # before this variable existed.
            $action = Get-HDTFinishAction -Value '' -Environment FullOS

            $action.Action | Should -BeExactly 'None'
            $action.IsRecognised | Should -BeTrue
        }

        It 'reads a null value as doing nothing' {
            (Get-HDTFinishAction -Value $null -Environment FullOS).Action | Should -BeExactly 'None'
        }
    }

    Context 'the spellings a person actually types' {

        It 'reads a value case-insensitively' {
            (Get-HDTFinishAction -Value 'Reboot' -Environment FullOS).Action | Should -BeExactly 'Restart'
            (Get-HDTFinishAction -Value 'shutdown' -Environment FullOS).Action | Should -BeExactly 'Stop'
        }

        It 'trims the space around a value a YAML editor left behind' {
            (Get-HDTFinishAction -Value '  REBOOT  ' -Environment FullOS).Action | Should -BeExactly 'Restart'
        }

        It 'reads RESTART as REBOOT' {
            # The word this toolkit uses everywhere else for the same thing - a
            # Restart step, IPowerService.Restart. Somebody will write it.
            (Get-HDTFinishAction -Value 'RESTART' -Environment FullOS).Action | Should -BeExactly 'Restart'
        }

        It 'reads NONE as doing nothing' {
            (Get-HDTFinishAction -Value 'NONE' -Environment FullOS).Action | Should -BeExactly 'None'
        }
    }

    Context 'a value nobody meant' {

        It 'does nothing, rather than guessing' {
            # A TYPO MUST NOT POWER A MACHINE OFF. 'SHUTDONW' resolving to the
            # nearest match would take down a machine somebody was about to work
            # on, and every wrong guess here is silent and physical.
            $action = Get-HDTFinishAction -Value 'SHUTDONW' -Environment FullOS

            $action.Action | Should -BeExactly 'None'
        }

        It 'says it did not recognise the value, so the caller can log it' {
            # AND IT IS NOT A FAILURE. The deployment succeeded; refusing at the
            # very end over a misspelt finish action would turn a built machine
            # into a failed one. The caller warns, naming the value.
            $action = Get-HDTFinishAction -Value 'SHUTDONW' -Environment FullOS

            $action.IsRecognised | Should -BeFalse
            $action.Reason | Should -BeLike '*SHUTDONW*'
        }
    }

    Context 'WinPE' {

        It 'restarts and stops in WinPE like anywhere else' {
            (Get-HDTFinishAction -Value 'REBOOT' -Environment WinPE).Action | Should -BeExactly 'Restart'
            (Get-HDTFinishAction -Value 'SHUTDOWN' -Environment WinPE).Action | Should -BeExactly 'Stop'
        }

        It 'does nothing for LOGOFF in WinPE' {
            # WinPE has one session and nobody logged into it, so there is
            # nothing to log off from. Doing nothing beats refusing: the value
            # is legitimate, and the leg it is legitimate for is the other one.
            $action = Get-HDTFinishAction -Value 'LOGOFF' -Environment WinPE

            $action.Action | Should -BeExactly 'None'
            $action.IsRecognised | Should -BeTrue
        }

        It 'says why LOGOFF did nothing in WinPE' {
            (Get-HDTFinishAction -Value 'LOGOFF' -Environment WinPE).Reason | Should -BeLike '*WinPE*'
        }
    }

    Context 'the delay' {

        It 'defaults to no delay' {
            (Get-HDTFinishAction -Value 'REBOOT' -Environment FullOS).DelaySecond | Should -Be 0
        }

        It 'carries the delay it was given' {
            (Get-HDTFinishAction -Value 'REBOOT' -Environment FullOS -DelaySecond 30).DelaySecond | Should -Be 30
        }

        It 'refuses a negative delay' {
            { Get-HDTFinishAction -Value 'REBOOT' -Environment FullOS -DelaySecond -5 } | Should -Throw
        }
    }
}
