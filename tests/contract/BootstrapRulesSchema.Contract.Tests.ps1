# The bootstrap-rules.yaml schema contract (DESIGN 2.2: "Every file has a
# schemaVersion and a JSON Schema in schemas/ so the console, CI, and cmdlets
# validate identically").
#
# TWO VALIDATORS, ONE VERDICT. The schema is the gate the console, an editor and
# CI use; Import-HDTBootstrapRuleDocument - the rules reader plus
# Assert-HDTBootstrapRuleDocument - is what actually runs in WinPE, where
# Test-Json does not exist. They must agree on every case here, or an
# administrator gets a green editor and a red deployment.
#
# THIS FILE IS THE ONE THAT COSTS A REBUILD TO GET WRONG. bootstrap-rules.yaml
# travels INSIDE the boot image; it is read before there is a share, a workspace
# or a task sequence, and fixing a typo in it means building the image again. It
# had no schema at all until now, so the console and every editor had nothing to
# check it against - the survey of 2026-09-02, section 6.3.
#
# Test-Json exists under pwsh 7 and NOT under Windows PowerShell 5.1, so the
# whole file skips there rather than silently passing. That is also why the
# engine carries its own validator instead of leaning on the schema.
#
# THE CASES ARE INLINE, NOT IN tests\fixtures\. Nothing ships a
# bootstrap-rules.yaml - New-HDTBootImage writes one from the console's settings
# - so there is no corpus of real files to point at, and a fixture directory
# holding documents invented for this test would look like captured data and
# would not be.

$script:HDTSchemaSkip = -not [bool](Get-Command -Name Test-Json -ErrorAction SilentlyContinue)

if ($script:HDTSchemaSkip) {
    Write-Warning ("BootstrapRulesSchema contract SKIPPED: Test-Json does not exist on PowerShell {0} ({1}). The schema is validated on the pwsh 7 leg; Assert-HDTBootstrapRuleDocument is what runs here." -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
}

# Discovery-time enumeration, so every case becomes its own test rather than one
# loop whose first failure hides the rest.
$script:HDTCase = @(
    @{
        Name          = 'valid-site-share'
        ShouldBeValid = $true
        Yaml          = @'
schemaVersion: 1
rules:
  - name: Site A
    when:
      HDTDefaultGateway: 192.0.2.1
    set:
      HDTDeployRoot: \\SERVER-A\DeploymentShare$
'@
    }
    @{
        Name          = 'valid-share-and-account'
        ShouldBeValid = $true
        Yaml          = @'
schemaVersion: 1
rules:
  - name: Site B
    when:
      HDTDefaultGateway: 198.51.100.1
    set:
      HDTDeployRoot: \\SERVER-B\DeploymentShare$
      HDTUserId: svc-hdt-deploy
      HDTUserDomain: CONTOSO
      HDTUserPassword: not-a-real-secret
'@
    }
    @{
        Name          = 'valid-fallback-only'
        ShouldBeValid = $true
        Yaml          = @'
schemaVersion: 1
rules:
  - name: Default
    set:
      HDTDeployRoot: \\SERVER-A\DeploymentShare$
'@
    }
    @{
        Name          = 'invalid-setfrom'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
rules:
  - name: Decide it in script
    setFrom: Scripts\ChooseShare.ps1
'@
    }
    @{
        Name          = 'invalid-variable-after-the-share'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
rules:
  - name: Name the machine
    set:
      HDTComputerName: FIN-0007
'@
    }
    @{
        Name          = 'invalid-domain-join-password'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
rules:
  - name: Join the domain
    set:
      HDTDeployRoot: \\SERVER-A\DeploymentShare$
      HDTDomainAdminPassword: not-a-real-secret
'@
    }
    @{
        Name          = 'invalid-one-backslash-deploy-root'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
rules:
  - name: Site A
    set:
      HDTDeployRoot: \SERVER-A\DeploymentShare$
'@
    }
    @{
        Name          = 'invalid-missing-schemaversion'
        ShouldBeValid = $false
        Yaml          = @'
rules:
  - name: Site A
    set:
      HDTDeployRoot: \\SERVER-A\DeploymentShare$
'@
    }
    @{
        Name          = 'invalid-rule-without-name'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
rules:
  - set:
      HDTDeployRoot: \\SERVER-A\DeploymentShare$
'@
    }
    @{
        Name          = 'invalid-rule-without-assignment'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
rules:
  - name: Sets nothing
    when:
      HDTDefaultGateway: 192.0.2.1
'@
    }
)

Describe 'bootstrap-rules.yaml schema contract' -Skip:$script:HDTSchemaSkip {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name powershell-yaml -ErrorAction Stop

        $script:schemaPath = Join-Path -Path $script:repoRoot -ChildPath 'schemas/bootstrap-rules.schema.json'
        $script:documentPath = 'X:\HDT\bootstrap-rules.yaml'

        function ConvertTo-HDTCaseJson {
            <#
                A case as the JSON the schema is handed. An empty YAML document
                parses to $null and ConvertTo-Json emits nothing at all for it,
                which Test-Json refuses to bind rather than reporting as
                invalid; the honest JSON for "the file held no document" is the
                literal null.
            #>
            param([string] $Yaml)

            $document = ConvertFrom-Yaml -Yaml $Yaml -Ordered

            if ($null -eq $document) { return 'null' }

            return ($document | ConvertTo-Json -Depth 10)
        }

        function Test-HDTCaseEngineVerdict {
            <#
                What the engine says about a case - the reader and the
                vocabulary check together, which is what
                Import-HDTBootstrapRuleDocument is.
            #>
            param([string] $Yaml)

            $fileSystem = New-HDTFakeFileSystem -File @{ 'X:\HDT\bootstrap-rules.yaml' = $Yaml }

            try {
                $null = Import-HDTBootstrapRuleDocument -Path 'X:\HDT\bootstrap-rules.yaml' -FileSystem $fileSystem
                return $true
            } catch {
                return $false
            }
        }
    }

    Context 'the schema file' {

        It 'ships schemas/bootstrap-rules.schema.json' {
            Test-Path -LiteralPath $script:schemaPath -PathType Leaf | Should -BeTrue
        }

        It 'declares draft-07' {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json

            $schema.'$schema' | Should -BeExactly 'http://json-schema.org/draft-07/schema#'
        }

        It 'publishes exactly the four names the validator allows' {
            # THE ALLOW-LIST IS THE WHOLE POINT OF THIS DOCUMENT TYPE, so it is
            # asserted against the schema's own enum rather than only through a
            # case. Assert-HDTBootstrapRuleDocument holds the same four; the two
            # drifting apart is what this contract exists to catch.
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json

            @($schema.definitions.set.propertyNames.enum) |
                Should -Be @('HDTDeployRoot', 'HDTUserId', 'HDTUserDomain', 'HDTUserPassword')
        }

        It 'does not declare setFrom' {
            # setFrom names a script under Scripts\ on the share, and this file
            # is read before there is one.
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json

            $schema.definitions.rule.properties.PSObject.Properties.Name | Should -Not -Contain 'setFrom'
        }
    }

    Context 'the cases' {

        It 'validates <Name> against schemas/bootstrap-rules.schema.json' -ForEach @($script:HDTCase | Where-Object { $_.ShouldBeValid }) {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }

        It 'rejects <Name> against schemas/bootstrap-rules.schema.json' -ForEach @($script:HDTCase | Where-Object { -not $_.ShouldBeValid }) {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'agrees with Import-HDTBootstrapRuleDocument about <Name>' -ForEach $script:HDTCase {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            $schemaVerdict = [bool] (Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue)
            $engineVerdict = Test-HDTCaseEngineVerdict -Yaml $Yaml

            $engineVerdict | Should -Be $ShouldBeValid
            $schemaVerdict | Should -Be $engineVerdict
        }
    }
}
