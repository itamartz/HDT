# The Control\selection-profiles.yaml schema contract (DESIGN 2.2: "Every file
# has a schemaVersion and a JSON Schema in schemas/ so the console, CI, and
# cmdlets validate identically").
#
# TWO VALIDATORS, ONE VERDICT. The schema is the gate the console, an editor and
# CI use; Assert-HDTSelectionProfileDocument is what actually runs in WinPE,
# where Test-HDTJsonSchema does not exist. They must agree on every case here, or an
# administrator gets a green editor and a red deployment.
#
# THE include CASES ARE THE SECURITY BOUNDARY OF THIS WHOLE FEATURE, not
# housekeeping. Expand-HDTSelectionProfile turns each include into a folder under
# the share and the boot image build hands that folder to Add-WindowsDriver WITH
# -Recurse - so a rooted path or a '..' segment is a directory traversal whose
# payload ends up inside a WIM transferred to every machine that PXE boots. The
# schema's pattern and the validator's three rules have to mean the same thing,
# and this file is what says they do.
#
# THE SCHEMA SIDE IS VALIDATED BY Test-HDTJsonSchema, NOT BY Test-Json, and that
# is what lets this file run on the gate at all. Test-Json is PowerShell 6+; the
# gate is Windows PowerShell 5.1, because that is the edition WinPE ships. This
# file used to open with `-Skip:(-not (Get-Command Test-Json))`, so on the only
# run that gates a merge the whole Describe vanished and reported green having
# executed nothing. Test-HDTJsonSchema is the draft-07 subset schemas/ uses,
# hand-written for 5.1, and it THROWS on a keyword it does not implement rather
# than ignoring one - see tests/helpers/HDTTestTools/tools/.
# engine carries its own validator instead of leaning on the schema.
#
# THE CASES ARE INLINE, NOT IN tests\fixtures\. New-HDTWorkspace seeds this
# document, so there is no corpus of authored ones to point at, and a fixture
# directory of documents invented for this test would look like captured data
# and would not be.

$script:HDTSchemaToolRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:HDTSchemaToolRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

$script:HDTCase = @(
    @{
        Name          = 'valid-no-profiles-yet'
        ShouldBeValid = $true
        Yaml          = @'
schemaVersion: 1
profiles: []
'@
    }
    @{
        Name          = 'valid-two-profiles'
        ShouldBeValid = $true
        Yaml          = @'
schemaVersion: 1
profiles:
  - id: dell-latitude
    name: Dell Latitude drivers
    include:
      - Drivers\Dell\Latitude
      - Drivers\Dell\Common
  - id: field-build
    name: Field build content
    include:
      - Applications
      - OperatingSystems\WIN11-LTSC-2024
      - TaskSequences\STD-CLIENT
      - Scripts
'@
    }
    @{
        # A profile that selects nothing is a useful thing to name - it is what
        # MDT's Nothing profile is - and a profile being built up over an
        # afternoon must not be a document the engine refuses to load.
        Name          = 'valid-empty-include'
        ShouldBeValid = $true
        Yaml          = @'
schemaVersion: 1
profiles:
  - id: work-in-progress
    name: Being built this afternoon
    include: []
'@
    }
    @{
        Name          = 'invalid-unknown-root-key'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
profiles: []
default: everything
'@
    }
    @{
        Name          = 'invalid-missing-schemaversion'
        ShouldBeValid = $false
        Yaml          = @'
profiles: []
'@
    }
    @{
        Name          = 'invalid-newer-schemaversion'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 99
profiles: []
'@
    }
    @{
        Name          = 'invalid-missing-profiles'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
'@
    }
    @{
        Name          = 'invalid-unknown-profile-key'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
profiles:
  - id: dell-latitude
    name: Dell Latitude drivers
    include: []
    exclude:
      - Drivers\Dell\Optiplex
'@
    }
    @{
        Name          = 'invalid-profile-without-id'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
profiles:
  - name: Dell Latitude drivers
    include: []
'@
    }
    @{
        Name          = 'invalid-profile-id-with-a-space'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
profiles:
  - id: dell latitude
    name: Dell Latitude drivers
    include: []
'@
    }
    @{
        Name          = 'invalid-profile-without-name'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
profiles:
  - id: dell-latitude
    include: []
'@
    }
    @{
        Name          = 'invalid-blank-profile-name'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
profiles:
  - id: dell-latitude
    name: ''
    include: []
'@
    }
    @{
        Name          = 'invalid-profile-without-include'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
profiles:
  - id: dell-latitude
    name: Dell Latitude drivers
'@
    }
    @{
        # A ROOTED PATH IS A TRAVERSAL. What it names goes into a WIM that every
        # machine that PXE boots receives.
        Name          = 'invalid-rooted-include'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
profiles:
  - id: dell-latitude
    name: Dell Latitude drivers
    include:
      - C:\Windows\System32
'@
    }
    @{
        Name          = 'invalid-parent-segment-include'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
profiles:
  - id: dell-latitude
    name: Dell Latitude drivers
    include:
      - Drivers\..\..\Windows
'@
    }
    @{
        # Boot\, Logs\, Captures\ and Control\ are generated, written to during a
        # deployment, or this document itself. Only the five authored content
        # folders may be included.
        Name          = 'invalid-include-outside-the-content-folders'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
profiles:
  - id: dell-latitude
    name: Dell Latitude drivers
    include:
      - Boot
'@
    }
)

# WHAT JSON SCHEMA DRAFT-07 CANNOT SAY ABOUT A PROFILE LIST, listed rather than
# quietly excluded. If a future schema gains the ability, the blind-spot test
# goes red and the case moves into $script:HDTCase.
#
#   reserved-id     the built-in ids are answered by the engine, so the schema
#                   would have to know a list that lives in
#                   Get-HDTSelectionProfileBuiltIn. An authored 'all-drivers'
#                   either beats the built-in or loses to it, and both answers
#                   leave a share where the name on the Windows PE tab does not
#                   mean what it says
#   duplicate-id    there is no uniqueness constraint on a property across array
#                   items, so the schema cannot see that two profiles claim the
#                   same id
$script:HDTBlindSpot = @(
    @{
        Name = 'reserved-id'
        Yaml = @'
schemaVersion: 1
profiles:
  - id: all-drivers
    name: My own all-drivers
    include:
      - Drivers
'@
    }
    @{
        Name = 'duplicate-id'
        Yaml = @'
schemaVersion: 1
profiles:
  - id: dell-latitude
    name: Dell Latitude drivers
    include: []
  - id: dell-latitude
    name: Dell Latitude drivers again
    include: []
'@
    }
)

Describe 'selection-profiles.yaml schema contract' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name powershell-yaml -ErrorAction Stop

        $script:schemaPath = Join-Path -Path $script:repoRoot -ChildPath 'schemas/selection-profile.schema.json'
        $script:documentPath = 'C:\HDTLab\does-not-exist\Share\Control\selection-profiles.yaml'

        function ConvertTo-HDTCaseJson {
            <#
                A case as the JSON the schema is handed. An empty YAML document
                parses to $null and ConvertTo-Json emits nothing at all for it,
                which Test-HDTJsonSchema refuses to bind rather than reporting as invalid;
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

        It 'ships schemas/selection-profile.schema.json' {
            Test-Path -LiteralPath $script:schemaPath -PathType Leaf | Should -BeTrue
        }

        It 'declares draft-07' {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json

            $schema.'$schema' | Should -BeExactly 'http://json-schema.org/draft-07/schema#'
        }

        It 'names the five content folders and no others in the include pattern' {
            # THE CONTENT FOLDERS ARE A SUBSET OF Get-HDTWorkspacePath's KINDS ON
            # PURPOSE - Boot\, Logs\ and Captures\ are generated or written to
            # during a deployment, and Control\ holds this very document. The
            # pattern is asserted directly because a sixth folder appearing in it
            # is exactly the change that would go unnoticed through the cases.
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json

            $schema.definitions.includePath.pattern |
                Should -BeLike '^(Applications|OperatingSystems|Drivers|TaskSequences|Scripts)*'
        }
    }

    Context 'the cases' {

        It 'validates <Name> against schemas/selection-profile.schema.json' -ForEach @($script:HDTCase | Where-Object { $_.ShouldBeValid }) {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            Test-HDTJsonSchema -Json $json -Schema $schema | Should -BeTrue
        }

        It 'rejects <Name> against schemas/selection-profile.schema.json' -ForEach @($script:HDTCase | Where-Object { -not $_.ShouldBeValid }) {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            Test-HDTJsonSchema -Json $json -Schema $schema | Should -BeFalse
        }

        It 'agrees with Assert-HDTSelectionProfileDocument about <Name>' -ForEach $script:HDTCase {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            $schemaVerdict = [bool] (Test-HDTJsonSchema -Json $json -Schema $schema)

            $engineVerdict = $true
            try {
                InModuleScope Hephaestus -Parameters @{ Yaml = $Yaml; Path = $script:documentPath } {
                    param($Yaml, $Path)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path
                    Assert-HDTSelectionProfileDocument -Document $document -Path $Path
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
            Test-HDTJsonSchema -Json $json -Schema $schema | Should -BeTrue

            $record = $null
            try {
                InModuleScope Hephaestus -Parameters @{ Yaml = $Yaml; Path = $script:documentPath } {
                    param($Yaml, $Path)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path
                    Assert-HDTSelectionProfileDocument -Document $document -Path $Path
                }
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }
}
