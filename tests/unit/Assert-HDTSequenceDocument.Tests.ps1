# Assert-HDTSequenceDocument is the WinPE-side validator for sequence.yaml,
# mirroring Assert-HDTRuleDocument exactly: Test-Json does not exist under
# Windows PowerShell 5.1, so schemas/sequence.schema.json is the gate for the
# console, editors and CI while this is the gate for a deployment.
#
# Every refusal asserts the ERROR ID and the LOCATOR, never merely that
# something threw (tests/helpers/README.md 12): a missing implementation throws
# CommandNotFoundException, which satisfies a bare -Throw.
#
# STEP TYPES ARE DELIBERATELY NOT VALIDATED HERE. Types are pluggable and
# discovered at runtime, so a sequence authored for a workspace whose Modules\
# carries a third-party step must still import on a machine that does not. An
# unknown type fails the STEP, at execution, naming the known types.
#
# It is private, so every call runs inside InModuleScope.

$script:HDTSequenceFixtureRoot = Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'tests/fixtures/sequences'

$script:HDTValidFixture = @(Get-ChildItem -LiteralPath $script:HDTSequenceFixtureRoot -Filter 'valid-*.yaml' -File |
        ForEach-Object { @{ Name = $_.Name; FixturePath = $_.FullName } })

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # A scriptblock rather than a function: every .ps1 under tests/ is covered by
    # the naming contract and the analyzer, and a helper here would have to be a
    # Verb-HDTNoun command for no gain.
    $script:assertFailure = {
        param([string] $Yaml)

        $record = $null
        try {
            InModuleScope Hephaestus -Parameters @{ Yaml = $Yaml } {
                param($Yaml)
                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\sequence.yaml'
                Assert-HDTSequenceDocument -Document $document -Path 'C:\ws\sequence.yaml'
            }
        } catch {
            $record = $_
        }

        return $record
    }
}

Describe 'Assert-HDTSequenceDocument' {

    Context 'the document' {

        It 'refuses an empty file' {
            $record = & $script:assertFailure ''

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*empty*'
        }

        It 'refuses a document that is not a mapping' {
            $record = & $script:assertFailure "- one`n- two`n"

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*mapping*'
        }

        It 'refuses an unknown root key' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
priority: 1
steps:
  - name: First
    type: NoOp
'@

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike "*priority*"
        }

        It 'refuses a missing schemaVersion' {
            $record = & $script:assertFailure @'
id: X
name: X
steps:
  - name: First
    type: NoOp
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*schemaVersion*'
        }

        It 'refuses a schemaVersion that is not an integer' {
            $record = & $script:assertFailure @'
schemaVersion: one
id: X
name: X
steps:
  - name: First
    type: NoOp
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*integer*'
        }

        It 'refuses a schemaVersion newer than this engine' {
            $record = & $script:assertFailure @'
schemaVersion: 99
id: X
name: X
steps:
  - name: First
    type: NoOp
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*newer*'
        }

        It 'refuses a missing id' {
            $record = & $script:assertFailure @'
schemaVersion: 1
name: X
steps:
  - name: First
    type: NoOp
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*id*'
        }

        It 'refuses a malformed id' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: "bad id"
name: X
steps:
  - name: First
    type: NoOp
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*bad id*'
        }

        It 'refuses a missing name' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
steps:
  - name: First
    type: NoOp
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*name*'
        }

        It 'refuses a missing steps key' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*steps*'
        }

        It 'refuses an empty steps list' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps: []
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*at least one step*'
        }
    }

    Context 'nodes' {

        It 'refuses a node that is not a mapping' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - just a string
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*mapping*'
        }

        It 'refuses a group without a steps key' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - group: Preinstall
    condition: '"%A%" == "1"'
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Preinstall*'
        }

        It 'refuses a group with an empty steps list' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - group: Preinstall
    steps: []
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Preinstall*'
        }

        It 'refuses a group with an unknown key' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - group: Preinstall
    priority: 1
    steps:
      - name: First
        type: NoOp
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*priority*'
            $record.Exception.Message | Should -BeLike '*Preinstall*'
        }

        It 'refuses a step without a name' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - name: First
    type: NoOp
  - type: NoOp
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*step 2*'
        }

        It 'refuses a step without a type' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - name: First
    type: NoOp
  - name: Typeless
    message: nothing
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Typeless*'
        }

        It 'refuses a malformed type' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - name: First
    type: Apply-Image
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Apply-Image*'
        }

        It 'refuses a node that is both a group and a step' {
            # It declares steps, which makes it a group, AND type, which makes it
            # a step. This is the one case JSON Schema draft-07 cannot reject.
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - group: Preinstall
    name: Also a step
    type: PowerShell
    steps:
      - name: First
        type: NoOp
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Preinstall*'
        }

        It 'accepts a step type-specific property called group' {
            # DESIGN 4.1's ApplyDrivers step declares `group: "%HDTDriverGroup%"`,
            # so `group` alone cannot be the discriminator without invalidating
            # the design's own example. A node is a GROUP when it declares steps.
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - name: Inject Drivers
    type: ApplyDrivers
    group: "%HDTDriverGroup%"
'@

            $record | Should -BeNullOrEmpty
        }
    }

    Context 'common properties' {

        It 'refuses a non-boolean continueOnError' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - name: First
    type: NoOp
    continueOnError: sometimes
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*continueOnError*'
            $record.Exception.Message | Should -BeLike '*First*'
        }

        It 'refuses a non-boolean resumable' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - name: First
    type: NoOp
    resumable: maybe
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*resumable*'
        }

        It 'refuses a zero timeoutMinutes' {
            # 0 is not "unbounded" in the document. Unbounded is the ABSENCE of
            # timeoutMinutes; writing 0 is far more likely to be a mistake.
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - name: First
    type: NoOp
    timeoutMinutes: 0
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*timeoutMinutes*'
        }

        It 'refuses a negative timeoutMinutes' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - name: First
    type: NoOp
    timeoutMinutes: -5
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*timeoutMinutes*'
        }

        It 'refuses a runIn outside the set' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - name: First
    type: NoOp
    runIn: Windows
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Windows*'
        }

        It 'refuses a retry that is not a mapping' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - name: First
    type: NoOp
    retry: 3
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*retry*'
        }

        It 'refuses a retry count above ten' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - name: First
    type: NoOp
    retry:
      count: 11
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*count*'
        }

        It 'refuses a negative retry delaySeconds' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - name: First
    type: NoOp
    retry:
      count: 2
      delaySeconds: -1
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*delaySeconds*'
        }

        It 'refuses an unknown retry backoff' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - name: First
    type: NoOp
    retry:
      count: 2
      backoff: quadratic
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*quadratic*'
        }

        It 'refuses an unparseable condition on a step' {
            # The condition grammar is checked at IMPORT, not at execution: a
            # malformed condition must fail authoring, not a deployment at 3 a.m.
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - name: First
    type: NoOp
    condition: "%A% =~ 1"
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*%A% =~ 1*'
        }

        It 'refuses an unparseable condition on a group' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
steps:
  - group: Preinstall
    condition: "%A% =~ 1"
    steps:
      - name: First
        type: NoOp
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Preinstall*'
        }
    }

    Context 'variables' {

        It 'refuses a variable name that does not start with HDT' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
variables:
  OSImage: Win11
steps:
  - name: First
    type: NoOp
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*OSImage*'
        }

        It 'refuses an engine variable' {
            $record = & $script:assertFailure @'
schemaVersion: 1
id: X
name: X
variables:
  _HDTLogPath: C:\Somewhere
steps:
  - name: First
    type: NoOp
'@

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*_HDTLogPath*'
        }
    }

    Context 'what it accepts' {

        It 'accepts <Name> without throwing' -ForEach $script:HDTValidFixture {
            $yaml = Get-Content -LiteralPath $FixturePath -Raw

            {
                InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                    param($Yaml)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\sequence.yaml'
                    Assert-HDTSequenceDocument -Document $document -Path 'C:\ws\sequence.yaml'
                }
            } | Should -Not -Throw
        }
    }
}
