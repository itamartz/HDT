#Requires -Modules Pester

# THE SET OF WINDOWS A PAYLOAD DECLARES, READ OFF THE PAYLOAD ITSELF.
#
# Start-HDTDeployment.ps1 takes its XAML as parameters defaulted to X:\HDT\UI\ -
# correct in WinPE, where X: is the RAM disk the boot image staged them onto, and
# meaningless anywhere else. A full-OS Refresh runs the SAME file on a machine
# with no X: at all, so every one of those defaults has to be answered by the
# caller.
#
# AND THE CALLER MAY NOT KEEP A LIST. Six of them shipped wrong at once because
# the set lived in the payload and nowhere else; a seventh added tomorrow would
# have shipped wrong the same way. So the set is DISCOVERED from the param block
# of the very file that is about to be run - one place of truth, and the file
# doing the telling is the file doing the reading (CLAUDE.md rule 8).
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # A PAYLOAD STUB WITH A SEVENTH SCREEN IN IT. The six real ones are named
    # below in the contract test, against the real file; this one carries an
    # invented ChecklistXamlPath so the discovery is proved to be discovery
    # rather than the same list written out twice.
    $script:payloadText = @'
[CmdletBinding()]
param(
    [Parameter()]
    [string] $BootstrapPath = 'X:\HDT\bootstrap.json',

    [Parameter()]
    [string] $ModuleRoot = 'X:\HDT\Modules',

    [Parameter()]
    [AllowEmptyString()]
    [string] $SequenceId = '',

    [Parameter()]
    [string] $WizardShellPath = 'X:\HDT\UI\HDTWizardShell.xaml',

    [Parameter()]
    [string] $ProgressXamlPath = 'X:\HDT\UI\HDTProgress.xaml',

    [Parameter()]
    [string] $ChecklistXamlPath = 'X:\HDT\UI\HDTChecklist.xaml'
)
'@
}

Describe 'Get-HDTPayloadUiPath' {

    It 'rebases every X:\HDT\UI default the payload declares onto the given root' {
        InModuleScope Hephaestus -Parameters @{ Text = $script:payloadText } {
            param($Text)

            $fileSystem = New-HDTFakeFileSystem -File @{ 'Q:\Share\Modules\Hephaestus\Payload\Start-HDTDeployment.ps1' = $Text }

            $map = Get-HDTPayloadUiPath -PayloadPath 'Q:\Share\Modules\Hephaestus\Payload\Start-HDTDeployment.ps1' `
                -UiRoot 'Q:\Share\Modules\Hephaestus\UI' -FileSystem $fileSystem

            @($map.Keys) | Sort-Object | Should -Be @('ChecklistXamlPath', 'ProgressXamlPath', 'WizardShellPath')
            $map['WizardShellPath'] | Should -Be 'Q:\Share\Modules\Hephaestus\UI\HDTWizardShell.xaml'
        }
    }

    It 'carries a screen nobody wrote down here, because the payload is what is read' {
        # THE WHOLE POINT. ChecklistXamlPath exists in no list in src\ and in no
        # list in this repository's tests; it is in the stub's param block, and
        # that is the only reason it comes back.
        InModuleScope Hephaestus -Parameters @{ Text = $script:payloadText } {
            param($Text)

            $fileSystem = New-HDTFakeFileSystem -File @{ 'Q:\p.ps1' = $Text }
            $map = Get-HDTPayloadUiPath -PayloadPath 'Q:\p.ps1' -UiRoot 'Q:\UI' -FileSystem $fileSystem

            $map['ChecklistXamlPath'] | Should -Be 'Q:\UI\HDTChecklist.xaml'
        }
    }

    It 'leaves the X: defaults that are not screens alone' {
        # BootstrapPath AND ModuleRoot ARE ANSWERED ELSEWHERE and answered
        # differently - one is a document this run writes, the other is the share.
        # Rebasing them into UI\ would put the engine in the wrong folder.
        InModuleScope Hephaestus -Parameters @{ Text = $script:payloadText } {
            param($Text)

            $fileSystem = New-HDTFakeFileSystem -File @{ 'Q:\p.ps1' = $Text }
            $map = Get-HDTPayloadUiPath -PayloadPath 'Q:\p.ps1' -UiRoot 'Q:\UI' -FileSystem $fileSystem

            $map.ContainsKey('BootstrapPath') | Should -BeFalse
            $map.ContainsKey('ModuleRoot') | Should -BeFalse
            $map.ContainsKey('SequenceId') | Should -BeFalse
        }
    }

    It 'names no path on the RAM disk' {
        InModuleScope Hephaestus -Parameters @{ Text = $script:payloadText } {
            param($Text)

            $fileSystem = New-HDTFakeFileSystem -File @{ 'Q:\p.ps1' = $Text }
            $map = Get-HDTPayloadUiPath -PayloadPath 'Q:\p.ps1' -UiRoot 'Q:\UI' -FileSystem $fileSystem

            @($map.Values | Where-Object { $_ -match '^[Xx]:' }) | Should -BeNullOrEmpty
        }
    }

    It 'answers an empty set for a payload that declares none, rather than throwing' {
        # AN OLDER SHARE. The engine staged on a share is whatever somebody
        # copied there, and a launcher that threw on one would refuse to start a
        # Refresh that would otherwise have run with console output.
        InModuleScope Hephaestus {
            $fileSystem = New-HDTFakeFileSystem -File @{ 'Q:\p.ps1' = '# the engine entry point' }
            $map = Get-HDTPayloadUiPath -PayloadPath 'Q:\p.ps1' -UiRoot 'Q:\UI' -FileSystem $fileSystem

            @($map.Keys).Count | Should -Be 0
        }
    }

    It 'answers an empty set for a payload that is not there' {
        InModuleScope Hephaestus {
            $fileSystem = New-HDTFakeFileSystem
            $map = Get-HDTPayloadUiPath -PayloadPath 'Q:\missing.ps1' -UiRoot 'Q:\UI' -FileSystem $fileSystem

            @($map.Keys).Count | Should -Be 0
        }
    }
}
