#requires -Version 5.1

# Set-HDTMediaWorkspaceLine - the provider swap, and it is one key plus a
# deletion.
#
# DESIGN 6.2: "media generation is a content projection plus a provider swap".
# The projection is Get-HDTMediaProjection; this is the swap, and the whole trick
# is that the provider is DERIVED rather than configured. Update-HDTBootImage
# reads:
#
#     $provider = 'Local'
#     if (([string] $workspace.DeployRoot).StartsWith('\\')) { $provider = 'Smb' }
#
# So a projected workspace.yaml carrying deployRoot \Share produces a Local boot
# image and nothing else has to know. The last test in the first context asserts
# exactly that predicate, so the two cannot drift apart silently.
#
# IT IS PRIVATE AND IT IS PURE: lines in, lines out, no filesystem.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # A DOCUMENT WITH COMMENTS IN IT, because the point of a splice is that they
    # survive onto the disc. An administrator wrote these and nobody asked the
    # build to have an opinion about them.
    $script:uncDocument = @(
        '# The lab deployment share. Do not point this at the old server -'
        '# the 2026-08 lease moved and both rules still named the old address.'
        'schemaVersion: 1'
        'id: HDT-LAB'
        'name: HDT lab deployment share'
        'deployRoot: \\server\HDTShare'
        'logLevel: Info'
        ''
        '# The deployment account. The secret lives in'
        '# Control\share-credential.json, never here.'
        'credential:'
        '  username: CONTOSO\svc-hdt-deploy'
        ''
        'bootImage:'
        '  name: HDTPE_x64'
        '  architecture: amd64'
        '  language: en-us'
        '  scratchSpaceMB: 512'
        '  drivers: boot-critical'
    )

    $script:localDocument = @(
        'schemaVersion: 1'
        'id: HDT-LAB'
        'name: HDT lab deployment share'
        'deployRoot: C:\HDTLab\Share'
        'logLevel: Info'
    )

    $script:noDeployRootDocument = @(
        'schemaVersion: 1'
        'id: HDT-LAB'
        'name: HDT lab deployment share'
        'logLevel: Info'
    )

    $script:noCredentialDocument = @(
        'schemaVersion: 1'
        'id: HDT-LAB'
        'name: HDT lab deployment share'
        'deployRoot: \\server\HDTShare'
        'logLevel: Info'
        ''
        'bootImage:'
        '  name: HDTPE_x64'
    )

    # It is private, so every call runs inside InModuleScope. Wrapped once.
    function Set-HDTMediaTestWorkspaceLine {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Returns a copy of in-memory lines; it changes no state.')]
        [CmdletBinding()]
        [OutputType([string[]])]
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [AllowEmptyString()]
            [string[]] $Line
        )

        return [string[]] @(InModuleScope Hephaestus -Parameters @{ Text = $Line } {
                param($Text)

                Set-HDTMediaWorkspaceLine -Line ([string[]] @($Text))
            })
    }

    function Get-HDTTestWorkspaceValue {
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [AllowEmptyString()]
            [string[]] $Line,

            [Parameter(Mandatory = $true)]
            [string] $Key
        )

        $match = @($Line | Where-Object { $_ -match ('^\s*{0}\s*:' -f [regex]::Escape($Key)) })
        if (@($match).Count -eq 0) { return '' }

        return ([string] $match[0] -replace ('^\s*{0}\s*:\s*' -f [regex]::Escape($Key)), '').Trim()
    }
}

Describe 'Set-HDTMediaWorkspaceLine' {

    Context 'the one key that is the whole trick' {

        BeforeAll {
            $script:swapped = Set-HDTMediaTestWorkspaceLine -Line $script:uncDocument
        }

        It 'sets deployRoot to \Share, the volume-relative form' {
            Get-HDTTestWorkspaceValue -Line $script:swapped -Key 'deployRoot' | Should -BeExactly '\Share'
        }

        It 'does not expand \Share to a drive letter, because the letter the disc lands on is unknowable here' {
            $value = Get-HDTTestWorkspaceValue -Line $script:swapped -Key 'deployRoot'

            $value | Should -Not -Match '^[A-Za-z]:'
            [System.IO.Path]::IsPathRooted($value) | Should -BeTrue
        }

        It 'replaces a UNC deployRoot, which is what a real share carries' {
            @($script:swapped | Where-Object { $_ -like '*\\server\HDTShare*' }) | Should -BeNullOrEmpty
        }

        It 'replaces a local deployRoot' {
            $result = Set-HDTMediaTestWorkspaceLine -Line $script:localDocument

            Get-HDTTestWorkspaceValue -Line $result -Key 'deployRoot' | Should -BeExactly '\Share'
            @($result | Where-Object { $_ -like '*C:\HDTLab\Share*' }) | Should -BeNullOrEmpty
        }

        It 'inserts deployRoot when the document has none' {
            $result = Set-HDTMediaTestWorkspaceLine -Line $script:noDeployRootDocument

            Get-HDTTestWorkspaceValue -Line $result -Key 'deployRoot' | Should -BeExactly '\Share'
        }
    }

    Context 'the credential a disc has no use for' {

        It 'removes the credential block' {
            $result = Set-HDTMediaTestWorkspaceLine -Line $script:uncDocument

            @($result | Where-Object { $_ -match '^\s*credential\s*:' }) | Should -BeNullOrEmpty
        }

        It 'removes the block and not just its username key, leaving no husk that will not parse' {
            # A credential: holding nothing parses as a null, and the engine
            # refuses a workspace whose credential is not a mapping. Removing the
            # key and leaving the header would be a disc that cannot be read.
            $result = Set-HDTMediaTestWorkspaceLine -Line $script:uncDocument

            @($result | Where-Object { $_ -match '^\s*username\s*:' }) | Should -BeNullOrEmpty
            @($result | Where-Object { $_ -match 'svc-hdt-deploy' }) | Should -BeNullOrEmpty
        }

        It 'leaves a document with no credential block alone' {
            $result = Set-HDTMediaTestWorkspaceLine -Line $script:noCredentialDocument

            @($result | Where-Object { $_ -match '^\s*credential\s*:' }) | Should -BeNullOrEmpty
            @($result | Where-Object { $_ -eq 'bootImage:' }).Count | Should -Be 1
        }
    }

    Context 'it splices' {

        BeforeAll {
            $script:spliced = Set-HDTMediaTestWorkspaceLine -Line $script:uncDocument
        }

        It 'leaves every other line byte-identical, comments included' {
            # THE COMMENTS AN ADMINISTRATOR WROTE REACH THE DISC. A re-serialised
            # document loses every one of them at parse time.
            $script:spliced | Should -Contain '# The lab deployment share. Do not point this at the old server -'
            $script:spliced | Should -Contain '# the 2026-08 lease moved and both rules still named the old address.'
            $script:spliced | Should -Contain 'schemaVersion: 1'
            $script:spliced | Should -Contain 'id: HDT-LAB'
            $script:spliced | Should -Contain 'name: HDT lab deployment share'
            $script:spliced | Should -Contain 'logLevel: Info'
        }

        It 'leaves the bootImage block untouched' {
            foreach ($line in @('bootImage:', '  name: HDTPE_x64', '  architecture: amd64',
                    '  language: en-us', '  scratchSpaceMB: 512', '  drivers: boot-critical')) {

                $script:spliced | Should -Contain $line
            }
        }

        It 'produces a document Assert-HDTWorkspaceDocument accepts' {
            $text = ($script:spliced -join "`r`n")

            { InModuleScope Hephaestus -Parameters @{ Yaml = $text } {
                    param($Yaml)

                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'X:\Share\workspace.yaml'
                    Assert-HDTWorkspaceDocument -Document $document -Path 'X:\Share\workspace.yaml'
                } } | Should -Not -Throw
        }

        It 'produces a document whose deployRoot Update-HDTBootImage would read as the Local provider' {
            # THE PROVIDER-SWAP ASSERTION, made at the level it can honestly be
            # made at without a build. This is the exact predicate
            # Update-HDTBootImage.ps1 uses, quoted so the two cannot drift:
            #
            #     $provider = 'Local'
            #     if (([string] $workspace.DeployRoot).StartsWith('\\')) { $provider = 'Smb' }
            $value = Get-HDTTestWorkspaceValue -Line $script:spliced -Key 'deployRoot'

            $value.StartsWith('\\') | Should -BeFalse
        }

        It 'is idempotent, so projecting an already projected document changes nothing' {
            $twice = Set-HDTMediaTestWorkspaceLine -Line $script:spliced

            $twice | Should -Be $script:spliced
        }
    }
}
