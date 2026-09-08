# THE VALIDATOR THAT LET THE 5.1 GATE SEE schemas/ AT ALL.
#
# Twelve contract suites validated schemas/*.schema.json with Test-Json, which is
# PowerShell 6+. HDT's gate is Windows PowerShell 5.1 - the edition WinPE ships -
# so every one of those Describe blocks opened with
# `-Skip:(-not (Get-Command Test-Json))` and vanished whole on the only run that
# gates a merge. Twelve suites reported green having executed nothing.
#
# Get-HDTJsonSchemaViolation is the draft-07 subset the shipped schemas actually
# use, hand-written for 5.1. It is a TEST HELPER and never ships in the engine:
# the engine validates with Assert-HDT*Document, and the contract suites exist to
# prove those two agree.
#
# THE ONE THING THAT MAKES IT SAFE IS THAT IT REFUSES WHAT IT DOES NOT KNOW.
# A validator that silently ignores an unrecognised keyword is the green skip
# again in a costume: add `if`/`then`/`else` to a schema and every fixture would
# pass for the wrong reason. So an unimplemented keyword THROWS, and this suite
# asserts that first, before it asserts a single verdict.
#
# The keyword tests are written as accept AND reject pairs on purpose. A keyword
# implemented as "return $true" passes every accept test ever written.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

# Every schema the repository ships, as its own test case, so "the validator
# understands this file" names the file that broke.
$script:HDTShippedSchemaCase = @(
    Get-ChildItem -LiteralPath (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'schemas') -Filter '*.schema.json' -File |
        ForEach-Object { @{ Name = $_.Name; SchemaPath = $_.FullName } })

Describe 'Get-HDTJsonSchemaViolation' {

    BeforeAll {
        $script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
    }

    Context 'it refuses what it does not implement' {

        It 'throws on a schema keyword it does not know' {
            # THE ANTI-VACUITY GUARD, AND THE REASON THIS FILE EXISTS. A schema
            # that grows a keyword the validator has never heard of must fail
            # loudly on the commit that adds it, not validate vacuously for
            # three months.
            { Get-HDTJsonSchemaViolation -Json '{}' -Schema '{ "type": "object", "if": { "const": 1 } }' } |
                Should -Throw -ExpectedMessage '*if*'
        }

        It 'names the keyword and the location it found it at' {
            $record = $null
            try {
                Get-HDTJsonSchemaViolation -Json '{}' -Schema '{ "properties": { "a": { "maxLength": 3 } } }'
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*maxLength*'
            $record.Exception.Message | Should -BeLike '*#/properties/a*'
        }

        It 'throws on a tuple-form items, which no shipped schema uses' {
            # draft-07 lets `items` be an array of schemas positionally. Nothing
            # here uses it, so it is refused rather than half-implemented.
            { Get-HDTJsonSchemaViolation -Json '[]' -Schema '{ "items": [ { "type": "string" } ] }' } |
                Should -Throw -ExpectedMessage '*items*'
        }

        It 'throws on a reference it cannot resolve' {
            { Get-HDTJsonSchemaViolation -Json '{}' -Schema '{ "$ref": "#/definitions/missing" }' } |
                Should -Throw -ExpectedMessage '*#/definitions/missing*'
        }

        It 'throws on a reference to another document' {
            # Every reference in schemas/ is internal. An external one would need
            # a resolver, and silently ignoring it would accept anything.
            { Get-HDTJsonSchemaViolation -Json '{}' -Schema '{ "$ref": "https://example.invalid/a.json" }' } |
                Should -Throw -ExpectedMessage '*example.invalid*'
        }

        It 'throws on JSON that is not JSON' {
            { Get-HDTJsonSchemaViolation -Json '{ nope' -Schema '{}' } | Should -Throw
        }
    }

    Context 'the shipped schemas' {

        It 'understands every keyword in <Name>' -ForEach $script:HDTShippedSchemaCase {
            # Walking the schema itself, not a document through it: a keyword
            # under a branch no fixture reaches would never be visited by a
            # validation run, and that is exactly where an unknown one hides.
            { Get-HDTJsonSchemaKeyword -Schema (Get-Content -LiteralPath $SchemaPath -Raw) } | Should -Not -Throw
        }

        It 'finds the keywords <Name> uses rather than an empty set' -ForEach $script:HDTShippedSchemaCase {
            $keyword = @(Get-HDTJsonSchemaKeyword -Schema (Get-Content -LiteralPath $SchemaPath -Raw))

            $keyword.Count | Should -BeGreaterThan 0
            $keyword | Should -Contain 'type'
        }
    }

    Context 'type' {

        It 'accepts <Json> as <Type>' -ForEach @(
            @{ Json = '"a"'; Type = 'string' }
            @{ Json = '1'; Type = 'integer' }
            @{ Json = '1.0'; Type = 'integer' }
            @{ Json = '1.5'; Type = 'number' }
            @{ Json = '1'; Type = 'number' }
            @{ Json = 'true'; Type = 'boolean' }
            @{ Json = '[]'; Type = 'array' }
            @{ Json = '{}'; Type = 'object' }
            @{ Json = 'null'; Type = 'null' }
        ) {
            Test-HDTJsonSchema -Json $Json -Schema ('{{ "type": "{0}" }}' -f $Type) | Should -BeTrue
        }

        It 'rejects <Json> as <Type>' -ForEach @(
            @{ Json = '1'; Type = 'string' }
            @{ Json = '"1"'; Type = 'integer' }
            @{ Json = '1.5'; Type = 'integer' }
            @{ Json = 'true'; Type = 'integer' }
            @{ Json = '"a"'; Type = 'number' }
            @{ Json = '1'; Type = 'boolean' }
            @{ Json = '{}'; Type = 'array' }
            @{ Json = '[]'; Type = 'object' }
            @{ Json = '0'; Type = 'null' }
        ) {
            Test-HDTJsonSchema -Json $Json -Schema ('{{ "type": "{0}" }}' -f $Type) | Should -BeFalse
        }

        It 'accepts any member of a type union' {
            $schema = '{ "type": ["string", "boolean", "integer"] }'

            Test-HDTJsonSchema -Json '"a"' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json 'true' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '7' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '[]' -Schema $schema | Should -BeFalse
        }

        It 'does not treat a boolean as a number' {
            # $true -as [int] is 1 in PowerShell, which is exactly how a
            # hand-written type check gets this wrong.
            Test-HDTJsonSchema -Json 'true' -Schema '{ "type": "number" }' | Should -BeFalse
        }
    }

    Context 'objects' {

        It 'requires every name in required' {
            $schema = '{ "type": "object", "required": ["id", "name"] }'

            Test-HDTJsonSchema -Json '{ "id": "a", "name": "b" }' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '{ "id": "a" }' -Schema $schema | Should -BeFalse
        }

        It 'validates a property against its own schema' {
            $schema = '{ "properties": { "id": { "type": "string" } } }'

            Test-HDTJsonSchema -Json '{ "id": "a" }' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '{ "id": 1 }' -Schema $schema | Should -BeFalse
        }

        It 'leaves a property the schema does not mention alone unless additionalProperties says otherwise' {
            Test-HDTJsonSchema -Json '{ "other": 1 }' -Schema '{ "properties": { "id": { "type": "string" } } }' |
                Should -BeTrue
        }

        It 'refuses an unknown property when additionalProperties is false' {
            $schema = '{ "properties": { "id": { "type": "string" } }, "additionalProperties": false }'

            Test-HDTJsonSchema -Json '{ "id": "a" }' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '{ "id": "a", "other": 1 }' -Schema $schema | Should -BeFalse
        }

        It 'validates an unknown property against additionalProperties when it is a schema' {
            $schema = '{ "properties": { "id": { "type": "string" } }, "additionalProperties": { "type": "integer" } }'

            Test-HDTJsonSchema -Json '{ "id": "a", "other": 1 }' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '{ "id": "a", "other": "x" }' -Schema $schema | Should -BeFalse
        }

        It 'counts properties for minProperties' {
            $schema = '{ "type": "object", "minProperties": 1 }'

            Test-HDTJsonSchema -Json '{ "a": 1 }' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '{}' -Schema $schema | Should -BeFalse
        }

        It 'validates every property NAME against propertyNames' {
            $schema = '{ "type": "object", "propertyNames": { "pattern": "^HDT" } }'

            Test-HDTJsonSchema -Json '{ "HDTComputerName": 1 }' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '{ "ComputerName": 1 }' -Schema $schema | Should -BeFalse
        }
    }

    Context 'arrays' {

        It 'validates every element against items' {
            $schema = '{ "type": "array", "items": { "type": "string" } }'

            Test-HDTJsonSchema -Json '["a", "b"]' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '["a", 2]' -Schema $schema | Should -BeFalse
        }

        It 'counts elements for minItems' {
            $schema = '{ "type": "array", "minItems": 1 }'

            Test-HDTJsonSchema -Json '["a"]' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '[]' -Schema $schema | Should -BeFalse
        }

        It 'refuses a repeated element under uniqueItems' {
            $schema = '{ "type": "array", "uniqueItems": true }'

            Test-HDTJsonSchema -Json '["a", "b"]' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '["a", "a"]' -Schema $schema | Should -BeFalse
            Test-HDTJsonSchema -Json '[{ "a": 1 }, { "a": 1 }]' -Schema $schema | Should -BeFalse
        }
    }

    Context 'strings and numbers' {

        It 'enforces minLength' {
            $schema = '{ "type": "string", "minLength": 1 }'

            Test-HDTJsonSchema -Json '"a"' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '""' -Schema $schema | Should -BeFalse
        }

        It 'enforces pattern' {
            $schema = '{ "type": "string", "pattern": "^HDT[A-Za-z0-9_]*$" }'

            Test-HDTJsonSchema -Json '"HDTComputerName"' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '"ComputerName"' -Schema $schema | Should -BeFalse
        }

        It 'enforces a pattern with a lookahead, which is what the path rules are made of' {
            $schema = '{ "type": "string", "pattern": "^(?!.*\\.\\.)\\\\.+$" }'

            Test-HDTJsonSchema -Json '"\\\\server\\share"' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '"\\\\server\\..\\share"' -Schema $schema | Should -BeFalse
        }

        It 'enforces minimum and maximum' {
            $schema = '{ "type": "integer", "minimum": 1, "maximum": 3 }'

            Test-HDTJsonSchema -Json '1' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '3' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '0' -Schema $schema | Should -BeFalse
            Test-HDTJsonSchema -Json '4' -Schema $schema | Should -BeFalse
        }

        It 'leaves minLength and pattern to strings alone' {
            # draft-07 keywords apply only to their own type. A number is not
            # short, and it does not fail a pattern.
            Test-HDTJsonSchema -Json '7' -Schema '{ "minLength": 3, "pattern": "^a" }' | Should -BeTrue
        }
    }

    Context 'enum, const, oneOf and not' {

        It 'enforces enum' {
            $schema = '{ "enum": ["Info", "Debug"] }'

            Test-HDTJsonSchema -Json '"Info"' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '"info"' -Schema $schema | Should -BeFalse
        }

        It 'enforces const' {
            $schema = '{ "const": 1 }'

            Test-HDTJsonSchema -Json '1' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '2' -Schema $schema | Should -BeFalse
        }

        It 'requires exactly one branch of oneOf' {
            $schema = '{ "oneOf": [ { "type": "string" }, { "type": "integer" } ] }'

            Test-HDTJsonSchema -Json '"a"' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '1' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json 'true' -Schema $schema | Should -BeFalse
        }

        It 'refuses a document matching two branches of oneOf' {
            # "one" is not "at least one". Branches that overlap are a schema
            # bug, and this is what surfaces it.
            $schema = '{ "oneOf": [ { "type": "integer" }, { "minimum": 0 } ] }'

            Test-HDTJsonSchema -Json '1' -Schema $schema | Should -BeFalse
        }

        It 'inverts not' {
            $schema = '{ "not": { "type": "string" } }'

            Test-HDTJsonSchema -Json '1' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '"a"' -Schema $schema | Should -BeFalse
        }
    }

    Context 'references' {

        It 'resolves an internal reference' {
            $schema = '{ "definitions": { "id": { "type": "string" } }, "properties": { "a": { "$ref": "#/definitions/id" } } }'

            Test-HDTJsonSchema -Json '{ "a": "x" }' -Schema $schema | Should -BeTrue
            Test-HDTJsonSchema -Json '{ "a": 1 }' -Schema $schema | Should -BeFalse
        }

        It 'resolves a reference that refers to itself, which is what a step group is' {
            # sequence.schema.json's group contains steps AND groups. Inlining a
            # reference would not terminate; resolution happens per instance.
            $schema = '{ "definitions": { "group": { "type": "object", "required": ["name"], "additionalProperties": false, "properties": { "name": { "type": "string" }, "steps": { "type": "array", "items": { "$ref": "#/definitions/group" } } } } }, "$ref": "#/definitions/group" }'

            Test-HDTJsonSchema -Json '{ "name": "a", "steps": [ { "name": "b", "steps": [ { "name": "c" } ] } ] }' -Schema $schema |
                Should -BeTrue
            Test-HDTJsonSchema -Json '{ "name": "a", "steps": [ { "name": "b", "steps": [ { "nope": "c" } ] } ] }' -Schema $schema |
                Should -BeFalse
        }
    }

    Context 'annotations' {

        It 'ignores <Keyword>, which says nothing about validity' -ForEach @(
            @{ Keyword = '$schema'; Value = '"http://json-schema.org/draft-07/schema#"' }
            @{ Keyword = '$id'; Value = '"https://example.invalid/a.json"' }
            @{ Keyword = 'title'; Value = '"A title"' }
            @{ Keyword = 'description'; Value = '"Some prose"' }
            @{ Keyword = 'default'; Value = '"x"' }
        ) {
            Test-HDTJsonSchema -Json '1' -Schema ('{{ "{0}": {1} }}' -f $Keyword, $Value) | Should -BeTrue
        }
    }

    Context 'the violations it reports' {

        It 'says where and why, so a failing contract names the field' {
            $violation = @(Get-HDTJsonSchemaViolation -Json '{ "a": { "b": 1 } }' `
                    -Schema '{ "properties": { "a": { "properties": { "b": { "type": "string" } } } } }')

            $violation.Count | Should -Be 1
            $violation[0].Location | Should -BeExactly '#/a/b'
            $violation[0].Keyword | Should -BeExactly 'type'
            $violation[0].Message | Should -BeLike '*string*'
        }

        It 'reports every failure rather than stopping at the first' {
            $violation = @(Get-HDTJsonSchemaViolation -Json '{ "a": 1, "b": 2 }' `
                    -Schema '{ "properties": { "a": { "type": "string" }, "b": { "type": "string" } } }')

            $violation.Count | Should -Be 2
        }

        It 'reports nothing for a document that validates' {
            @(Get-HDTJsonSchemaViolation -Json '{ "a": "x" }' -Schema '{ "properties": { "a": { "type": "string" } } }').Count |
                Should -Be 0
        }
    }
}

Describe 'Test-HDTJsonSchema' {

    BeforeAll {
        $script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
    }

    It 'is the boolean face of Get-HDTJsonSchemaViolation' {
        Test-HDTJsonSchema -Json '{ "a": "x" }' -Schema '{ "properties": { "a": { "type": "string" } } }' | Should -BeTrue
        Test-HDTJsonSchema -Json '{ "a": 1 }' -Schema '{ "properties": { "a": { "type": "string" } } }' | Should -BeFalse
    }

    It 'returns a real boolean rather than a truthy object' {
        # `Should -BeTrue` passes for a non-empty array too, and a contract that
        # asserted one would pass on a list of violations.
        (Test-HDTJsonSchema -Json '1' -Schema '{}') -is [bool] | Should -BeTrue
    }
}
