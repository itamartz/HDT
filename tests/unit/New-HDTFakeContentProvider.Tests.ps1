# The IContentProvider double (DESIGN 6, DESIGN 12.2.1, DESIGN 12.2.3).
#
# DESIGN 6.2's claim is that media generation is "a content projection plus a
# provider swap, not a parallel code path" - which is only true if a step cannot
# tell one provider from another. That makes the FIVE members, and their
# refusals, the thing worth pinning down here:
#
#   ResolveContent(relativePath) -> an absolute path a step can use
#   TestContent(relativePath)    -> [bool]
#   CopyContent(relativePath, destination) -> the destination
#   Connect()                    -> the root that is now reachable
#   Disconnect()                 -> void
#
# Connect and Disconnect exist on EVERY implementation, including the ones for
# which they do nothing, because a provider interface where one implementation
# has two extra methods is a provider interface a step has to branch on.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTFakeContentProvider' {

    BeforeEach {
        $script:content = New-HDTFakeContentProvider -Root 'Z:\Deploy'
    }

    Context 'resolution' {

        It 'resolves a relative path against the root' {
            $script:content.ResolveContent('OperatingSystems\Win11-LTSC-2024\sources\install.wim') |
                Should -BeExactly 'Z:\Deploy\OperatingSystems\Win11-LTSC-2024\sources\install.wim'
        }

        It 'returns a rooted path unchanged' {
            # DESIGN 9.3: media too large to bring into the share is registered
            # where it stands, and a provider that re-rooted it would send the
            # apply step to a path with nothing in it.
            $script:content.ResolveContent('D:\Captures\surface.ffu') | Should -BeExactly 'D:\Captures\surface.ffu'
        }

        It 'refuses a path that escapes the root' {
            $record = $null
            try { $script:content.ResolveContent('..\..\Windows\System32\config\SAM') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception | Should -BeOfType ([System.ArgumentException])
            $record.Exception.Message | Should -BeLike '*HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Z:\Deploy*'
        }

        It 'refuses an empty path' {
            $record = $null
            try { $script:content.ResolveContent('   ') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception | Should -BeOfType ([System.ArgumentException])
            $record.Exception.Message | Should -BeLike '*HDTConfigurationError*'
        }

        It 'resolves a seeded path to the absolute path it was seeded with' {
            $content = New-HDTFakeContentProvider -Root 'Z:\Deploy' -Content @{
                'OperatingSystems\Win11-LTSC-2024\sources\install.wim' = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
            }

            $content.ResolveContent('OperatingSystems\Win11-LTSC-2024\sources\install.wim') |
                Should -BeExactly 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
        }
    }

    Context 'presence' {

        It 'reports TestContent true for content it was seeded with' {
            $content = New-HDTFakeContentProvider -Root 'Z:\Deploy' -Content @{
                'Applications\7zip\install.cmd' = 'Z:\Deploy\Applications\7zip\install.cmd'
            }

            $content.TestContent('Applications\7zip\install.cmd') | Should -BeTrue
        }

        It 'reports TestContent false for content it was not seeded with' {
            $script:content.TestContent('Applications\NoSuchApp\install.cmd') | Should -BeFalse
        }

        It 'matches a seeded path with either separator' {
            $content = New-HDTFakeContentProvider -Root 'Z:\Deploy' -Content @{
                'Applications/7zip/install.cmd' = 'Z:\Deploy\Applications\7zip\install.cmd'
            }

            $content.TestContent('Applications\7zip\install.cmd') | Should -BeTrue
        }
    }

    Context 'copying' {

        It 'copies content to the destination it was given' {
            $content = New-HDTFakeContentProvider -Root 'Z:\Deploy' -Content @{
                'Boot\HDTPE_x64.wim' = 'Z:\Deploy\Boot\HDTPE_x64.wim'
            }

            $content.CopyContent('Boot\HDTPE_x64.wim', 'C:\HDTLab\nothing-here\HDTPE_x64.wim') |
                Should -BeExactly 'C:\HDTLab\nothing-here\HDTPE_x64.wim'
        }

        It 'throws from CopyContent for a source it does not have' {
            $record = $null
            try { $script:content.CopyContent('Boot\Absent.wim', 'C:\HDTLab\nothing-here\Absent.wim') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception | Should -BeOfType ([System.IO.FileNotFoundException])
        }

        It 'touches no real filesystem' {
            # tests/helpers/README.md section 7: without this a fake can fall
            # through to the real machine and every test above it becomes a lie.
            $content = New-HDTFakeContentProvider -Root 'C:\HDTLab\nothing-here' -Content @{
                'source.txt' = 'C:\HDTLab\nothing-here\source.txt'
            }

            $content.CopyContent('source.txt', 'C:\HDTLab\nothing-here\copy.txt') | Out-Null

            Test-Path -LiteralPath 'C:\HDTLab\nothing-here\copy.txt' | Should -BeFalse
            Test-Path -LiteralPath 'C:\HDTLab\nothing-here' | Should -BeFalse
        }
    }

    Context 'connection' {

        It 'records Connect and Disconnect' {
            $script:content.Connect() | Out-Null
            $script:content.Disconnect()

            $script:content.GetOperationName() | Should -Be @('Connect', 'Disconnect')
        }

        It 'returns the root from Connect' {
            $script:content.Connect() | Should -BeExactly 'Z:\Deploy'
        }

        It 'does not throw from Disconnect when nothing was connected' {
            { $script:content.Disconnect() } | Should -Not -Throw
        }
    }

    Context 'recording' {

        It 'names itself ContentProvider' {
            $script:content.ServiceName | Should -BeExactly 'ContentProvider'
        }

        It 'exposes a Root' {
            $script:content.Root | Should -BeExactly 'Z:\Deploy'
        }

        It 'records ResolveContent before it can throw' {
            try { $script:content.ResolveContent('..\..\Windows') } catch { $null = $_ }

            $script:content.GetOperationName() | Should -Be @('ResolveContent')
            [string] $script:content.Operations[0].Arguments[0] | Should -BeExactly '..\..\Windows'
        }

        It 'records the read-only calls too' {
            $script:content.TestContent('a.txt') | Out-Null
            $script:content.ResolveContent('a.txt') | Out-Null

            $script:content.GetOperationName() | Should -Be @('TestContent', 'ResolveContent')
        }

        It 'records into a shared journal' {
            $journal = [System.Collections.ArrayList]::new()
            $content = New-HDTFakeContentProvider -Root 'Z:\Deploy' -Journal $journal

            $content.ResolveContent('a.txt') | Out-Null

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('ContentProvider.ResolveContent')
        }

        It 'does not record seeding' {
            $content = New-HDTFakeContentProvider -Root 'Z:\Deploy' -Content @{ 'a.txt' = 'Z:\Deploy\a.txt' }

            @($content.Operations).Count | Should -Be 0
        }
    }

    Context 'seeded failures' {

        It 'throws the seeded failure from ResolveContent' {
            $content = New-HDTFakeContentProvider -Root 'Z:\Deploy' -Failure @{ ResolveContent = 'the share went away' }

            $record = $null
            try { $content.ResolveContent('a.txt') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception | Should -BeOfType ([System.InvalidOperationException])
            $record.Exception.Message | Should -BeExactly 'the share went away'
        }

        It 'throws the seeded failure from Connect' {
            $content = New-HDTFakeContentProvider -Root 'Z:\Deploy' -Failure @{ Connect = 'the network is not up' }

            { $content.Connect() } | Should -Throw -ExpectedMessage '*the network is not up*'
        }

        It 'records Connect before it throws' {
            $content = New-HDTFakeContentProvider -Root 'Z:\Deploy' -Failure @{ Connect = 'the network is not up' }

            try { $content.Connect() } catch { $null = $_ }

            $content.GetOperationName() | Should -Be @('Connect')
        }
    }
}
