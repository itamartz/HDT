# Whether ticking or unticking an optional component should touch the document.
#
# ALREADY THERE MEANS WPF RAISED THIS, NOT A PERSON. The Features tab's
# checkboxes are built the first time the tab is clicked, and every one of them
# raises Checked as it takes its bound value. Add-HDTBootImageComponent refuses a
# duplicate outright, so without this guard the window DIED on the first click
# of that tab.
#
# A LOCKED ROW IS NOT THE DOCUMENT'S TO NAME, and this is the subtler one. The
# six components the engine applies to every image are shown ticked and cannot
# be unticked, and the document does not list them - so they pass the
# already-there test and would be written into optionalComponents by the very
# click that first draws them. THAT IS HOW A SHARE THAT NAMED NOTHING ENDED UP
# NAMING TEN, freezing today's defaults into a file that is meant to inherit
# tomorrow's.
#
# UNTICKING IS THE MIRROR AND NEEDS NO LOCK TEST. Not-there means there is
# nothing to remove, and a locked component is never in the document, so the
# same check covers both.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {

    function New-HDTTestComponentRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter()] [string] $Name = 'WinPE-NetFx',
            [Parameter()] [bool] $CanChange = $true
        )

        return [pscustomobject] @{ Name = $Name; CanChange = $CanChange }
    }
}

Describe 'Test-HDTConsoleComponentWrite' {

    Context 'ticking a component the document does not name' {

        It 'writes it' {
            Test-HDTConsoleComponentWrite -Row (New-HDTTestComponentRow) -Declared @('WinPE-WMI') -Ticking |
                Should -BeTrue
        }

        It 'writes it when the document names nothing at all' {
            Test-HDTConsoleComponentWrite -Row (New-HDTTestComponentRow) -Declared @() -Ticking |
                Should -BeTrue
        }
    }

    # THE ONE THAT KILLED THE WINDOW.
    Context 'ticking a component the document already names' {

        It 'writes nothing, because WPF raised this and not a person' {
            # Add-HDTBootImageComponent refuses a duplicate outright.
            Test-HDTConsoleComponentWrite -Row (New-HDTTestComponentRow) `
                -Declared @('WinPE-NetFx', 'WinPE-WMI') -Ticking | Should -BeFalse
        }
    }

    # THE ONE THAT FROZE TOMORROW'S DEFAULTS INTO TODAY'S FILE.
    Context 'ticking a component the engine always applies' {

        It 'writes nothing, even though the document does not name it' {
            $locked = New-HDTTestComponentRow -Name 'WinPE-WDS-Tools' -CanChange $false

            Test-HDTConsoleComponentWrite -Row $locked -Declared @() -Ticking | Should -BeFalse
        }

        It 'is not saved by the already-there check, which it passes' {
            # It passes that check precisely because the document is silent
            # about it - which is why the lock has to be tested separately.
            $locked = New-HDTTestComponentRow -Name 'WinPE-WDS-Tools' -CanChange $false

            Test-HDTConsoleComponentWrite -Row $locked -Declared @('WinPE-NetFx') -Ticking |
                Should -BeFalse
        }
    }

    Context 'unticking a component the document names' {

        It 'removes it' {
            Test-HDTConsoleComponentWrite -Row (New-HDTTestComponentRow) -Declared @('WinPE-NetFx') |
                Should -BeTrue
        }
    }

    Context 'unticking a component the document does not name' {

        It 'writes nothing, because there is nothing to remove' {
            Test-HDTConsoleComponentWrite -Row (New-HDTTestComponentRow) -Declared @('WinPE-WMI') |
                Should -BeFalse
        }

        It 'covers the always-applied six without a second test for the lock' {
            $locked = New-HDTTestComponentRow -Name 'WinPE-WDS-Tools' -CanChange $false

            Test-HDTConsoleComponentWrite -Row $locked -Declared @('WinPE-NetFx') | Should -BeFalse
        }
    }

    Context 'a component name that differs only in case' {

        It 'is the same component, because the document is not case sensitive here' {
            Test-HDTConsoleComponentWrite -Row (New-HDTTestComponentRow -Name 'winpe-netfx') `
                -Declared @('WinPE-NetFx') -Ticking | Should -BeFalse
        }
    }

    Context 'no row at all' {

        It 'writes nothing rather than failing' {
            Test-HDTConsoleComponentWrite -Row $null -Declared @() -Ticking | Should -BeFalse
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Test-HDTConsoleComponentWrite -ErrorAction Stop

        $help.Name | Should -BeExactly 'Test-HDTConsoleComponentWrite'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
