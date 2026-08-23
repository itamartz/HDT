# THE HALF THAT PUTS THE TEXT ON THE WINDOW.
#
# It is tested against a stand-in with a FindName method rather than a real
# window, and that is the whole reason the command takes a ROOT rather than
# reaching for WPF itself: Pester runs MTA, WPF needs STA, and a command that
# could only be exercised from an STA probe would be a command nobody tests.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # A window, as far as this command is concerned: something with controls it
    # can find by name.
    $script:newRoot = {
        param([hashtable] $Control)

        $root = [pscustomobject] @{ Control = $Control }

        $root | Add-Member -MemberType ScriptMethod -Name FindName -Value {
            param([string] $Name)

            if ($this.Control.ContainsKey($Name)) { return $this.Control[$Name] }
            return $null
        }

        return $root
    }

    $script:newControl = {
        param([string[]] $Property)

        $control = [pscustomobject] @{}
        foreach ($name in @($Property)) {
            $control | Add-Member -MemberType NoteProperty -Name $name -Value ''
        }

        return $control
    }
}

Describe 'Set-HDTWindowText' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Set-HDTWindowText' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'writes the property the key names' {
        $box = & $script:newControl @('Text', 'ToolTip')
        $root = & $script:newRoot @{ HDTNameBox = $box }

        Set-HDTWindowText -Root $root -String @{ 'HDTNameBox.Text' = 'Image name' } | Out-Null

        [string] $box.Text | Should -BeExactly 'Image name'
    }

    It 'writes a property that is not Text' {
        # A Button carries Content and a TabItem carries Header; a walker that
        # only knew Text would leave every button in the shipped language.
        $button = & $script:newControl @('Content')
        $root = & $script:newRoot @{ HDTSaveButton = $button }

        Set-HDTWindowText -Root $root -String @{ 'HDTSaveButton.Content' = 'Save' } | Out-Null

        [string] $button.Content | Should -BeExactly 'Save'
    }

    It 'reports what it applied' {
        $root = & $script:newRoot @{ HDTNameBox = (& $script:newControl @('Text')) }

        $result = Set-HDTWindowText -Root $root -String @{ 'HDTNameBox.Text' = 'a' }

        @($result.Applied) | Should -Be @('HDTNameBox.Text')
    }

    It 'skips a key no control answers to' {
        # ONE TABLE SERVES EVERY WINDOW, and no window has all the controls.
        $root = & $script:newRoot @{ HDTNameBox = (& $script:newControl @('Text')) }

        $result = Set-HDTWindowText -Root $root -String ([ordered] @{
                'HDTNameBox.Text'      = 'here'
                'HDTSomewhereElse.Text' = 'not here'
            })

        @($result.Applied) | Should -Be @('HDTNameBox.Text')
        @($result.Missing) | Should -BeNullOrEmpty
    }

    It 'records a key naming a property the control has not got' {
        # 'HDTNextButton.Text' on a Button, where the property is Content: a
        # mistake in the table, and one that must not stop every string after
        # it from being written.
        $button = & $script:newControl @('Content')
        $root = & $script:newRoot @{ HDTNextButton = $button; HDTNameBox = (& $script:newControl @('Text')) }

        $result = Set-HDTWindowText -Root $root -String ([ordered] @{
                'HDTNextButton.Text' = 'wrong property'
                'HDTNameBox.Text'    = 'still written'
            })

        (@($result.Missing) -join ' ') | Should -BeLike '*HDTNextButton.Text*'
        @($result.Applied) | Should -Contain 'HDTNameBox.Text'
    }

    It 'defaults to Text for a key with no property' {
        $box = & $script:newControl @('Text')
        $root = & $script:newRoot @{ HDTNameBox = $box }

        Set-HDTWindowText -Root $root -String @{ 'HDTNameBox' = 'no property named' } | Out-Null

        [string] $box.Text | Should -BeExactly 'no property named'
    }

    It 'leaves a control the table says nothing about alone' {
        # A VALUE SOMEBODY TYPED IS NOT TEXT THIS COMMAND OWNS.
        $box = & $script:newControl @('Text')
        $box.Text = 'HDTPE_x64'
        $root = & $script:newRoot @{ HDTNameBox = $box }

        Set-HDTWindowText -Root $root -String @{ 'HDTOtherBox.Text' = 'something' } | Out-Null

        [string] $box.Text | Should -BeExactly 'HDTPE_x64'
    }
}


}
