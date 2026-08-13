# The deployment share credential (DESIGN 6.3).
#
# A PXE-booted WinPE has no machine identity to authenticate with, so the
# deployment account's password is embedded in the boot image - MDT's
# Bootstrap.ini model, and the same exposure. What HDT controls is where the
# value lives and what is claimed about it:
#
#   - ONE WRITER. Set-HDTShareCredential, and nothing else, writes
#     Control\share-credential.json. 05-01 made a password: key in
#     workspace.yaml a validation error naming this command, because
#     workspace.yaml is the file an admin hand-edits and commits.
#   - NOT PLAIN TEXT, AND NOT CLAIMED TO BE SECURE. The file carries a warning
#     sentence saying that anyone who can read it, or the boot image, can
#     recover the password. DESIGN 6.3: "obfuscation is not claimed as
#     security ... the docs say so plainly rather than implying the image is
#     safe to hand out."
#   - NOT DPAPI. DPAPI is user- and machine-bound, and this file has to be
#     readable inside WinPE on a machine that has never seen this one, which is
#     the entire point of embedding it.
#   - NOT IN GIT. .gitignore carries Control/share-credential.json.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:workspaceRoot = 'C:\HDTLab\does-not-exist\Share'
    $script:credentialPath = 'C:\HDTLab\does-not-exist\Share\Control\share-credential.json'
    $script:plain = 'P@ssw0rd-not-in-a-log'

    # Built a character at a time: PSScriptAnalyzer refuses
    # ConvertTo-SecureString -AsPlainText outright.
    $script:newCredential = {
        param([string] $UserName, [string] $Plain)

        $secure = New-Object System.Security.SecureString
        foreach ($character in $Plain.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()

        return (New-Object System.Management.Automation.PSCredential $UserName, $secure)
    }
}

Describe 'Set-HDTShareCredential' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem
        $script:credential = & $script:newCredential 'CONTOSO\svc-hdt-deploy' $script:plain
    }

    Context 'where it writes' {

        It 'writes to Control\share-credential.json' {
            Set-HDTShareCredential -WorkspaceRoot $script:workspaceRoot -Credential $script:credential `
                -FileSystem $script:fileSystem -Confirm:$false

            @($script:fileSystem.Operations | Where-Object { $_.Operation -eq 'WriteAllText' } |
                    ForEach-Object { [string] $_.Arguments[0] }) | Should -Contain $script:credentialPath
        }

        It 'builds the path with Get-HDTWorkspacePath rather than a literal' {
            # The same discipline the resume launcher's test uses: a folder name
            # written twice is a folder name that will disagree with itself.
            $source = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Set-HDTShareCredential.ps1') -Raw

            $source | Should -Match 'Get-HDTWorkspacePath'
            $source | Should -Not -Match "'Control'"
        }

        It 'touches no real filesystem' {
            Set-HDTShareCredential -WorkspaceRoot $script:workspaceRoot -Credential $script:credential `
                -FileSystem $script:fileSystem -Confirm:$false

            Test-Path -LiteralPath $script:credentialPath | Should -BeFalse
        }
    }

    Context 'what it writes' {

        BeforeEach {
            Set-HDTShareCredential -WorkspaceRoot $script:workspaceRoot -Credential $script:credential `
                -FileSystem $script:fileSystem -Confirm:$false

            $script:text = $script:fileSystem.ReadAllText($script:credentialPath)
            $script:document = ConvertFrom-Json -InputObject $script:text
        }

        It 'writes the user name in the clear' {
            # The account name is not the secret, and an admin has to be able to
            # read which account a boot image carries.
            $script:document.username | Should -BeExactly 'CONTOSO\svc-hdt-deploy'
        }

        It 'does not write the password in plain text' {
            $script:text | Should -Not -BeLike ('*{0}*' -f $script:plain)
        }

        It 'writes the warning sentence into the file' {
            $script:document.warning | Should -Not -BeNullOrEmpty
            $script:document.warning | Should -BeLike '*recover*'
            $script:document.warning | Should -BeLike '*boot image*'
        }

        It 'writes a schema version' {
            $script:document.schemaVersion | Should -Be 1
        }

        It 'writes UTF-8 with no BOM' {
            # SPIKES S6's third finding, in a different disguise: a BOM here
            # would land in exactly the file a parser reads inside WinPE.
            $script:text.Substring(0, 1) | Should -BeExactly '{'
            [int] $script:text[0] | Should -Not -Be 65279
        }

        It 'round-trips the password through Get-HDTShareCredential' {
            $read = Get-HDTShareCredential -WorkspaceRoot $script:workspaceRoot -FileSystem $script:fileSystem

            $read.UserName | Should -BeExactly 'CONTOSO\svc-hdt-deploy'
            $read.Password | Should -BeExactly $script:plain
        }

        It 'overwrites an existing secret' {
            $second = & $script:newCredential 'CONTOSO\svc-other' 'a-different-password'
            Set-HDTShareCredential -WorkspaceRoot $script:workspaceRoot -Credential $second `
                -FileSystem $script:fileSystem -Confirm:$false

            $read = Get-HDTShareCredential -WorkspaceRoot $script:workspaceRoot -FileSystem $script:fileSystem

            $read.UserName | Should -BeExactly 'CONTOSO\svc-other'
            $read.Password | Should -BeExactly 'a-different-password'
        }
    }

    Context 'refusals' {

        It 'refuses an empty password' {
            $empty = New-Object System.Management.Automation.PSCredential 'CONTOSO\svc-hdt-deploy',
            (New-Object System.Security.SecureString)

            $record = $null
            try {
                Set-HDTShareCredential -WorkspaceRoot $script:workspaceRoot -Credential $empty `
                    -FileSystem $script:fileSystem -Confirm:$false
            } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'writes nothing when it refuses' {
            $empty = New-Object System.Management.Automation.PSCredential 'CONTOSO\svc-hdt-deploy',
            (New-Object System.Security.SecureString)

            try {
                Set-HDTShareCredential -WorkspaceRoot $script:workspaceRoot -Credential $empty `
                    -FileSystem $script:fileSystem -Confirm:$false
            } catch { $null = $_ }

            @($script:fileSystem.GetOperationName()) | Should -Not -Contain 'WriteAllText'
        }

        It 'writes nothing under -WhatIf' {
            Set-HDTShareCredential -WorkspaceRoot $script:workspaceRoot -Credential $script:credential `
                -FileSystem $script:fileSystem -WhatIf

            @($script:fileSystem.GetOperationName()) | Should -Not -Contain 'WriteAllText'
        }

        It 'supports ShouldProcess' {
            # It overwrites a secret, so CLAUDE.md hard rule 6 applies.
            (Get-Command Set-HDTShareCredential).Parameters.ContainsKey('WhatIf') | Should -BeTrue
        }
    }

    Context 'what it returns' {

        It 'returns nothing to the pipeline' {
            # A cmdlet that echoed the credential would put it in a transcript.
            $output = Set-HDTShareCredential -WorkspaceRoot $script:workspaceRoot -Credential $script:credential `
                -FileSystem $script:fileSystem -Confirm:$false

            $output | Should -BeNullOrEmpty
        }
    }

    Context 'Get-HDTShareCredential' {

        It 'throws naming the file when no credential was written' {
            $record = $null
            try { Get-HDTShareCredential -WorkspaceRoot $script:workspaceRoot -FileSystem $script:fileSystem } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*share-credential.json*'
            $record.Exception.Message | Should -BeLike '*Set-HDTShareCredential*'
        }

        It 'reports the file as a configuration error when it cannot be read as JSON' {
            $script:fileSystem.SeedFile($script:credentialPath, 'this is not json {')

            $record = $null
            try { Get-HDTShareCredential -WorkspaceRoot $script:workspaceRoot -FileSystem $script:fileSystem } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name Set-HDTShareCredential -ErrorAction Stop

            $help.Name | Should -BeExactly 'Set-HDTShareCredential'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }

        It 'has comment-based help on the reader too' {
            $help = Get-Help -Name Get-HDTShareCredential -ErrorAction Stop

            $help.Name | Should -BeExactly 'Get-HDTShareCredential'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the secret is not in git' {

        It 'gitignores Control/share-credential.json' {
            $ignore = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath '.gitignore') -Raw

            $ignore | Should -BeLike '*Control/share-credential.json*'
        }
    }
}
