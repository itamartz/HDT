# The update.yaml schema contract (DESIGN 2.2: "Every file has a schemaVersion
# and a JSON Schema in schemas/ so the console, CI, and cmdlets validate
# identically").
#
# TWO VALIDATORS, ONE VERDICT. The schema is the gate the console, an editor and
# CI use; Assert-HDTWindowsUpdateDocument is what actually runs in WinPE, where
# Test-Json does not exist. They must agree on every case here, or an
# administrator gets a green editor and a red deployment.
#
# WHAT IS IN THIS DOCUMENT AND WHERE IT CAME FROM, because it decides which
# cases matter: everything from baselineVersion downwards was read out of the
# package's own CompDB metadata rather than parsed from a file name, so a value
# that is not shaped like one means somebody hand-edited it. kind is the sharp
# one - it comes from Feature/@Type and is what makes servicing-stack ordering
# exact rather than a guess at a file name, so an unknown kind has to be refused
# by both gates and not merely by one.
#
# Test-Json exists under pwsh 7 and NOT under Windows PowerShell 5.1, so the
# whole file skips there rather than silently passing. That is also why the
# engine carries its own validator instead of leaning on the schema.
#
# THE CASES ARE INLINE, NOT IN tests\fixtures\update\. That directory holds real
# captured CompDB XML, which is what an update document is DERIVED from;
# Import-HDTWindowsUpdate writes the .yaml, so there is no corpus of authored
# ones, and inventing a directory of them would look like captured data and
# would not be.

$script:HDTSchemaSkip = -not [bool](Get-Command -Name Test-Json -ErrorAction SilentlyContinue)

if ($script:HDTSchemaSkip) {
    Write-Warning ("UpdateSchema contract SKIPPED: Test-Json does not exist on PowerShell {0} ({1}). The schema is validated on the pwsh 7 leg; Assert-HDTWindowsUpdateDocument is what runs here." -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
}

$script:HDTCase = @(
    @{
        Name          = 'valid-minimal'
        ShouldBeValid = $true
        Yaml          = @'
schemaVersion: 1
id: KB5094126-x64
kb: KB5094126
name: Cumulative Update for Windows 11 24H2
release: win11-24h2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
'@
    }
    @{
        Name          = 'valid-every-key'
        ShouldBeValid = $true
        Yaml          = @'
schemaVersion: 1
id: KB5094126-x64
kb: KB5094126
name: Cumulative Update for Windows 11 24H2
description: The October cumulative
release: win11-24h2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
sizeBytes: 812345678
baselineVersion: 10.0.26100.1
targetVersion: 10.0.26100.2314
build: 26100
revision: 2314
packageId: Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.2314.1.5
sourceBranch: ge_release
bundledSsuKb: KB5094135
bundledSsuVersion: 10.0.26100.2300
createdUtc: 2026-08-13T09:14:22Z
importedUtc: 2026-08-14T11:02:05Z
enabled: true
note: filed under win11-24h2 by hand; the package does not say which product it is for
'@
    }
    @{
        Name          = 'valid-servicing-stack'
        ShouldBeValid = $true
        Yaml          = @'
schemaVersion: 1
id: KB5094135-x64
kb: KB5094135
name: Servicing Stack Update
release: win11-24h2
kind: ServicingStackUpdate
architecture: x64
fileName: ssu-26100.2300-x64.msu
'@
    }
    @{
        Name          = 'invalid-unknown-key'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: KB5094126-x64
kb: KB5094126
name: Cumulative Update for Windows 11 24H2
release: win11-24h2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
product: Desktop
'@
    }
    @{
        Name          = 'invalid-missing-schemaversion'
        ShouldBeValid = $false
        Yaml          = @'
id: KB5094126-x64
kb: KB5094126
name: Cumulative Update for Windows 11 24H2
release: win11-24h2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
'@
    }
    @{
        Name          = 'invalid-newer-schemaversion'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 99
id: KB5094126-x64
kb: KB5094126
name: Cumulative Update for Windows 11 24H2
release: win11-24h2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
'@
    }
    @{
        Name          = 'invalid-missing-kb'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: KB5094126-x64
name: Cumulative Update for Windows 11 24H2
release: win11-24h2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
'@
    }
    @{
        # The kb is read from the package's own CompDB, so a bare number means
        # somebody hand-edited it into something the console will show and
        # nothing can look up.
        Name          = 'invalid-kb-is-not-a-kb-number'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: KB5094126-x64
kb: '5094126'
name: Cumulative Update for Windows 11 24H2
release: win11-24h2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
'@
    }
    @{
        Name          = 'invalid-blank-name'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: KB5094126-x64
kb: KB5094126
name: ''
release: win11-24h2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
'@
    }
    @{
        # The id is the folder name under WindowsUpdates\.
        Name          = 'invalid-id-with-a-space'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: KB5094126 x64
kb: KB5094126
name: Cumulative Update for Windows 11 24H2
release: win11-24h2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
'@
    }
    @{
        Name          = 'invalid-release-with-a-space'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: KB5094126-x64
kb: KB5094126
name: Cumulative Update for Windows 11 24H2
release: win11 24h2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
'@
    }
    @{
        # kind decides servicing order. A value outside the three is an ordering
        # decision nothing can make.
        Name          = 'invalid-unknown-kind'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: KB5094126-x64
kb: KB5094126
name: Cumulative Update for Windows 11 24H2
release: win11-24h2
kind: Hotfix
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
'@
    }
    @{
        Name          = 'invalid-unknown-architecture'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: KB5094126-x64
kb: KB5094126
name: Cumulative Update for Windows 11 24H2
release: win11-24h2
kind: CumulativeUpdate
architecture: ia64
fileName: windows11.0-kb5094126-x64.msu
'@
    }
    @{
        Name          = 'invalid-blank-filename'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: KB5094126-x64
kb: KB5094126
name: Cumulative Update for Windows 11 24H2
release: win11-24h2
kind: CumulativeUpdate
architecture: x64
fileName: ''
'@
    }
    @{
        Name          = 'invalid-negative-size'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: KB5094126-x64
kb: KB5094126
name: Cumulative Update for Windows 11 24H2
release: win11-24h2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
sizeBytes: -1
'@
    }
    @{
        Name          = 'invalid-build-is-not-an-integer'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: KB5094126-x64
kb: KB5094126
name: Cumulative Update for Windows 11 24H2
release: win11-24h2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
build: '26100'
'@
    }
    @{
        Name          = 'invalid-enabled-is-not-a-boolean'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: KB5094126-x64
kb: KB5094126
name: Cumulative Update for Windows 11 24H2
release: win11-24h2
kind: CumulativeUpdate
architecture: x64
fileName: windows11.0-kb5094126-x64.msu
enabled: sometimes
'@
    }
)

Describe 'update.yaml schema contract' -Skip:$script:HDTSchemaSkip {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name powershell-yaml -ErrorAction Stop

        $script:schemaPath = Join-Path -Path $script:repoRoot -ChildPath 'schemas/update.schema.json'
        $script:documentPath = 'C:\HDTLab\does-not-exist\Share\WindowsUpdates\KB5094126-x64\update.yaml'

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

        It 'ships schemas/update.schema.json' {
            Test-Path -LiteralPath $script:schemaPath -PathType Leaf | Should -BeTrue
        }

        It 'declares draft-07' {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json

            $schema.'$schema' | Should -BeExactly 'http://json-schema.org/draft-07/schema#'
        }

        It 'publishes exactly the three kinds the validator allows' {
            # kind is what makes servicing-stack ordering exact rather than a
            # guess at a file name, so the enum is asserted directly: a fourth
            # kind in one gate and not the other is an ordering decision the two
            # would make differently.
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json

            @($schema.properties.kind.enum) |
                Should -Be @('CumulativeUpdate', 'ServicingStackUpdate', 'Other')
        }

        It 'publishes exactly the three architectures the validator allows' {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json

            @($schema.properties.architecture.enum) | Should -Be @('x86', 'x64', 'arm64')
        }
    }

    Context 'the cases' {

        It 'validates <Name> against schemas/update.schema.json' -ForEach @($script:HDTCase | Where-Object { $_.ShouldBeValid }) {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }

        It 'rejects <Name> against schemas/update.schema.json' -ForEach @($script:HDTCase | Where-Object { -not $_.ShouldBeValid }) {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'agrees with Assert-HDTWindowsUpdateDocument about <Name>' -ForEach $script:HDTCase {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            $schemaVerdict = [bool] (Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue)

            $engineVerdict = $true
            try {
                InModuleScope Hephaestus -Parameters @{ Yaml = $Yaml; Path = $script:documentPath } {
                    param($Yaml, $Path)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path
                    Assert-HDTWindowsUpdateDocument -Document $document -Path $Path
                }
            } catch {
                $engineVerdict = $false
            }

            $engineVerdict | Should -Be $ShouldBeValid
            $schemaVerdict | Should -Be $engineVerdict
        }
    }
}
