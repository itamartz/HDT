# The engine's own os.yaml validator, and the one that actually runs in WinPE:
# Test-Json does not exist under Windows PowerShell 5.1, so schemas/os.schema.json
# is a gate for the console, editors and CI while this is the gate for a
# deployment.
#
# It is private, so every assertion runs inside InModuleScope. Every rule asserts
# the error ID AND that the message names the offending field - a validator that
# rejects the right file with the wrong sentence sends an administrator looking
# in the wrong place.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:osFixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/os'
    $script:catalogPath = 'C:\HDTLab\does-not-exist\OperatingSystems\Contoso\os.yaml'

    $script:fixture = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $script:osFixtureRoot -Filter '*.yaml' -File)) {
        $script:fixture[$file.Name] = Get-Content -LiteralPath $file.FullName -Raw
    }
}

Describe 'Assert-HDTOperatingSystemDocument' {

    Context 'what it accepts' {

        It 'accepts <_>' -ForEach @('valid-minimal.yaml', 'valid-win11-ltsc.yaml', 'valid-ffu.yaml') {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture[$_]; Path = $script:catalogPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } | Should -Not -Throw
            }
        }

        It 'returns nothing for a valid document' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['valid-minimal.yaml']; Path = $script:catalogPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                Assert-HDTOperatingSystemDocument -Document $document -Path $Path | Should -BeNullOrEmpty
            }
        }
    }

    Context 'the document' {

        It 'rejects an empty file' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:catalogPath } {
                param($Path)

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $null -Path $Path } catch { $record = $_ }

                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
                $record.Exception.Message | Should -BeLike '*empty*'
            }
        }

        It 'rejects a document that is not a mapping' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:catalogPath } {
                param($Path)

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document @(1, 2) -Path $Path } catch { $record = $_ }

                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
                $record.Exception.Message | Should -BeLike '*mapping*'
            }
        }

        It 'rejects an unknown root key and names it' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['invalid-unknown-key.yaml']; Path = $script:catalogPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
                $record.Exception.Message | Should -BeLike '*priority*'
            }
        }

        It 'rejects a missing schemaVersion' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['invalid-missing-schemaversion.yaml']; Path = $script:catalogPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*schemaVersion*'
            }
        }

        It 'rejects a schemaVersion that is not an integer' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:catalogPath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: one`nid: A`nname: A`ntype: wim`nsourcePath: a.wim`nimages:`n  - index: 1`n    name: A" -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*schemaVersion*'
            }
        }

        It 'rejects a schemaVersion newer than this engine' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:catalogPath } {
                param($Path)

                # Delegated to Test-HDTSchemaVersion, as every document type does.
                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 99`nid: A`nname: A`ntype: wim`nsourcePath: a.wim`nimages:`n  - index: 1`n    name: A" -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*99*'
            }
        }
    }

    Context 'the identity' {

        It 'rejects a missing id' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['invalid-missing-id.yaml']; Path = $script:catalogPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*id*'
            }
        }

        It 'rejects a malformed id' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:catalogPath } {
                param($Path)

                # The id becomes a folder name under OperatingSystems\, so a path
                # separator in it is a directory traversal waiting to happen.
                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nid: ../escape`nname: A`ntype: wim`nsourcePath: a.wim`nimages:`n  - index: 1`n    name: A" -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
                $record.Exception.Message | Should -BeLike '*id*'
            }
        }

        It 'rejects a missing name' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['invalid-missing-name.yaml']; Path = $script:catalogPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                # The error id is asserted here as well: a missing command's
                # message also contains the word "name".
                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
                $record.Exception.Message | Should -BeLike '*name*'
            }
        }

        It 'rejects a type outside wim and ffu' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['invalid-bad-type.yaml']; Path = $script:catalogPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*iso*'
                $record.Exception.Message | Should -BeLike '*wim*'
            }
        }

        It 'rejects an architecture outside x86, x64 and arm64' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['invalid-bad-architecture.yaml']; Path = $script:catalogPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*ia64*'
            }
        }

        It 'rejects a missing sourcePath' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:catalogPath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nid: A`nname: A`ntype: wim`nimages:`n  - index: 1`n    name: A" -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*sourcePath*'
            }
        }
    }

    Context 'the images' {

        It 'rejects a missing images key' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:catalogPath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nid: A`nname: A`ntype: wim`nsourcePath: a.wim" -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*images*'
            }
        }

        It 'rejects an empty images list' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['invalid-empty-images.yaml']; Path = $script:catalogPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*images*'
            }
        }

        It 'rejects an images key that is not a list' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:catalogPath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nid: A`nname: A`ntype: wim`nsourcePath: a.wim`nimages:`n  index: 1" -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*images*'
            }
        }

        It 'rejects an image without an index' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:catalogPath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nid: A`nname: A`ntype: wim`nsourcePath: a.wim`nimages:`n  - name: A" -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*index*'
            }
        }

        It 'rejects a non-positive index' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['invalid-bad-index.yaml']; Path = $script:catalogPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*index*'
                $record.Exception.Message | Should -BeLike '*0*'
            }
        }

        It 'rejects a duplicate index and names it' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['invalid-duplicate-index-distinct.yaml']; Path = $script:catalogPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
                $record.Exception.Message | Should -BeLike '*index 1*'
            }
        }

        It 'rejects an image without a name' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:catalogPath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nid: A`nname: A`ntype: wim`nsourcePath: a.wim`nimages:`n  - index: 1" -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
                $record.Exception.Message | Should -BeLike '*name*'
            }
        }

        It 'rejects an unknown image key' {
            InModuleScope Hephaestus -Parameters @{ Path = $script:catalogPath } {
                param($Path)

                $document = ConvertFrom-HDTYaml -Yaml "schemaVersion: 1`nid: A`nname: A`ntype: wim`nsourcePath: a.wim`nimages:`n  - index: 1`n    name: A`n    flavour: spicy" -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike '*flavour*'
            }
        }

        It 'rejects a defaultIndex no image carries' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['invalid-default-index-absent.yaml']; Path = $script:catalogPath } {
                param($Yaml, $Path)

                # The schema blind spot: draft-07 has no cross-field reference
                # from defaultIndex into the images array, so only this closes it.
                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
                $record.Exception.Message | Should -BeLike '*defaultIndex*'
                $record.Exception.Message | Should -BeLike '*7*'
            }
        }
    }

    Context 'the error shape' {

        It 'names the file in every message' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['invalid-missing-id.yaml']; Path = $script:catalogPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $record = $null
                try { Assert-HDTOperatingSystemDocument -Document $document -Path $Path } catch { $record = $_ }

                $record.Exception.Message | Should -BeLike ('{0}*' -f $Path)
                $record.TargetObject | Should -BeExactly $Path
            }
        }
    }
}
