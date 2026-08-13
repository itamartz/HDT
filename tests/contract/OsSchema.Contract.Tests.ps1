# The os.yaml schema contract (DESIGN 2.2: "Every file has a schemaVersion and a
# JSON Schema in schemas/ so the console, CI, and cmdlets validate identically").
#
# TWO VALIDATORS, ONE VERDICT. The schema is the gate the console, an editor and
# CI use; Assert-HDTOperatingSystemDocument is what actually runs in WinPE, where
# Test-Json does not exist. They must agree on every fixture, or an administrator
# gets a green editor and a red deployment.
#
# The schema is NOT the source of the message a user reads. Its rejection of the
# bad-type fixture reads "Value is not accepted. Valid values: wim, ffu" against
# a JSON pointer; the engine's says which file, which key and what to do.
#
# Test-Json exists under pwsh 7 and NOT under Windows PowerShell 5.1, so the
# whole file skips there rather than silently passing. That is also why the
# engine carries its own validator instead of leaning on the schema.

$script:HDTSchemaSkip = -not [bool](Get-Command -Name Test-Json -ErrorAction SilentlyContinue)

if ($script:HDTSchemaSkip) {
    Write-Warning ("OsSchema contract SKIPPED: Test-Json does not exist on PowerShell {0} ({1}). The schema is validated on the pwsh 7 leg; Assert-HDTOperatingSystemDocument is what runs here." -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
}

# Discovery-time enumeration, so every fixture becomes its own test case rather
# than one loop whose first failure hides the rest.
$script:HDTOsFixtureRoot = Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'tests/fixtures/os'

# The two things JSON Schema draft-07 cannot say, listed rather than quietly
# excluded. If a future schema gains the ability, the blind-spot test goes red
# and the file moves out of this list.
#
#   invalid-default-index-absent.yaml   there is no cross-field reference from
#                                       defaultIndex into the images array
#   invalid-duplicate-index-distinct    uniqueItems compares WHOLE items, so it
#                                       cannot express "no two images share an
#                                       index" when the items differ elsewhere
$script:HDTSchemaBlindSpot = @('invalid-default-index-absent.yaml', 'invalid-duplicate-index-distinct.yaml')

$script:HDTValidFixture = @(Get-ChildItem -LiteralPath $script:HDTOsFixtureRoot -Filter 'valid-*.yaml' -File |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName; ShouldBeValid = $true } })

$script:HDTInvalidFixture = @(Get-ChildItem -LiteralPath $script:HDTOsFixtureRoot -Filter 'invalid-*.yaml' -File |
        Where-Object { $script:HDTSchemaBlindSpot -notcontains $_.Name } |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName; ShouldBeValid = $false } })

$script:HDTBlindSpotFixture = @(Get-ChildItem -LiteralPath $script:HDTOsFixtureRoot -Filter 'invalid-*.yaml' -File |
        Where-Object { $script:HDTSchemaBlindSpot -contains $_.Name } |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName } })

$script:HDTAgreementFixture = @($script:HDTValidFixture + $script:HDTInvalidFixture)

Describe 'os.yaml schema contract' -Skip:$script:HDTSchemaSkip {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name powershell-yaml -ErrorAction Stop

        $script:osSchemaPath = Join-Path -Path $script:repoRoot -ChildPath 'schemas/os.schema.json'
    }

    Context 'the schema file' {

        It 'ships schemas/os.schema.json' {
            Test-Path -LiteralPath $script:osSchemaPath -PathType Leaf | Should -BeTrue
        }

        It 'declares draft-07' {
            $schema = Get-Content -LiteralPath $script:osSchemaPath -Raw | ConvertFrom-Json

            $schema.'$schema' | Should -BeExactly 'http://json-schema.org/draft-07/schema#'
        }
    }

    Context 'the fixtures' {

        It 'validates <Name> against schemas/os.schema.json' -ForEach $script:HDTValidFixture {
            $schema = Get-Content -LiteralPath $script:osSchemaPath -Raw
            $json = (ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $FixturePath -Raw) -Ordered) | ConvertTo-Json -Depth 10

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }

        It 'rejects <Name> against schemas/os.schema.json' -ForEach $script:HDTInvalidFixture {
            $schema = Get-Content -LiteralPath $script:osSchemaPath -Raw
            $json = (ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $FixturePath -Raw) -Ordered) | ConvertTo-Json -Depth 10

            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'agrees with Assert-HDTOperatingSystemDocument about <Name>' -ForEach $script:HDTAgreementFixture {
            $schema = Get-Content -LiteralPath $script:osSchemaPath -Raw
            $yaml = Get-Content -LiteralPath $FixturePath -Raw
            $json = (ConvertFrom-Yaml -Yaml $yaml -Ordered) | ConvertTo-Json -Depth 10

            $schemaVerdict = [bool] (Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue)

            $engineVerdict = $true
            try {
                InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                    param($Yaml)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\OperatingSystems\Contoso\os.yaml'
                    Assert-HDTOperatingSystemDocument -Document $document -Path 'C:\ws\OperatingSystems\Contoso\os.yaml'
                }
            } catch {
                $engineVerdict = $false
            }

            $engineVerdict | Should -Be $ShouldBeValid
            $schemaVerdict | Should -Be $engineVerdict
        }

        It 'cannot express <Name>, so only the engine rejects it' -ForEach $script:HDTBlindSpotFixture {
            $schema = Get-Content -LiteralPath $script:osSchemaPath -Raw
            $yaml = Get-Content -LiteralPath $FixturePath -Raw
            $json = (ConvertFrom-Yaml -Yaml $yaml -Ordered) | ConvertTo-Json -Depth 10

            # The schema accepting this is the documented blind spot, recorded in
            # tests/fixtures/README.md. When that stops being true, move the file
            # out of $script:HDTSchemaBlindSpot rather than deleting this test.
            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeTrue

            $record = $null
            try {
                InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                    param($Yaml)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\OperatingSystems\Contoso\os.yaml'
                    Assert-HDTOperatingSystemDocument -Document $document -Path 'C:\ws\OperatingSystems\Contoso\os.yaml'
                }
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }
}
