# THE INSTALL APPLICATIONS PAGE'S VIEW MODEL - MDT's Install Application dialog,
# answered without a window.
#
# THE STEP TYPE THAT HAD NO PAGE. An InstallApplications step fell through to the
# generic Properties tab, where its selection was a text box: an administrator
# typed an application id from memory, and a typo was not found until a
# deployment ran and Resolve-HDTApplicationOrder refused the whole plan on the
# machine in front of them. The same argument that put Depends On behind a
# picker.
#
# AND THE VARIABLE HAS TO SURVIVE. The step template writes
# selection: '%HDTApplications%' on purpose - that is what a wizard answer or a
# rule fills - so a page that only offered ticks would delete the indirection the
# sequence was built on the first time anybody pressed Apply.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:path = 'X:\Share\TaskSequences\DEMO\sequence.yaml'

    # THE SHARE, AS Get-HDTConsoleWorkspace RETURNS IT. The rows carry the four
    # members this reads and nothing else, which is what the editor hands in.
    $script:catalog = @(
        [pscustomobject] @{ Id = 'Igor-Pavlov-7-Zip-24.09'; Name = 'Igor Pavlov 7-Zip'; Version = '24.09'; Status = 'Ok' }
        [pscustomobject] @{ Id = 'Contoso-Suite-3.1'; Name = 'Contoso Suite 3.1'; Version = '3.1'; Status = 'Ok' }
        [pscustomobject] @{ Id = 'Broken-App'; Name = 'Broken-App'; Version = ''; Status = 'Error' }
    )

    $script:lineOf = {
        param([string] $Selection)

        $body = @'
schemaVersion: 1
id: DEMO-APPS
name: application page
steps:
  - group: State Restore
    steps:
      - name: Install Applications
        type: InstallApplications
SELECTION
        runIn: FullOS
      - name: Apply OS
        type: ApplyImage
        os: Win11
'@

        return [string[]] @(($body -replace 'SELECTION', $Selection) -split "`r?`n")
    }
}

Describe 'Get-HDTConsoleApplicationChoice' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTConsoleApplicationChoice' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'a step whose selection is a fixed list' {

        BeforeAll {
            $script:view = Get-HDTConsoleApplicationChoice -Path $script:path -Name 'Install Applications' `
                -Line (& $script:lineOf '        selection: Igor-Pavlov-7-Zip-24.09, Contoso-Suite-3.1') `
                -Workspace 'X:\Share' -Catalog $script:catalog
        }

        It 'belongs on screen' {
            $script:view.IsApplicationStep | Should -BeTrue
        }

        It 'offers the applications the share holds, not only the chosen ones' {
            # A PAGE LISTING ONLY WHAT THE DOCUMENT SAYS IS A PAGE YOU CANNOT ADD
            # AN APPLICATION ON, which is the whole reason to have one.
            @($script:view.Application | ForEach-Object { $_.Id }) | Should -Contain 'Igor-Pavlov-7-Zip-24.09'
            @($script:view.Application | ForEach-Object { $_.Id }) | Should -Contain 'Contoso-Suite-3.1'
        }

        It 'ticks the ones the selection names' {
            @($script:view.Application | Where-Object { $_.Selected } | ForEach-Object { $_.Id }) |
                Should -Be @('Contoso-Suite-3.1', 'Igor-Pavlov-7-Zip-24.09')
        }

        It 'reads the list rather than the variable' {
            $script:view.FromVariable | Should -BeFalse
        }

        It 'shows the name and the version, never the id' {
            # The id is composed FROM the name and the version, so a row showing
            # both says the same sentence twice - the rule the tree already
            # follows.
            $seven = @($script:view.Application | Where-Object { $_.Id -eq 'Igor-Pavlov-7-Zip-24.09' })[0]

            $seven.Display | Should -BeExactly 'Igor Pavlov 7-Zip 24.09'
        }

        It 'does not offer an application whose document will not read' {
            # Its id is the folder name and nothing else, so selecting it would
            # write an id that may not be what app.yaml says - the bargain
            # Get-HDTConsoleDependencyChoice already makes.
            @($script:view.Application | ForEach-Object { $_.Id }) | Should -Not -Contain 'Broken-App'
        }

        It 'says what a press would run' {
            $script:view.Command | Should -BeLike '*Set-HDTStepProperty*'
            $script:view.Command | Should -BeLike '*selection*'
        }
    }

    Context 'a step whose selection is a variable' {

        BeforeAll {
            $script:token = Get-HDTConsoleApplicationChoice -Path $script:path -Name 'Install Applications' `
                -Line (& $script:lineOf "        selection: '%HDTApplications%'") `
                -Workspace 'X:\Share' -Catalog $script:catalog
        }

        It 'reports the variable rather than guessing what it will hold' {
            $script:token.FromVariable | Should -BeTrue
            $script:token.Variable | Should -BeExactly 'HDTApplications'
        }

        It 'ticks nothing, because the document names nothing' {
            @($script:token.Application | Where-Object { $_.Selected }) | Should -BeNullOrEmpty
        }

        It 'still offers the share, so a fixed list can be built from it' {
            @($script:token.Application).Count | Should -Be 2
        }

        It 'keeps what the document says, so applying an untouched page changes nothing' {
            $script:token.Written | Should -BeExactly '%HDTApplications%'
        }

        It 'says in a sentence where the list comes from' {
            $script:token.Note | Should -BeLike '*HDTApplications*'
        }
    }

    Context 'a step with no selection at all' {

        BeforeAll {
            $script:bare = Get-HDTConsoleApplicationChoice -Path $script:path -Name 'Install Applications' `
                -Line (& $script:lineOf '        # nothing here') `
                -Workspace 'X:\Share' -Catalog $script:catalog
        }

        It 'is the variable, because that is what the engine reads' {
            # Invoke-HDTInstallApplicationsStep falls back to the HDTApplications
            # variable when the step declares no selection, so a page reporting
            # "nothing selected" would contradict the step it is editing.
            $script:bare.FromVariable | Should -BeTrue
            $script:bare.Variable | Should -BeExactly 'HDTApplications'
        }
    }

    Context 'a selection naming an application this share does not hold' {

        BeforeAll {
            $script:gone = Get-HDTConsoleApplicationChoice -Path $script:path -Name 'Install Applications' `
                -Line (& $script:lineOf '        selection: Contoso-Suite-3.1, Deleted-App-1.0') `
                -Workspace 'X:\Share' -Catalog $script:catalog
        }

        It 'shows it, ticked, rather than dropping it' {
            # A dropdown that silently forgot it would rewrite the deployment the
            # next time anybody pressed Apply.
            $missing = @($script:gone.Application | Where-Object { $_.Id -eq 'Deleted-App-1.0' })

            @($missing).Count | Should -Be 1
            $missing[0].Selected | Should -BeTrue
            $missing[0].Missing | Should -BeTrue
        }

        It 'says so on the row rather than in a dialog' {
            $missing = @($script:gone.Application | Where-Object { $_.Id -eq 'Deleted-App-1.0' })[0]

            $missing.Display | Should -BeLike '*not in this share*'
        }
    }

    Context 'a share with no applications' {

        BeforeAll {
            $script:empty = Get-HDTConsoleApplicationChoice -Path $script:path -Name 'Install Applications' `
                -Line (& $script:lineOf "        selection: '%HDTApplications%'") `
                -Workspace 'X:\Share' -Catalog @()
        }

        It 'says the share is empty rather than showing an empty box' {
            $script:empty.HasCatalog | Should -BeFalse
        }
    }

    Context 'any other step type' {

        BeforeAll {
            $script:other = Get-HDTConsoleApplicationChoice -Path $script:path -Name 'Apply OS' `
                -Line (& $script:lineOf '        selection: Contoso-Suite-3.1') `
                -Workspace 'X:\Share' -Catalog $script:catalog
        }

        It 'does not belong on screen' {
            $script:other.IsApplicationStep | Should -BeFalse
        }
    }

    Context 'a share that cannot be read' {

        It 'opens the page empty rather than refusing' {
            # Offline, renamed or not yet created is exactly the moment somebody
            # needs to look at the sequence.
            $view = Get-HDTConsoleApplicationChoice -Path $script:path -Name 'Install Applications' `
                -Line (& $script:lineOf '        selection: Contoso-Suite-3.1') `
                -Workspace 'X:\NoSuchShare'

            $view.IsApplicationStep | Should -BeTrue
            @($view.Application | Where-Object { -not $_.Missing }) | Should -BeNullOrEmpty
        }
    }
}
