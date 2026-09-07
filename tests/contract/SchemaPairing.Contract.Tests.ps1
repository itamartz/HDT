# A DOCUMENT TYPE HAS THREE SURFACES AND THEY SHIP AS A SET.
#
# DESIGN 2.2: "Every file has a schemaVersion and a JSON Schema in schemas/ so
# the console, CI, and cmdlets validate identically". That sentence names three
# things, and this repository has shipped each of them without the others:
#
#   schemas\<type>.schema.json          the gate a console, an editor and CI use
#   Private\Assert-HDT<Type>Document    the gate that runs in WinPE, where
#                                       Test-Json does not exist
#   tests\contract\*.Contract.Tests.ps1 the file that proves the two agree
#
# WHAT WENT MISSING, EACH TIME UNNOTICED:
#
#   machine.schema.json had no validator. Get-HDTMachineOverride carried the
#   rules inline instead, so the schema and the engine were two hand-written
#   copies of one vocabulary with nothing holding them together.
#
#   Assert-HDTBootstrapRuleDocument had no schema. The console and every editor
#   had nothing to validate bootstrap-rules.yaml against - the one document that
#   travels INSIDE the boot image, where being wrong costs a rebuild.
#
#   media, os-releases, selection-profile and update had schemas and validators
#   and no contract test, so nothing proved schema equals validator for them.
#
# THIS IS THE TEST WRITTEN AGAINST THE SET (CLAUDE.md rule 8). A test naming
# app.schema.json passes for app.schema.json and fails nobody afterwards. The
# three sets are enumerated off disk and paired through the map below, so the
# FOURTEENTH document type cannot be half-added: a schema with no validator, a
# validator with no schema, or either with no contract test is a red test on the
# commit that introduced it, not a survey finding three months later.
#
# THE MAP IS DECLARED RATHER THAN DERIVED because the names genuinely differ -
# os.schema.json is Assert-HDTOperatingSystemDocument, state.schema.json is
# Assert-HDTRunStateDocument, update.schema.json is
# Assert-HDTWindowsUpdateDocument. A rule that guessed would either reject those
# or accept anything.
#
# NO Test-Json HERE, SO IT RUNS ON THE 5.1 GATE. Everything below is file
# existence and a text scan; the schema contracts this test insists on are the
# ones that skip on 5.1 (see AppSchema.Contract.Tests.ps1). That is deliberate -
# the test that says "the contract file exists" must not itself be skipped on
# the leg that runs every day.
#
# EVERYTHING THE RUN PHASE NEEDS ARRIVES THROUGH -ForEach OR IS RECOMPUTED IN
# BeforeAll. The lists below are discovery's (SPIKES S9.15, and
# SlowSuiteSkip.Contract.Tests.ps1 scans this directory for exactly that
# mistake); a -ForEach hashtable is captured at discovery and handed to the run
# phase, which is the supported way across that boundary.

$script:HDTDocumentType = @(
    @{ Schema = 'app'; Validator = 'Assert-HDTApplicationDocument' }
    @{ Schema = 'bootstrap-rules'; Validator = 'Assert-HDTBootstrapRuleDocument' }
    @{ Schema = 'machine'; Validator = 'Assert-HDTMachineDocument' }
    @{ Schema = 'media'; Validator = 'Assert-HDTMediaDocument' }
    @{ Schema = 'os'; Validator = 'Assert-HDTOperatingSystemDocument' }
    @{ Schema = 'os-releases'; Validator = 'Assert-HDTOsReleaseDocument' }
    @{ Schema = 'rules'; Validator = 'Assert-HDTRuleDocument' }
    @{ Schema = 'selection-profile'; Validator = 'Assert-HDTSelectionProfileDocument' }
    @{ Schema = 'sequence'; Validator = 'Assert-HDTSequenceDocument' }
    @{ Schema = 'state'; Validator = 'Assert-HDTRunStateDocument' }
    @{ Schema = 'update'; Validator = 'Assert-HDTWindowsUpdateDocument' }
    @{ Schema = 'wizard'; Validator = 'Assert-HDTWizardDocument' }
    @{ Schema = 'workspace'; Validator = 'Assert-HDTWorkspaceDocument' }
)

# THE EXCEPTION LIST, AND IT IS EMPTY. A row here must carry a reason a reader
# can weigh; "not written yet" is not one - that is a red test, which is the
# point of this file.
#
#   @{ Schema = '<name>'; Reason = 'why this type has no contract test' }
$script:HDTContractException = @()

$script:HDTDocumentTypeCase = @($script:HDTDocumentType | ForEach-Object {
        @{
            Name          = $_.Schema
            SchemaFile    = ('{0}.schema.json' -f $_.Schema)
            ValidatorFile = ('{0}.ps1' -f $_.Validator)
            Validator     = $_.Validator
        }
    })

$script:HDTContractCase = @($script:HDTDocumentTypeCase |
        Where-Object { @($script:HDTContractException | ForEach-Object { $_.Schema }) -notcontains $_.Name })

# The whole declared map, as one -ForEach case, for the two set-direction tests.
$script:HDTDeclaredCase = @(@{
        DeclaredSchema    = @($script:HDTDocumentType | ForEach-Object { '{0}.schema.json' -f $_.Schema })
        DeclaredValidator = @($script:HDTDocumentType | ForEach-Object { '{0}.ps1' -f $_.Validator })
    })

Describe 'every HDT document type ships a schema, a validator and a contract test' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:schemaDirectory = Join-Path -Path $script:repoRoot -ChildPath 'schemas'
        $script:validatorDirectory = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Private'
        $script:contractDirectory = $PSScriptRoot

        $script:schemaFile = @(Get-ChildItem -LiteralPath $script:schemaDirectory -Filter '*.schema.json' -File |
                ForEach-Object { $_.Name })

        $script:validatorFile = @(Get-ChildItem -LiteralPath $script:validatorDirectory -Filter 'Assert-HDT*Document.ps1' -File |
                ForEach-Object { $_.Name })

        # The contract files that could name a schema, this one excluded: it
        # names every schema in the repository, so counting itself would make
        # the coverage test below pass for a schema nothing validates.
        $script:contractText = @(Get-ChildItem -LiteralPath $script:contractDirectory -Filter '*.Contract.Tests.ps1' -File |
                Where-Object { $_.Name -ne 'SchemaPairing.Contract.Tests.ps1' } |
                ForEach-Object {
                    [pscustomobject] @{ Name = $_.Name; Text = (Get-Content -LiteralPath $_.FullName -Raw) }
                })
    }

    Context 'the sets are real' {

        # A contract that scans nothing passes for the wrong reason
        # (tests/helpers/README.md section 12), and @($null).Count is 1, so a
        # count alone proves nothing. These name members the sets must contain.

        It 'finds the schemas' {
            @($script:schemaFile).Count | Should -BeGreaterThan 10
            $script:schemaFile | Should -Contain 'rules.schema.json'
            $script:schemaFile | Should -Contain 'sequence.schema.json'
        }

        It 'finds the validators' {
            @($script:validatorFile).Count | Should -BeGreaterThan 10
            $script:validatorFile | Should -Contain 'Assert-HDTRuleDocument.ps1'
            $script:validatorFile | Should -Contain 'Assert-HDTSequenceDocument.ps1'
        }

        It 'finds the contract files' {
            @($script:contractText).Count | Should -BeGreaterThan 10
            @($script:contractText | ForEach-Object { $_.Name }) | Should -Contain 'AppSchema.Contract.Tests.ps1'
        }
    }

    Context 'the map covers what is on disk' {

        It 'declares every schema in the schemas directory' -ForEach $script:HDTDeclaredCase {
            $undeclared = @($script:schemaFile | Where-Object { $DeclaredSchema -notcontains $_ })

            $undeclared -join ', ' | Should -BeExactly '' -Because (
                'a schema nothing declares is a document type whose validator and contract test nobody is checking for. ' +
                'Add a row to $script:HDTDocumentType in this file.')
        }

        It 'declares every Assert-HDT*Document validator in Private' -ForEach $script:HDTDeclaredCase {
            $undeclared = @($script:validatorFile | Where-Object { $DeclaredValidator -notcontains $_ })

            $undeclared -join ', ' | Should -BeExactly '' -Because (
                'a validator nothing declares is a document type with no published schema, so a console or an editor ' +
                'has nothing to validate the file against. Add a row to $script:HDTDocumentType in this file.')
        }
    }

    Context 'each declared type has all three surfaces' {

        It 'ships schemas\<SchemaFile>' -ForEach $script:HDTDocumentTypeCase {
            $path = Join-Path -Path $script:schemaDirectory -ChildPath $SchemaFile

            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue -Because (
                '{0} is the gate the console, an editor and CI validate a {1} document against.' -f $SchemaFile, $Name)
        }

        It 'ships Private\<ValidatorFile>' -ForEach $script:HDTDocumentTypeCase {
            $path = Join-Path -Path $script:validatorDirectory -ChildPath $ValidatorFile

            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue -Because (
                '{0} is the gate that runs in WinPE, where Test-Json does not exist.' -f $Validator)
        }

        It 'has a contract test that validates <SchemaFile>' -ForEach $script:HDTContractCase {
            $naming = @($script:contractText |
                    Where-Object { $_.Text -like ('*{0}*' -f $SchemaFile) } |
                    ForEach-Object { $_.Name })

            @($naming).Count | Should -BeGreaterThan 0 -Because (
                'nothing proves {0} and {1} agree, so an administrator can get a green editor and a red deployment.' -f
                $SchemaFile, $Validator)
        }
    }

    Context 'the exception list' {

        It 'carries a reason for <Schema>' -ForEach @($script:HDTContractException) {
            # An empty list makes this Context vacuous, which is the state the
            # repository is meant to be in. A row added without a reason is the
            # failure this catches.
            [string]::IsNullOrWhiteSpace($Reason) | Should -BeFalse
        }
    }
}
