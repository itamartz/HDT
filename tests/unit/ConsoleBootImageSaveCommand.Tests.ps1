# The command lines the boot image pane echoes after Save.
#
# EVERY COMMAND SAVE RAN, NOT JUST THE LAST ONE. One press of Save is seven
# invocations, and echoing only the write hid the six that decided what was
# written - which is exactly the surface DESIGN 12 says the box at the bottom of
# the window exists to teach. An administrator reading that box has to be able
# to retype the press.
#
# FOURTEEN BRANCHES INSIDE AN Add_Click, and the same "empty means clear"
# decision as the write half - made a second time, against different data. The
# write half reads the BOXES; this reads the REFRESHED VIEW, so what the box
# shows is what the file now says rather than what was typed into it. Those two
# can disagree: the document normalises a time zone id, and the echo has to show
# the normalised one or it is not the command that ran.
#
# THE ORDER IS THE ORDER THEY RAN IN. Retyping the box top to bottom has to
# reproduce the save, so Set-HDTWorkspaceProperty comes first, the five
# documents in the order the pane applies them, and the write last.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {

    # The shape Get-HDTConsoleBootImage builds and the window refreshes after a
    # save: each optional setting carries what it is set to, the line that
    # clears it, and the format string that applies it.
    function New-HDTTestBootImageView {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter()] [string] $Unattend = '',
            [Parameter()] [string] $Background = '',
            [Parameter()] [string] $TimeZone = '',
            [Parameter()] [string] $ClientCertificate = '',
            [Parameter()] [string] $Driver = ''
        )

        return [pscustomobject] @{
            General           = [pscustomobject] @{
                Command                 = "Set-HDTWorkspaceProperty -Line `$line -BootImageName 'HDT-Boot'"
                Unattend                = $Unattend
                UnattendClearCommand    = "Set-HDTBootImageUnattend -Line `$line -Clear"
                UnattendCommandFormat   = "Set-HDTBootImageUnattend -Line `$line -Path '{0}'"
                Background              = $Background
                BackgroundClearCommand  = "Set-HDTBootImageBackground -Line `$line -Clear"
                BackgroundCommandFormat = "Set-HDTBootImageBackground -Line `$line -Path '{0}'"
            }
            TimeZone          = [pscustomobject] @{
                Id                 = $TimeZone
                ClearCommand       = "Set-HDTBootImageTimeZone -Line `$line -Clear"
                ApplyCommandFormat = "Set-HDTBootImageTimeZone -Line `$line -Name '{0}'"
            }
            ClientCertificate = [pscustomobject] @{
                Path               = $ClientCertificate
                ClearCommand       = "Set-HDTBootImageClientCertificate -Line `$line -Clear"
                ApplyCommandFormat = "Set-HDTBootImageClientCertificate -Line `$line -Path '{0}'"
            }
            Driver            = [pscustomobject] @{
                Group              = $Driver
                ClearCommand       = "Set-HDTBootImageDriver -Line `$line -Clear"
                ApplyCommandFormat = "Set-HDTBootImageDriver -Line `$line -Name '{0}'"
            }
        }
    }
}

Describe 'Get-HDTConsoleBootImageSaveCommand' {

    Context 'a boot image with every optional setting filled in' {

        BeforeAll {
            $script:full = @(Get-HDTConsoleBootImageSaveCommand -Path 'C:\ws\workspace.yaml' `
                    -View (New-HDTTestBootImageView -Unattend 'X:\unattend.xml' -Background 'X:\wall.jpg' `
                        -TimeZone 'GMT Standard Time' -ClientCertificate 'X:\client.pfx' -Driver 'WinPE-Net'))
        }

        It 'echoes all seven invocations, not just the write' {
            $script:full.Count | Should -Be 7
        }

        It 'leads with the property write the pane made first' {
            $script:full[0] | Should -BeExactly "Set-HDTWorkspaceProperty -Line `$line -BootImageName 'HDT-Boot'"
        }

        It 'applies each setting rather than clearing it' {
            $script:full[1] | Should -BeExactly "Set-HDTBootImageUnattend -Line `$line -Path 'X:\unattend.xml'"
            $script:full[2] | Should -BeExactly "Set-HDTBootImageBackground -Line `$line -Path 'X:\wall.jpg'"
            $script:full[3] | Should -BeExactly "Set-HDTBootImageTimeZone -Line `$line -Name 'GMT Standard Time'"
            $script:full[4] | Should -BeExactly "Set-HDTBootImageClientCertificate -Line `$line -Path 'X:\client.pfx'"
            $script:full[5] | Should -BeExactly "Set-HDTBootImageDriver -Line `$line -Name 'WinPE-Net'"
        }

        It 'ends with the write, naming the document it went to' {
            $script:full[6] | Should -BeExactly "Save-HDTWorkspaceDocument -Line `$line -Path 'C:\ws\workspace.yaml'"
        }
    }

    # A SAVE THAT CLEARS IS STILL SEVEN COMMANDS. The box has to show the clears,
    # because "I emptied that box and pressed Save" is a thing an administrator
    # needs to be able to reproduce from the command line.
    Context 'a boot image with every optional setting emptied' {

        BeforeAll {
            $script:cleared = @(Get-HDTConsoleBootImageSaveCommand -Path 'C:\ws\workspace.yaml' `
                    -View (New-HDTTestBootImageView))
        }

        It 'still echoes seven invocations' {
            $script:cleared.Count | Should -Be 7
        }

        It 'clears each of the five rather than applying an empty value' {
            $script:cleared[1] | Should -BeExactly "Set-HDTBootImageUnattend -Line `$line -Clear"
            $script:cleared[2] | Should -BeExactly "Set-HDTBootImageBackground -Line `$line -Clear"
            $script:cleared[3] | Should -BeExactly "Set-HDTBootImageTimeZone -Line `$line -Clear"
            $script:cleared[4] | Should -BeExactly "Set-HDTBootImageClientCertificate -Line `$line -Clear"
            $script:cleared[5] | Should -BeExactly "Set-HDTBootImageDriver -Line `$line -Clear"
        }

        It 'names no path in a line that clears' {
            @($script:cleared | Where-Object { $_ -match "-Path 'X:" }).Count | Should -Be 0
        }
    }

    Context 'one setting kept and the rest emptied' {

        It 'applies the one and clears the four' {
            $answer = @(Get-HDTConsoleBootImageSaveCommand -Path 'C:\ws\workspace.yaml' `
                    -View (New-HDTTestBootImageView -TimeZone 'Israel Standard Time'))

            $answer[3] | Should -BeExactly "Set-HDTBootImageTimeZone -Line `$line -Name 'Israel Standard Time'"
            @($answer | Where-Object { $_ -match '-Clear$' }).Count | Should -Be 4
        }
    }

    # WHITESPACE IS EMPTY. A box holding a space is a box somebody cleared badly,
    # and echoing "-Path ' '" teaches a command that would write a key of spaces.
    Context 'a setting holding only whitespace' {

        It 'clears rather than applying the whitespace' {
            $answer = @(Get-HDTConsoleBootImageSaveCommand -Path 'C:\ws\workspace.yaml' `
                    -View (New-HDTTestBootImageView -Unattend '   '))

            $answer[1] | Should -BeExactly "Set-HDTBootImageUnattend -Line `$line -Clear"
        }
    }

    Context 'the document the save went to' {

        It 'names a path holding a space without losing the rest of it' {
            $answer = @(Get-HDTConsoleBootImageSaveCommand -Path 'C:\Deployment Share\workspace.yaml' `
                    -View (New-HDTTestBootImageView))

            $answer[6] | Should -BeExactly "Save-HDTWorkspaceDocument -Line `$line -Path 'C:\Deployment Share\workspace.yaml'"
        }
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTConsoleBootImageSaveCommand -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTConsoleBootImageSaveCommand'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}

}
