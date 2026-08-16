# What a WinPE optional component actually does, in one line.
#
# THE ADK SHIPS NO DESCRIPTIONS. WinPE_OCs\ is 34 .cab files and nothing else -
# no manifest, no metadata, not even a friendly name. Everything
# Get-HDTAdkComponent knows is derived from those filenames, which is why the
# Features tab read `WinPE-Dot3Svc  1.3 MB` and told an administrator nothing.
#
# So HDT ships a table, exactly as MDT does. The text comes from Microsoft's
# WinPE Optional Components (OC) Reference, condensed to a line that fits a
# column - a paragraph in a list row is a paragraph nobody reads.
#
# It is private: it is a lookup Get-HDTAdkComponent joins on, not a command an
# administrator runs.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:ocRoot = Join-Path -Path ${env:ProgramFiles(x86)} `
        -ChildPath 'Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment'

    # It is private, so every call goes through InModuleScope. These two exist
    # so the assertions read as assertions rather than as scope plumbing.
    function Get-HDTTestDescription {
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory = $true)] [string] $Name)

        return [string] (InModuleScope Hephaestus -Parameters @{ Wanted = $Name } {
                param($Wanted)
                Get-HDTAdkComponentDescription -Name $Wanted
            })
    }

    function Get-HDTTestDescriptionTable {
        [CmdletBinding()]
        [OutputType([object[]])]
        param()

        return @(InModuleScope Hephaestus { (Get-HDTAdkComponentDescription).GetEnumerator() })
    }
}

Describe 'Get-HDTAdkComponentDescription' {

    It 'is private to the module' {
        InModuleScope Hephaestus {
            Get-Command -Name 'Get-HDTAdkComponentDescription' -ErrorAction SilentlyContinue
        } | Should -Not -BeNullOrEmpty

        Get-Command -Name 'Get-HDTAdkComponentDescription' -Module Hephaestus -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'describes <Name> as something naming <Word>' -ForEach @(
        @{ Name = 'WinPE-WMI'; Word = 'WMI' }
        @{ Name = 'WinPE-Dot3Svc'; Word = '802.1X' }
        @{ Name = 'WinPE-SecureStartup'; Word = 'BitLocker' }
        @{ Name = 'WinPE-Scripting'; Word = 'Script Host' }
        @{ Name = 'WinPE-NetFx'; Word = '.NET' }
        @{ Name = 'WinPE-PowerShell'; Word = 'PowerShell' }
        @{ Name = 'WinPE-WDS-Tools'; Word = 'multicast' }
        @{ Name = 'WinPE-HTA'; Word = 'HTML' }
        @{ Name = 'WinPE-MDAC'; Word = 'database' }
        @{ Name = 'WinPE-EnhancedStorage'; Word = 'encrypted' }
    ) {
        Get-HDTTestDescription -Name $Name | Should -BeLike ('*{0}*' -f $Word)
    }

    It 'answers whatever case the name is written in' {
        # A workspace document is hand-edited, and the component pattern in the
        # schema does not police case. Get-HDTBootImageComponent already compares
        # without regard to it, so a lookup that did not would put a description
        # beside one row and not beside the same row spelled differently.
        Get-HDTTestDescription -Name 'winpe-wmi' |
            Should -BeExactly (Get-HDTTestDescription -Name 'WinPE-WMI')
    }

    It 'answers empty for a component it has never heard of' {
        # A NEXT ADK WILL SHIP ONE. The row must still appear, with its name and
        # its size, rather than the window refusing to open over a cab nobody
        # has written a line for yet.
        Get-HDTTestDescription -Name 'WinPE-NotAThing' | Should -BeExactly ''
    }

    It 'keeps every line short enough to sit in a column' {
        # The Features tab gives this one column beside a name and a size. A
        # paragraph there wraps the row to five lines and the list stops being
        # scannable, which is the whole reason the table exists.
        $tooLong = @(Get-HDTTestDescriptionTable | Where-Object { $_.Value.Length -gt 130 } |
                ForEach-Object { '{0} ({1})' -f $_.Key, $_.Value.Length })

        ($tooLong -join '; ') | Should -BeExactly ''
    }

    It 'writes every line on one line' {
        $multiLine = @(Get-HDTTestDescriptionTable |
                Where-Object { $_.Value.IndexOfAny([char[]] @("`r", "`n")) -ge 0 } |
                ForEach-Object { [string] $_.Key })

        ($multiLine -join '; ') | Should -BeExactly ''
    }

    It 'covers every cab the installed ADK ships for <_>' -ForEach @('amd64', 'arm64') -Skip:(
        -not (Test-Path -LiteralPath (Join-Path -Path ${env:ProgramFiles(x86)} `
                    -ChildPath 'Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment'))) {

        # THE ONE THAT CATCHES A NEW ADK. The table is authored and the cab set
        # is not; a release that adds a component would otherwise show a blank
        # column for it and nobody would notice until somebody asked what it
        # did.
        $folder = Join-Path -Path $script:ocRoot -ChildPath ('{0}\WinPE_OCs' -f $_)

        # An ADK installed for one architecture only is an ordinary machine, not
        # a failure - there is simply nothing to check.
        $missing = @()

        if (Test-Path -LiteralPath $folder) {
            $missing = @(Get-ChildItem -LiteralPath $folder -Filter '*.cab' -File |
                    ForEach-Object { $_.BaseName } |
                    Where-Object { [string]::IsNullOrWhiteSpace((Get-HDTTestDescription -Name $_)) })
        }

        ($missing -join '; ') | Should -BeExactly ''
    }
}

Describe 'Get-HDTAdkComponent carries the description' {

    It 'puts a Description on every row it returns' {
        # The join is what the window reads. A command that knew the table and
        # did not hand it on would leave the Features tab exactly as cryptic as
        # it was.
        $row = InModuleScope Hephaestus {
            Get-HDTAdkComponent -ComponentRoot 'X:\OCs' -FileSystem (
                New-HDTFakeFileSystem -File @{
                    'X:\OCs\WinPE-WMI.cab'        = 'binary'
                    'X:\OCs\WinPE-NotAThing.cab'  = 'binary'
                })
        }

        @($row).Count | Should -Be 2
        @($row | Where-Object { $_.Name -eq 'WinPE-WMI' })[0].Description | Should -BeLike '*WMI*'
    }

    It 'leaves the description empty for a cab the table does not know' {
        $row = InModuleScope Hephaestus {
            Get-HDTAdkComponent -ComponentRoot 'X:\OCs' -FileSystem (
                New-HDTFakeFileSystem -File @{ 'X:\OCs\WinPE-NotAThing.cab' = 'binary' })
        }

        @($row)[0].Description | Should -BeExactly ''
    }
}
