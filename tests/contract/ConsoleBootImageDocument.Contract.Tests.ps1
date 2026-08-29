# EVERY DOCUMENT THE WINDOWS PE WINDOW CAN WRITE IS OFFERED TO THE CLOSE PROMPT
# - and the set of documents is READ OUT OF THE SOURCE, not written down here.
#
# CLAUDE.md rule 8: a thing is not added until every surface that must know
# about it does, and the proof is a test written against the SET rather than
# against the one just added.
#
# THIS IS THE SURFACE THAT ALREADY SHIPPED HALF A FEATURE. rules.yaml and
# bootstrap-rules.yaml were editable on this window, with their own Save
# buttons - and the close prompt knew only about workspace.yaml, so a window
# holding an unsaved rule shut without a word and the edit was gone. A test
# naming those two files would pass for them and fail nobody after them.
#
# SO THE DOCUMENTS ARE FOUND THE WAY THE VIEW MAKES THEM: every sibling file
# the view derives from the workspace root with -ChildPath, plus the workspace
# document it is handed. A fourth one added tomorrow is covered the day the
# line is written, or this fails.

# THE COMMAND UNDER TEST IS PRIVATE, so this file runs in module scope.
# InModuleScope has to resolve the module while Pester is still discovering,
# which is why the import sits at file scope here rather than only inside a
# BeforeAll.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

Describe 'New-HDTConsoleBootImageView and the documents it can write' {

    BeforeAll {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        $script:viewPath = Join-Path -Path $script:repoRoot `
            -ChildPath 'src\Hephaestus\Private\New-HDTConsoleBootImageView.ps1'

        $script:viewSource = [System.IO.File]::ReadAllText($script:viewPath)

        # EVERY SIBLING DOCUMENT THE VIEW NAMES. The view builds each one the
        # same way - Join-Path against the workspace root - so the source is the
        # register, and nothing here has to be kept in step with it by hand.
        $script:derived = @(
            [regex]::Matches($script:viewSource, "-ChildPath\s+'([^']+\.yaml)'") |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        )

        $script:workspacePath = 'C:\ws\workspace.yaml'

        $script:window = New-HDTConsoleBootImageView `
            -ConsoleHost ([pscustomobject] @{ Answer = ''; Width = 0; Height = 0; Window = $null }) `
            -Xaml ([System.IO.File]::ReadAllText(
                (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTBootImage.xaml'))) `
            -Path $script:workspacePath `
            -Line ([string[]] @('schemaVersion: 1', 'id: HDT-LAB', 'name: HDT deployment share')) `
            -Component ([object[]] @()) -SelectionProfile ([object[]] @()) `
            -Theme (Get-HDTConsoleTheme) `
            -Size ([pscustomobject] @{ Width = 1180; Height = 760; Left = 40; Top = 20 })

        $script:registered = @(@($script:window.HDTDocument) | ForEach-Object { [string] $_.Path })
    }

    It 'found the sibling documents in the source, so the scan below is not vacuous' {
        @($script:derived).Count | Should -BeGreaterThan 0
    }

    It 'registers the workspace document it was handed' {
        $script:registered | Should -Contain $script:workspacePath
    }

    It 'registers every sibling document the view derives from the workspace root' {
        foreach ($name in $script:derived) {
            @($script:registered | ForEach-Object { Split-Path -Path $_ -Leaf }) |
                Should -Contain $name -Because "$name is editable on this window and its close must ask about it"
        }
    }

    It 'names a Save button for every registered document' {
        # The close prompt tells an administrator which button keeps the work.
        # An entry with no button is a file it can only tell them they lost.
        foreach ($one in @($script:window.HDTDocument)) {
            [string] $one.SaveWith | Should -Not -BeNullOrEmpty -Because "$($one.Path) is unsaveable without one"
        }
    }

    It 'reports a live dirty state for every registered document' {
        # The closing handler passes this set straight to Get-HDTConsoleClosePrompt.
        # An entry whose Dirty was copied at build time would answer $false for
        # ever, which is exactly the silence this window closed in.
        foreach ($one in @($script:window.HDTDocument)) {
            $one.PSObject.Properties['Dirty'] | Should -Not -BeNullOrEmpty
            $one.PSObject.Properties['Dirty'].MemberType | Should -BeExactly 'ScriptProperty' `
                -Because "$($one.Path) must be asked, not remembered"
        }
    }
}

}
