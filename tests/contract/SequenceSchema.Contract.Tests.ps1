# The sequence.yaml schema contract (DESIGN 2.2: "Every file has a schemaVersion
# and a JSON Schema in schemas/ so the console, CI, and cmdlets validate
# identically").
#
# TWO VALIDATORS, ONE VERDICT. The schema is the gate the console, an editor and
# CI use; Assert-HDTSequenceDocument is what actually runs in WinPE, where
# Test-Json does not exist. They must agree on every fixture, or an administrator
# gets a green editor and a red deployment.
#
# Test-Json exists under pwsh 7 and NOT under Windows PowerShell 5.1, so the
# whole file skips there rather than silently passing.

$script:HDTSchemaSkip = -not [bool](Get-Command -Name Test-Json -ErrorAction SilentlyContinue)

if ($script:HDTSchemaSkip) {
    Write-Warning ("SequenceSchema contract SKIPPED: Test-Json does not exist on PowerShell {0} ({1}). The schema is validated on the pwsh 7 leg; Assert-HDTSequenceDocument is what runs here." -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
}

# Discovery-time enumeration, so every fixture becomes its own test case rather
# than one loop whose first failure hides the rest.
$script:HDTSequenceFixtureRoot = Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'tests/fixtures/sequences'

# THE TWO BLIND SPOTS, listed rather than quietly excluded.
#
#   invalid-bad-condition.yaml   JSON Schema draft-07 cannot parse HDT's
#                                condition grammar. To the schema a condition is
#                                just a string, so "%A% =~ 1" is well formed.
#                                Only ConvertFrom-HDTStepCondition, which the
#                                engine validator calls, can reject it.
#
#   invalid-group-and-step.yaml  A node carrying group, name, type AND steps.
#                                oneOf accepts it because the step branch
#                                requires only name and type and tolerates extra
#                                properties, so exactly one branch matches. There
#                                is no draft-07 construction that says "these two
#                                keys are mutually exclusive across branches"
#                                without abandoning oneOf entirely.
#
# If a future schema gains the ability to express either, the blind-spot test
# goes red and the file moves out of this list.
$script:HDTSchemaBlindSpot = @('invalid-bad-condition.yaml', 'invalid-group-and-step.yaml')

$script:HDTValidFixture = @(Get-ChildItem -LiteralPath $script:HDTSequenceFixtureRoot -Filter 'valid-*.yaml' -File |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName; ShouldBeValid = $true } })

$script:HDTInvalidFixture = @(Get-ChildItem -LiteralPath $script:HDTSequenceFixtureRoot -Filter 'invalid-*.yaml' -File |
        Where-Object { $script:HDTSchemaBlindSpot -notcontains $_.Name } |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName; ShouldBeValid = $false } })

$script:HDTBlindSpotFixture = @(Get-ChildItem -LiteralPath $script:HDTSequenceFixtureRoot -Filter 'invalid-*.yaml' -File |
        Where-Object { $script:HDTSchemaBlindSpot -contains $_.Name } |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName } })

$script:HDTAgreementFixture = @($script:HDTValidFixture + $script:HDTInvalidFixture)

# The shipped samples are held to the same gate as the fixtures. A sample that
# does not validate is worse than no sample: it is a file administrators copy.
$script:HDTSampleRoot = Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'samples/workspace/TaskSequences'

# AND THE SHIPPED TEMPLATES, WHICH WERE HELD TO NOTHING. Every sequence an
# administrator creates in the console starts as one of these - the New Task
# Sequence wizard offers them and writes the chosen one into the share - so a
# template that does not validate is a broken sequence in every new workspace,
# not a broken sample somebody might copy.
#
# They were the least tested file in the repository and the most copied. Found
# on 2026-08-28 while adding an ApplyDrivers step to client.yaml: the change was
# green everywhere and nothing had checked the template against the schema at
# all. Assert-HDTSequenceDocument reads it - that is the hand-written validator
# and it runs on 5.1 - but the JSON Schema, which is the published contract, had
# never seen it.
$script:HDTTemplateRoot = Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'src/Hephaestus/Templates'

$script:HDTSampleSequence = @(
    @{ Name = 'DEMO-M2'; FixturePath = (Join-Path -Path $script:HDTSampleRoot -ChildPath 'DEMO-M2/sequence.yaml') }
    @{ Name = 'STD-CLIENT'; FixturePath = (Join-Path -Path $script:HDTSampleRoot -ChildPath 'STD-CLIENT/sequence.yaml') }
) + @(@(Get-ChildItem -LiteralPath $script:HDTTemplateRoot -Filter '*.yaml' -File -ErrorAction SilentlyContinue) |
        ForEach-Object { @{ Name = ('template {0}' -f $_.Name); FixturePath = $_.FullName } })

Describe 'sequence.yaml schema contract' -Skip:$script:HDTSchemaSkip {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name powershell-yaml -ErrorAction Stop

        $script:sequenceSchemaPath = Join-Path -Path $script:repoRoot -ChildPath 'schemas/sequence.schema.json'
    }

    Context 'the schema file' {

        It 'ships schemas/sequence.schema.json' {
            Test-Path -LiteralPath $script:sequenceSchemaPath -PathType Leaf | Should -BeTrue
        }

        It 'declares draft-07' {
            $schema = Get-Content -LiteralPath $script:sequenceSchemaPath -Raw | ConvertFrom-Json

            $schema.'$schema' | Should -BeExactly 'http://json-schema.org/draft-07/schema#'
        }
    }

    Context 'the fixtures' {

        It 'validates <Name> against schemas/sequence.schema.json' -ForEach $script:HDTValidFixture {
            $schema = Get-Content -LiteralPath $script:sequenceSchemaPath -Raw
            $json = (ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $FixturePath -Raw) -Ordered) | ConvertTo-Json -Depth 20

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }

        It 'rejects <Name> against schemas/sequence.schema.json' -ForEach $script:HDTInvalidFixture {
            $schema = Get-Content -LiteralPath $script:sequenceSchemaPath -Raw
            $json = (ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $FixturePath -Raw) -Ordered) | ConvertTo-Json -Depth 20

            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'agrees with Assert-HDTSequenceDocument about <Name>' -ForEach $script:HDTAgreementFixture {
            $schema = Get-Content -LiteralPath $script:sequenceSchemaPath -Raw
            $yaml = Get-Content -LiteralPath $FixturePath -Raw
            $json = (ConvertFrom-Yaml -Yaml $yaml -Ordered) | ConvertTo-Json -Depth 20

            $schemaVerdict = [bool] (Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue)

            $engineVerdict = $true
            try {
                InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                    param($Yaml)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\sequence.yaml'
                    Assert-HDTSequenceDocument -Document $document -Path 'C:\ws\sequence.yaml'
                }
            } catch {
                $engineVerdict = $false
            }

            $engineVerdict | Should -Be $ShouldBeValid
            $schemaVerdict | Should -Be $engineVerdict
        }

        It 'cannot express <Name>, so only the engine rejects it' -ForEach $script:HDTBlindSpotFixture {
            $schema = Get-Content -LiteralPath $script:sequenceSchemaPath -Raw
            $yaml = Get-Content -LiteralPath $FixturePath -Raw
            $json = (ConvertFrom-Yaml -Yaml $yaml -Ordered) | ConvertTo-Json -Depth 20

            # The schema accepting this is the documented blind spot. When that
            # stops being true, move the file out of $script:HDTSchemaBlindSpot
            # rather than deleting this test.
            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeTrue

            $record = $null
            try {
                InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                    param($Yaml)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\sequence.yaml'
                    Assert-HDTSequenceDocument -Document $document -Path 'C:\ws\sequence.yaml'
                }
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }

    Context 'the shipped samples' {

        It 'validates the <Name> sample sequence' -ForEach $script:HDTSampleSequence {
            $schema = Get-Content -LiteralPath $script:sequenceSchemaPath -Raw
            $yaml = Get-Content -LiteralPath $FixturePath -Raw
            $json = (ConvertFrom-Yaml -Yaml $yaml -Ordered) | ConvertTo-Json -Depth 20

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }

        It 'imports the <Name> sample sequence through the engine validator' -ForEach $script:HDTSampleSequence {
            # STD-CLIENT names step types that phases 04-07 have not built yet.
            # It still has to IMPORT: the schema and Assert-HDTSequenceDocument
            # are about the document, and whether a type exists is what
            # Test-HDTTaskSequence reports.
            $yaml = Get-Content -LiteralPath $FixturePath -Raw

            { InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                    param($Yaml)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\sequence.yaml'
                    Assert-HDTSequenceDocument -Document $document -Path 'C:\ws\sequence.yaml'
                } } | Should -Not -Throw
        }
    }
}
