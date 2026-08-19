# TYPING A LIST INTO A ONE-LINE BOX, and the command that takes it.
#
# THE PROPERTIES PANE WRITES THROUGH Set-HDTApplication, and until now every row
# it could write was a string: a name, a description, a command line. The four
# rows this file is about are not. successCodes and rebootCodes are int[],
# dependencies is string[], and detect is a whole block - so the pane needed
# something between "what was typed" and "what the cmdlet takes", and this is it.
#
# AND THE PARAMETER IS NOT THE KEY. app.yaml says successCodes and dependencies;
# Set-HDTApplication takes -SuccessCode and -Dependency, singular, because
# Verb-Noun parameters are singular. A pane that capitalised the key and hoped
# would call a parameter that does not exist.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function Get-HDTTestEdit {
        [CmdletBinding()]
        [OutputType([object])]
        param([string] $Property, [string] $Text)

        return InModuleScope -ModuleName 'Hephaestus' -Parameters @{ P = $Property; T = $Text } {
            param($P, $T)
            Get-HDTConsoleApplicationEdit -Property $P -Text $T
        }
    }
}

Describe 'Get-HDTConsoleApplicationEdit' {

    Context 'the rows that were always strings' {

        It 'passes a command line through as it was typed' {
            $edit = Get-HDTTestEdit -Property 'install' -Text 'msiexec.exe /i AcroRead.msi /qn'

            $edit.Parameter | Should -BeExactly 'Install'
            $edit.Value | Should -BeExactly 'msiexec.exe /i AcroRead.msi /qn'
        }

        It 'names the parameter for a key that is only a capital away' {
            (Get-HDTTestEdit -Property 'publisher' -Text 'Adobe').Parameter | Should -BeExactly 'Publisher'
        }
    }

    Context 'the exit codes' {

        It 'reads a comma-separated list as numbers' {
            $edit = Get-HDTTestEdit -Property 'successCodes' -Text '0, 3010'

            $edit.Parameter | Should -BeExactly 'SuccessCode'
            @($edit.Value) | Should -Be @(0, 3010)
            $edit.Value | Should -BeOfType ([int])
        }

        It 'takes spaces or no spaces' {
            @((Get-HDTTestEdit -Property 'rebootCodes' -Text '3010,1641').Value) | Should -Be @(3010, 1641)
        }

        It 'names the singular parameter for rebootCodes' {
            (Get-HDTTestEdit -Property 'rebootCodes' -Text '3010').Parameter | Should -BeExactly 'RebootCode'
        }

        It 'reads an empty box as the empty list, which removes the key' {
            # AND THE DEFAULT COMES BACK. DESIGN 8: no successCodes means 0 and
            # 3010, so clearing the box is how an administrator says "whatever
            # HDT says", not "no code succeeds".
            @((Get-HDTTestEdit -Property 'successCodes' -Text '   ').Value).Count | Should -Be 0
        }

        It 'refuses something that is not a number, saying which word' {
            $record = $null
            try { Get-HDTTestEdit -Property 'successCodes' -Text '0, ok' } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*ok*'
            $record.Exception.Message | Should -BeLike '*Success codes*'
        }
    }

    Context 'the dependencies' {

        It 'reads a comma-separated list of ids' {
            $edit = Get-HDTTestEdit -Property 'dependencies' -Text '7Zip-24.09, Contoso-Suite'

            $edit.Parameter | Should -BeExactly 'Dependency'
            @($edit.Value) | Should -Be @('7Zip-24.09', 'Contoso-Suite')
        }

        It 'reads an empty box as nothing to wait for' {
            @((Get-HDTTestEdit -Property 'dependencies' -Text '').Value).Count | Should -Be 0
        }
    }

    Context 'the detection rule' {

        It 'reads the block as the document writes it' {
            $edit = Get-HDTTestEdit -Property 'detect' -Text "type: msiProduct`nproductCode: '{AC76BA86}'"

            $edit.Parameter | Should -BeExactly 'Detect'
            $edit.Value | Should -BeOfType ([System.Collections.IDictionary])
            [string] $edit.Value['type'] | Should -BeExactly 'msiProduct'
            [string] $edit.Value['productCode'] | Should -BeExactly '{AC76BA86}'
        }

        It 'reads an empty box as no rule at all' {
            # DESIGN 8's "installs every time", said by clearing the box.
            $edit = Get-HDTTestEdit -Property 'detect' -Text ''

            $edit.Value | Should -BeOfType ([System.Collections.IDictionary])
            @($edit.Value.Keys).Count | Should -Be 0
        }

        It 'refuses a block that is not a rule, naming what it is for' {
            $record = $null
            try { Get-HDTTestEdit -Property 'detect' -Text 'msiProduct' } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*detection rule*'
        }
    }

    Context 'the command the footer echoes' {

        # DESIGN 12: EVERY EDIT NAMES THE COMMAND THAT WOULD REPEAT IT, which is
        # how an administrator learns the automation surface by clicking around.
        # A list echoed as if it were a string teaches the wrong line - it would
        # not run.

        It 'quotes a string' {
            (Get-HDTTestEdit -Property 'install' -Text 'setup.exe /quiet').Text |
                Should -BeExactly "'setup.exe /quiet'"
        }

        It 'doubles a quote inside one, so the line can be pasted' {
            (Get-HDTTestEdit -Property 'name' -Text "Frank's Reader").Text |
                Should -BeExactly "'Frank''s Reader'"
        }

        It 'echoes an exit code list as an array of numbers' {
            (Get-HDTTestEdit -Property 'successCodes' -Text '0, 3010').Text |
                Should -BeExactly '@(0, 3010)'
        }

        It 'echoes a dependency list as an array of strings' {
            (Get-HDTTestEdit -Property 'dependencies' -Text '7Zip-24.09, Contoso-Suite').Text |
                Should -BeExactly "@('7Zip-24.09', 'Contoso-Suite')"
        }

        It 'echoes an empty list as one' {
            (Get-HDTTestEdit -Property 'dependencies' -Text '').Text | Should -BeExactly '@()'
        }

        It 'echoes a detection rule as the hashtable the cmdlet takes' {
            (Get-HDTTestEdit -Property 'detect' -Text "type: msiProduct`nproductCode: '{AC76BA86}'").Text |
                Should -BeExactly "@{ type = 'msiProduct'; productCode = '{AC76BA86}' }"
        }

        It 'echoes a cleared rule as the empty hashtable that removes it' {
            (Get-HDTTestEdit -Property 'detect' -Text '').Text | Should -BeExactly '@{ }'
        }
    }
}
