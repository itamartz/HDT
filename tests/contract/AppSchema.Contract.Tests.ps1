# The app.yaml schema contract (DESIGN 2.2: "Every file has a schemaVersion and a
# JSON Schema in schemas/ so the console, CI, and cmdlets validate identically").
#
# TWO VALIDATORS, ONE VERDICT. The schema is the gate the console, an editor and
# CI use; Assert-HDTApplicationDocument is what actually runs in WinPE, where
# Test-Json does not exist. They must agree on every fixture, or an administrator
# gets a green editor and a red deployment.
#
# Test-Json exists under pwsh 7 and NOT under Windows PowerShell 5.1, so the whole
# file skips there rather than silently passing. That is also why the engine
# carries its own validator instead of leaning on the schema.

$script:HDTSchemaSkip = -not [bool](Get-Command -Name Test-Json -ErrorAction SilentlyContinue)

if ($script:HDTSchemaSkip) {
    Write-Warning ("AppSchema contract SKIPPED: Test-Json does not exist on PowerShell {0} ({1}). The schema is validated on the pwsh 7 leg; Assert-HDTApplicationDocument is what runs here." -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
}

# Discovery-time enumeration, so every fixture becomes its own test case rather
# than one loop whose first failure hides the rest.
$script:HDTAppFixtureRoot = Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'tests/fixtures/apps'

# The one thing JSON Schema draft-07 cannot say about an application, listed
# rather than quietly excluded. If a future schema gains the ability, the
# blind-spot test goes red and the file moves out of this list.
#
#   invalid-dependency-self.yaml   there is no cross-field reference from the
#                                  dependencies array back to id, so the schema
#                                  cannot see that an app depends on itself
$script:HDTSchemaBlindSpot = @('invalid-dependency-self.yaml')

$script:HDTValidFixture = @(Get-ChildItem -LiteralPath $script:HDTAppFixtureRoot -Filter 'valid-*.yaml' -File |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName; ShouldBeValid = $true } })

$script:HDTInvalidFixture = @(Get-ChildItem -LiteralPath $script:HDTAppFixtureRoot -Filter 'invalid-*.yaml' -File |
        Where-Object { $script:HDTSchemaBlindSpot -notcontains $_.Name } |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName; ShouldBeValid = $false } })

$script:HDTBlindSpotFixture = @(Get-ChildItem -LiteralPath $script:HDTAppFixtureRoot -Filter 'invalid-*.yaml' -File |
        Where-Object { $script:HDTSchemaBlindSpot -contains $_.Name } |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName } })

$script:HDTAgreementFixture = @($script:HDTValidFixture + $script:HDTInvalidFixture)

Describe 'app.yaml schema contract' -Skip:$script:HDTSchemaSkip {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name powershell-yaml -ErrorAction Stop

        $script:appSchemaPath = Join-Path -Path $script:repoRoot -ChildPath 'schemas/app.schema.json'
        $script:appPath = 'C:\ws\Applications\Contoso-Agent\app.yaml'

        function script:ConvertTo-HDTFixtureJson {
            <#
                A fixture as the JSON the schema is handed.

                AN EMPTY YAML DOCUMENT PARSES TO $null, and ConvertTo-Json emits
                nothing at all for it - which Test-Json refuses to bind rather
                than reporting as invalid. The honest JSON for "the file held no
                document" is the literal null, and the schema rejects it because
                the root must be an object. Writing that here keeps
                invalid-empty.yaml an ordinary rejection case on both sides
                instead of a special one.
            #>
            param([string] $FixturePath)

            $document = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $FixturePath -Raw) -Ordered

            if ($null -eq $document) { return 'null' }

            return ($document | ConvertTo-Json -Depth 10)
        }
    }

    Context 'the schema file' {

        It 'ships schemas/app.schema.json' {
            Test-Path -LiteralPath $script:appSchemaPath -PathType Leaf | Should -BeTrue
        }

        It 'declares draft-07' {
            $schema = Get-Content -LiteralPath $script:appSchemaPath -Raw | ConvertFrom-Json

            $schema.'$schema' | Should -BeExactly 'http://json-schema.org/draft-07/schema#'
        }

        It 'does not require detect' {
            # DESIGN 8: an application declaring no detection rule installs every
            # time. Asserted against the schema's own required list rather than
            # only through a fixture, because this is the rule most likely to be
            # "tightened" by someone who reads detection as mandatory.
            $schema = Get-Content -LiteralPath $script:appSchemaPath -Raw | ConvertFrom-Json

            $schema.required | Should -Not -Contain 'detect'
        }
    }

    Context 'the fixtures' {

        It 'validates <Name> against schemas/app.schema.json' -ForEach $script:HDTValidFixture {
            $schema = Get-Content -LiteralPath $script:appSchemaPath -Raw
            $json = script:ConvertTo-HDTFixtureJson -FixturePath $FixturePath

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }

        It 'rejects <Name> against schemas/app.schema.json' -ForEach $script:HDTInvalidFixture {
            $schema = Get-Content -LiteralPath $script:appSchemaPath -Raw
            $json = script:ConvertTo-HDTFixtureJson -FixturePath $FixturePath

            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'agrees with Assert-HDTApplicationDocument about <Name>' -ForEach $script:HDTAgreementFixture {
            $schema = Get-Content -LiteralPath $script:appSchemaPath -Raw
            $yaml = Get-Content -LiteralPath $FixturePath -Raw
            $json = script:ConvertTo-HDTFixtureJson -FixturePath $FixturePath

            $schemaVerdict = [bool] (Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue)

            $engineVerdict = $true
            try {
                InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:appPath } {
                    param($Yaml, $Path)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path
                    Assert-HDTApplicationDocument -Document $document -Path $Path
                }
            } catch {
                $engineVerdict = $false
            }

            $engineVerdict | Should -Be $ShouldBeValid
            $schemaVerdict | Should -Be $engineVerdict
        }

        It 'cannot express <Name>, so only the engine rejects it' -ForEach $script:HDTBlindSpotFixture {
            $schema = Get-Content -LiteralPath $script:appSchemaPath -Raw
            $yaml = Get-Content -LiteralPath $FixturePath -Raw
            $json = script:ConvertTo-HDTFixtureJson -FixturePath $FixturePath

            # The schema accepting this is the documented blind spot. When that
            # stops being true, move the file out of $script:HDTSchemaBlindSpot
            # rather than deleting this test.
            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeTrue

            $record = $null
            try {
                InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $script:appPath } {
                    param($Yaml, $Path)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path
                    Assert-HDTApplicationDocument -Document $document -Path $Path
                }
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }
}
