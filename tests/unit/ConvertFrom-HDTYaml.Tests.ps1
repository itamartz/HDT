# ConvertFrom-HDTYaml is the engine's ONLY mention of ConvertFrom-Yaml, and it
# delivers the ROADMAP M1 bullet "malformed YAML producing a pointed
# configuration error, not a crash".
#
# Two behaviours are load-bearing and both are asserted here rather than assumed:
#
#   * -Ordered is mandatory. Without it the parser returns a [hashtable] whose
#     key order DIFFERS BETWEEN ENGINES - the same document yielded a different
#     order under pwsh 7 than under Windows PowerShell 5.1. rules.yaml applies
#     set: in document order, so that difference would make variable resolution
#     engine-dependent. The order test below is why this file must pass under
#     both engines.
#   * a YAML syntax error arrives as a MethodInvocationException wrapping a
#     YamlDotNet exception, which carries .Start.Line. Nothing of either type may
#     escape this adapter; what escapes is a configuration error naming the file
#     and the line.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # The same shape as tests/fixtures/rules/unparseable-indentation.yaml: the
    # mis-indented 'set:' puts the parser error on line 4.
    $script:unparseable = "schemaVersion: 1`nrules:`n  - name: A`n      set:`n        HDTX: 1`n"
}

Describe 'ConvertFrom-HDTYaml' {

    It 'parses a mapping into an ordered dictionary' {
        $document = InModuleScope Hephaestus {
            ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nrules: []`n" -Path 'C:\ws\rules.yaml'
        }

        $document | Should -BeOfType ([System.Collections.Specialized.OrderedDictionary])
        $document['schemaVersion'] | Should -Be 1
    }

    It 'preserves the document order of keys' {
        $document = InModuleScope Hephaestus {
            ConvertFrom-HDTYaml -Yaml "Zebra: 1`nAlpha: 2`nMiddle: 3`n" -Path 'C:\ws\rules.yaml'
        }

        @($document.Keys) | Should -Be @('Zebra', 'Alpha', 'Middle')
    }

    It 'looks a key up case-insensitively' {
        $document = InModuleScope Hephaestus {
            ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`n" -Path 'C:\ws\rules.yaml'
        }

        $document['SCHEMAVERSION'] | Should -Be 1
    }

    It 'parses a sequence into a list' {
        $document = InModuleScope Hephaestus {
            ConvertFrom-HDTYaml -Yaml "rules:`n  - one`n  - two`n" -Path 'C:\ws\rules.yaml'
        }

        @($document['rules']).Count | Should -Be 2
        @($document['rules'])[0] | Should -BeExactly 'one'
    }

    It 'parses true as a boolean' {
        $document = InModuleScope Hephaestus {
            ConvertFrom-HDTYaml -Yaml "HDTSkipWizard: true`n" -Path 'C:\ws\rules.yaml'
        }

        $document['HDTSkipWizard'] | Should -BeOfType ([bool])
        $document['HDTSkipWizard'] | Should -BeTrue
    }

    It 'parses an integer as an integer' {
        $document = InModuleScope Hephaestus {
            ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`n" -Path 'C:\ws\rules.yaml'
        }

        $document['schemaVersion'] | Should -BeOfType ([int])
    }

    It 'leaves an unquoted date as a string' {
        $document = InModuleScope Hephaestus {
            ConvertFrom-HDTYaml -Yaml "HDTBuildDate: 2026-08-13`n" -Path 'C:\ws\rules.yaml'
        }

        $document['HDTBuildDate'] | Should -BeOfType ([string])
        $document['HDTBuildDate'] | Should -BeExactly '2026-08-13'
    }

    It 'returns null for an empty document' {
        $document = InModuleScope Hephaestus {
            ConvertFrom-HDTYaml -Yaml '' -Path 'C:\ws\rules.yaml'
        }

        $document | Should -BeNullOrEmpty
    }

    It 'returns null for a whitespace-only document' {
        $document = InModuleScope Hephaestus {
            ConvertFrom-HDTYaml -Yaml "   `n  `n" -Path 'C:\ws\rules.yaml'
        }

        $document | Should -BeNullOrEmpty
    }

    It 'throws a configuration error naming the file for malformed YAML' {
        $yaml = $script:unparseable

        {
            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                param($Yaml)
                ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml'
            }
        } | Should -Throw -ExpectedMessage '*rules.yaml*'
    }

    It 'includes the line number of a syntax error' {
        $yaml = $script:unparseable

        {
            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                param($Yaml)
                ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml'
            }
        } | Should -Throw -ExpectedMessage '*(4)*'
    }

    It 'says the YAML could not be parsed' {
        $yaml = $script:unparseable

        {
            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                param($Yaml)
                ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml'
            }
        } | Should -Throw -ExpectedMessage '*the YAML in this file could not be parsed.*'
    }

    It 'includes the parser message in the error' {
        $yaml = $script:unparseable

        {
            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                param($Yaml)
                ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml'
            }
        } | Should -Throw -ExpectedMessage '*found invalid mapping*'
    }

    It 'does not leak a MethodInvocationException' {
        # The ROADMAP M1 bullet, asserted literally: nothing of the parser's own
        # exception types may reach the caller, at any depth of the chain.
        $yaml = $script:unparseable

        $record = InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
            param($Yaml)
            $captured = $null
            try { ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml' } catch { $captured = $_ }
            $captured
        }

        # The identity assertions come first on purpose. Without them this test
        # passes against ANY unexpected failure - a CommandNotFoundException is
        # not a MethodInvocationException either - and it was observed doing
        # exactly that before the implementation existed.
        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        $record.Exception.Message | Should -BeLike '*the YAML in this file could not be parsed.*'

        $current = $record.Exception
        while ($null -ne $current) {
            $current | Should -Not -BeOfType ([System.Management.Automation.MethodInvocationException])
            $current.GetType().FullName | Should -Not -BeLike 'YamlDotNet.*'
            $current = $current.InnerException
        }
    }

    It 'reports the path as the target object' {
        $yaml = $script:unparseable

        $record = InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
            param($Yaml)
            $captured = $null
            try { ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml' } catch { $captured = $_ }
            $captured
        }

        $record.TargetObject | Should -BeExactly 'C:\ws\rules.yaml'
    }

    It 'uses the HDTConfigurationError error id' {
        $yaml = $script:unparseable

        $record = InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
            param($Yaml)
            $captured = $null
            try { ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml' } catch { $captured = $_ }
            $captured
        }

        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'throws a configuration error naming the file for a duplicate key' {
        {
            InModuleScope Hephaestus {
                ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nrules: []`nrules: []`n" -Path 'C:\ws\rules.yaml'
            }
        } | Should -Throw -ExpectedMessage '*rules.yaml*Duplicate key*'
    }

    It 'has comment-based help with a synopsis' {
        InModuleScope Hephaestus {
            $help = Get-Help -Name ConvertFrom-HDTYaml -ErrorAction Stop

            $help.Synopsis | Should -Not -BeNullOrEmpty
            $help.Synopsis | Should -Not -Match 'ConvertFrom-HDTYaml \['
        }
    }
}
