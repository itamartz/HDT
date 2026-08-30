# The Rules tabs on the Windows PE window, and the work they used to lose.
#
# WHAT HAPPENED. An administrator edited a rule, the document was valid, the
# 'Save rules' button was lit - and they pressed the 'Save' at the BOTTOM of the
# window, which writes workspace.yaml and deliberately does not touch rules.
# They got a success footer naming a different file, closed the window, and the
# edit was gone. Save-HDTRuleDocument appears nowhere in that day's console log.
#
# NOTHING TOLD THEM, AND THAT IS THE WHOLE DEFECT. The save path works. But the
# rules tabs never set the window's dirty state, so the close prompt asked only
# about workspace.yaml and a window holding unsaved rule text shut in silence -
# the same failure, in the same window, that the sequence editor's title-bar X
# was fixed for.
#
# SO THREE THINGS ARE ASSERTED HERE. A rules tab knows when it has been edited;
# it stops knowing when the edit is saved, reloaded, or typed back to what the
# file says; and every document this window can write is offered to the close
# prompt, driven off the SET the view registers rather than a list copied here -
# because a fourth document added later is exactly how this one was forgotten.
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

    # A REAL DIRECTORY, because 'Save rules' really writes. TestDrive is Pester's
    # own and it clears it up; nothing here goes near the lab.
    $script:shareRoot = Join-Path -Path $TestDrive -ChildPath 'Share'
    [void] (New-Item -Path $script:shareRoot -ItemType Directory -Force)

    $script:workspacePath = Join-Path -Path $script:shareRoot -ChildPath 'workspace.yaml'
    $script:rulesPath = Join-Path -Path $script:shareRoot -ChildPath 'rules.yaml'
    $script:bootstrapPath = Join-Path -Path $script:shareRoot -ChildPath 'bootstrap-rules.yaml'

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

    [System.IO.File]::WriteAllLines($script:bootstrapPath, [string[]] @(
            'schemaVersion: 1'
            'rules:'
            '  - name: Site A'
            '    when: { HDTDefaultGateway: "192.168.1.1" }'
            '    set:'
            '      HDTDeployRoot: \\SERVER-A\HdtShare'
        ))

    function New-HDTTestRuleWindow {
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

    function Get-HDTTestDocumentState {
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter(Mandatory = $true)] [object] $Window,
            [Parameter(Mandatory = $true)] [string] $Path
        )

        return @($Window.HDTDocument) | Where-Object { [string] $_.Path -eq $Path }
    }

    function Invoke-HDTTestClick {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Raises a routed event on an in-memory control.')]
        [CmdletBinding()]
        [OutputType([void])]
        param([Parameter(Mandatory = $true)] [object] $Button)

        $Button.RaiseEvent((New-Object -TypeName System.Windows.RoutedEventArgs `
                    -ArgumentList ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    }
}

Describe 'The Rules tabs know when they hold unsaved work' {

    Context 'a window as it opens' {

        BeforeAll { $script:fresh = New-HDTTestRuleWindow }

        It 'registers every document it can write' {
            @($script:fresh.HDTDocument).Count | Should -BeGreaterThan 0
        }

        It 'holds no unsaved rules, because filling a box is not an edit' {
            # $fill assigns TextBox.Text, which raises TextChanged - so a tab
            # that compared nothing would open dirty and prompt on every close.
            (Get-HDTTestDocumentState -Window $script:fresh -Path $script:rulesPath).Dirty |
                Should -BeFalse
        }

        It 'wears no marker on the Rules tab header' {
            [string] $script:fresh.FindName('HDTBootImageRules').Header |
                Should -Not -BeLike '*`**'
        }
    }

    Context 'a rule typed into the Rules box' {

        BeforeAll {
            $script:typed = New-HDTTestRuleWindow
            $script:typed.FindName('HDTRulesBox').Text = "schemaVersion: 1`r`nrules: []"
        }

        It 'marks that document unsaved' {
            (Get-HDTTestDocumentState -Window $script:typed -Path $script:rulesPath).Dirty |
                Should -BeTrue
        }

        It 'shows a marker on the Rules tab header, where the bottom Save can see it' {
            # The bottom Save lives on the General tab. An administrator standing
            # there cannot see the Rules box at all, which is how they pressed
            # the wrong Save and lost the edit.
            [string] $script:typed.FindName('HDTBootImageRules').Header |
                Should -BeLike '*`**'
        }

        It 'leaves the other rules document alone' {
            (Get-HDTTestDocumentState -Window $script:typed -Path $script:bootstrapPath).Dirty |
                Should -BeFalse
        }

        It 'leaves workspace.yaml alone, because no box on the other tabs was touched' {
            (Get-HDTTestDocumentState -Window $script:typed -Path $script:workspacePath).Dirty |
                Should -BeFalse
        }
    }

    Context 'a rule typed into the Bootstrap box' {

        BeforeAll {
            $script:typedBootstrap = New-HDTTestRuleWindow
            $script:typedBootstrap.FindName('HDTBootstrapRulesBox').Text = "schemaVersion: 1`r`nrules: []"
        }

        It 'marks bootstrap-rules.yaml unsaved' {
            (Get-HDTTestDocumentState -Window $script:typedBootstrap -Path $script:bootstrapPath).Dirty |
                Should -BeTrue
        }

        It 'does not mark rules.yaml, because one scriptblock wires both tabs' {
            # $wireRuleTab is invoked twice. A flag shared between the two
            # invocations would make either tab dirty the moment the other was
            # touched, and the prompt would name a file nobody had edited.
            (Get-HDTTestDocumentState -Window $script:typedBootstrap -Path $script:rulesPath).Dirty |
                Should -BeFalse
        }
    }

    Context 'an edit typed back to what the file says' {

        BeforeAll {
            $script:restored = New-HDTTestRuleWindow
            $box = $script:restored.FindName('HDTRulesBox')

            $script:onDisk = [string] $box.Text
            $box.Text = "schemaVersion: 1`r`nrules: []"
            $box.Text = $script:onDisk
        }

        It 'leaves the tab clean' {
            # The flag compares against what the file said, not against whether
            # a key was pressed - so undoing an edit is not an unsaved change.
            (Get-HDTTestDocumentState -Window $script:restored -Path $script:rulesPath).Dirty |
                Should -BeFalse
        }

        It 'takes the marker off the tab header again' {
            [string] $script:restored.FindName('HDTBootImageRules').Header |
                Should -Not -BeLike '*`**'
        }
    }

    Context 'Save rules, pressed' {

        BeforeAll {
            $script:saved = New-HDTTestRuleWindow
            $script:saved.FindName('HDTRulesBox').Text = @(
                'schemaVersion: 1'
                'rules:'
                '  - name: Saved by the test'
                '    set:'
                '      HDTComputerName: "PC-1"'
            ) -join "`r`n"

            Invoke-HDTTestClick -Button $script:saved.FindName('HDTRulesSaveButton')
        }

        It 'wrote the document' {
            [System.IO.File]::ReadAllText($script:rulesPath) | Should -BeLike '*Saved by the test*'
        }

        It 'clears the unsaved mark' {
            (Get-HDTTestDocumentState -Window $script:saved -Path $script:rulesPath).Dirty |
                Should -BeFalse
        }

        It 'takes the marker off the tab header' {
            [string] $script:saved.FindName('HDTBootImageRules').Header |
                Should -Not -BeLike '*`**'
        }
    }

    Context 'Reload, pressed on an edited tab' {

        BeforeAll {
            $script:reloaded = New-HDTTestRuleWindow
            $script:reloaded.FindName('HDTRulesBox').Text = "schemaVersion: 1`r`nrules: []"

            Invoke-HDTTestClick -Button $script:reloaded.FindName('HDTRulesReloadButton')
        }

        It 'clears the unsaved mark, because the edit is gone' {
            (Get-HDTTestDocumentState -Window $script:reloaded -Path $script:rulesPath).Dirty |
                Should -BeFalse
        }
    }
}

Describe 'Closing the Windows PE window with unsaved rules' {

    # THE REGRESSION. This is what the administrator did: edit a rule, press the
    # bottom Save, close. The prompt the closing handler asks for is asked for
    # here with the same set the handler passes it - $window.HDTDocument, whose
    # Dirty is live - so what is asserted is the question the window would put
    # on the screen.

    BeforeAll {
        $script:closing = New-HDTTestRuleWindow
        $script:closing.FindName('HDTRulesBox').Text = "schemaVersion: 1`r`nrules: []"

        $script:closingPrompt = Get-HDTConsoleClosePrompt -Document ([object[]] @($script:closing.HDTDocument))
    }

    It 'asks, instead of closing in silence' {
        $script:closingPrompt.Ask | Should -BeTrue
    }

    It 'names the rules document, which is the file that was lost' {
        $script:closingPrompt.Message | Should -BeLike '*rules.yaml*'
        $script:closingPrompt.Unsaved | Should -Contain $script:rulesPath
    }

    It 'names the button that writes it, because the bottom Save does not' {
        $script:closingPrompt.Message | Should -BeLike '*Save rules*'
    }

    It 'still offers leaving without saving' {
        $script:closingPrompt.Button | Should -BeExactly 'YesNoCancel'
    }
}

Describe 'Every document the Windows PE window can write reaches the close prompt' {

    # THE GENERAL FORM, and the reason this defect existed. rules.yaml was
    # editable on this window for months while the close prompt knew only about
    # workspace.yaml. A test naming the three documents would pass for them and
    # fail nobody after them, so this drives off the SET the view registers:
    # a fourth editable document is covered the day it is added, or it fails
    # here.

    BeforeAll { $script:everyWindow = New-HDTTestRuleWindow }

    It 'registers the three documents this window edits today' {
        # Not the assertion that matters - the loop below is - but a registry
        # that quietly lost an entry would make that loop vacuously green.
        @($script:everyWindow.HDTDocument).Path | Sort-Object |
            Should -Be (@($script:bootstrapPath, $script:rulesPath, $script:workspacePath) | Sort-Object)
    }

    It 'names each registered document in the prompt when that one is unsaved' {
        foreach ($one in @($script:everyWindow.HDTDocument)) {
            $only = @(
                foreach ($each in @($script:everyWindow.HDTDocument)) {
                    [pscustomobject] @{
                        Path     = [string] $each.Path
                        Dirty    = ([string] $each.Path -eq [string] $one.Path)
                        SaveWith = [string] $each.SaveWith
                    }
                }
            )

            $prompt = Get-HDTConsoleClosePrompt -Document ([object[]] $only)

            $prompt.Ask | Should -BeTrue -Because "$($one.Path) is unsaved"
            $prompt.Unsaved | Should -Contain ([string] $one.Path)
            $prompt.Message | Should -BeLike ('*{0}*' -f [string] $one.Path)
        }
    }

    It 'names the button that saves each one, so the way to keep the work is on the screen' {
        foreach ($one in @($script:everyWindow.HDTDocument)) {
            [string] $one.SaveWith | Should -Not -BeNullOrEmpty -Because "$($one.Path) needs a button"
        }
    }
}

Describe 'Get-HDTConsoleClosePrompt over a set of documents' {

    BeforeAll {
        $script:setClean = [object[]] @(
            [pscustomobject] @{ Path = 'C:\ws\workspace.yaml'; Dirty = $false; SaveWith = 'Save' }
            [pscustomobject] @{ Path = 'C:\ws\rules.yaml'; Dirty = $false; SaveWith = 'Save rules' }
        )

        $script:setDirty = [object[]] @(
            [pscustomobject] @{ Path = 'C:\ws\workspace.yaml'; Dirty = $false; SaveWith = 'Save' }
            [pscustomobject] @{ Path = 'C:\ws\rules.yaml'; Dirty = $true; SaveWith = 'Save rules' }
        )
    }

    It 'does not ask when nothing is unsaved' {
        $prompt = Get-HDTConsoleClosePrompt -Document $script:setClean

        $prompt.Ask | Should -BeFalse
        @($prompt.Unsaved).Count | Should -Be 0
    }

    It 'asks when any one of them is unsaved' {
        (Get-HDTConsoleClosePrompt -Document $script:setDirty).Ask | Should -BeTrue
    }

    It 'names only the unsaved ones' {
        $prompt = Get-HDTConsoleClosePrompt -Document $script:setDirty

        $prompt.Unsaved | Should -Be @('C:\ws\rules.yaml')
        $prompt.Message | Should -Not -BeLike '*workspace.yaml*'
    }

    It 'spells out what each answer does' {
        $prompt = Get-HDTConsoleClosePrompt -Document $script:setDirty

        $prompt.Message | Should -BeLike '*Yes*'
        $prompt.Message | Should -BeLike '*No*'
        $prompt.Message | Should -BeLike '*Cancel*'
    }

    It 'is a question, not a warning' {
        $prompt = Get-HDTConsoleClosePrompt -Document $script:setDirty

        $prompt.Icon | Should -BeExactly 'Question'
        $prompt.Title | Should -Not -BeNullOrEmpty
    }

    It 'still answers for one document, because the sequence editor asks that way' {
        # New-HDTConsoleEditorView calls the single-document form. Changing it
        # would be a second defect in a window that has already lost work once.
        $one = Get-HDTConsoleClosePrompt -DocumentPath 'C:\ws\TaskSequences\DEMO-M4\sequence.yaml' -Dirty

        $one.Ask | Should -BeTrue
        $one.Message | Should -BeLike '*DEMO-M4*'
        $one.Button | Should -BeExactly 'YesNoCancel'
    }
}

Describe 'The application list of a rule, edited on the Rules tab' {

    # WHAT WAS REPORTED. An administrator took Acrobat out of a rule's
    # HDTApplications list, pressed a Save, and found on the way out that the
    # window still thought the tab was dirty - and Acrobat still in the file
    # when they came back. The save path was accused; it is not at fault. What
    # they pressed was the Save at the BOTTOM of the window, which writes
    # workspace.yaml and deliberately writes nothing else.
    #
    # SO THIS PINS THE PATH THAT DOES WORK, over the SET of edits an
    # application list takes rather than the one edit that was reported.
    # Removing the first id, removing the second, adding one, reordering them
    # and emptying the list are five different strings through the same
    # splice-free editor, and a test naming only 'remove Acrobat' would pass for
    # it and fail nobody after it.
    #
    # AND IT PROVES THE COMMENTS SURVIVE. rules.yaml is mostly commentary - the
    # HDTApplications line on the lab share carries two sentences above it
    # explaining why a skipped page still has to be answered - and an editor
    # that parsed and re-serialised the document would take them out. This tab
    # never parses to write: Save-HDTRuleDocument writes the lines it was given.

    # HERE AND NOT IN BeforeAll, because -ForEach is read during DISCOVERY and
    # BeforeAll does not run until the tests do. A set declared in there is
    # $null when Pester asks for it, and the whole file fails to discover.
    #
    # Before, after, and what the administrator was doing. Held as data so the
    # assertions below run over the set rather than over one of them.
    $listEdit = @(
        @{ What = 'removes the first application'
            From = 'Acrobat-Acrobat-Reader-DC-2600121771;TightVNC-Software-Tightvnc-2.8.88'
            To   = 'TightVNC-Software-Tightvnc-2.8.88' }
        @{ What = 'removes the last application'
            From = 'Acrobat-Acrobat-Reader-DC-2600121771;TightVNC-Software-Tightvnc-2.8.88'
            To   = 'Acrobat-Acrobat-Reader-DC-2600121771' }
        @{ What = 'adds an application'
            From = 'TightVNC-Software-Tightvnc-2.8.88'
            To   = 'TightVNC-Software-Tightvnc-2.8.88;Acrobat-Acrobat-Reader-DC-2600121771' }
        @{ What = 'reorders them'
            From = 'Acrobat-Acrobat-Reader-DC-2600121771;TightVNC-Software-Tightvnc-2.8.88'
            To   = 'TightVNC-Software-Tightvnc-2.8.88;Acrobat-Acrobat-Reader-DC-2600121771' }
        @{ What = 'removes the only application, leaving the list empty'
            From = 'Acrobat-Acrobat-Reader-DC-2600121771'
            To   = '' }
    )

    BeforeAll {
        # A SECOND RULE, AND THE LIST LIVES IN IT. The reported rule was not the
        # first in the file, and an editor that only ever wrote rule 1 would
        # have passed a test that used rule 1.
        function New-HDTTestApplicationRule {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Composes an array of strings in memory and writes nothing.')]
            [CmdletBinding()]
            [OutputType([string[]])]
            param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Selection)

            return [string[]] @(
                'schemaVersion: 1'
                'rules:'
                '  - name: Language and region'
                '    set:'
                '      HDTUILanguage: en-US'
                ''
                '  - name: Lab, by gateway - zero touch'
                '    when: { HDTDefaultGateway: "192.168.1.1" }'
                '    set:'
                '      # WHAT THIS MACHINE INSTALLS. The Applications page is skipped too, and a'
                '      # skipped page still has to be answered - ids from Applications, ; separated.'
                ('      HDTApplications: "{0}"' -f $Selection)
                '      HDTTimeZone: Israel Standard Time'
            )
        }

        # ONE PRESS, DONE THE WAY THE WINDOW DOES IT: put the file on disk, open
        # the window on it, retype the box, raise the click.
        function Invoke-HDTTestApplicationEdit {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Writes only into the Pester TestDrive fixture this suite created.')]
            [CmdletBinding()]
            [OutputType([object])]
            param(
                [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $From,
                [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $To,
                [Parameter()] [switch] $PressTheBottomSave
            )

            [System.IO.File]::WriteAllLines($script:rulesPath, (New-HDTTestApplicationRule -Selection $From))

            $window = New-HDTTestRuleWindow
            $box = $window.FindName('HDTRulesBox')

            $box.Text = ((New-HDTTestApplicationRule -Selection $To) -join "`r`n")

            if ($PressTheBottomSave) {
                Invoke-HDTTestClick -Button $window.FindName('HDTBootImageSaveButton')
            } else {
                Invoke-HDTTestClick -Button $window.FindName('HDTRulesSaveButton')
            }

            return [pscustomobject] @{
                Window = $window
                Text   = [string] [System.IO.File]::ReadAllText($script:rulesPath)
                Dirty  = [bool] (Get-HDTTestDocumentState -Window $window -Path $script:rulesPath).Dirty
                Prompt = (Get-HDTConsoleClosePrompt -Document ([object[]] @($window.HDTDocument)))
            }
        }
    }

    It 'writes the new list to rules.yaml when Save rules is pressed - <What>' -ForEach $listEdit {
        $result = Invoke-HDTTestApplicationEdit -From $From -To $To

        $result.Text | Should -BeLike ('*HDTApplications: "{0}"*' -f $To)
    }

    It 'takes the removed application out of the file - <What>' -ForEach $listEdit {
        # The assertion the report turns on, and it looks at the WHOLE document:
        # an id left anywhere in it is an application that still installs.
        $result = Invoke-HDTTestApplicationEdit -From $From -To $To

        $kept = @($To -split ';' | Where-Object { $_ })

        foreach ($gone in @($From -split ';' | Where-Object { $_ -and $kept -notcontains $_ })) {
            $result.Text | Should -Not -BeLike ('*{0}*' -f $gone)
        }
    }

    It 'leaves the tab clean, so closing asks nothing - <What>' -ForEach $listEdit {
        # THE SECOND HALF OF THE REPORT. A save that wrote the file but left the
        # tab dirty would put a 'save changes?' box on the way out and read as a
        # save that had not happened.
        $result = Invoke-HDTTestApplicationEdit -From $From -To $To

        $result.Dirty | Should -BeFalse
        $result.Prompt.Ask | Should -BeFalse
    }

    It 'keeps the comments above the list - <What>' -ForEach $listEdit {
        $result = Invoke-HDTTestApplicationEdit -From $From -To $To

        $result.Text | Should -BeLike '*WHAT THIS MACHINE INSTALLS*'
        $result.Text | Should -BeLike '*skipped page still has to be answered*'
    }

    It 'leaves the rule above it alone - <What>' -ForEach $listEdit {
        $result = Invoke-HDTTestApplicationEdit -From $From -To $To

        $result.Text | Should -BeLike '*  - name: Language and region*'
        $result.Text | Should -BeLike '*      HDTUILanguage: en-US*'
    }

    Context 'the bottom Save, which is the button that was actually pressed' {

        # NOT A CLAIM THAT THIS IS RIGHT - it is the reported experience, pinned
        # so that whatever shape is chosen for the two buttons has to change a
        # test rather than change behaviour quietly. The bottom Save writes
        # workspace.yaml; rules.yaml is untouched and the tab stays dirty, which
        # is why the close prompt fires and why the application is still there
        # on the next open.

        BeforeAll {
            $script:wrongButton = Invoke-HDTTestApplicationEdit `
                -From 'Acrobat-Acrobat-Reader-DC-2600121771;TightVNC-Software-Tightvnc-2.8.88' `
                -To 'TightVNC-Software-Tightvnc-2.8.88' -PressTheBottomSave
        }

        It 'does not write the rules file' {
            $script:wrongButton.Text | Should -BeLike '*Acrobat-Acrobat-Reader-DC-2600121771*'
        }

        It 'leaves the tab unsaved' {
            $script:wrongButton.Dirty | Should -BeTrue
        }

        It 'is why the close prompt asks, and it names the button that would have worked' {
            $script:wrongButton.Prompt.Ask | Should -BeTrue
            $script:wrongButton.Prompt.Unsaved | Should -Contain $script:rulesPath
            $script:wrongButton.Prompt.Message | Should -BeLike '*Save rules*'
        }
    }
}

}
