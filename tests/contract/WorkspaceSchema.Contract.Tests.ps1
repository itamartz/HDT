# The workspace.yaml schema contract (DESIGN 2.2: "Every file has a
# schemaVersion and a JSON Schema in schemas/ so the console, CI, and cmdlets
# validate identically").
#
# TWO VALIDATORS, ONE VERDICT. The schema is the gate the console, an editor and
# CI use; Assert-HDTWorkspaceDocument is what actually runs in WinPE, where
# Test-Json does not exist. They must agree on every fixture, or an administrator
# gets a green editor and a red boot image build.
#
# AND ONE COMPARISON THAT IS THE POINT OF THE FILE: the schema's own "required"
# array and the validator's own required-key list are read out of the two source
# files and compared. Without it the schema is decoration - a key added to one
# and forgotten in the other would sail through every fixture that does not
# happen to omit it.
#
# Test-Json exists under pwsh 7 and NOT under Windows PowerShell 5.1, so the
# schema half skips there rather than silently passing.

$script:HDTSchemaSkip = -not [bool](Get-Command -Name Test-Json -ErrorAction SilentlyContinue)

if ($script:HDTSchemaSkip) {
    Write-Warning ("WorkspaceSchema contract SKIPPED: Test-Json does not exist on PowerShell {0} ({1}). The schema is validated on the pwsh 7 leg; Assert-HDTWorkspaceDocument is what runs here." -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
}

# Discovery-time enumeration, so every fixture becomes its own test case rather
# than one loop whose first failure hides the rest.
$script:HDTWorkspaceFixtureRoot = Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'tests/fixtures/workspace'

# No blind spots today. draft-07 cannot express a cross-field reference, and
# nothing in workspace.yaml needs one; the '..' rules are expressible with a
# negative lookahead, which Test-Json's regex engine supports (verified). If a
# future rule cannot be expressed, add it here with a fixture rather than
# quietly dropping the fixture from the list.
$script:HDTSchemaBlindSpot = @()

$script:HDTValidFixture = @(Get-ChildItem -LiteralPath $script:HDTWorkspaceFixtureRoot -Filter 'valid-*.yaml' -File |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName; ShouldBeValid = $true } })

$script:HDTInvalidFixture = @(Get-ChildItem -LiteralPath $script:HDTWorkspaceFixtureRoot -Filter 'invalid-*.yaml' -File |
        Where-Object { $script:HDTSchemaBlindSpot -notcontains $_.Name } |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName; ShouldBeValid = $false } })

$script:HDTAgreementFixture = @($script:HDTValidFixture + $script:HDTInvalidFixture)

Describe 'workspace.yaml schema contract' -Skip:$script:HDTSchemaSkip {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name powershell-yaml -ErrorAction Stop

        $script:workspaceSchemaPath = Join-Path -Path $script:repoRoot -ChildPath 'schemas/workspace.schema.json'
        $script:assertPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Private/Assert-HDTWorkspaceDocument.ps1'
        $script:samplePath = Join-Path -Path $script:repoRoot -ChildPath 'samples/workspace/workspace.yaml'
    }

    Context 'the schema file' {

        It 'ships schemas/workspace.schema.json' {
            Test-Path -LiteralPath $script:workspaceSchemaPath -PathType Leaf | Should -BeTrue
        }

        It 'declares draft-07' {
            $schema = Get-Content -LiteralPath $script:workspaceSchemaPath -Raw | ConvertFrom-Json

            $schema.'$schema' | Should -BeExactly 'http://json-schema.org/draft-07/schema#'
        }
    }

    Context 'the fixtures' {

        It 'validates <Name> against schemas/workspace.schema.json' -ForEach $script:HDTValidFixture {
            $schema = Get-Content -LiteralPath $script:workspaceSchemaPath -Raw
            $json = (ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $FixturePath -Raw) -Ordered) | ConvertTo-Json -Depth 10

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }

        It 'rejects <Name> against schemas/workspace.schema.json' -ForEach $script:HDTInvalidFixture {
            $schema = Get-Content -LiteralPath $script:workspaceSchemaPath -Raw
            $json = (ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $FixturePath -Raw) -Ordered) | ConvertTo-Json -Depth 10

            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'agrees with Assert-HDTWorkspaceDocument about <Name>' -ForEach $script:HDTAgreementFixture {
            $schema = Get-Content -LiteralPath $script:workspaceSchemaPath -Raw
            $yaml = Get-Content -LiteralPath $FixturePath -Raw
            $json = (ConvertFrom-Yaml -Yaml $yaml -Ordered) | ConvertTo-Json -Depth 10

            $schemaVerdict = [bool] (Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue)

            $engineVerdict = $true
            try {
                InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                    param($Yaml)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\workspace.yaml'
                    Assert-HDTWorkspaceDocument -Document $document -Path 'C:\ws\workspace.yaml'
                }
            } catch {
                $engineVerdict = $false
            }

            $engineVerdict | Should -Be $ShouldBeValid
            $schemaVerdict | Should -Be $engineVerdict
        }
    }

    Context 'the sample workspace' {

        It 'ships samples/workspace/workspace.yaml' {
            Test-Path -LiteralPath $script:samplePath -PathType Leaf | Should -BeTrue
        }

        It 'validates against the schema' {
            $schema = Get-Content -LiteralPath $script:workspaceSchemaPath -Raw
            $json = (ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $script:samplePath -Raw) -Ordered) | ConvertTo-Json -Depth 10

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }

        It 'is accepted by Assert-HDTWorkspaceDocument' {
            $yaml = Get-Content -LiteralPath $script:samplePath -Raw

            {
                InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                    param($Yaml)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\workspace.yaml'
                    Assert-HDTWorkspaceDocument -Document $document -Path 'C:\ws\workspace.yaml'
                }
            } | Should -Not -Throw
        }

        It 'carries no password anywhere in it' {
            # DESIGN 6.3 as a grep: the secret lives in
            # Control\share-credential.json, written by Set-HDTShareCredential,
            # and this is the file an admin hand-edits and commits.
            Get-Content -LiteralPath $script:samplePath -Raw | Should -Not -Match '(?im)^\s*password\s*:'
        }
    }

    Context 'the two required-key lists' {

        It 'declares the same required keys in the schema and in the validator' {
            $schema = Get-Content -LiteralPath $script:workspaceSchemaPath -Raw | ConvertFrom-Json
            $schemaRequired = @($schema.required) | Sort-Object

            # Read out of the validator's own source, from the variable it
            # actually loops over, so the comparison cannot be satisfied by a
            # list nothing uses.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:assertPath, [ref] $null, [ref] $null)
            $assignment = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left.Extent.Text -eq '$requiredRootKey'
                    }, $true))

            $assignment.Count | Should -Be 1 -Because 'Assert-HDTWorkspaceDocument declares its required keys in one place named $requiredRootKey'

            $engineRequired = @($assignment[0].Right.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
                    }, $true) | ForEach-Object { $_.Value }) | Sort-Object

            $engineRequired | Should -Be $schemaRequired
        }
    }

    Context 'the allowed-key lists' {

        # THE HOLE THIS CLOSES, AND IT WAS A REAL ONE. The required-key check
        # above compares only "required", so bootImage.skip could be added to
        # the schema, read by Import-HDTWorkspaceDocument and written by
        # Update-HDTBootImage with every unit test green - and still be refused
        # by the validator the moment a real workspace.yaml declared it. The
        # whole suite passed; the E2E fell over on the first boot.
        #
        # additionalProperties is false on all four of these objects, so the
        # schema's property list IS its allowed-key list, and the validator's
        # must say the same thing.
        It 'declares the same allowed keys as the schema for <Variable>' -ForEach @(
            @{ Variable = '$allowedRootKey'; Pointer = 'properties' }
            @{ Variable = '$allowedCredentialKey'; Pointer = 'properties.credential.properties' }
            @{ Variable = '$allowedBootImageKey'; Pointer = 'properties.bootImage.properties' }
            @{ Variable = '$allowedExtraContentKey'; Pointer = 'definitions.extraContentEntry.properties' }) {

            $schema = Get-Content -LiteralPath $script:workspaceSchemaPath -Raw | ConvertFrom-Json

            $node = $schema
            foreach ($step in ($Pointer -split '\.')) { $node = $node.$step }

            $schemaKey = @($node.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object

            # Read out of the validator's own source, same as above, so the
            # comparison cannot be satisfied by a list nothing loops over.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:assertPath, [ref] $null, [ref] $null)
            $assignment = @($ast.FindAll({
                        param($astNode)
                        $astNode -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $astNode.Left.Extent.Text -eq $Variable
                    }.GetNewClosure(), $true))

            $assignment.Count | Should -Be 1 -Because (
                'Assert-HDTWorkspaceDocument declares these keys in one place named {0}' -f $Variable)

            $engineKey = @($assignment[0].Right.FindAll({
                        param($astNode)
                        $astNode -is [System.Management.Automation.Language.StringConstantExpressionAst]
                    }, $true) | ForEach-Object { $_.Value }) | Sort-Object

            $engineKey | Should -Be $schemaKey -Because (
                'a key in one and not the other is a document the schema accepts and the engine refuses')
        }
    }
}
