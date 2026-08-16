# Assert-HDTApplicationDocument is the gate that actually runs in WinPE, where
# Test-Json does not exist. schemas/app.schema.json is the gate the console, an
# editor and CI use; the two must agree on every fixture
# (tests/contract/AppSchema.Contract.Tests.ps1), and this file is where the
# MESSAGE an administrator reads is held in place.
#
# It is private, so every assertion runs inside InModuleScope.
#
# THE INTERESTING HALF IS WHAT IS OPTIONAL. DESIGN 8 makes detect: optional, so
# the fixture that declares none must pass here - a validator that quietly
# required it would turn "installs every time", which is MDT's behaviour and a
# legitimate choice, into an authoring error.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:appFixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/apps'
    $script:appPath = 'C:\HDTLab\does-not-exist\Share\Applications\Contoso-Agent\app.yaml'

    $script:fixture = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $script:appFixtureRoot -Filter '*.yaml' -File)) {
        $script:fixture[$file.Name] = Get-Content -LiteralPath $file.FullName -Raw
    }
}

Describe 'Assert-HDTApplicationDocument' {

    Context 'the documents it accepts' {

        It 'accepts <_>' -ForEach @(
            'valid-7zip.yaml'
            'valid-no-detect.yaml'
            'valid-detect-file.yaml'
            'valid-detect-registry.yaml'
            'valid-detect-registry-key-only.yaml'
            'valid-detect-script.yaml'
            'valid-dependency-chain.yaml'
        ) {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture[$_]; Path = $script:appPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTApplicationDocument -Document $document -Path $Path } | Should -Not -Throw
            }
        }

        It 'accepts an application that declares no detection rule' {
            # DESIGN 8, stated as its own test rather than as one row of the table
            # above: this is the behaviour the roadmap changed on 2026-08-16, and a
            # regression here is a silent authoring break for every unconditional
            # installer in a workspace.
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['valid-no-detect.yaml']; Path = $script:appPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTApplicationDocument -Document $document -Path $Path } | Should -Not -Throw
            }
        }

        It 'returns nothing for a valid document' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['valid-no-detect.yaml']; Path = $script:appPath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                Assert-HDTApplicationDocument -Document $document -Path $Path | Should -BeNullOrEmpty
            }
        }
    }

    Context 'the documents it refuses' {

        It 'refuses <Fixture>, naming <Locator>' -ForEach @(
            @{ Fixture = 'invalid-empty.yaml'; Locator = 'empty' }
            @{ Fixture = 'invalid-unknown-key.yaml'; Locator = 'installCommand' }
            @{ Fixture = 'invalid-missing-install.yaml'; Locator = 'install' }
            @{ Fixture = 'invalid-bad-id.yaml'; Locator = 'id' }
            @{ Fixture = 'invalid-detect-unknown-type.yaml'; Locator = 'wmi' }
            @{ Fixture = 'invalid-detect-missing-field.yaml'; Locator = 'productCode' }
            @{ Fixture = 'invalid-runin.yaml'; Locator = 'Windows' }
            @{ Fixture = 'invalid-success-code-not-integer.yaml'; Locator = 'successCodes' }
            @{ Fixture = 'invalid-dependency-self.yaml'; Locator = 'Contoso-Agent' }
        ) {
            InModuleScope Hephaestus -Parameters @{
                Yaml    = $script:fixture[$Fixture]
                Path    = $script:appPath
                Locator = $Locator
            } {
                param($Yaml, $Path, $Locator)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                { Assert-HDTApplicationDocument -Document $document -Path $Path } |
                    Should -Throw -ExpectedMessage ('*{0}*' -f $Locator)
            }
        }

        It 'lists all four detection types when it refuses one it cannot run' {
            # The message is the whole value of this rule: an administrator who
            # typed 'wmi' needs to be told what to type instead, in the sentence
            # that rejected them.
            InModuleScope Hephaestus -Parameters @{
                Yaml = $script:fixture['invalid-detect-unknown-type.yaml']
                Path = $script:appPath
            } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $message = ''
                try {
                    Assert-HDTApplicationDocument -Document $document -Path $Path
                } catch {
                    $message = [string] $_.Exception.Message
                }

                foreach ($type in @('msiProduct', 'file', 'registry', 'script')) {
                    $message | Should -BeLike ('*{0}*' -f $type)
                }
            }
        }
    }

    Context 'the error it raises' {

        It 'names the file and reports a configuration error' {
            InModuleScope Hephaestus -Parameters @{
                Yaml = $script:fixture['invalid-missing-install.yaml']
                Path = $script:appPath
            } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                $record = $null
                try {
                    Assert-HDTApplicationDocument -Document $document -Path $Path
                } catch {
                    $record = $_
                }

                $record | Should -Not -BeNullOrEmpty
                $record.TargetObject | Should -BeExactly $Path
                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            }
        }
    }
}
