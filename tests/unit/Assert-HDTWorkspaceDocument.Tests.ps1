# The engine's own workspace.yaml validator, and the one that actually runs in
# WinPE: Test-Json does not exist under Windows PowerShell 5.1, so
# schemas/workspace.schema.json is the gate for the console, an editor and CI
# while this is the gate for a deployment.
#
# It is private, so every assertion runs inside InModuleScope. Every rule asserts
# that the message names THE FILE and THE OFFENDING KEY - a validator that
# rejects the right file with the wrong sentence sends an administrator looking
# in the wrong place.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:workspaceFixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/workspace'
    $script:workspacePath = 'C:\HDTLab\does-not-exist\workspace.yaml'

    $script:fixture = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $script:workspaceFixtureRoot -Filter '*.yaml' -File)) {
        $script:fixture[$file.Name] = Get-Content -LiteralPath $file.FullName -Raw
    }

    # The rejection, or $null when the document was accepted. Every negative test
    # goes through here so the InModuleScope boilerplate is written once and the
    # It body is the assertion.
    function Get-HDTWorkspaceRejection {
        [CmdletBinding()]
        [OutputType([System.Management.Automation.ErrorRecord])]
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string] $Yaml
        )

        $record = $null
        try {
            InModuleScope Hephaestus -Parameters @{ Yaml = $Yaml; Path = $script:workspacePath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path
                Assert-HDTWorkspaceDocument -Document $document -Path $Path
            }
        } catch {
            $record = $_
        }

        return $record
    }
}

Describe 'Assert-HDTWorkspaceDocument' {

    Context 'what it accepts' {

        It 'accepts <_>' -ForEach @('valid-minimal.yaml', 'valid-design-example.yaml', 'valid-volume-relative-deployroot.yaml') {
            Get-HDTWorkspaceRejection -Yaml $script:fixture[$_] | Should -BeNullOrEmpty
        }

        It 'returns nothing for a valid document' {
            InModuleScope Hephaestus -Parameters @{ Yaml = $script:fixture['valid-minimal.yaml']; Path = $script:workspacePath } {
                param($Yaml, $Path)

                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path

                Assert-HDTWorkspaceDocument -Document $document -Path $Path | Should -BeNullOrEmpty
            }
        }

        It 'accepts a document with no bootImage block' {
            # "The admin did not say" and "the admin said nothing unusual" are the
            # same build, so an absent block is legal and the defaults apply.
            Get-HDTWorkspaceRejection -Yaml $script:fixture['valid-minimal.yaml'] | Should -BeNullOrEmpty
        }

        It 'accepts an empty optionalComponents list' {
            # Set-to-nothing is a different instruction from unset, and it is
            # legal: it means "the six required components and nothing else".
            Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  optionalComponents: []" |
                Should -BeNullOrEmpty
        }

        It 'accepts a credential block with only a username' {
            Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`ncredential:`n  username: CONTOSO\svc-hdt-deploy" |
                Should -BeNullOrEmpty
        }

        It 'accepts a UNC deployRoot' {
            Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\HDT-HOST\HdtShare" |
                Should -BeNullOrEmpty
        }

        It 'accepts a rooted local deployRoot' {
            Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: C:\HDTLab\Share" |
                Should -BeNullOrEmpty
        }

        It 'accepts a volume-relative deployRoot' {
            # SPIKES S9.1: WinPE gave the content disk C: and the RAM disk X:, so
            # a boot image cannot know the letter its own content will land on.
            # \Share is the only form a Local boot image may carry, and NOTHING
            # in this plan resolves it - Resolve-HDTDeployRoot (05-03) does that
            # inside WinPE by probing every ready drive for the marker.
            Get-HDTWorkspaceRejection -Yaml $script:fixture['valid-volume-relative-deployroot.yaml'] |
                Should -BeNullOrEmpty
        }

        It 'accepts every logLevel the design names' -ForEach @('Error', 'Warning', 'Info', 'Debug') {
            Get-HDTWorkspaceRejection -Yaml ("schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nlogLevel: {0}" -f $_) |
                Should -BeNullOrEmpty
        }
    }

    Context 'the document' {

        It 'rejects an empty file' {
            $record = Get-HDTWorkspaceRejection -Yaml ''

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*empty*'
            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:workspacePath)
        }

        It 'rejects a document that is not a mapping' {
            $record = $null
            try {
                InModuleScope Hephaestus -Parameters @{ Path = $script:workspacePath } {
                    param($Path)
                    Assert-HDTWorkspaceDocument -Document @(1, 2) -Path $Path
                }
            } catch { $record = $_ }

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*mapping*'
        }

        It 'rejects an unknown top-level key, naming it and the accepted keys' {
            $record = Get-HDTWorkspaceRejection -Yaml $script:fixture['invalid-unknown-key.yaml']

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:workspacePath)
            $record.Exception.Message | Should -BeLike '*priority*'
            $record.Exception.Message | Should -BeLike '*deployRoot*'
            $record.Exception.Message | Should -BeLike '*bootImage*'
        }

        It 'rejects a missing schemaVersion' {
            $record = Get-HDTWorkspaceRejection -Yaml $script:fixture['invalid-missing-schemaversion.yaml']

            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:workspacePath)
            $record.Exception.Message | Should -BeLike '*schemaVersion*'
        }

        It 'rejects a schemaVersion that is not an integer' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: one`nid: A`nname: A`ndeployRoot: \\s\h"

            $record.Exception.Message | Should -BeLike '*schemaVersion*'
        }

        It 'rejects a schemaVersion newer than this engine, naming both numbers' {
            $record = Get-HDTWorkspaceRejection -Yaml $script:fixture['invalid-newer-schemaversion.yaml']

            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:workspacePath)
            $record.Exception.Message | Should -BeLike '*99*'
            $record.Exception.Message | Should -BeLike '*1*'
        }
    }

    Context 'the identity' {

        It 'rejects a missing id' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nname: A`ndeployRoot: \\s\h"

            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:workspacePath)
            $record.Exception.Message | Should -BeLike '*id*'
        }

        It 'rejects a missing name' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`ndeployRoot: \\s\h"

            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:workspacePath)
            $record.Exception.Message | Should -BeLike '*name*'
        }

        It 'rejects an id with a character outside [A-Za-z0-9-_], naming the value' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: HDT LAB\..`nname: A`ndeployRoot: \\s\h"

            $record.Exception.Message | Should -BeLike '*HDT LAB\..*'
        }

        It 'rejects an id longer than 64 characters' {
            $long = 'A' * 65
            $record = Get-HDTWorkspaceRejection -Yaml ("schemaVersion: 1`nid: {0}`nname: A`ndeployRoot: \\s\h" -f $long)

            $record.Exception.Message | Should -BeLike '*64*'
        }
    }

    Context 'deployRoot' {

        It 'rejects a missing deployRoot' {
            $record = Get-HDTWorkspaceRejection -Yaml $script:fixture['invalid-missing-deployroot.yaml']

            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:workspacePath)
            $record.Exception.Message | Should -BeLike '*deployRoot*'
        }

        It 'rejects an empty deployRoot' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: '   '"

            $record.Exception.Message | Should -BeLike '*deployRoot*'
        }

        It 'rejects a deployRoot containing .., naming the value' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h\..\other"

            $record.Exception.Message | Should -BeLike '*deployRoot*'
            $record.Exception.Message | Should -BeLike '*\\s\h\..\other*'
        }
    }

    Context 'the credential' {

        It 'refuses a password under credential' {
            # THE DESIGN 6.3 CORRECTION. 6.3 shows "password: <set by
            # Set-HDTShareCredential>" in workspace.yaml and says in the very
            # next line that the value "never appears in a file an admin
            # hand-edits, so it does not end up in git". Both cannot be true of
            # the same file. The secret lives in Control\share-credential.json,
            # written by Set-HDTShareCredential (05-02); this file carries a
            # username and nothing else.
            $record = Get-HDTWorkspaceRejection -Yaml $script:fixture['invalid-credential-with-password.yaml']

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:workspacePath)
            $record.Exception.Message | Should -BeLike '*password*'
            $record.Exception.Message | Should -BeLike '*Set-HDTShareCredential*'
        }

        It 'does not echo the password back in the message' {
            # A validator that quotes the secret it is refusing has written the
            # secret to the log the administrator is about to paste into a chat.
            $record = Get-HDTWorkspaceRejection -Yaml $script:fixture['invalid-credential-with-password.yaml']

            $record.Exception.Message | Should -Not -BeLike '*Summer2026!*'
        }

        It 'rejects a credential block with no username' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`ncredential:`n  username: ''"

            $record.Exception.Message | Should -BeLike '*username*'
        }

        It 'rejects an unknown key under credential' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`ncredential:`n  username: A`n  domain: CONTOSO"

            $record.Exception.Message | Should -BeLike '*domain*'
        }
    }

    Context 'the bootImage block' {

        It 'rejects an unknown key under bootImage' {
            $record = Get-HDTWorkspaceRejection -Yaml $script:fixture['invalid-unknown-bootimage-key.yaml']

            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:workspacePath)
            $record.Exception.Message | Should -BeLike '*bootImage*'
            $record.Exception.Message | Should -BeLike '*scratchSpace*'
        }

        It 'rejects an architecture outside amd64 and arm64' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  architecture: x86"

            $record.Exception.Message | Should -BeLike '*x86*'
        }

        It 'rejects a scratchSpaceMB below 32' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  scratchSpaceMB: 16"

            $record.Exception.Message | Should -BeLike '*scratchSpaceMB*'
            $record.Exception.Message | Should -BeLike '*16*'
        }

        It 'rejects a scratchSpaceMB above 1024' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  scratchSpaceMB: 2048"

            $record.Exception.Message | Should -BeLike '*scratchSpaceMB*'
            $record.Exception.Message | Should -BeLike '*2048*'
        }

        It 'rejects a logLevel outside the four, naming the value and the four' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nlogLevel: Verbose"

            $record.Exception.Message | Should -BeLike '*Verbose*'
            $record.Exception.Message | Should -BeLike '*Error*'
            $record.Exception.Message | Should -BeLike '*Warning*'
            $record.Exception.Message | Should -BeLike '*Info*'
            $record.Exception.Message | Should -BeLike '*Debug*'
        }
    }

    Context 'optionalComponents' {

        It 'rejects optionalComponents that is not a list' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  optionalComponents: WinPE-WMI"

            $record.Exception.Message | Should -BeLike '*optionalComponents*'
        }

        It 'rejects a component not matching WinPE-*, naming the value' {
            $record = Get-HDTWorkspaceRejection -Yaml $script:fixture['invalid-component-not-winpe.yaml']

            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:workspacePath)
            $record.Exception.Message | Should -BeLike '*Storage-WMI*'
        }

        It 'refuses a duplicate component that differs only in case' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  optionalComponents:`n    - WinPE-WMI`n    - winpe-wmi"

            $record.Exception.Message | Should -BeLike '*winpe-wmi*'
        }
    }

    Context 'extraContent' {

        It 'rejects an entry with no destination, naming the index and the key' {
            $record = Get-HDTWorkspaceRejection -Yaml $script:fixture['invalid-extracontent-without-destination.yaml']

            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:workspacePath)
            $record.Exception.Message | Should -BeLike '*extraContent*1*'
            $record.Exception.Message | Should -BeLike '*destination*'
        }

        It 'rejects an entry with no source, naming the index and the key' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  extraContent:`n    - destination: \HDT\Tools"

            $record.Exception.Message | Should -BeLike '*extraContent*1*'
            $record.Exception.Message | Should -BeLike '*source*'
        }

        It 'rejects a destination that does not start with a separator' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  extraContent:`n    - source: Modules\Tools`n      destination: HDT\Tools"

            $record.Exception.Message | Should -BeLike '*HDT\Tools*'
            $record.Exception.Message | Should -BeLike '*a destination is a path inside the image*'
        }

        It 'rejects a destination containing .., saying it escapes the image' {
            $record = Get-HDTWorkspaceRejection -Yaml $script:fixture['invalid-extracontent-escapes.yaml']

            $record.Exception.Message | Should -BeLike '*escapes the image*'
            $record.Exception.Message | Should -BeLike '*\HDT\..\..\Windows\System32*'
        }

        It 'rejects an unknown key inside an extraContent entry' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  extraContent:`n    - source: Modules\Tools`n      destination: \HDT\Tools`n      recurse: true"

            $record.Exception.Message | Should -BeLike '*recurse*'
        }
    }

    Context 'entryCommand' {

        It 'accepts an entryCommand naming a script staged inside the image' {
            # The diagnostic boot image Get-HDTStartnetScript's own .EXAMPLE
            # describes: extraContent puts the script at X:\HDT, entryCommand
            # launches it. X: is deterministic - it is the WinPE RAM disk - which
            # is why nothing has to scan for a drive letter.
            Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  entryCommand: powershell.exe -NoProfile -File X:\HDT\Start-HDTProbe.ps1" |
                Should -BeNullOrEmpty
        }

        It 'accepts a document with no entryCommand, which takes the default payload' {
            Get-HDTWorkspaceRejection -Yaml $script:fixture['valid-minimal.yaml'] | Should -BeNullOrEmpty
        }

        It 'rejects an empty entryCommand rather than writing a startnet.cmd that runs nothing' {
            $record = Get-HDTWorkspaceRejection -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  entryCommand: ''"

            # THE MESSAGE, NOT JUST THE KEY NAME. While entryCommand was not yet
            # an allowed key this assertion passed on the unknown-key rejection,
            # which mentions every key by name - a test green for a reason that
            # had nothing to do with emptiness. Matching the sentence the empty
            # case actually produces is what makes the pass mean something.
            $record.Exception.Message | Should -BeLike '*must be a command to run*'
            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:workspacePath)
        }

        It 'rejects an entryCommand carrying a newline, which would be a second startnet line' {
            # THE REASON THIS FIELD IS VALIDATED AT ALL. The value is written into
            # startnet.cmd verbatim, so an embedded newline is not a formatting
            # nuisance: it is a second command, executing inside WinPE, that no
            # reader of the workspace document would see as one.
            #
            # A single-quoted here-string, so the \n reaches the YAML parser as
            # the two characters a double-quoted YAML scalar turns into a line
            # break. Writing the break in PowerShell instead would end the YAML
            # scalar before the parser ever saw it.
            $yaml = @'
schemaVersion: 1
id: A
name: A
deployRoot: \\s\h
bootImage:
  entryCommand: "wpeutil shutdown\nformat C: /y"
'@

            $record = Get-HDTWorkspaceRejection -Yaml $yaml

            $record.Exception.Message | Should -BeLike '*entryCommand*'
            $record.Exception.Message | Should -BeLike '*one command*'
        }
    }

    Context 'unparseable YAML' {

        It 'names the file and the line' {
            # ConvertFrom-HDTYaml already does this; the point of asserting it
            # here is that the read path does not swallow the line on the way.
            $record = Get-HDTWorkspaceRejection -Yaml $script:fixture['unparseable-indentation.yaml']

            $record.Exception.Message | Should -BeLike ('*{0}(3)*' -f $script:workspacePath)
        }
    }
}
