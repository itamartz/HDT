# The rules.yaml schema contract (DESIGN 2.2: "Every file has a schemaVersion and
# a JSON Schema in schemas/ so the console, CI, and cmdlets validate
# identically").
#
# TWO VALIDATORS, ONE VERDICT. The schema is the gate the console, an editor and
# CI use; Assert-HDTRuleDocument is what actually runs in WinPE, where Test-Json
# does not exist. They must agree on every fixture, or an administrator gets a
# green editor and a red deployment. That agreement is the point of this file.
#
# The schema is NOT the source of the message a user reads. Its rejection of the
# engine-variable fixture, for instance, is reported as "Required properties
# ["setFrom"] are not present at '/rules/0'" - true in schema terms, useless to
# the person who wrote _HDTLogPath. Assert-HDTRuleDocument owns the message.
#
# Test-Json exists under pwsh 7 and NOT under Windows PowerShell 5.1, so the
# whole file skips there rather than silently passing. That is also why the
# engine carries its own validator instead of leaning on the schema.

$script:HDTSchemaSkip = -not [bool](Get-Command -Name Test-Json -ErrorAction SilentlyContinue)

if ($script:HDTSchemaSkip) {
    Write-Warning ("RulesSchema contract SKIPPED: Test-Json does not exist on PowerShell {0} ({1}). The schema is validated on the pwsh 7 leg; Assert-HDTRuleDocument is what runs here." -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
}

# Discovery-time enumeration, so every fixture becomes its own test case rather
# than one loop whose first failure hides the rest.
$script:HDTRulesFixtureRoot = Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'tests/fixtures/rules'

# JSON Schema draft-07 cannot express "no two rules share a name" - there is no
# uniqueness constraint over a property across array items. This is the single
# fixture the schema accepts and the engine rejects, and it is listed here rather
# than quietly excluded. If a future schema gains the ability, the blind-spot
# test goes red and the file moves out of this list.
$script:HDTSchemaBlindSpot = @('invalid-duplicate-rule-name.yaml')

$script:HDTValidFixture = @(Get-ChildItem -LiteralPath $script:HDTRulesFixtureRoot -Filter 'valid-*.yaml' -File |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName; ShouldBeValid = $true } })

$script:HDTInvalidFixture = @(Get-ChildItem -LiteralPath $script:HDTRulesFixtureRoot -Filter 'invalid-*.yaml' -File |
        Where-Object { $script:HDTSchemaBlindSpot -notcontains $_.Name } |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName; ShouldBeValid = $false } })

$script:HDTBlindSpotFixture = @(Get-ChildItem -LiteralPath $script:HDTRulesFixtureRoot -Filter 'invalid-*.yaml' -File |
        Where-Object { $script:HDTSchemaBlindSpot -contains $_.Name } |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName } })

$script:HDTAgreementFixture = @($script:HDTValidFixture + $script:HDTInvalidFixture)

Describe 'rules.yaml schema contract' -Skip:$script:HDTSchemaSkip {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name powershell-yaml -ErrorAction Stop

        $script:rulesSchemaPath = Join-Path -Path $script:repoRoot -ChildPath 'schemas/rules.schema.json'
        $script:machineSchemaPath = Join-Path -Path $script:repoRoot -ChildPath 'schemas/machine.schema.json'
    }

    Context 'the schema files' {

        It 'ships schemas/rules.schema.json' {
            Test-Path -LiteralPath $script:rulesSchemaPath -PathType Leaf | Should -BeTrue
        }

        It 'ships schemas/machine.schema.json' {
            Test-Path -LiteralPath $script:machineSchemaPath -PathType Leaf | Should -BeTrue
        }

        It 'declares draft-07 in <_>' -ForEach @('rules.schema.json', 'machine.schema.json') {
            $path = Join-Path -Path $script:repoRoot -ChildPath ('schemas/{0}' -f $_)
            $schema = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json

            $schema.'$schema' | Should -BeExactly 'http://json-schema.org/draft-07/schema#'
        }
    }

    Context 'the fixtures' {

        It 'validates <Name> against schemas/rules.schema.json' -ForEach $script:HDTValidFixture {
            $schema = Get-Content -LiteralPath $script:rulesSchemaPath -Raw
            $json = (ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $FixturePath -Raw) -Ordered) | ConvertTo-Json -Depth 10

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }

        It 'rejects <Name> against schemas/rules.schema.json' -ForEach $script:HDTInvalidFixture {
            $schema = Get-Content -LiteralPath $script:rulesSchemaPath -Raw
            $json = (ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $FixturePath -Raw) -Ordered) | ConvertTo-Json -Depth 10

            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'agrees with Assert-HDTRuleDocument about <Name>' -ForEach $script:HDTAgreementFixture {
            $schema = Get-Content -LiteralPath $script:rulesSchemaPath -Raw
            $yaml = Get-Content -LiteralPath $FixturePath -Raw
            $json = (ConvertFrom-Yaml -Yaml $yaml -Ordered) | ConvertTo-Json -Depth 10

            $schemaVerdict = [bool] (Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue)

            $engineVerdict = $true
            try {
                InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                    param($Yaml)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml'
                    Assert-HDTRuleDocument -Document $document -Path 'C:\ws\rules.yaml'
                }
            } catch {
                $engineVerdict = $false
            }

            $engineVerdict | Should -Be $ShouldBeValid
            $schemaVerdict | Should -Be $engineVerdict
        }

        It 'cannot express <Name>, so only the engine rejects it' -ForEach $script:HDTBlindSpotFixture {
            $schema = Get-Content -LiteralPath $script:rulesSchemaPath -Raw
            $yaml = Get-Content -LiteralPath $FixturePath -Raw
            $json = (ConvertFrom-Yaml -Yaml $yaml -Ordered) | ConvertTo-Json -Depth 10

            # The schema accepting this is the documented blind spot, recorded in
            # tests/fixtures/README.md. When that stops being true, move the file
            # out of $script:HDTSchemaBlindSpot rather than deleting this test.
            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeTrue

            {
                InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                    param($Yaml)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml'
                    Assert-HDTRuleDocument -Document $document -Path 'C:\ws\rules.yaml'
                }
            } | Should -Throw
        }
    }

    Context 'the sample workspace' {

        It 'validates the sample workspace rules file' {
            # The workspace an administrator copies is held to the same schema as
            # every fixture: a sample that would be rejected by the console is
            # worse than no sample.
            $schema = Get-Content -LiteralPath $script:rulesSchemaPath -Raw
            $samplePath = Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/rules.yaml'
            $json = (ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $samplePath -Raw) -Ordered) | ConvertTo-Json -Depth 10

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }

        It 'validates the sample machine override against schemas/machine.schema.json' {
            $schema = Get-Content -LiteralPath $script:machineSchemaPath -Raw
            $samplePath = Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/Control/machines/4C4C4544-0031-3610-8052-B7C04F515A31.yaml'
            $json = (ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $samplePath -Raw) -Ordered) | ConvertTo-Json -Depth 10

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }
    }
}
