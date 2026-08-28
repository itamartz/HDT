# The local Administrator password, judged.
#
# THIS EXISTS BECAUSE THE WIZARD COULD NOT ASK FOR ONE. A Latitude deployed
# from the shipped client template reached step 6 of 11 and stopped:
#
#   step 'Apply Windows Settings' stages an answer file that asks for
#   %HDTAdminPassword%, but nothing supplies it. Set it in the fallback rule of
#   rules.yaml, in Control\machines\<UUID>.yaml for this machine, or on the
#   wizard's administrator password page.
#
# There was no administrator password page. The message named a screen nobody
# could open, and the only way through was to hand-edit rules.yaml - which is
# how MDT's Administrator Password pane earns its place: it is the one value a
# deployment cannot invent and cannot proceed without.
#
# DESIGN 4.5.2 settles the policy - "the administrator sets the password; HDT
# does not invent one" - so this judges what was typed and never supplies a
# default.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Test-HDTAdminPassword' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Test-HDTAdminPassword' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'answers in the shape the wizard rail paints' {
        # THE SAME SHAPE Test-HDTComputerName ANSWERS IN. The host reads
        # Severity to colour the message and IsValid to open the Next button;
        # a validator that answered differently would need a second host.
        $answer = Test-HDTAdminPassword -Password 'Pa$$w0rd!' -Confirmation 'Pa$$w0rd!'

        foreach ($name in 'IsValid', 'Severity', 'Reason') {
            $answer.PSObject.Properties[$name] | Should -Not -BeNullOrEmpty -Because "the wizard host reads $name"
        }
    }

    Context 'what it accepts' {

        It 'accepts two boxes that match' {
            (Test-HDTAdminPassword -Password 'Pa$$w0rd!' -Confirmation 'Pa$$w0rd!').IsValid | Should -BeTrue
        }

        It 'says nothing when there is nothing to say' {
            (Test-HDTAdminPassword -Password 'Pa$$w0rd!' -Confirmation 'Pa$$w0rd!').Reason | Should -BeNullOrEmpty
        }

        It 'accepts a password with spaces in it' {
            # A PASSPHRASE IS A PASSWORD. Windows allows spaces and refusing
            # them here would refuse the strongest thing a technician can type.
            (Test-HDTAdminPassword -Password 'correct horse battery staple' -Confirmation 'correct horse battery staple').IsValid |
                Should -BeTrue
        }

        It 'treats the password as case sensitive' {
            (Test-HDTAdminPassword -Password 'Secret1!' -Confirmation 'secret1!').IsValid | Should -BeFalse
        }
    }

    Context 'what it refuses' {

        It 'refuses an empty password' {
            # NOT A BLANK ADMINISTRATOR ACCOUNT. Windows permits one and a
            # deployment that quietly produced it would be a machine on the
            # network with no password on its local administrator.
            $answer = Test-HDTAdminPassword -Password '' -Confirmation ''

            $answer.IsValid | Should -BeFalse
            $answer.Reason | Should -Match 'required'
        }

        It 'refuses a password that is only spaces' {
            (Test-HDTAdminPassword -Password '    ' -Confirmation '    ').IsValid | Should -BeFalse
        }

        It 'refuses two boxes that differ' {
            $answer = Test-HDTAdminPassword -Password 'Pa$$w0rd!' -Confirmation 'Pa$$w0rd'

            $answer.IsValid | Should -BeFalse
            $answer.Reason | Should -Match 'match'
        }

        It 'refuses a confirm box nobody filled in' {
            (Test-HDTAdminPassword -Password 'Pa$$w0rd!' -Confirmation '').IsValid | Should -BeFalse
        }

        It 'asks for the password before it complains they differ' {
            # AN EMPTY PAGE MUST NOT OPEN SAYING "they do not match". That is
            # true and useless: nothing has been typed yet, and the first thing
            # a technician sees should be what to do.
            (Test-HDTAdminPassword -Password '' -Confirmation '').Reason | Should -Match 'required'
        }
    }

    Context 'what it must never do' {

        It 'never echoes the password back' {
            # A REASON IS WRITTEN TO THE LOG AND PAINTED ON THE SCREEN. Quoting
            # the value the way the computer-name validator quotes a name would
            # put the local administrator password into Console.log and into a
            # photograph of a deployment screen.
            $secret = 'Sup3rSecret-Value!'

            foreach ($answer in @(
                    (Test-HDTAdminPassword -Password $secret -Confirmation 'different')
                    (Test-HDTAdminPassword -Password $secret -Confirmation '')
                    (Test-HDTAdminPassword -Password $secret -Confirmation $secret)
                )) {
                ([string] $answer.Reason) | Should -Not -Match ([regex]::Escape($secret))
            }
        }

        It 'carries no property holding the password' {
            # Test-HDTComputerName answers with the Name it judged, which is
            # the right thing for a computer name and the wrong thing here -
            # the judgement travels through the host and into a log record.
            $secret = 'Sup3rSecret-Value!'
            $answer = Test-HDTAdminPassword -Password $secret -Confirmation $secret

            foreach ($property in $answer.PSObject.Properties) {
                ([string] $property.Value) | Should -Not -Match ([regex]::Escape($secret)) -Because "$($property.Name) reaches the log"
            }
        }
    }
}
