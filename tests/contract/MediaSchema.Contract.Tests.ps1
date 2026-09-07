# The media.yaml schema contract (DESIGN 2.2: "Every file has a schemaVersion and
# a JSON Schema in schemas/ so the console, CI, and cmdlets validate
# identically").
#
# TWO VALIDATORS, ONE VERDICT. The schema is the gate the console, an editor and
# CI use; Assert-HDTMediaDocument is what actually runs in WinPE, where Test-Json
# does not exist. They must agree on every case here, or an administrator gets a
# green editor and a red deployment.
#
# TWO OF THESE CASES ARE NOT THEATRE. `id` becomes the folder Remove-HDTMedia
# deletes and `output` becomes the path a multi-gigabyte ISO is written to, so
# the schema's pattern for each is load-bearing rather than decorative - and a
# schema that had quietly stopped agreeing with the validator about either would
# be a console that accepts a delete target the engine refuses, or worse.
#
# Test-Json exists under pwsh 7 and NOT under Windows PowerShell 5.1, so the
# whole file skips there rather than silently passing. That is also why the
# engine carries its own validator instead of leaning on the schema.
#
# THE CASES ARE INLINE, NOT IN tests\fixtures\media\. There is no captured
# corpus of media.yaml to point at - New-HDTMedia writes them - and a fixture
# directory of documents invented for this test would look like captured data
# and would not be.

$script:HDTSchemaSkip = -not [bool](Get-Command -Name Test-Json -ErrorAction SilentlyContinue)

if ($script:HDTSchemaSkip) {
    Write-Warning ("MediaSchema contract SKIPPED: Test-Json does not exist on PowerShell {0} ({1}). The schema is validated on the pwsh 7 leg; Assert-HDTMediaDocument is what runs here." -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
}

$script:HDTCase = @(
    @{
        Name          = 'valid-minimal'
        ShouldBeValid = $true
        Yaml          = @'
schemaVersion: 1
id: WIN11-FIELD
name: Windows 11 field media
selectionProfile: everything
output: Media\WIN11-FIELD\HDT_WIN11-FIELD.iso
'@
    }
    @{
        Name          = 'valid-every-key'
        ShouldBeValid = $true
        Yaml          = @'
schemaVersion: 1
id: WIN11-FIELD
name: Windows 11 field media
description: Engineers' laptop build, no network
selectionProfile: everything
output: D:\Build\HDT_WIN11-FIELD.iso
enabled: false
'@
    }
    @{
        Name          = 'invalid-unknown-key'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: WIN11-FIELD
name: Windows 11 field media
selectionProfile: everything
output: Media\WIN11-FIELD\HDT_WIN11-FIELD.iso
mediaPath: D:\somewhere
'@
    }
    @{
        Name          = 'invalid-missing-schemaversion'
        ShouldBeValid = $false
        Yaml          = @'
id: WIN11-FIELD
name: Windows 11 field media
selectionProfile: everything
output: Media\WIN11-FIELD\HDT_WIN11-FIELD.iso
'@
    }
    @{
        Name          = 'invalid-newer-schemaversion'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 99
id: WIN11-FIELD
name: Windows 11 field media
selectionProfile: everything
output: Media\WIN11-FIELD\HDT_WIN11-FIELD.iso
'@
    }
    @{
        Name          = 'invalid-missing-id'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
name: Windows 11 field media
selectionProfile: everything
output: Media\WIN11-FIELD\HDT_WIN11-FIELD.iso
'@
    }
    @{
        # The id names the folder Remove-HDTMedia deletes.
        Name          = 'invalid-id-with-a-separator'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: WIN11\FIELD
name: Windows 11 field media
selectionProfile: everything
output: Media\WIN11-FIELD\HDT_WIN11-FIELD.iso
'@
    }
    @{
        Name          = 'invalid-blank-name'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: WIN11-FIELD
name: ''
selectionProfile: everything
output: Media\WIN11-FIELD\HDT_WIN11-FIELD.iso
'@
    }
    @{
        Name          = 'invalid-output-is-not-an-iso'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: WIN11-FIELD
name: Windows 11 field media
selectionProfile: everything
output: Media\WIN11-FIELD\HDT_WIN11-FIELD.wim
'@
    }
    @{
        # A '..' segment in a share-relative output is a write outside the share.
        Name          = 'invalid-output-escapes-the-share'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: WIN11-FIELD
name: Windows 11 field media
selectionProfile: everything
output: Media\..\..\HDT_WIN11-FIELD.iso
'@
    }
    @{
        Name          = 'invalid-enabled-is-not-a-boolean'
        ShouldBeValid = $false
        Yaml          = @'
schemaVersion: 1
id: WIN11-FIELD
name: Windows 11 field media
selectionProfile: everything
output: Media\WIN11-FIELD\HDT_WIN11-FIELD.iso
enabled: sometimes
'@
    }
)

Describe 'media.yaml schema contract' -Skip:$script:HDTSchemaSkip {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name powershell-yaml -ErrorAction Stop

        $script:schemaPath = Join-Path -Path $script:repoRoot -ChildPath 'schemas/media.schema.json'
        $script:mediaPath = 'C:\HDTLab\does-not-exist\Share\Media\WIN11-FIELD\media.yaml'

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

        It 'ships schemas/media.schema.json' {
            Test-Path -LiteralPath $script:schemaPath -PathType Leaf | Should -BeTrue
        }

        It 'declares draft-07' {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json

            $schema.'$schema' | Should -BeExactly 'http://json-schema.org/draft-07/schema#'
        }

        It 'does not require description or enabled' {
            # Both are optional in the engine, and a schema that "tightened"
            # either would refuse a document New-HDTMedia itself writes.
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json

            $schema.required | Should -Not -Contain 'description'
            $schema.required | Should -Not -Contain 'enabled'
        }
    }

    Context 'the cases' {

        It 'validates <Name> against schemas/media.schema.json' -ForEach @($script:HDTCase | Where-Object { $_.ShouldBeValid }) {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            Test-Json -Json $json -Schema $schema | Should -BeTrue
        }

        It 'rejects <Name> against schemas/media.schema.json' -ForEach @($script:HDTCase | Where-Object { -not $_.ShouldBeValid }) {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'agrees with Assert-HDTMediaDocument about <Name>' -ForEach $script:HDTCase {
            $schema = Get-Content -LiteralPath $script:schemaPath -Raw
            $json = ConvertTo-HDTCaseJson -Yaml $Yaml

            $schemaVerdict = [bool] (Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue)

            $engineVerdict = $true
            try {
                InModuleScope Hephaestus -Parameters @{ Yaml = $Yaml; Path = $script:mediaPath } {
                    param($Yaml, $Path)
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path
                    Assert-HDTMediaDocument -Document $document -Path $Path
                }
            } catch {
                $engineVerdict = $false
            }

            $engineVerdict | Should -Be $ShouldBeValid
            $schemaVerdict | Should -Be $engineVerdict
        }
    }
}
