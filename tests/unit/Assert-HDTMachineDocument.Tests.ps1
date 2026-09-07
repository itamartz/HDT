# Assert-HDTMachineDocument is the gate that actually runs in WinPE, where
# Test-Json does not exist. schemas/machine.schema.json is the gate the console,
# an editor and CI use; this file is where the MESSAGE an administrator reads is
# held in place.
#
# WHY IT EXISTS AT ALL. The rules were already written - inline, in
# Get-HDTMachineOverride, which read the file and validated it in one pass. That
# left machine.schema.json as the only schema in the repository with no
# Assert-HDT*Document beside it, so the published contract and the engine were
# two hand-written copies of one vocabulary with nothing holding them together.
# SchemaPairing.Contract.Tests.ps1 is what now says so out loud.
#
# THE MESSAGES ARE THE ONES Get-HDTMachineOverride ALREADY GAVE, word for word.
# This was an extraction, not a rewrite: a machine override that is refused today
# must be refused with the same sentence tomorrow, because that sentence is what
# an administrator at a bench reads. Get-HDTMachineOverride.Tests.ps1 asserts the
# same refusals from the other side of the call.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:machinePath = 'C:\HDTLab\does-not-exist\ws\Control\machines\4C4C4544-0031-3610-8052-B7C04F515A31.yaml'

    $script:validYaml = @'
schemaVersion: 1
variables:
  HDTComputerName: FIN-0007
  HDTTaskSequenceID: OVR-CLIENT
'@
}

Describe 'Assert-HDTMachineDocument' {

    Context 'the document itself' {

        It 'accepts the canonical override' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:validYaml; Path = $script:machinePath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTMachineDocument -Document $document -Path $Path } | Should -Not -Throw
            }
        }

        It 'returns nothing when the document is valid' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:validYaml; Path = $script:machinePath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                Assert-HDTMachineDocument -Document $document -Path $Path | Should -BeNullOrEmpty
            }
        }

        It 'refuses a null document, reporting an empty file rather than crashing' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                { Assert-HDTMachineDocument -Document $null -Path $Path } |
                    Should -Throw -ExpectedMessage '*empty*'
            }
        }

        It 'refuses a document that is not a mapping, naming what it is instead' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                { Assert-HDTMachineDocument -Document 'not a mapping' -Path $Path } |
                    Should -Throw -ExpectedMessage '*String*'
            }
        }

        It 'names the file in the message' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                $record = $null
                try { Assert-HDTMachineDocument -Document $null -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*4C4C4544-0031-3610-8052-B7C04F515A31.yaml*'
            }
        }

        It 'reports HDTConfigurationError' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                $record = $null
                try { Assert-HDTMachineDocument -Document $null -Path $Path } catch { $record = $_ }

                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            }
        }
    }

    Context 'the key set' {

        It 'refuses a key a machine override does not declare, and lists the ones it may' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                $yaml = "schemaVersion: 1`nvariables:`n  HDTComputerName: FIN-0007`nnotes: bought in 2019`n"
                $document = ConvertFrom-HDTYaml -Yaml $yaml -Path $Path

                { Assert-HDTMachineDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage "*'notes'*schemaVersion and variables*"
            }
        }
    }

    Context 'schemaVersion' {

        It 'refuses a missing schemaVersion' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "variables:`n  HDTComputerName: FIN-0007`n" -Path $Path

                { Assert-HDTMachineDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*schemaVersion is missing*'
            }
        }

        It 'refuses a schemaVersion that is not an integer' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: one`nvariables:`n  HDTComputerName: FIN-0007`n" -Path $Path

                { Assert-HDTMachineDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*schemaVersion must be an integer*'
            }
        }

        It 'refuses a schemaVersion newer than this engine understands' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 99`nvariables:`n  HDTComputerName: FIN-0007`n" -Path $Path

                { Assert-HDTMachineDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*99*'
            }
        }
    }

    Context 'the variables' {

        It 'refuses a missing variables key' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`n" -Path $Path

                { Assert-HDTMachineDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*variables key is missing*'
            }
        }

        It 'refuses variables that are not a mapping' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nvariables:`n  - HDTComputerName`n" -Path $Path

                { Assert-HDTMachineDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*must be a mapping*'
            }
        }

        It 'refuses an empty variables mapping rather than shipping an override that sets nothing' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nvariables: {}`n" -Path $Path

                { Assert-HDTMachineDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*empty*'
            }
        }

        It 'refuses an engine-owned _HDT variable' {
            # An override that assigned _HDTLogPath would be arguing with the
            # engine about a value the engine sets, and losing silently.
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nvariables:`n  _HDTLogPath: X:\HDT\Logs`n" -Path $Path

                { Assert-HDTMachineDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*_HDTLogPath*engine-owned*'
            }
        }

        It 'refuses a variable name outside the HDT namespace' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nvariables:`n  ComputerName: FIN-0007`n" -Path $Path

                { Assert-HDTMachineDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage "*'ComputerName' is not an HDT variable name*"
            }
        }

        It 'refuses a lower-case hdt prefix, because the namespace is case sensitive' {
            # -cnotmatch, not -notmatch: 'hdtComputerName' resolves to nothing
            # and would set a variable no step reads.
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nvariables:`n  hdtComputerName: FIN-0007`n" -Path $Path

                { Assert-HDTMachineDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage '*hdtComputerName*'
            }
        }

        It 'accepts a bare HDT with nothing after it' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:machinePath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nvariables:`n  HDT: yes`n" -Path $Path

                { Assert-HDTMachineDocument -Document $document -Path $Path } | Should -Not -Throw
            }
        }
    }
}
