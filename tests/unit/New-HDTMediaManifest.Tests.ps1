#requires -Version 5.1

# New-HDTMediaManifest - what the build wrote down, beside the ISO.
#
# New-HDTBootImageManifest's shape exactly, for its reasons: it is PURE and it
# RETURNS TEXT, so every claim in it is assertable without a ten-minute build,
# and the caller writes it through IFileSystem like everything else.
#
# TWO TRAPS THAT FILE'S HEADER ALREADY RECORDS, and both are tests here:
#   - a one-element list serialises as an OBJECT on both engines, and an operator
#     indexing projected[0] would get nothing. ConvertTo-Json -AsArray does not
#     exist under Windows PowerShell 5.1, so the arrays are forced by wrapping.
#   - builtUtc is a STRING, because pwsh 7 and 5.1 disagree about round-tripping
#     a [datetime] through JSON.
#
# AND THE SECRET GREP IS NOT THEATRE. The manifest sits in Media\<id>\ beside an
# ISO that is handed around, and DESIGN 6.3 says boot media is to be treated as a
# credential.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:secret = 'Sup3rSecret-Deploy-Password!'

    $script:projected = @(
        [pscustomobject] @{ Kind = 'Marker'; Source = 'rules.yaml'; Destination = '\Share\rules.yaml'
            Reason = 'it is the content marker.'; Present = $true; Rewritten = $false
        }
        [pscustomobject] @{ Kind = 'Content'; Source = 'Applications\TightVNC'
            Destination = '\Share\Applications\TightVNC'; Reason = "the profile names it."
            Present = $true; Rewritten = $false
        }
    )

    $script:excluded = @(
        [pscustomobject] @{ Kind = 'Excluded'; Source = 'bootstrap-rules.yaml'; Destination = ''
            Reason = 'it is injected into the boot image and its rules choose a share by gateway.'
            Present = $true; Rewritten = $false
        }
    )

    $script:oneRow = @(
        [pscustomobject] @{ Kind = 'Content'; Source = 'Drivers'; Destination = '\Share\Drivers'
            Reason = 'the profile names it.'; Present = $true; Rewritten = $false
        }
    )

    function New-HDTMediaTestManifest {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a string; it changes no state.')]
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter()]
            [hashtable] $Override
        )

        $argument = @{
            MediaId          = 'LAB-DISC'
            Name             = 'Lab standalone disc'
            BuildId          = '2f6c1c1e-5b2b-4a2f-9f0a-1d2e3f4a5b6c'
            BuiltUtc         = '2026-09-03T09:14:22Z'
            BuiltOn          = 'BUILD-HOST'
            EngineVersion    = '0.15.0'
            WorkspaceId      = 'HDT-LAB'
            WorkspaceRoot    = 'X:\Share'
            SelectionProfile = 'everything'
            DeployRoot       = '\Share'
            Architecture     = 'amd64'
            Firmware         = 'UEFI'
            Projected        = [object[]] @($script:projected)
            Excluded         = [object[]] @($script:excluded)
            Warning          = [string[]] @('TightVNC is on this disc and Acrobat, which it depends on, is not.')
            Iso              = @{ Path = 'X:\Share\Media\LAB-DISC\HDT_LAB-DISC.iso'; Sha256 = 'A1B2C3'; SizeBytes = [long] 5368709120 }
            BootWimSha256    = 'D4E5F6'
        }

        if ($null -ne $Override) {
            foreach ($key in @($Override.Keys)) { $argument[[string] $key] = $Override[$key] }
        }

        return [string] (InModuleScope Hephaestus -Parameters @{ Argument = $argument } {
                param($Argument)

                New-HDTMediaManifest @Argument
            })
    }
}

Describe 'New-HDTMediaManifest' {

    BeforeAll {
        $script:text = New-HDTMediaTestManifest
        $script:document = ConvertFrom-Json -InputObject $script:text
    }

    It 'returns JSON text and writes nothing' {
        $script:text | Should -BeOfType ([string])
        { ConvertFrom-Json -InputObject $script:text } | Should -Not -Throw
    }

    It 'records the media id, the selection profile and the workspace it was projected from' {
        $script:document.mediaId | Should -BeExactly 'LAB-DISC'
        $script:document.selectionProfile | Should -BeExactly 'everything'
        $script:document.workspaceRoot | Should -BeExactly 'X:\Share'
        $script:document.workspaceId | Should -BeExactly 'HDT-LAB'
    }

    It 'records the ISO path, its size and its SHA256' {
        $script:document.artifacts.iso.path | Should -BeExactly 'X:\Share\Media\LAB-DISC\HDT_LAB-DISC.iso'
        $script:document.artifacts.iso.sizeBytes | Should -Be 5368709120
        $script:document.artifacts.iso.sha256 | Should -BeExactly 'A1B2C3'
    }

    It 'records the boot wim SHA256 that went into it' {
        $script:document.artifacts.bootWimSha256 | Should -BeExactly 'D4E5F6'
    }

    It 'records the deployRoot the projected workspace carries, which is \Share' {
        $script:document.deployRoot | Should -BeExactly '\Share'
    }

    It 'records the provider as Local, so the file says which kind of disc this is' {
        # DERIVED FROM deployRoot, not passed in, and by the same predicate
        # Update-HDTBootImage uses: a value starting \\ is Smb and anything else
        # is Local. Two ways to say it would be two answers.
        $script:document.provider | Should -BeExactly 'Local'
    }

    It 'records every projected folder and every refusal, with its reason' {
        @($script:document.projected).Count | Should -Be 2
        @($script:document.excluded).Count | Should -Be 1

        @($script:document.projected | ForEach-Object { $_.source }) |
            Should -Be @('rules.yaml', 'Applications\TightVNC')

        $script:document.excluded[0].source | Should -BeExactly 'bootstrap-rules.yaml'
        [string]::IsNullOrWhiteSpace($script:document.excluded[0].reason) | Should -BeFalse
    }

    It 'records the dependency warnings, so a disc that shipped with one says so' {
        @($script:document.warnings).Count | Should -Be 1
        $script:document.warnings[0] | Should -Match 'Acrobat'
    }

    It 'carries no credential, no password and no secret - proved by grepping the text' {
        $manifest = New-HDTMediaTestManifest -Override @{
            Warning = [string[]] @('a warning that mentions no secret')
        }

        $manifest | Should -Not -Match 'password'
        $manifest | Should -Not -Match 'credential'
        $manifest | Should -Not -Match ([regex]::Escape($script:secret))
    }

    It 'forces every list to a JSON array, so a one-folder projection is not an object' {
        $manifest = New-HDTMediaTestManifest -Override @{
            Projected = [object[]] @($script:oneRow)
            Excluded  = [object[]] @()
            Warning   = [string[]] @('one sentence')
        }

        $manifest | Should -Match '"projected":\s*\['
        $manifest | Should -Match '"excluded":\s*(\[|null)'
        $manifest | Should -Match '"warnings":\s*\['

        $one = ConvertFrom-Json -InputObject $manifest
        @($one.projected).Count | Should -Be 1
        $one.projected[0].source | Should -BeExactly 'Drivers'
    }

    It 'records builtUtc as a string, because pwsh 7 and 5.1 disagree about round-tripping a datetime' {
        $script:text | Should -Match '"builtUtc":\s*"2026-09-03T09:14:22Z"'
    }

    It 'records the firmware and the architecture the disc was built for' {
        $script:document.firmware | Should -BeExactly 'UEFI'
        $script:document.architecture | Should -BeExactly 'amd64'
    }
}
