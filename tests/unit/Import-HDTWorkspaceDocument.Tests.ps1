# The read half of workspace.yaml: read through IFileSystem, parse with
# ConvertFrom-HDTYaml, validate with Assert-HDTWorkspaceDocument, project with
# EVERY DEFAULT ALREADY APPLIED so no caller repeats them.
#
# Never Get-Content: the whole authoring path has to be provable under Pester
# with no share and no disk (PROJECT constraint 4), which is why the filesystem
# is injected here and asserted from the fake's journal.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:workspaceFixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/workspace'
    $script:workspacePath = 'X:\Deploy\workspace.yaml'

    $script:fixture = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $script:workspaceFixtureRoot -Filter '*.yaml' -File)) {
        $script:fixture[$file.Name] = Get-Content -LiteralPath $file.FullName -Raw
    }

    function New-HDTWorkspaceTestFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string] $Yaml
        )

        return (New-HDTFakeFileSystem -File @{ $script:workspacePath = $Yaml })
    }
}

Describe 'Import-HDTWorkspaceDocument' {

    Context 'reading' {

        It 'reads through the injected filesystem' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-minimal.yaml']

            Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem | Out-Null

            @($filesystem.GetOperationName()) | Should -Contain 'ReadAllText'
        }

        It 'carries the path it was read from' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-minimal.yaml']

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).Path |
                Should -BeExactly $script:workspacePath
        }

        It 'throws HDTConfigurationError naming the file when it does not exist' {
            $filesystem = New-HDTFakeFileSystem

            $record = $null
            try { Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:workspacePath)
        }

        It 'names the file and the line for unparseable YAML' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['unparseable-indentation.yaml']

            $record = $null
            try { Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike ('*{0}(3)*' -f $script:workspacePath)
        }

        It 'holds itself to the validator' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['invalid-credential-with-password.yaml']

            $record = $null
            try { Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*Set-HDTShareCredential*'
        }
    }

    Context 'the identity' {

        It 'projects schemaVersion, id, name and deployRoot' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-minimal.yaml']

            $workspace = Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem

            $workspace.SchemaVersion | Should -Be 1
            $workspace.Id | Should -BeExactly 'HDT-LAB'
            $workspace.Name | Should -BeExactly 'HDT lab deployment share'
            $workspace.DeployRoot | Should -BeExactly '\\HDT-HOST\HdtShare'
        }

        It 'defaults logLevel to Info' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-minimal.yaml']

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).LogLevel |
                Should -BeExactly 'Info'
        }

        It 'keeps a declared logLevel' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nlogLevel: Debug"

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).LogLevel |
                Should -BeExactly 'Debug'
        }

        It 'carries a volume-relative deployRoot through unchanged' {
            # Nothing here resolves it: Resolve-HDTDeployRoot (05-03) does that
            # inside WinPE, where the volume can actually be probed for.
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-volume-relative-deployroot.yaml']

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).DeployRoot |
                Should -BeExactly '\Share'
        }
    }

    Context 'the credential' {

        It 'returns Credential null when there is no credential block' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-minimal.yaml']

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).Credential |
                Should -BeNullOrEmpty
        }

        It 'projects the username when there is one' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-design-example.yaml']

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).Credential.Username |
                Should -BeExactly 'CONTOSO\svc-hdt-deploy'
        }

        It 'carries no password property at all' {
            # The secret is in Control\share-credential.json (05-02). There is no
            # property here for it to arrive in.
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-design-example.yaml']

            $credential = (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).Credential

            @($credential.PSObject.Properties.Name) | Should -Be @('Username')
        }
    }

    Context 'the bootImage defaults' {

        It 'returns a BootImage object even when the block is absent' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-minimal.yaml']

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage |
                Should -Not -BeNullOrEmpty
        }

        It 'applies the default architecture, language and scratch space' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-minimal.yaml']

            $bootImage = (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage

            $bootImage.Architecture | Should -BeExactly 'amd64'
            $bootImage.Language | Should -BeExactly 'en-us'
            $bootImage.ScratchSpaceMB | Should -Be 512
        }

        It 'defaults the boot image name to HDTPE_x64 for amd64' {
            # DESIGN 2.1 and DESIGN 5 both name the artifacts HDTPE_x64.wim and
            # HDTPE_x64.iso. The ADK folder for that architecture is amd64, so
            # the default maps the folder name to the artifact name rather than
            # producing an HDTPE_amd64.wim the design does not mention.
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-minimal.yaml']

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.Name |
                Should -BeExactly 'HDTPE_x64'
        }

        It 'defaults the boot image name to HDTPE_arm64 for arm64' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  architecture: arm64"

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.Name |
                Should -BeExactly 'HDTPE_arm64'
        }

        It 'keeps a declared boot image name' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-design-example.yaml']

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.Name |
                Should -BeExactly 'HDTPE_x64'
        }

        It 'returns EntryCommand empty when none was declared' {
            # Empty means "the builder decides", and the builder's decision is
            # Get-HDTStartnetScript's own default parameter value. Defaulting the
            # payload path HERE as well would be a second place to change it.
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-minimal.yaml']

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.EntryCommand |
                Should -BeNullOrEmpty
        }

        It 'carries a declared entryCommand through verbatim' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  entryCommand: powershell.exe -NoProfile -File X:\HDT\Start-HDTProbe.ps1"

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.EntryCommand |
                Should -BeExactly 'powershell.exe -NoProfile -File X:\HDT\Start-HDTProbe.ps1'
        }

        It 'returns StartCommand empty when none were declared' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-minimal.yaml']

            @((Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.StartCommand).Count |
                Should -Be 0
        }

        It 'carries the declared startCommand list through in order' {
            # THE ORDER IS THE INSTRUCTION. They are written into startnet.cmd
            # one after another, so a reordering here would silently start a tool
            # before the one it depends on.
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  startCommand:`n    - X:\HDT\Tools\bginfo.exe /timer:0`n    - X:\HDT\Tools\winvnc.exe -service"

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.StartCommand |
                Should -Be @('X:\HDT\Tools\bginfo.exe /timer:0', 'X:\HDT\Tools\winvnc.exe -service')
        }

        It 'returns Drivers empty when none were declared' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-minimal.yaml']

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.Drivers |
                Should -BeNullOrEmpty
        }

        It 'projects the declared driver group' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-design-example.yaml']

            (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.Drivers |
                Should -BeExactly 'boot-critical'
        }
    }

    Context 'the optional components' {

        It 'returns the three default optional components when none were declared' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-minimal.yaml']

            @((Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.OptionalComponent) |
                Should -Be @('WinPE-SecureStartup', 'WinPE-EnhancedStorage', 'WinPE-WDS-Tools')
        }

        It 'returns no optional components for an explicit empty list' {
            # Unset and set-to-nothing are different instructions, and this is
            # the one test that says so at the document layer.
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  optionalComponents: []"

            @((Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.OptionalComponent).Count |
                Should -Be 0
        }

        It 'preserves the declared order of optionalComponents' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  optionalComponents:`n    - WinPE-WDS-Tools`n    - WinPE-SecureStartup`n    - WinPE-FMAPI"

            @((Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.OptionalComponent) |
                Should -Be @('WinPE-WDS-Tools', 'WinPE-SecureStartup', 'WinPE-FMAPI')
        }

        It 'returns a string array, not a single string, for one component' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml "schemaVersion: 1`nid: A`nname: A`ndeployRoot: \\s\h`nbootImage:`n  optionalComponents:`n    - WinPE-FMAPI"

            $component = (Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.OptionalComponent

            , $component | Should -BeOfType [string[]]
        }
    }

    Context 'extraContent' {

        It 'projects Source and Destination per row' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-design-example.yaml']

            $extra = @((Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.ExtraContent)

            $extra.Count | Should -Be 1
            $extra[0].Source | Should -BeExactly 'Modules\MyVendorTools'
            $extra[0].Destination | Should -BeExactly '\HDT\Modules\MyVendorTools'
        }

        It 'returns an empty ExtraContent when none was declared' {
            $filesystem = New-HDTWorkspaceTestFileSystem -Yaml $script:fixture['valid-minimal.yaml']

            @((Import-HDTWorkspaceDocument -Path $script:workspacePath -FileSystem $filesystem).BootImage.ExtraContent).Count |
                Should -Be 0
        }
    }
}
