# THE COMMAND AN ADMINISTRATOR TYPES, and the file they double-click.
#
# WHY THIS IS A FUNCTION AT ALL. It used to be only Start-HDTConsole.ps1, and a
# .ps1 in a folder is not a command: Import-Module gives you functions, and
# nothing puts a script file on the command path. So an administrator who had
# imported the module still got "The term 'Start-HDTConsole.ps1' is not
# recognized" unless they typed the whole path.
#
# WHAT CAN AND CANNOT BE ASSERTED HERE. Win32 window state and Start-Process
# are an adapter and cannot be proven under Pester - the -Detach path is
# measured by hand, and by the window appearing. What is provable is the
# contract: the command exists, it is exported, it takes what the script takes,
# and the script DELEGATES rather than keeping a second copy of the rules.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:launcherPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Start-HDTConsole.ps1'
    $script:launcherText = [string] (Get-Content -LiteralPath $script:launcherPath -Raw)
}

Describe 'Start-HDTConsole' {

    It 'is exported, so importing the module is enough' {
        Get-Command -Name 'Start-HDTConsole' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'takes <Parameter>' -ForEach @(
        @{ Parameter = 'Path' }
        @{ Parameter = 'Title' }
        @{ Parameter = 'Theme' }
        @{ Parameter = 'Detach' }
    ) {
        (Get-Command -Name 'Start-HDTConsole' -Module 'Hephaestus').Parameters.Keys | Should -Contain $Parameter
    }

    It 'takes the rest of the command line as shares' {
        # 'C:\a' '\\host\share' has to open both, which is what an administrator
        # types and what -File on a relaunch produces.
        $parameter = (Get-Command -Name 'Start-HDTConsole' -Module 'Hephaestus').Parameters['Path']
        $attribute = @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] })[0]

        $attribute.ValueFromRemainingArguments | Should -BeTrue
        $parameter.ParameterType | Should -Be ([string[]])
    }

    It 'offers the two palettes and refuses a third' {
        $parameter = (Get-Command -Name 'Start-HDTConsole' -Module 'Hephaestus').Parameters['Theme']
        $allowed = @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })[0]

        @($allowed.ValidValues) | Should -Be @('Light', 'Dark')
    }
}

Describe 'the file Explorer runs' {

    It 'is still there, because a double-click needs one' {
        Test-Path -LiteralPath $script:launcherPath | Should -BeTrue
    }

    It 'delegates to the command rather than keeping its own copy of the rules' {
        # TWO COPIES OF THE WINDOW-HIDING RULES IS ONE COPY TO GET WRONG, and the
        # one that would rot is this file - it is edited least and read never.
        $script:launcherText | Should -BeLike '*Start-HDTConsole -Path*'
    }

    It 'names none of the Win32 the command owns' {
        foreach ($token in @('GetConsoleWindow', 'GetConsoleProcessList', 'ShowWindow')) {
            $script:launcherText | Should -Not -BeLike ('*{0}*' -f $token)
        }
    }

    It 'takes the same four parameters, so the two cannot drift' {
        $command = (Get-Command -Name 'Start-HDTConsole' -Module 'Hephaestus').Parameters
        $script = @((Get-Command -Name $script:launcherPath).Parameters.Keys)

        foreach ($name in @('Path', 'Title', 'Theme', 'Detach')) {
            $script | Should -Contain $name
            $command.Keys | Should -Contain $name
        }
    }

    It 'reports a failure where somebody who double-clicked will see it' {
        # A console that has been hidden, or was never there, cannot show an
        # error - so the catch puts it in a message box.
        $script:launcherText | Should -BeLike '*MessageBox*'
    }
}
