# THE WINDOWS PE WINDOW SAYS WHEN THE IMAGE HAS GONE STALE.
#
# WHAT HAPPENED. Somebody picked a time zone on that window, pressed Save, and
# got a success footer. The document was right and the boot image was not: the
# zone is written by dism into the mounted WIM, so it reaches a machine only
# when Update Boot Image runs. Nothing on the screen said so - and the same is
# true of nearly every other field on the window.
#
# SO ONE LINE APPEARS IN THE FOOTER, beside the button that fixes it, and only
# once something baked has actually moved. Three things are asserted here:
#
#   it stays quiet for a window nobody has touched, and for the one document on
#   this window that is read live off the share;
#
#   it appears for a baked field, whether that field is a box, a list or the
#   bootstrap rules - which are written INTO the image and only look share-side;
#
#   AND IT SURVIVES SAVE. That is the subtle one. Save writes workspace.yaml and
#   builds nothing, so a notice cleared by Save would go out exactly when it had
#   just become true.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # THE SHIPPED MARKUP, so this window and the one the console opens cannot
    # drift apart.
    $script:bootXaml = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTBootImage.xaml'))

    # A REAL DIRECTORY, because Save really writes. TestDrive is Pester's own and
    # it clears it up; nothing here goes near the lab.
    $script:shareRoot = Join-Path -Path $TestDrive -ChildPath 'RebuildShare'
    [void] (New-Item -Path $script:shareRoot -ItemType Directory -Force)

    $script:workspacePath = Join-Path -Path $script:shareRoot -ChildPath 'workspace.yaml'
    $script:rulesPath = Join-Path -Path $script:shareRoot -ChildPath 'rules.yaml'

    $script:workspaceYaml = [string[]] @(
        'schemaVersion: 1'
        'id: HDT-LAB'
        'name: HDT deployment share'
        'bootImage:'
        '  name: HDTPE_wiz_x64'
        '  architecture: amd64'
        '  scratchSpaceMB: 512'
    )

    [System.IO.File]::WriteAllLines($script:workspacePath, [string[]] $script:workspaceYaml)

    [System.IO.File]::WriteAllLines($script:rulesPath, [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Fallback'
            '    set:'
            '      HDTComputerName: "PC-%HDTSerialNumber%"'
        ))

    function New-HDTTestRebuildWindow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a WPF object graph in memory; it shows nothing and changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param()

        $double = [pscustomobject] @{ Answer = ''; Width = 0; Height = 0; Window = $null }

        return New-HDTConsoleBootImageView -ConsoleHost $double -Xaml $script:bootXaml `
            -Path $script:workspacePath -Line $script:workspaceYaml `
            -Component ([object[]] @()) -SelectionProfile ([object[]] @()) `
            -Theme (Get-HDTConsoleTheme) `
            -Size ([pscustomobject] @{ Width = 1180; Height = 760; Left = 40; Top = 20 })
    }

    function Test-HDTTestRebuildShown {
        [CmdletBinding()]
        [OutputType([bool])]
        param([Parameter(Mandatory = $true)] [object] $Window)

        $notice = $Window.FindName('HDTBootImageRebuildText')

        return ($notice.Visibility -eq [System.Windows.Visibility]::Visible)
    }

    function Invoke-HDTTestRebuildClick {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Raises a routed event on an in-memory control.')]
        [CmdletBinding()]
        [OutputType([void])]
        param([Parameter(Mandatory = $true)] [object] $Button)

        $Button.RaiseEvent((New-Object -TypeName System.Windows.RoutedEventArgs `
                    -ArgumentList ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    }
}

Describe 'The Windows PE window and the boot image it has left behind' {

    Context 'a window nobody has touched' {

        BeforeAll { $script:fresh = New-HDTTestRebuildWindow }

        It 'has the notice on it at all' {
            # A control this file cannot find would make every assertion below
            # pass by being absent.
            $script:fresh.FindName('HDTBootImageRebuildText') | Should -Not -BeNullOrEmpty
        }

        It 'says nothing about rebuilding' {
            # FILLING THE BOXES IS NOT AN EDIT. The window assigns every value on
            # the way up, and a notice raised by that would be on the screen
            # before anybody had done anything - which is the wallpaper this is
            # meant not to be.
            Test-HDTTestRebuildShown -Window $script:fresh | Should -BeFalse
        }

        It 'carries the text from the string table rather than the markup' {
            [string] $script:fresh.FindName('HDTBootImageRebuildText').Text |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'a baked box that changes' {

        It 'raises the notice when the image name is retyped' {
            $window = New-HDTTestRebuildWindow
            $window.FindName('HDTBootImageNameBox').Text = 'HDTPE_other'

            Test-HDTTestRebuildShown -Window $window | Should -BeTrue
        }

        It 'raises the notice when the architecture is picked' {
            # UBI:344 - the build reads bootImage.architecture and it decides
            # which ADK cab set goes in.
            $window = New-HDTTestRebuildWindow
            $window.FindName('HDTBootImageArchitectureBox').SelectedValue = 'arm64'

            Test-HDTTestRebuildShown -Window $window | Should -BeTrue
        }

        It 'raises the notice when the scratch space is picked' {
            $window = New-HDTTestRebuildWindow
            $window.FindName('HDTBootImageScratchBox').SelectedValue = '1024'

            Test-HDTTestRebuildShown -Window $window | Should -BeTrue
        }

        It 'raises the notice when the boot prompt is ticked' {
            # A tick box has no empty, and this one decides which efisys boot
            # sector oscdimg writes into the ISO.
            $window = New-HDTTestRebuildWindow
            $window.FindName('HDTBootImagePromptForKeyCheck').IsChecked = $true

            Test-HDTTestRebuildShown -Window $window | Should -BeTrue
        }
    }

    Context 'a baked list that changes' {

        It 'raises the notice when a start command is added' {
            # THE LIST PATH, WHICH IS A DIFFERENT ONE. A box is read at Save; a
            # list splices the document as the button is pressed. Both are baked
            # - startnet.cmd is written into the image at UBI:793 - so both have
            # to say so.
            $window = New-HDTTestRebuildWindow
            $window.FindName('HDTStartCommandBox').Text = 'wpeutil InitializeNetwork'

            Invoke-HDTTestRebuildClick -Button $window.FindName('HDTStartCommandAddButton')

            Test-HDTTestRebuildShown -Window $window | Should -BeTrue
        }

        It 'raises the notice when extra content is added' {
            $window = New-HDTTestRebuildWindow
            $window.FindName('HDTContentSourceBox').Text = 'C:\Tools\BGInfo'
            $window.FindName('HDTContentDestinationBox').Text = '\HDT\Tools\BGInfo'

            Invoke-HDTTestRebuildClick -Button $window.FindName('HDTContentAddButton')

            Test-HDTTestRebuildShown -Window $window | Should -BeTrue
        }
    }

    Context 'the two rule editors, which are not alike' {

        It 'says nothing when rules.yaml is edited' {
            # READ LIVE OFF THE SHARE at deployment, so the next run picks it up
            # and no image has to be built. A notice here would be a lie, and one
            # lie is enough to train somebody to ignore the true ones.
            $window = New-HDTTestRebuildWindow
            $window.FindName('HDTRulesBox').Text = "schemaVersion: 1`nrules: []"

            Test-HDTTestRebuildShown -Window $window | Should -BeFalse
        }

        It 'raises the notice when bootstrap-rules.yaml is edited' {
            # WRITTEN INTO THE IMAGE, at Update-HDTBootImage step 12b, because
            # WinPE reads it before the share is reachable. It looks like the box
            # above it and behaves like the boxes on the General tab.
            $window = New-HDTTestRebuildWindow
            $window.FindName('HDTBootstrapRulesBox').Text = "schemaVersion: 1`nrules: []"

            Test-HDTTestRebuildShown -Window $window | Should -BeTrue
        }
    }

    Context 'Save, which writes the document and builds nothing' {

        BeforeAll {
            $script:saved = New-HDTTestRebuildWindow
            $script:saved.FindName('HDTBootImageNameBox').Text = 'HDTPE_after_save'

            Invoke-HDTTestRebuildClick -Button $script:saved.FindName('HDTBootImageSaveButton')
        }

        It 'wrote the document' {
            # Otherwise the assertion below would be about a Save that did not
            # happen.
            ([System.IO.File]::ReadAllText($script:workspacePath)) | Should -Match 'HDTPE_after_save'
        }

        It 'leaves the notice up' {
            # THE ONE MOST LIKELY TO BE GOT WRONG. Save clears the document's
            # dirty flag and refills every box, and a notice hung off that flag
            # would disappear at the very moment the share and the image had
            # started to disagree.
            Test-HDTTestRebuildShown -Window $script:saved | Should -BeTrue
        }
    }
}

}
