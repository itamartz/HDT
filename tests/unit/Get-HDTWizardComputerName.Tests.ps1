# W4 OF .planning/WPF-FIRST.md: the computer name, "prefilled from the rules,
# with the 15-character NetBIOS refusal visible".
#
# THE CONVENTION IS THE RULES', NOT THIS COMMAND'S. rules.yaml already names
# machines - Add-HDTRule's own examples are PC-%HDTSerialNumber% and
# LT-%HDTSerialNumber% - so a wizard that invented a naming scheme of its own
# would be a second answer to a question the engine already answers. This
# command shows what resolved, and falls back only when nothing did.
#
# THE REFUSAL IS SHOWN BEFORE IT IS EARNED. Test-HDTComputerName is what the
# page validates with when Next is pressed; the same verdict is computed HERE,
# on the prefilled value, so a name the rules produced that cannot be used says
# so while the box is still empty of the technician's typing rather than after
# they have pressed Next.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:bag = {
        param([System.Collections.IDictionary] $Value)

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Value) {
            foreach ($key in @($Value.Keys)) { $live[[string] $key] = $Value[$key] }
        }

        return $live
    }
}

Describe 'Get-HDTWizardComputerName' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTWizardComputerName' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'what the rules resolved' {

        It 'prefills the name the rules produced' {
            $answer = Get-HDTWizardComputerName -Variable (& $script:bag ([ordered] @{ HDTComputerName = 'LT-8CG2401XYZ' }))

            [string] $answer.Value | Should -BeExactly 'LT-8CG2401XYZ'
            [string] $answer.Source | Should -BeExactly 'Rules'
        }

        It 'says the name is usable when it is' {
            $answer = Get-HDTWizardComputerName -Variable (& $script:bag ([ordered] @{ HDTComputerName = 'LAB-01' }))

            [string] $answer.Severity | Should -BeExactly 'None'
            [string] $answer.Reason | Should -BeNullOrEmpty
        }

        It 'shows the refusal for a name the rules produced that is too long' {
            # THE ONE W4 NAMES. A rule that builds PC-%HDTSerialNumber% out of a
            # long serial produces a name nothing can use, and the technician is
            # the person who finds out - so they find out while looking at it
            # rather than after pressing Next.
            $answer = Get-HDTWizardComputerName -Variable (& $script:bag ([ordered] @{ HDTComputerName = 'PC-ABCDEFGHIJKLMNOP' }))

            [string] $answer.Severity | Should -BeExactly 'Error'
            [string] $answer.Reason | Should -BeLike '*15*'
        }

        It 'shows the warning for a name that is legal but not DNS-safe' {
            $answer = Get-HDTWizardComputerName -Variable (& $script:bag ([ordered] @{ HDTComputerName = 'LAB_01' }))

            [string] $answer.Severity | Should -BeExactly 'Warning'
            [string] $answer.Reason | Should -Not -BeNullOrEmpty
        }

        It 'never repairs the name it was given' {
            # A wizard that silently trimmed a name would deploy a machine
            # called something nobody chose.
            $answer = Get-HDTWizardComputerName -Variable (& $script:bag ([ordered] @{ HDTComputerName = 'PC-ABCDEFGHIJKLMNOP' }))

            [string] $answer.Value | Should -BeExactly 'PC-ABCDEFGHIJKLMNOP'
        }
    }

    Context 'when the rules said nothing' {

        It 'falls back to the serial number, cut to fifteen' {
            $answer = Get-HDTWizardComputerName -Variable (& $script:bag ([ordered] @{ HDTSerialNumber = '8CG2401XYZ1234567' }))

            [string] $answer.Value | Should -BeExactly '8CG2401XYZ12345'
            [string] $answer.Source | Should -BeExactly 'Serial'
        }

        It 'uses the serial as it is when it already fits' {
            $answer = Get-HDTWizardComputerName -Variable (& $script:bag ([ordered] @{ HDTSerialNumber = '8CG2401XYZ' }))

            [string] $answer.Value | Should -BeExactly '8CG2401XYZ'
        }

        It 'leaves the box empty rather than inventing a name' {
            # MINWINPC is what WinPE calls itself, and deploying a machine under
            # it would be worse than asking.
            $answer = Get-HDTWizardComputerName -Variable (& $script:bag $null) `
                -Environment (New-HDTFakeEnvironmentProvider -Variable @{ COMPUTERNAME = 'MINWINPC' })

            [string] $answer.Value | Should -BeExactly ''
            [string] $answer.Source | Should -BeExactly 'None'
        }

        It 'offers the machine its own name when it has a real one' {
            # A rebuild of a machine that is already named keeps its name unless
            # a rule says otherwise - which is what MDT does.
            $answer = Get-HDTWizardComputerName -Variable (& $script:bag $null) `
                -Environment (New-HDTFakeEnvironmentProvider -Variable @{ COMPUTERNAME = 'LAB-07' })

            [string] $answer.Value | Should -BeExactly 'LAB-07'
            [string] $answer.Source | Should -BeExactly 'Machine'
        }

        It 'prefers the serial to the machine name, because the rules prefer the serial' {
            $answer = Get-HDTWizardComputerName `
                -Variable (& $script:bag ([ordered] @{ HDTSerialNumber = '8CG2401XYZ' })) `
                -Environment (New-HDTFakeEnvironmentProvider -Variable @{ COMPUTERNAME = 'LAB-07' })

            [string] $answer.Source | Should -BeExactly 'Serial'
        }

        It 'survives having no environment provider at all' {
            { Get-HDTWizardComputerName -Variable (& $script:bag $null) -Environment $null } | Should -Not -Throw
        }
    }

    Context 'the field the wizard host applies' {

        It 'names the control the page collects from' {
            $field = (Get-HDTWizardComputerName -Variable (& $script:bag ([ordered] @{ HDTComputerName = 'LAB-01' }))).Field

            [string] $field.Name | Should -BeExactly 'HDTComputerNameBox'
            [string] $field.Text | Should -BeExactly 'LAB-01'
        }

        It 'can be told which control to fill' {
            $field = (Get-HDTWizardComputerName -Variable (& $script:bag $null) -Control 'HDTNameBox').Field

            [string] $field.Name | Should -BeExactly 'HDTNameBox'
        }
    }
}
