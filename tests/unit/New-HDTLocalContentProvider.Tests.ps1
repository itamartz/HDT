# The Local IContentProvider (DESIGN 6, DESIGN 6.2).
#
# It is what standalone media runs on, and - because SPIKES S6 records that a VM
# on the isolated 'HDT Lab' switch cannot reach a share on the host - it is what
# the lab runs on too.
#
# EVERYTHING GOES THROUGH IFileSystem. PROJECT constraint 4: engine logic never
# touches the disk directly, so the whole provider is provable here with no
# media, no share and no USB stick.
#
# The resolution rules are written as the same It names as
# New-HDTSmbContentProvider.Tests.ps1 uses, so the two files can be diffed - that
# is DESIGN 6.2's "a step cannot tell them apart" as a reading exercise, with the
# contract test as the enforcement.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTLocalContentProvider' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -Directory @('E:\HDTMedia') -File @{
            'E:\HDTMedia\OperatingSystems\Win11-LTSC-2024\sources\install.wim' = 'WIM'
        }

        $script:content = New-HDTLocalContentProvider -Root 'E:\HDTMedia' -FileSystem $script:fileSystem
    }

    Context 'the interface' {

        It 'exposes every method the contract requires' {
            $method = @($script:content | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('ResolveContent', 'TestContent', 'CopyContent', 'Connect', 'Disconnect')) {
                $method | Should -Contain $name
            }
        }

        It 'names itself ContentProvider' {
            $script:content.ServiceName | Should -BeExactly 'ContentProvider'
        }

        It 'exposes a Root' {
            $script:content.Root | Should -BeExactly 'E:\HDTMedia'
        }
    }

    Context 'resolution' {

        It 'resolves a relative path against the root' {
            $script:content.ResolveContent('OperatingSystems\Win11-LTSC-2024\sources\install.wim') |
                Should -BeExactly 'E:\HDTMedia\OperatingSystems\Win11-LTSC-2024\sources\install.wim'
        }

        It 'accepts a forward-slash relative path' {
            $script:content.ResolveContent('OperatingSystems/Win11-LTSC-2024/sources/install.wim') |
                Should -BeExactly 'E:\HDTMedia\OperatingSystems\Win11-LTSC-2024\sources\install.wim'
        }

        It 'returns a rooted path unchanged' {
            $script:content.ResolveContent('D:\Captures\surface.ffu') | Should -BeExactly 'D:\Captures\surface.ffu'
        }

        It 'refuses a path that escapes the root' {
            $record = $null
            try { $script:content.ResolveContent('..\..\Windows\System32\config\SAM') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty

            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.ArgumentException])

            $record.Exception.Message | Should -BeLike '*HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*E:\HDTMedia*'
        }

        It 'allows a .. that stays inside the root' {
            $script:content.ResolveContent('OperatingSystems\..\Applications\7zip\install.cmd') |
                Should -BeExactly 'E:\HDTMedia\Applications\7zip\install.cmd'
        }

        It 'refuses an empty path' {
            $record = $null
            try { $script:content.ResolveContent('  ') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*HDTConfigurationError*'
        }

        It 'does not check existence when it resolves' {
            # ResolveContent answers "where would this be"; TestContent answers
            # "is it there", and a step asks the second one when it wants to know.
            $script:content.ResolveContent('OperatingSystems\NoSuchOs\sources\install.wim') |
                Should -BeExactly 'E:\HDTMedia\OperatingSystems\NoSuchOs\sources\install.wim'

            @($script:fileSystem.Operations).Count | Should -Be 0
        }
    }

    Context 'presence' {

        It 'reads through the injected filesystem' {
            $script:content.TestContent('OperatingSystems\Win11-LTSC-2024\sources\install.wim') | Should -BeTrue

            @($script:fileSystem.Operations | ForEach-Object { $_.Operation }) | Should -Be @('TestPath')
            [string] $script:fileSystem.Operations[0].Arguments[0] |
                Should -BeExactly 'E:\HDTMedia\OperatingSystems\Win11-LTSC-2024\sources\install.wim'
        }

        It 'reports false for content that is not there' {
            $script:content.TestContent('OperatingSystems\NoSuchOs\sources\install.wim') | Should -BeFalse
        }
    }

    Context 'copying' {

        It 'creates the destination directory before copying' {
            $script:content.CopyContent('OperatingSystems\Win11-LTSC-2024\sources\install.wim', 'C:\Stage\install.wim') | Out-Null

            @($script:fileSystem.Operations | ForEach-Object { $_.Operation }) |
                Should -Be @('TestPath', 'CreateDirectory', 'CopyItem')
        }

        It 'returns the destination from CopyContent' {
            $script:content.CopyContent('OperatingSystems\Win11-LTSC-2024\sources\install.wim', 'C:\Stage\install.wim') |
                Should -BeExactly 'C:\Stage\install.wim'
        }

        It 'copies through the injected filesystem' {
            $script:content.CopyContent('OperatingSystems\Win11-LTSC-2024\sources\install.wim', 'C:\Stage\install.wim') | Out-Null

            $script:fileSystem.ReadAllText('C:\Stage\install.wim') | Should -BeExactly 'WIM'
        }

        It 'throws for a source that is not there' {
            $record = $null
            try { $script:content.CopyContent('OperatingSystems\NoSuchOs\sources\install.wim', 'C:\Stage\install.wim') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty

            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.IO.FileNotFoundException])
        }
    }

    Context 'connect and disconnect' {

        It 'returns the root from Connect' {
            $script:content.Connect() | Should -BeExactly 'E:\HDTMedia'
        }

        It 'throws from Connect when the root does not exist' {
            # A USB stick that was never inserted must fail here, not at the apply.
            $empty = New-HDTFakeFileSystem
            $content = New-HDTLocalContentProvider -Root 'E:\HDTMedia' -FileSystem $empty

            $record = $null
            try { $content.Connect() } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*E:\HDTMedia*'
        }

        It 'records Connect even though it does nothing' {
            # Connect and Disconnect are no-ops here and they still record,
            # because that is what makes the recorded ceremony identical to the
            # Smb provider's (DESIGN 6.2).
            $script:content.Connect() | Out-Null
            $script:content.Disconnect()

            $script:content.GetOperationName() | Should -Be @('Connect', 'Disconnect')
        }

        It 'does not throw from Disconnect when nothing is connected' {
            { $script:content.Disconnect() } | Should -Not -Throw
        }
    }

    Context 'recording' {

        It 'records ResolveContent before it can throw' {
            try { $script:content.ResolveContent('..\..\Windows') } catch { $null = $_ }

            $script:content.GetOperationName() | Should -Be @('ResolveContent')
        }

        It 'honours -Journal' {
            $journal = [System.Collections.ArrayList]::new()
            $content = New-HDTLocalContentProvider -Root 'E:\HDTMedia' -FileSystem (New-HDTFakeFileSystem) -Journal $journal

            $content.ResolveContent('a.txt') | Out-Null

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('ContentProvider.ResolveContent')
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name New-HDTLocalContentProvider -ErrorAction Stop

            $help.Name | Should -BeExactly 'New-HDTLocalContentProvider'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
