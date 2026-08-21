# THE COMMAND AN ADMINISTRATOR TYPES, and the script a loose copy still needs.
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

    }

Describe 'the launcher script' {

    It 'is still there, because a copy off the module path has no command yet' {
        # NOT FOR A DOUBLE-CLICK: Windows gives .ps1 no Open verb, so Explorer
        # edits it rather than running it. It is for the working tree and any
        # other loose copy, where nothing has imported the manifest yet.
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

    It 'takes the same three parameters, so the two cannot drift' {
        $command = (Get-Command -Name 'Start-HDTConsole' -Module 'Hephaestus').Parameters
        $script = @((Get-Command -Name $script:launcherPath).Parameters.Keys)

        # Theme is deliberately absent: the console is light, and a parameter
        # with one legal value is a question with one answer.
        foreach ($name in @('Path', 'Title', 'Detach')) {
            $script | Should -Contain $name
            $command.Keys | Should -Contain $name
        }
    }

    It 'reports a failure somewhere other than a console it may have hidden' {
        # -Detach hides the console this process owns, so by the time anything
        # throws there may be nowhere left to print - hence the message box.
        $script:launcherText | Should -BeLike '*MessageBox*'
    }
}
