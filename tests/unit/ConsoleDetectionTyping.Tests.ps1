# WHAT IS TYPED INTO THE DETECTION BOXES HAS TO REACH THE RULE.
#
# THE DEFECT THIS PINS, seen on a real console: Detection opened on an
# application with no rule, "A file is there" chosen, the path typed in full -
# and the window went on saying "this rule needs path before it can be saved",
# went on previewing -Detect @{ }, and went on refusing to enable Save. The one
# box on screen was the one it claimed was empty.
#
# THE BOXES ARE BUILT AT RUNTIME, one per key the chosen type takes, and nothing
# was ever hung off them. Get-HDTConsoleDetectionForm was asked again only when
# the window opened and when the TYPE changed, so every keystroke after that
# landed in a TextBox the validator and the preview never read. Every other
# dialog in New-HDTConsoleHost wires Add_TextChanged; this one had no markup to
# hang it on, because its rows do not exist until a type is picked.
#
# IT IS WRITTEN AGAINST THE SET, NOT AGAINST 'file'. The rows come from
# Get-HDTApplicationDetectKey, so a fifth type added tomorrow is swept the day
# it is added - and msiProduct, registry and script were all just as broken,
# which naming only the type from the screenshot would have hidden.
#
# NO DESKTOP IS NEEDED. New-HDTConsoleDetectionDialog builds and wires the
# window without showing it, the way New-HDTConsoleView already does for the
# console - ShowDialog is the part that blocks, and it stays in the host method.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    Set-StrictMode -Version Latest

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    $script:detectionXaml = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTApplicationDetection.xaml'))

    # A VALUE THAT LOOKS LIKE THE KEY IT IS FOR, so a rule built out of the
    # wrong box is visible in the assertion rather than merely non-empty.
    $script:sample = @{
        productCode = '{11111111-2222-3333-4444-555555555555}'
        path        = 'C:\Program Files\TightVNC\tvnviewer.exe'
        version     = '2.8.88'
        key         = 'HKLM:\SOFTWARE\Contoso\Suite'
        value       = 'InstallPath'
        data        = 'C:\Contoso'
    }

    function New-HDTTestDetectionDialog {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a WPF object graph in memory; it shows nothing and changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter()] [AllowNull()] [object] $Detect = $null)

        return New-HDTConsoleDetectionDialog -Xaml $script:detectionXaml `
            -Workspace 'C:\HDTLab\Share' -Id 'TightVNC-Software-Tightvnc-2.8.88' `
            -Detect $Detect -Theme (Get-HDTConsoleTheme) -Owner $null `
            -ConsoleHost ([pscustomobject] @{ DetectionAnswer = $null })
    }

    # THE BOXES THE PANEL IS HOLDING RIGHT NOW, in the order the form named its
    # keys - which is Required first, then Optional.
    function Get-HDTTestDetectionBox {
        [CmdletBinding()]
        [OutputType([object[]])]
        param([Parameter(Mandatory = $true)] [object] $Dialog)

        $found = New-Object -TypeName System.Collections.ArrayList

        foreach ($row in @($Dialog.FindName('HDTDetectionFieldPanel').Children)) {
            foreach ($child in @($row.Children)) {
                if ($child -is [System.Windows.Controls.TextBox]) { [void] $found.Add($child) }
            }
        }

        return [object[]] @($found)
    }
}

Describe 'the detection dialog, typed into' {

    # EVERY TYPE THE ENGINE KNOWS, from the engine's own table.
    $script:kind = @(@((Get-HDTApplicationDetectKey).Keys) | ForEach-Object { @{ Kind = [string] $_ } })

    Context 'the type <Kind>, chosen on a rule that had none' -ForEach $script:kind {

        BeforeAll {
            $script:dialog = New-HDTTestDetectionDialog
            $script:field = @((Get-HDTConsoleDetectionForm -Type $Kind -Detect $null).Field)

            $script:dialog.FindName('HDTDetectionTypeBox').SelectedValue = $Kind
        }

        It 'draws one box per key the type takes' {
            @(Get-HDTTestDetectionBox -Dialog $script:dialog).Count |
                Should -Be @($script:field).Count
        }

        It 'refuses to save while the required box is empty' {
            $script:dialog.FindName('HDTDetectionSaveButton').IsEnabled | Should -BeFalse
            $script:dialog.FindName('HDTDetectionMessageText').Text | Should -Not -BeNullOrEmpty
        }

        # THE ONE THAT WAS BROKEN.
        It 'clears the refusal as soon as the required boxes hold something' {
            $box = @(Get-HDTTestDetectionBox -Dialog $script:dialog)

            for ($i = 0; $i -lt @($script:field).Count; $i++) {
                if (-not [bool] $script:field[$i].Required) { continue }
                $box[$i].Text = [string] $script:sample[[string] $script:field[$i].Key]
            }

            $script:dialog.FindName('HDTDetectionMessageText').Text |
                Should -BeNullOrEmpty -Because 'the boxes on screen now hold a rule that can be written'

            $script:dialog.FindName('HDTDetectionSaveButton').IsEnabled |
                Should -BeTrue -Because 'nothing is missing any more'
        }

        It 'previews a rule with what was typed in it, not an empty hashtable' {
            $preview = [string] $script:dialog.FindName('HDTDetectionCommandText').Text

            $preview | Should -Not -BeLike '*-Detect @{ }*'
            $preview | Should -BeLike ("*type = '{0}'*" -f $Kind)

            foreach ($one in @($script:field)) {
                if (-not [bool] $one.Required) { continue }

                $preview | Should -BeLike ("*{0} = '{1}'*" -f
                    [string] $one.Key, [string] $script:sample[[string] $one.Key])
            }
        }

        # AN EMPTY OPTIONAL BOX IS NOT A KEY - the validator accepts the
        # absence and the engine would compare against the blank.
        It 'leaves an untouched optional box out of the rule' {
            $preview = [string] $script:dialog.FindName('HDTDetectionCommandText').Text

            foreach ($one in @($script:field)) {
                if ([bool] $one.Required) { continue }
                $preview | Should -Not -BeLike ('*{0} =*' -f [string] $one.Key)
            }
        }
    }

    Context 'a type whose optional boxes are filled in too' {

        BeforeAll {
            $script:full = New-HDTTestDetectionDialog
            $script:full.FindName('HDTDetectionTypeBox').SelectedValue = 'registry'

            $script:fullField = @((Get-HDTConsoleDetectionForm -Type 'registry' -Detect $null).Field)
            $script:fullBox = @(Get-HDTTestDetectionBox -Dialog $script:full)

            for ($i = 0; $i -lt @($script:fullField).Count; $i++) {
                $script:fullBox[$i].Text = [string] $script:sample[[string] $script:fullField[$i].Key]
            }
        }

        It 'carries the optional keys into the preview as well' {
            $preview = [string] $script:full.FindName('HDTDetectionCommandText').Text

            $preview | Should -BeLike "*value = 'InstallPath'*"
            $preview | Should -BeLike "*data = 'C:\Contoso'*"
        }
    }

    # EMPTYING A REQUIRED BOX HAS TO PUT THE REFUSAL BACK. A validator that only
    # ever runs forwards would leave Save enabled over a rule that cannot be
    # written.
    Context 'a required box emptied again' {

        BeforeAll {
            $script:back = New-HDTTestDetectionDialog -Detect ([ordered] @{
                    type = 'file'; path = 'C:\Program Files\TightVNC\tvnviewer.exe' })
        }

        It 'opens on a rule it can save' {
            $script:back.FindName('HDTDetectionSaveButton').IsEnabled | Should -BeTrue
        }

        It 'refuses again once the path is cleared' {
            @(Get-HDTTestDetectionBox -Dialog $script:back)[0].Text = ''

            $script:back.FindName('HDTDetectionSaveButton').IsEnabled | Should -BeFalse
            $script:back.FindName('HDTDetectionMessageText').Text | Should -Not -BeNullOrEmpty
        }
    }
}
}
