# The way out of the Windows PE window, and the work Yes was supposed to keep.
#
# WHAT WENT WRONG. The close prompt asks about all three documents this window
# can write - workspace.yaml, rules.yaml, bootstrap-rules.yaml - and offers
# "Yes: press Save, and close the window". Yes then wrote workspace.yaml and
# ONLY workspace.yaml, because the branch behind it was gated on the workspace
# document's own dirty flag. An administrator who edited a rule, read a prompt
# naming rules.yaml and pressed the button that says it keeps the work lost it
# anyway - on the one button pressed to avoid exactly that.
#
# AND THE PLAIN FIELDS NEVER RAISED THE FLAG AT ALL. Boot image name,
# architecture, language, scratch space, prompt-for-key, unattend, background,
# time zone, client certificate and driver profile were wired to raise the
# rebuild banner and nothing else, so typing a new boot image name and closing
# prompted for nothing and threw the edit away in silence.
#
# SO BOTH ARE ASSERTED OVER THE SET. Every watched control, not the one that was
# reported; every registered document, not the one in front of you. A fourth
# document or an eleventh field is covered the day it is added, or these fail -
# which is the only kind of test that catches a half-feature in this window.
#
# THE MESSAGE BOX IS THE ONE THING THAT NEEDS A DESKTOP, so the view holds it in
# a replaceable HDTAsk property and everything else about closing is ordinary
# code. A modal dialog raised inside Add_Closing during a suite run is a window
# nobody is looking at and a run that never finishes.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    $script:bootXaml = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTBootImage.xaml'))

    # THE TWO RULE DOCUMENTS, AS THEY LOOK ON A SHARE. Both parse, so both Save
    # buttons are lit and the refusal case below has to be arranged on purpose
    # rather than arriving by accident.
    $script:workspaceYaml = [string[]] @(
        'schemaVersion: 1'
        'id: HDT-LAB'
        'name: HDT deployment share'
        'bootImage:'
        '  name: HDTPE_wiz_x64'
        '  architecture: amd64'
        '  scratchSpaceMB: 512'
    )

    $script:rulesYaml = [string[]] @(
        'schemaVersion: 1'
        'rules:'
        '  - name: Fallback'
        '    set:'
        '      HDTComputerName: "PC-%HDTSerialNumber%"'
    )

    $script:bootstrapYaml = [string[]] @(
        'schemaVersion: 1'
        'rules:'
        '  - name: Site A'
        '    when: { HDTDefaultGateway: "192.168.1.1" }'
        '    set:'
        '      HDTDeployRoot: \\SERVER-A\HdtShare'
    )

    # A SHARE PER WINDOW. These tests really write, so one directory shared
    # between them would let a save in one test answer an assertion in another.
    function New-HDTTestCloseShare {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes only into the Pester TestDrive fixture this suite created.')]
        [CmdletBinding()]
        [OutputType([object])]
        param()

        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        [void] (New-Item -Path $root -ItemType Directory -Force)

        $share = [pscustomobject] @{
            Root      = [string] $root
            Workspace = [string] (Join-Path -Path $root -ChildPath 'workspace.yaml')
            Rules     = [string] (Join-Path -Path $root -ChildPath 'rules.yaml')
            Bootstrap = [string] (Join-Path -Path $root -ChildPath 'bootstrap-rules.yaml')
        }

        [System.IO.File]::WriteAllLines($share.Workspace, [string[]] $script:workspaceYaml)
        [System.IO.File]::WriteAllLines($share.Rules, [string[]] $script:rulesYaml)
        [System.IO.File]::WriteAllLines($share.Bootstrap, [string[]] $script:bootstrapYaml)

        return $share
    }

    # A SECOND TIME ZONE AND A SECOND DRIVER PROFILE, so every ComboBox on this
    # window has something to change TO. A picker holding one row cannot be
    # driven, and a sweep that skipped it would report a field as covered that
    # nothing had touched.
    function New-HDTTestCloseWindow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a WPF object graph in memory; it shows nothing.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter(Mandatory = $true)] [object] $Share)

        $double = [pscustomobject] @{ Answer = ''; Width = 0; Height = 0; Window = $null }

        return New-HDTConsoleBootImageView -ConsoleHost $double -Xaml $script:bootXaml `
            -Path $Share.Workspace -Line $script:workspaceYaml `
            -Component ([object[]] @()) `
            -SelectionProfile ([object[]] @(
                    [pscustomobject] @{
                        Id       = 'Everything'
                        Name     = 'Everything'
                        IsBuiltIn = $true
                        Resolved = [object[]] @()
                    })) `
            -TimeZone ([object[]] @(
                    [pscustomobject] @{ Id = 'Israel Standard Time'; Display = 'Israel Standard Time' })) `
            -Theme (Get-HDTConsoleTheme) `
            -Size ([pscustomobject] @{ Width = 1180; Height = 760; Left = 40; Top = 20 })
    }

    # WHAT THE ADMINISTRATOR SEES AND WHAT THEY PRESS, both held here. The
    # window asks through this, so a test can read the question and answer it.
    function New-HDTTestCloseAnswer {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Replaces an in-memory property on a window this test built.')]
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter(Mandatory = $true)] [object] $Window,
            [Parameter(Mandatory = $true)] [string] $Answer
        )

        $record = [pscustomobject] @{
            Answer  = [string] $Answer
            Asked   = [int] 0
            Message = [string[]] @()
            Title   = [string[]] @()
            Button  = [string[]] @()
        }

        $Window.HDTAsk = {
            param($Message, $Title, $Button, $Icon)

            $record.Asked++
            $record.Message += [string] $Message
            $record.Title += [string] $Title
            $record.Button += [string] $Button

            # THE FIRST QUESTION IS THE YES/NO/CANCEL ONE; anything after it is
            # the window explaining why it did not close, and only OK answers
            # that.
            if ([string] $Button -eq 'OK') { return 'OK' }

            return [string] $record.Answer
        }.GetNewClosure()

        return $record
    }

    function Get-HDTTestCloseDocument {
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter(Mandatory = $true)] [object] $Window,
            [Parameter(Mandatory = $true)] [string] $Path
        )

        return @($Window.HDTDocument) | Where-Object { [string] $_.Path -eq $Path }
    }

    # ONE EDIT PER DOCUMENT, KEYED BY FILE NAME - and the test below proves the
    # keys are the whole registered set before it uses them, so a fourth
    # document fails here instead of going untested.
    function Set-HDTTestDocumentEdited {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Assigns Text on an in-memory control.')]
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory = $true)] [object] $Window,
            [Parameter(Mandatory = $true)] [string] $Leaf
        )

        switch ($Leaf) {
            'workspace.yaml' {
                $Window.FindName('HDTBootImageNameBox').Text = 'HDTPE_closed_x64'
                return 'HDTPE_closed_x64'
            }
            'rules.yaml' {
                $Window.FindName('HDTRulesBox').Text = @(
                    'schemaVersion: 1'
                    'rules:'
                    '  - name: Written by Yes'
                    '    set:'
                    '      HDTComputerName: "PC-2"'
                ) -join "`r`n"
                return 'Written by Yes'
            }
            'bootstrap-rules.yaml' {
                $Window.FindName('HDTBootstrapRulesBox').Text = @(
                    'schemaVersion: 1'
                    'rules:'
                    '  - name: Bootstrap written by Yes'
                    '    set:'
                    '      HDTDeployRoot: \\SERVER-B\HdtShare'
                ) -join "`r`n"
                return 'Bootstrap written by Yes'
            }
        }

        throw ("No edit is known for '{0}'. It is registered on the window, so add one here rather than leaving it untested." -f $Leaf)
    }

    # RETYPED, PICKED OR TICKED - whichever this control takes. It reports
    # whether it managed it, so a box nothing could drive fails the sweep rather
    # than passing it silently.
    function Set-HDTTestControlChanged {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Assigns a property on an in-memory control.')]
        [CmdletBinding()]
        [OutputType([bool])]
        param([Parameter(Mandatory = $true)] [object] $Control)

        if ($Control -is [System.Windows.Controls.CheckBox]) {
            $Control.IsChecked = (-not [bool] $Control.IsChecked)
            return $true
        }

        if ($Control -is [System.Windows.Controls.ComboBox]) {
            if ($Control.Items.Count -lt 2) { return $false }

            $Control.SelectedIndex = (([int] $Control.SelectedIndex + 1) % [int] $Control.Items.Count)
            return $true
        }

        if ($Control -is [System.Windows.Controls.TextBox]) {
            $Control.Text = ('{0}x' -f [string] $Control.Text)
            return $true
        }

        return $false
    }

    # THE WATCHED SET, READ THE WAY THE VIEW READS IT.
    # Get-HDTConsoleBootImageField is the register; the two rule boxes carry
    # their own dirty state and their own Save, and the lists splice the
    # document through their own buttons.
    function Get-HDTTestWatchedControl {
        [CmdletBinding()]
        [OutputType([object[]])]
        param([Parameter(Mandatory = $true)] [object] $Window)

        return [object[]] @(
            foreach ($one in @(Get-HDTConsoleBootImageField)) {
                if ([string] $one.Effect -ne 'Rebuild') { continue }
                if (@('HDTRulesBox', 'HDTBootstrapRulesBox') -contains [string] $one.Name) { continue }

                $found = $Window.FindName([string] $one.Name)
                if ($null -eq $found) { continue }

                if (-not ($found -is [System.Windows.Controls.TextBox] -or
                        $found -is [System.Windows.Controls.ComboBox] -or
                        $found -is [System.Windows.Controls.CheckBox])) {
                    continue
                }

                [pscustomobject] @{ Name = [string] $one.Name; Control = $found }
            }
        )
    }
}

Describe 'A field on the General or Drivers tab, changed' {

    # THE DEFECT: these controls raised the rebuild banner and nothing else. The
    # document they edit was never marked unsaved, so the window closed on a
    # retyped boot image name without a word.

    BeforeAll {
        $script:fieldShare = New-HDTTestCloseShare
        $script:fieldWindow = New-HDTTestCloseWindow -Share $script:fieldShare
    }

    It 'finds the watched controls, so the sweep below is not vacuous' {
        @(Get-HDTTestWatchedControl -Window $script:fieldWindow).Count | Should -BeGreaterThan 5
    }

    It 'opens clean, because filling a box is not an edit' {
        (Get-HDTTestCloseDocument -Window $script:fieldWindow -Path $script:fieldShare.Workspace).Dirty |
            Should -BeFalse
    }

    It 'marks workspace.yaml unsaved, for every one of them' {
        foreach ($one in (Get-HDTTestWatchedControl -Window $script:fieldWindow)) {
            $share = New-HDTTestCloseShare
            $window = New-HDTTestCloseWindow -Share $share

            $changed = Set-HDTTestControlChanged -Control ($window.FindName($one.Name))

            $changed | Should -BeTrue -Because "$($one.Name) has to be drivable for this sweep to mean anything"

            (Get-HDTTestCloseDocument -Window $window -Path $share.Workspace).Dirty |
                Should -BeTrue -Because "$($one.Name) edits workspace.yaml and closing must ask about it"
        }
    }

    It 'still raises the rebuild notice, for every one of them' {
        # SEPARATE AND BOTH CORRECT. Marking the document unsaved must not cost
        # the banner that says the .wim is behind the document.
        foreach ($one in (Get-HDTTestWatchedControl -Window $script:fieldWindow)) {
            $window = New-HDTTestCloseWindow -Share (New-HDTTestCloseShare)

            [void] (Set-HDTTestControlChanged -Control ($window.FindName($one.Name)))

            [string] $window.FindName('HDTBootImageRebuildText').Visibility |
                Should -BeExactly 'Visible' -Because "$($one.Name) is baked into the image"
        }
    }
}

Describe 'Yes on the close prompt writes every unsaved document' {

    # THE ONE THAT LOST THE WORK. "Yes - press Save, and close the window" wrote
    # workspace.yaml alone, so a dirty rules.yaml went out of the window on the
    # button pressed to keep it.

    It 'registers the documents this test knows how to edit, so the sweep is honest' {
        $window = New-HDTTestCloseWindow -Share (New-HDTTestCloseShare)

        @(@($window.HDTDocument) | ForEach-Object { Split-Path -Path ([string] $_.Path) -Leaf }) |
            Sort-Object |
            Should -Be (@('bootstrap-rules.yaml', 'rules.yaml', 'workspace.yaml') | Sort-Object)
    }

    It 'writes each one when it is the only one unsaved' {
        foreach ($leaf in @('workspace.yaml', 'rules.yaml', 'bootstrap-rules.yaml')) {
            $share = New-HDTTestCloseShare
            $window = New-HDTTestCloseWindow -Share $share
            $record = New-HDTTestCloseAnswer -Window $window -Answer 'Yes'

            $written = Set-HDTTestDocumentEdited -Window $window -Leaf $leaf

            $window.Close()

            $record.Asked | Should -BeGreaterThan 0 -Because "$leaf was unsaved and the window must ask"

            $path = Join-Path -Path $share.Root -ChildPath $leaf

            [System.IO.File]::ReadAllText($path) |
                Should -BeLike ('*{0}*' -f $written) -Because "Yes says it saves $leaf"

            (Get-HDTTestCloseDocument -Window $window -Path $path).Dirty |
                Should -BeFalse -Because "$leaf was just written"
        }
    }

    It 'writes all three when all three are unsaved' {
        $share = New-HDTTestCloseShare
        $window = New-HDTTestCloseWindow -Share $share
        [void] (New-HDTTestCloseAnswer -Window $window -Answer 'Yes')

        $expected = @{}
        foreach ($leaf in @('workspace.yaml', 'rules.yaml', 'bootstrap-rules.yaml')) {
            $expected[$leaf] = Set-HDTTestDocumentEdited -Window $window -Leaf $leaf
        }

        $window.Close()

        foreach ($leaf in @($expected.Keys)) {
            [System.IO.File]::ReadAllText((Join-Path -Path $share.Root -ChildPath $leaf)) |
                Should -BeLike ('*{0}*' -f $expected[$leaf]) -Because "$leaf was unsaved when Yes was pressed"
        }
    }

    It 'writes nothing when the answer is No' {
        $share = New-HDTTestCloseShare
        $window = New-HDTTestCloseWindow -Share $share
        [void] (New-HDTTestCloseAnswer -Window $window -Answer 'No')

        [void] (Set-HDTTestDocumentEdited -Window $window -Leaf 'rules.yaml')

        $window.Close()

        [System.IO.File]::ReadAllText($share.Rules) | Should -Not -BeLike '*Written by Yes*'
    }

    It 'stays open and writes nothing when the answer is Cancel' {
        $share = New-HDTTestCloseShare
        $window = New-HDTTestCloseWindow -Share $share
        [void] (New-HDTTestCloseAnswer -Window $window -Answer 'Cancel')

        [void] (Set-HDTTestDocumentEdited -Window $window -Leaf 'rules.yaml')

        $window.Close()

        [System.IO.File]::ReadAllText($share.Rules) | Should -Not -BeLike '*Written by Yes*'
        (Get-HDTTestCloseDocument -Window $window -Path $share.Rules).Dirty | Should -BeTrue
    }

    It 'does not ask at all when nothing was edited' {
        $window = New-HDTTestCloseWindow -Share (New-HDTTestCloseShare)
        $record = New-HDTTestCloseAnswer -Window $window -Answer 'Yes'

        $window.Close()

        $record.Asked | Should -Be 0
    }
}

Describe 'Yes when one of the unsaved documents will not parse' {

    # ALL OF THEM OR NONE OF THEM. A rules document whose Save button is dark
    # must not be written by a message box that has no way to be dark - and
    # half-saving would leave the administrator with no idea which half. So the
    # window refuses to close, says which file and why, and keeps everything.

    BeforeAll {
        $script:brokenShare = New-HDTTestCloseShare
        $script:brokenWindow = New-HDTTestCloseWindow -Share $script:brokenShare
        $script:brokenRecord = New-HDTTestCloseAnswer -Window $script:brokenWindow -Answer 'Yes'

        # BOTH KINDS OF UNSAVED AT ONCE: one document that would save and one
        # that will not, which is the case a half-save would get wrong.
        [void] (Set-HDTTestDocumentEdited -Window $script:brokenWindow -Leaf 'workspace.yaml')

        $script:brokenWindow.FindName('HDTRulesBox').Text = "schemaVersion: 1`r`nrules: [ this is not a rule"

        $script:brokenWindow.Close()
    }

    It 'left the Save rules button dark, which is the state being respected' {
        $script:brokenWindow.FindName('HDTRulesSaveButton').IsEnabled | Should -BeFalse
    }

    It 'kept the window open, so the work is still in it' {
        (Get-HDTTestCloseDocument -Window $script:brokenWindow -Path $script:brokenShare.Rules).Dirty |
            Should -BeTrue
    }

    It 'wrote the broken rules file nowhere' {
        [System.IO.File]::ReadAllText($script:brokenShare.Rules) | Should -Not -BeLike '*this is not a rule*'
    }

    It 'wrote nothing else either, because half a save is worse than none' {
        [System.IO.File]::ReadAllText($script:brokenShare.Workspace) | Should -Not -BeLike '*HDTPE_closed_x64*'

        (Get-HDTTestCloseDocument -Window $script:brokenWindow -Path $script:brokenShare.Workspace).Dirty |
            Should -BeTrue
    }

    It 'says which file it is and that nothing was written' {
        $said = [string] ($script:brokenRecord.Message -join "`n")

        $said | Should -BeLike '*rules.yaml*'
        $said | Should -BeLike '*Save rules*'
        $said | Should -BeLike '*nothing has been written*'
    }

    It 'says it with an OK box, because there is nothing to decide' {
        $script:brokenRecord.Button | Should -Contain 'OK'
    }
}

Describe 'Get-HDTConsoleClosePrompt and a document that cannot be saved' {

    BeforeAll {
        $script:mixed = [object[]] @(
            [pscustomobject] @{ Path = 'C:\ws\workspace.yaml'; Dirty = $true; SaveWith = 'Save settings'; CanSave = $true }
            [pscustomobject] @{ Path = 'C:\ws\rules.yaml'; Dirty = $true; SaveWith = 'Save rules'; CanSave = $false }
            [pscustomobject] @{ Path = 'C:\ws\bootstrap-rules.yaml'; Dirty = $false; SaveWith = 'Save rules'; CanSave = $false }
        )
    }

    It 'names only the unsaved document that will not save' {
        $prompt = Get-HDTConsoleClosePrompt -Document $script:mixed

        $prompt.Refused | Should -Be @('C:\ws\rules.yaml')
    }

    It 'refuses nothing when every unsaved document would save' {
        $prompt = Get-HDTConsoleClosePrompt -Document ([object[]] @(
                [pscustomobject] @{ Path = 'C:\ws\rules.yaml'; Dirty = $true; SaveWith = 'Save rules'; CanSave = $true }))

        @($prompt.Refused).Count | Should -Be 0
    }

    It 'treats a document that never said whether it could save as one that can' {
        # The sequence editor registers no CanSave, and a window that refused to
        # close because a property was missing would be a worse defect than the
        # one this fixes.
        $prompt = Get-HDTConsoleClosePrompt -Document ([object[]] @(
                [pscustomobject] @{ Path = 'C:\ws\rules.yaml'; Dirty = $true; SaveWith = 'Save rules' }))

        @($prompt.Refused).Count | Should -Be 0
    }

    It 'has something to put on the screen when it refuses' {
        $prompt = Get-HDTConsoleClosePrompt -Document $script:mixed

        $prompt.RefusedMessage | Should -BeLike '*rules.yaml*'
        $prompt.RefusedMessage | Should -BeLike '*Save rules*'
        $prompt.RefusedMessage | Should -BeLike '*nothing has been written*'
        $prompt.RefusedMessage | Should -Not -BeLike '*workspace.yaml*'
    }

    It 'promises Yes saves all of them, because that is now what it does' {
        $prompt = Get-HDTConsoleClosePrompt -Document $script:mixed

        $prompt.Message | Should -BeLike '*Yes*save*'
        $prompt.Message | Should -Not -BeLike '*writes only its own*'
    }
}

}
