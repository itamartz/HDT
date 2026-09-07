# The os-releases.yaml schema contract (DESIGN 2.2: "Every file has a
# schemaVersion and a JSON Schema in schemas/ so the console, CI, and cmdlets
# validate identically").
#
# TWO VALIDATORS, ONE VERDICT. The schema is the gate the console, an editor and
# CI use; Assert-HDTOsReleaseDocument is what actually runs in WinPE, where
# Test-Json does not exist. They must agree on every case here, or an
# administrator gets a green editor and a red deployment.
#
# WHY THIS LIST EXISTS AT ALL, because it decides what the cases mean: a .msu
# does not say which product it is for. The Windows 11 24H2 and Windows Server
# 2025 cumulative updates share a file-name shape, a Product of Desktop, an
# architecture and the build 26100 - so the administrator names the release at
# import, and this file is the vocabulary they name it from.
#
# Test-Json exists under pwsh 7 and NOT under Windows PowerShell 5.1, so the
# whole file skips there rather than silently passing. That is also why the
# engine carries its own validator instead of leaning on the schema.
#
# THE CASES ARE INLINE, NOT IN tests\fixtures\. New-HDTWorkspace seeds this
# document, so there is no corpus of authored ones to point at, and a fixture
# directory of documents invented for this test would look like captured data
# and would not be.

$script:HDTSchemaSkip = -not [bool](Get-Command -Name Test-Json -ErrorAction SilentlyContinue)

if ($script:HDTSchemaSkip) {
    Write-Warning ("OsReleasesSchema contract SKIPPED: Test-Json does not exist on PowerShell {0} ({1}). The schema is validated on the pwsh 7 leg; Assert-HDTOsReleaseDocument is what runs here." -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
}

$script:HDTCase = @(
    @{
        Name          = 'valid-minimal'
        ShouldBeValid = $true
        Yaml          = @'
schemaVersion: 1
releases:
  - id: win11-24h2
'@
    }
    @{
        Name          = 'valid-every-key'
        ShouldBeValid = $true
        Yaml          = @'
schemaVersion: 1
releases:
  - id: win11-24h2
    name: Windows 11 24H2
    build: 26100
    branch: ge_release
    verified: true
    note: read off C:\HDTLab\media\Win11-LTSC-2024 install.wim
  - id: ws2025
    name: Windows Server 2025
'@
    }
    @{
        Name          = 'invalid-unknown-root-key'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
releases:
  - id: win11-24h2
default: win11-24h2
'@
    }
    @{
        Name          = 'invalid-missing-schemaversion'
        ShouldBeValid = $false
        Yaml          = @'
releases:
  - id: win11-24h2
'@
    }
    @{
        Name          = 'invalid-newer-schemaversion'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 99
releases:
  - id: win11-24h2
'@
    }
    @{
        Name          = 'invalid-missing-releases'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
'@
    }
    @{
        Name          = 'invalid-empty-releases'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
releases: []
'@
    }
    @{
        Name          = 'invalid-unknown-release-key'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
releases:
  - id: win11-24h2
    product: Desktop
'@
    }
    @{
        Name          = 'invalid-release-without-id'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
releases:
  - name: Windows 11 24H2
'@
    }
    @{
        Name          = 'invalid-release-id-with-a-space'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
releases:
  - id: win11 24h2
'@
    }
    @{
        Name          = 'invalid-blank-release-name'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
releases:
  - id: win11-24h2
    name: ''
'@
    }
    @{
        # OMIT THE KEY RATHER THAN GUESS ONE. A wrong build silently refuses
        # every correct import filed under the release.
        Name          = 'invalid-build-is-not-an-integer'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
releases:
  - id: win11-24h2
    build: '26100'
'@
    }
    @{
        Name          = 'invalid-build-is-zero'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
releases:
  - id: win11-24h2
    build: 0
'@
    }
    @{
        Name          = 'invalid-verified-is-not-a-boolean'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
releases:
  - id: win11-24h2
    build: 26100
    verified: probably
'@
    }
)

# WHAT JSON SCHEMA DRAFT-07 CANNOT SAY ABOUT A RELEASE LIST, listed rather than
# quietly excluded. If a future schema gains the ability, the blind-spot test
# goes red and the case moves into $script:HDTCase.
#
#   duplicate-release-id     there is no uniqueness constraint on a property
#                            across array items, so the schema cannot see that
#                            two releases claim the same id - and the second
#                            would never be reachable, first match winning
#                            everywhere it is read
#   verified-without-build   expressible only as a nested not/allOf whose failure
#                            message would name none of the keys involved; the
#                            engine's sentence is the one worth having, and the
#                            contradiction is refused there
$script:HDTBlindSpot = @(
    @{
        Name = 'duplicate-release-id'
        Yaml = @'
schemaVersion: 1
releases:
  - id: win11-24h2
    name: Windows 11 24H2
  - id: win11-24h2
    name: Windows 11 24H2 again
'@
    }
    @{
        Name = 'verified-without-build'
        Yaml = @'
schemaVersion: 1
releases:
  - id: win11-24h2
    verified: true
'@
    }
)

Describe 'os-releases.yaml schema contract' -Skip:$script:HDTSchemaSkip {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name powershell-yaml -ErrorAction Stop

        $script:schemaPath = Join-Path -Path $script:repoRoot -ChildPath 'schemas/os-releases.schema.json'
        $script:documentPath = 'C:\HDTLab\does-not-exist\Share\Control\os-releases.yaml'

        function ConvertTo-HDTCaseJson {
            <#
                A case as the JSON the schema is handed. An empty YAML document
                parses to $null and ConvertTo-Json emits nothing at all for it,
                which Test-Json refuses to bind rather than reporting as invalid;
                the honest JSON for "the file held no document" is the literal
                null.
            #>
            param([string] $Yaml)

            $document = ConvertFrom-Yaml -Yaml $Yaml -Ordered

            if ($null -eq $document) { return 'null' }

            return ($document | ConvertTo-Json -Depth 10)
        }
    }

    Context 'the schema file' {

        It 'ships schemas/os-releases.schema.json' {
            Test-Path -LiteralPath $script:schemaPath -PathType Leaf | Should -BeTrue
        }

        It 'declares draft-07' {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json

            $schema.'$schema' | Should -BeExactly 'http://json-schema.org/draft-07/schema#'
        }

        It 'does not require build' {
            # A release whose build has not been read off real media omits the
            # key rather than guessing, because a wrong build silently refuses
            # every correct import filed under it. This is the rule most likely
            # to be "tightened" by someone reading build as mandatory.
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json

            $schema.definitions.release.required | Should -Not -Contain 'build'
        }
    }

    Context 'the cases' {

        It 'validates <Name> against schemas/os-releases.schema.json' -ForEach @($script:HDTCase | Where-Object { $_.ShouldBeValid }) {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }

        It 'rejects <Name> against schemas/os-releases.schema.json' -ForEach @($script:HDTCase | Where-Object { -not $_.ShouldBeValid }) {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'agrees with Assert-HDTOsReleaseDocument about <Name>' -ForEach $script:HDTCase {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            $schemaVerdict = [bool] (Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue)

            $engineVerdict = $true
            try {
                InModuleScope Hephaestus -Parameters @{ Yaml = $Yaml; Path = $script:documentPath } {
                    param($Yaml, $Path)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path
                    Assert-HDTOsReleaseDocument -Document $document -Path $Path
                }
            } catch {
                $engineVerdict = $false
            }

            $engineVerdict | Should -Be $ShouldBeValid
            $schemaVerdict | Should -Be $engineVerdict
        }

        It 'cannot express <Name>, so only the engine rejects it' -ForEach $script:HDTBlindSpot {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            # The schema accepting this is the documented blind spot. When that
            # stops being true, move the case out of $script:HDTBlindSpot rather
            # than deleting this test.
            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeTrue

            $record = $null
            try {
                InModuleScope Hephaestus -Parameters @{ Yaml = $Yaml; Path = $script:documentPath } {
                    param($Yaml, $Path)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path
                    Assert-HDTOsReleaseDocument -Document $document -Path $Path
                }
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }
}
