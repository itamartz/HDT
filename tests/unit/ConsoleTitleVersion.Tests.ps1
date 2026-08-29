# WHICH ENGINE AM I LOOKING AT? The console title bar is where that gets
# answered.
#
# A stale boot image cost a morning: it carried engine 0.8.0 while the share had
# moved on, and nothing on any screen said so - the only way to find out was to
# ask a shell. The version is already stamped into every artefact the build
# produces (Get-HDTModuleVersion, ModuleVersion.Tests.ps1); it just was not
# readable without typing a command.
#
# THE TITLE BAR IS THE ONE PLACE IT BELONGS ON THIS WINDOW. It is on screen the
# whole time, it is what a screenshot of a support question catches, and it
# costs no room that a control wanted.
#
# THE CHILD DIALOGS DELIBERATELY DO NOT CARRY IT. The boot image editor, the
# sequence editor and the import dialogs all belong to the same process as the
# console that opened them, so a version on each of them is the same number
# written six times - noise, and six places for it to drift. One authoritative
# place is what a person checks.
#
# AND IT IS NEVER A LITERAL. The number comes from Get-HDTModuleVersion, which
# reads the manifest the build writes, so a title that disagrees with the
# manifest is impossible rather than merely unlikely. A hard-coded '0.10.2' here
# would be the exact failure this whole thing exists to stop.
#
# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope, and
# the import sits at file scope because InModuleScope has to resolve the module
# while Pester is still discovering.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    # SOFTWARE RENDERING, because hardware rendering on this host paints blank
    # often enough to look like a wiring failure when it is not.
    [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # THE SHIPPED MARKUP, read off disk rather than retyped, so the window this
    # builds and the window the console opens cannot drift apart.
    $script:consoleXamlPath = Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTConsole.xaml'
    $script:xaml = [System.IO.File]::ReadAllText($script:consoleXamlPath)

    $script:tablePath = Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\Strings\en-us.psd1'

    function New-HDTTestTitleHost {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param()

        return [pscustomobject] @{
            Answer = ''
            Width  = 0
            Height = 0
            Window = $null
        }
    }

    function New-HDTTestTitleNode {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object[]])]
        param()

        return [object[]] @(
            [pscustomobject] @{
                Kind             = 'Root'
                Name             = 'Deployment Shares'
                Text             = 'Deployment Shares (0)'
                CanOpen          = $false
                Children         = New-Object System.Collections.ObjectModel.ObservableCollection[object]
                HeaderTitle      = ''
                HeaderRoot       = ''
                HeaderDeployRoot = ''
                Depth            = 0
            }
        )
    }
}

Describe 'Get-HDTConsoleTitle' {

    It 'puts the version after the name' {
        Get-HDTConsoleTitle -Text 'Hephaestus Deployment Toolkit' -Version '0.9.9' |
            Should -BeExactly 'Hephaestus Deployment Toolkit 0.9.9'
    }

    It 'gives the name alone when there is no version to show' {
        # THE BUNDLE CAN BE DOT-SOURCED RATHER THAN IMPORTED, and
        # $MyInvocation.MyCommand.Module is $null when it is. A title reading
        # 'Hephaestus Deployment Toolkit ' with a trailing space would be a
        # worse answer than the plain name.
        Get-HDTConsoleTitle -Text 'Hephaestus Deployment Toolkit' -Version $null |
            Should -BeExactly 'Hephaestus Deployment Toolkit'

        Get-HDTConsoleTitle -Text 'Hephaestus Deployment Toolkit' -Version '' |
            Should -BeExactly 'Hephaestus Deployment Toolkit'
    }

    It 'takes the version from the manifest when it is not given one' {
        Get-HDTConsoleTitle -Text 'HDT' |
            Should -BeExactly ('HDT {0}' -f (Get-HDTModuleVersion))
    }

    It 'takes the name from the string table when it is not given one' {
        # THE STATIC HALF IS THE TABLE'S, exactly like every other word on this
        # window. Only the number is composed in code, because a table holds
        # text and not a build's output.
        $expected = [string] (Get-HDTStringTable -Page 'Console')['HDTConsoleWindow.Title']

        $expected | Should -Not -BeNullOrEmpty
        Get-HDTConsoleTitle | Should -BeExactly ('{0} {1}' -f $expected, (Get-HDTModuleVersion))
    }

    It 'has comment-based help with a synopsis' {
        $synopsis = (Get-Help -Name Get-HDTConsoleTitle).Synopsis

        $synopsis | Should -Not -BeNullOrEmpty
        $synopsis.Trim() | Should -Not -BeExactly 'Get-HDTConsoleTitle'
    }
}

Describe 'the console window title' {

    BeforeAll {
        $script:window = New-HDTConsoleView -ConsoleHost (New-HDTTestTitleHost) `
            -Xaml $script:xaml -Title 'Hephaestus Deployment Toolkit' `
            -Node (New-HDTTestTitleNode) -Theme (Get-HDTConsoleTheme) `
            -Size ([pscustomobject] @{ Width = 1800; Height = 900; Left = 40; Top = 20 })
    }

    It 'carries the module version' {
        # A TITLE BAR IS DRAWN BY WINDOWS AND IS NOT IN WPF'S VISUAL TREE, so no
        # offscreen render can photograph this. The property is the evidence.
        $script:window.Title | Should -Match ([regex]::Escape([string] (Get-HDTModuleVersion)))
    }

    It 'reads as the product name followed by the version' {
        $script:window.Title |
            Should -BeExactly ('Hephaestus Deployment Toolkit {0}' -f (Get-HDTModuleVersion))
    }

    It 'names the window in the markup so the table can fill its title' {
        # Set-HDTWindowText finds a control by name; the window is a control
        # like any other, and without a name its Title is the one string on the
        # screen the table cannot reach.
        $document = [xml] (Get-Content -LiteralPath $script:consoleXamlPath -Raw)

        [string] $document.DocumentElement.GetAttribute(
            'Name', 'http://schemas.microsoft.com/winfx/2006/xaml') |
            Should -BeExactly 'HDTConsoleWindow'
    }
}

Describe 'the title the console defaults to' {

    It 'is the string table entry and not a second copy of it' {
        # TWO LITERALS SAYING THE SAME THING DRIFT. Show-HDTConsole's -Title
        # default is what a caller overrides; the table is what a translator
        # edits. They have to be the same sentence, and this is what notices
        # when somebody changes one of them.
        $ast = (Get-Command -Name Show-HDTConsole).ScriptBlock.Ast
        $parameter = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.ParameterAst] -and
                    $node.Name.VariablePath.UserPath -eq 'Title'
                }, $true))

        $parameter.Count | Should -BeGreaterThan 0

        $literal = [string] $parameter[0].DefaultValue.Value
        $table = [string] (Get-HDTStringTable -Page 'Console')['HDTConsoleWindow.Title']

        $literal | Should -BeExactly $table
    }
}

}
