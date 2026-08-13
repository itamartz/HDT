# The state.json schema contract (DESIGN 2.2: "every file has a schemaVersion and
# a JSON Schema in schemas/ so the console, CI, and cmdlets validate identically",
# DESIGN 4.3: the state document).
#
# TWO VALIDATORS, ONE VERDICT. The schema is the gate the console and CI use;
# Assert-HDTRunStateDocument is what actually runs in WinPE, where Test-Json does
# not exist. They must agree on every fixture, or a state document a console calls
# valid is rejected mid-deployment - on the machine that has already been wiped.
#
# Test-Json exists under pwsh 7 and NOT under Windows PowerShell 5.1, so the whole
# file skips there rather than silently passing. That is also why the engine
# carries its own validator instead of leaning on the schema.

$script:HDTSchemaSkip = -not [bool](Get-Command -Name Test-Json -ErrorAction SilentlyContinue)

if ($script:HDTSchemaSkip) {
    Write-Warning ("StateSchema contract SKIPPED: Test-Json does not exist on PowerShell {0} ({1}). The schema is validated on the pwsh 7 leg; Assert-HDTRunStateDocument is what runs here." -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
}

# Discovery-time enumeration, so every fixture becomes its own test case rather
# than one loop whose first failure hides the rest.
$script:HDTStateFixtureRoot = Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'tests/fixtures/state'

$script:HDTValidFixture = @(Get-ChildItem -LiteralPath $script:HDTStateFixtureRoot -Filter 'valid-*.json' -File |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName; ShouldBeValid = $true } })

$script:HDTInvalidFixture = @(Get-ChildItem -LiteralPath $script:HDTStateFixtureRoot -Filter 'invalid-*.json' -File |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName; ShouldBeValid = $false } })

$script:HDTAgreementFixture = @($script:HDTValidFixture + $script:HDTInvalidFixture)

Describe 'state.json schema contract' -Skip:$script:HDTSchemaSkip {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

        $script:stateSchemaPath = Join-Path -Path $script:repoRoot -ChildPath 'schemas/state.schema.json'
    }

    Context 'the schema file' {

        It 'ships schemas/state.schema.json' {
            Test-Path -LiteralPath $script:stateSchemaPath -PathType Leaf | Should -BeTrue
        }

        It 'declares draft-07' {
            $schema = Get-Content -LiteralPath $script:stateSchemaPath -Raw | ConvertFrom-Json

            $schema.'$schema' | Should -BeExactly 'http://json-schema.org/draft-07/schema#'
        }
    }

    Context 'the fixtures' {

        It 'validates <Name>' -ForEach $script:HDTValidFixture {
            $schema = Get-Content -LiteralPath $script:stateSchemaPath -Raw
            $json = Get-Content -LiteralPath $FixturePath -Raw

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }

        It 'rejects <Name>' -ForEach $script:HDTInvalidFixture {
            $schema = Get-Content -LiteralPath $script:stateSchemaPath -Raw
            $json = Get-Content -LiteralPath $FixturePath -Raw

            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'agrees with Assert-HDTRunStateDocument about <Name>' -ForEach $script:HDTAgreementFixture {
            $schema = Get-Content -LiteralPath $script:stateSchemaPath -Raw
            $json = Get-Content -LiteralPath $FixturePath -Raw

            $schemaVerdict = [bool] (Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue)

            $engineVerdict = $true
            try {
                InModuleScope Hephaestus -Parameters @{ Json = $json } {
                    param($Json)
                    $document = ConvertFrom-Json -InputObject $Json
                    Assert-HDTRunStateDocument -Document $document -Path 'C:\HDT\state.json'
                }
            } catch {
                $engineVerdict = $false
            }

            $engineVerdict | Should -Be $ShouldBeValid
            $schemaVerdict | Should -Be $engineVerdict
        }
    }

    Context 'the writer' {

        It 'round-trips a state document written by Save-HDTRunState' {
            # Worth more than any fixture: it is what keeps the writer and the
            # schema from drifting apart as the document grows.
            $fs = New-HDTFakeFileSystem
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc))

            $state = New-HDTRunState -SequenceId 'STD-CLIENT' -RunId 'r1' -Phase WinPE -Clock $clock `
                -Variable ([ordered] @{ HDTComputerName = 'PC-0001'; HDTApplications = @('7zip', 'Chrome') }) `
                -Step @(
                @{ Index = 1; Name = 'Validate'; Type = 'Validate'; Group = @('Preinstall'); Resumable = $false }
                @{ Index = 2; Name = 'Apply OS'; Type = 'ApplyImage'; Group = @('Install'); Resumable = $true }
            )

            Save-HDTRunState -State $state -Path 'X:\HDT\state.json' -FileSystem $fs -Clock $clock

            $schema = Get-Content -LiteralPath $script:stateSchemaPath -Raw
            Test-Json -Json ($fs.ReadAllText('X:\HDT\state.json')) -Schema $schema | Should -BeTrue
        }

        It 'round-trips an updated state document written by Save-HDTRunState' {
            $fs = New-HDTFakeFileSystem
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc))

            $state = New-HDTRunState -SequenceId 'STD-CLIENT' -RunId 'r1' -Phase WinPE -Clock $clock `
                -Step @(@{ Index = 1; Name = 'Validate'; Type = 'Validate'; Group = @('Preinstall'); Resumable = $false })

            $null = Update-HDTRunStateStep -State $state -Index 1 -Status Completed -Attempt 1 `
                -ExitCode 0 -Message 'ok' -DurationMs 1200 `
                -StartedUtc ([datetime]::new(2026, 8, 13, 0, 0, 1, [System.DateTimeKind]::Utc)) `
                -EndedUtc ([datetime]::new(2026, 8, 13, 0, 0, 2, [System.DateTimeKind]::Utc))

            Save-HDTRunState -State $state -Path 'X:\HDT\state.json' -FileSystem $fs -Clock $clock

            $schema = Get-Content -LiteralPath $script:stateSchemaPath -Raw
            Test-Json -Json ($fs.ReadAllText('X:\HDT\state.json')) -Schema $schema | Should -BeTrue
        }
    }
}
