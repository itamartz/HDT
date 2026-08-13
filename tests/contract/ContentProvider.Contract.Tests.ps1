# The IContentProvider contract (DESIGN 6, DESIGN 6.2, PROJECT constraint 4).
#
# DESIGN 6.2 says media generation is "a content projection plus a provider swap,
# not a parallel code path". THAT CLAIM IS THIS FILE, OR IT IS A HOPE. Every
# implementation - the fake, Local over a real temp tree, and Smb over a fake SMB
# service - answers the same five members with the same rules:
#
#   ResolveContent(relativePath) -> an absolute path a step can use
#   TestContent(relativePath)    -> [bool]
#   CopyContent(relativePath, destination) -> the destination
#   Connect()                    -> the root that is now reachable
#   Disconnect()                 -> void
#
# Connect and Disconnect are NO-OPS on Local and they are still on the interface,
# because a provider where one implementation carries two extra methods is a
# provider a step has to branch on - and a step that branches on its transport is
# the parallel code path DESIGN 6.2 exists to prevent.
#
# THE ERROR ID TRAVELS IN THE MESSAGE, NOT IN AN ErrorRecord. A refusal raised
# inside a PowerShell class method keeps its FullyQualifiedErrorId; the same
# refusal raised inside a ScriptMethod on a pscustomobject - which is what every
# real adapter is (tests/helpers/README.md F1) - arrives as
# ScriptMethodRuntimeException and loses it. Verified on pwsh 7.5.8 and Windows
# PowerShell 5.1.26100.8655. So the id is written into the sentence, where both
# shapes can carry it, and the type is asserted after unwrapping (README 5).
#
# The skip goes on a Context INSIDE the Describe, never on the -ForEach Describe
# itself (tests/helpers/README.md F9).

$script:HDTImplementation = @(
    @{
        Name           = 'FakeContentProvider'
        Factory        = { New-HDTFakeContentProvider -Root 'Z:\Deploy' }
        JournalFactory = { param($Journal) New-HDTFakeContentProvider -Root 'Z:\Deploy' -Journal $Journal }
        Skip           = $false
    }
    @{
        Name           = 'LocalContentProvider'
        Factory        = { param($LocalRoot) New-HDTLocalContentProvider -Root $LocalRoot -FileSystem (New-HDTFileSystem) }
        JournalFactory = { param($Journal, $LocalRoot) New-HDTLocalContentProvider -Root $LocalRoot -FileSystem (New-HDTFileSystem) -Journal $Journal }
        Skip           = $false
    }
    @{
        Name           = 'SmbContentProvider'
        Factory        = {
            # Over a FAKE SMB service and a FAKE filesystem, so this row runs on
            # any machine with nothing mapped. The contract is about shape; the
            # real SmbShare mechanism is proven in
            # tests/integration/SmbContentProvider.Integration.Tests.ps1.
            #
            # The SecureString is built a character at a time: PSScriptAnalyzer
            # refuses ConvertTo-SecureString -AsPlainText outright.
            $secure = New-Object System.Security.SecureString
            foreach ($character in 'P@ssw0rd!'.ToCharArray()) { $secure.AppendChar($character) }

            New-HDTSmbContentProvider -Root '\\hdtserver\HdtShare' `
                -Credential (New-Object System.Management.Automation.PSCredential 'CONTOSO\svc-hdt-deploy', $secure) `
                -SmbService (New-HDTFakeSmbService -Connection @(
                    [pscustomobject] @{ ServerName = 'hdtserver'; ShareName = 'HdtShare'; UserName = 'CONTOSO\svc-hdt-deploy'; Dialect = '3.1.1'; Encrypted = $true; Signed = $true })) `
                -FileSystem (New-HDTFakeFileSystem)
        }
        JournalFactory = {
            param($Journal)

            $secure = New-Object System.Security.SecureString
            foreach ($character in 'P@ssw0rd!'.ToCharArray()) { $secure.AppendChar($character) }

            New-HDTSmbContentProvider -Root '\\hdtserver\HdtShare' `
                -Credential (New-Object System.Management.Automation.PSCredential 'CONTOSO\svc-hdt-deploy', $secure) `
                -SmbService (New-HDTFakeSmbService -Connection @(
                    [pscustomobject] @{ ServerName = 'hdtserver'; ShareName = 'HdtShare'; UserName = 'CONTOSO\svc-hdt-deploy'; Dialect = '3.1.1'; Encrypted = $true; Signed = $true })) `
                -FileSystem (New-HDTFakeFileSystem) -Journal $Journal
        }
        Skip           = $false
    }
)

Describe 'IContentProvider contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

        # A real tree for the Local row, under TEMP and nowhere else. Never under
        # the repository, never under C:\HDTLab\vms (CLAUDE.md, protected paths).
        $script:localRoot = Join-Path -Path $env:TEMP -ChildPath ('HDTContentContract-{0}' -f [guid]::NewGuid())
        New-Item -Path (Join-Path -Path $script:localRoot -ChildPath 'OperatingSystems\Win11-LTSC-2024\sources') -ItemType Directory -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path -Path $script:localRoot -ChildPath 'OperatingSystems\Win11-LTSC-2024\sources\install.wim'), 'WIM')

        $script:relativePath = 'OperatingSystems\Win11-LTSC-2024\sources\install.wim'
    }

    AfterAll {
        # An explicit -LiteralPath to a directory this block created in this run,
        # which is the only kind of delete CLAUDE.md permits.
        if ($script:localRoot -and (Test-Path -LiteralPath $script:localRoot)) {
            Remove-Item -LiteralPath $script:localRoot -Recurse -Force
        }
    }

    Context 'implementation' -Skip:$Skip {

        BeforeEach {
            # The factory is PASSED the temp tree rather than closing over it: a
            # variable set in BeforeAll is not visible where the row was declared
            # at discovery. This contract's rows need the tree, not the
            # repository root, so that is the argument they get.
            $script:content = & $Factory $script:localRoot
        }

        It 'exposes every method the contract requires' {
            # Get-Member -MemberType Method does NOT list a ScriptMethod, and the
            # real providers are pscustomobjects carrying ScriptMethod members
            # (tests/helpers/README.md F2).
            $method = @($script:content | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('ResolveContent', 'TestContent', 'CopyContent', 'Connect', 'Disconnect')) {
                $method | Should -Contain $name -Because "IContentProvider requires $name"
            }
        }

        It 'names itself ContentProvider' {
            $script:content.ServiceName | Should -BeExactly 'ContentProvider'
        }

        It 'exposes a Root' {
            $script:content.Root | Should -Not -BeNullOrEmpty
        }

        It 'resolves a relative path under the root' {
            $resolved = $script:content.ResolveContent($script:relativePath)

            $resolved.StartsWith($script:content.Root, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
            $resolved.EndsWith('sources\install.wim', [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        }

        It 'returns a rooted path unchanged' {
            # DESIGN 9.3: media registered where it stands is not re-rooted.
            $script:content.ResolveContent('D:\Captures\surface.ffu') | Should -BeExactly 'D:\Captures\surface.ffu'
        }

        It 'refuses a path that escapes the root' {
            $record = $null
            try { $script:content.ResolveContent('..\..\Windows\System32\config\SAM') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty

            # Unwrapped to the innermost exception: a class throws the type
            # directly, a ScriptMethod wraps it twice (README section 5).
            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.ArgumentException])

            $record.Exception.Message | Should -BeLike '*HDTConfigurationError*'
        }

        It 'refuses an empty path' {
            $record = $null
            try { $script:content.ResolveContent(' ') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*HDTConfigurationError*'
        }

        It 'answers TestContent with a boolean' {
            $script:content.TestContent('OperatingSystems\NoSuchOs\sources\install.wim') | Should -BeOfType ([bool])
        }

        It 'records ResolveContent before it can throw' {
            try { $script:content.ResolveContent('..\..\Windows') } catch { $null = $_ }

            @($script:content.GetOperationName()) | Should -Be @('ResolveContent')
        }

        It 'honours -Journal' {
            $journal = [System.Collections.ArrayList]::new()
            $provider = & $JournalFactory $journal $script:localRoot

            $provider.ResolveContent('a.txt') | Out-Null

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('ContentProvider.ResolveContent')
        }

        It 'has a Connect that returns the root' {
            $script:content.Connect() | Should -BeExactly $script:content.Root
        }

        It 'has a Disconnect that does not throw when nothing is connected' {
            { $script:content.Disconnect() } | Should -Not -Throw
        }
    }
}
