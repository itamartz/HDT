# THE SHELL, DRIVEN. Show-HDTWizard shows ONE window and answers what the
# technician pressed. This shows MDT's LiteTouch shell - a rail, a page host and
# Back/Next - and drives it across every page the deployment still has to ask.
#
# THE WINDOW IS NOT HERE AND MUST NOT BE. New-HDTWizardHost owns WPF; this owns
# which file is refused, what reaches the host, and what an answer means. The
# fake host replays a technician's clicks through the same navigator the real
# host calls, so a whole Next/Next/Back/Next walk is asserted with no display.
#
# EVERY PAGE IS CHECKED BEFORE THE FIRST ONE IS SHOWN, and that is the rule this
# file exists to hold. A wizard that opens and then dies on page four - in WinPE,
# on a bench, with the console hidden behind it - is worse than one that refuses
# to open and says which file is broken.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:shellPath = 'X:\HDT\UI\HDTWizardShell.xaml'
    $script:themePath = 'X:\HDT\UI\HDTTheme.xaml'

    # The real shell and the real theme, read off disk rather than retyped, so
    # the shipped files and the files these tests exercise cannot drift.
    $script:realShell = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/HDTWizardShell.xaml'))
    $script:realTheme = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/HDTTheme.xaml'))

    $script:pageId = @('TaskSequence', 'ComputerName', 'Summary')

    function New-HDTTestShellPage {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds in-memory test data; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [string[]] $Id = $script:pageId
        )

        return @($Id | ForEach-Object {
                [pscustomobject] @{
                    Id         = $_
                    Title      = $_
                    Heading    = ('Heading for {0}' -f $_)
                    Subheading = ('Subheading for {0}' -f $_)
                    XamlPath   = ('X:\HDT\UI\{0}.xaml' -f $_)
                }
            })
    }

    function New-HDTShellTestFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fake file system; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowEmptyString()]
            [string] $Shell = $script:realShell,

            [Parameter()]
            [switch] $NoShell,

            [Parameter()]
            [switch] $NoTheme,

            [Parameter()]
            [AllowEmptyString()]
            [string] $BrokenPageId = '',

            [Parameter()]
            [AllowEmptyString()]
            [string] $MissingPageId = ''
        )

        $file = @{}
        if (-not $NoShell) { $file[$script:shellPath] = $Shell }
        if (-not $NoTheme) { $file[$script:themePath] = $script:realTheme }

        foreach ($id in $script:pageId) {
            if ($id -eq $MissingPageId) { continue }

            $markup = '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" />'
            if ($id -eq $BrokenPageId) { $markup = '<Grid><this is not xaml' }

            $file[('X:\HDT\UI\{0}.xaml' -f $id)] = $markup
        }

        return New-HDTFakeFileSystem -File $file
    }
}

Describe 'Show-HDTWizardShell' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Show-HDTWizardShell' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'takes an injected wizard host, so it can run with no display' {
            (Get-Command -Name 'Show-HDTWizardShell').Parameters.ContainsKey('WizardHost') | Should -BeTrue
        }
    }

    Context 'what it refuses, and it refuses all of it before anything is shown' {

        It 'refuses a shell window that is not there, naming the path' {
            $record = $null
            try {
                Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                    -WizardHost (New-HDTFakeWizardHost -Action 'Next') `
                    -FileSystem (New-HDTShellTestFileSystem -NoShell)
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:shellPath)
        }

        It 'refuses a shell window that does not parse, and shows nothing' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            $record = $null
            try {
                Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                    -WizardHost $wizardHost `
                    -FileSystem (New-HDTShellTestFileSystem -Shell '<Window><this is not xaml')
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            @($wizardHost.Operations) | Should -BeNullOrEmpty
        }

        It 'refuses a page whose markup is not there, naming the page and the path' {
            # THE POINT OF CHECKING EVERY PAGE UP FRONT. This one is page three;
            # without the check it would be discovered two clicks into a
            # deployment, on a machine whose console is hidden behind the window.
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            $record = $null
            try {
                Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                    -WizardHost $wizardHost `
                    -FileSystem (New-HDTShellTestFileSystem -MissingPageId 'Summary')
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*Summary*'
            @($wizardHost.Operations) | Should -BeNullOrEmpty -Because (
                'a wizard that opens and dies on page three is worse than one that refuses and says which file is broken')
        }

        It 'refuses a page whose markup does not parse, naming the page' {
            $record = $null
            try {
                Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                    -WizardHost (New-HDTFakeWizardHost -Action 'Next') `
                    -FileSystem (New-HDTShellTestFileSystem -BrokenPageId 'ComputerName')
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*ComputerName*'
        }

        It 'refuses a wizard with no pages at all' {
            # Every page skipped means NOT SHOWING THE WIZARD, and that is the
            # caller's decision - the same rule HDTSkipWelcome follows.
            $record = $null
            try {
                Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page @() `
                    -WizardHost (New-HDTFakeWizardHost -Action 'Next') `
                    -FileSystem (New-HDTShellTestFileSystem)
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
        }

        It 'refuses a theme that is not there, because a shell without it is unreadable' {
            $record = $null
            try {
                Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                    -ThemeXamlPath $script:themePath `
                    -WizardHost (New-HDTFakeWizardHost -Action 'Next') `
                    -FileSystem (New-HDTShellTestFileSystem -NoTheme)
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike ('*{0}*' -f $script:themePath)
        }
    }

    Context 'what reaches the host' {

        It 'hands the host the shell markup it read' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            [string] $wizardHost.LastShellXaml | Should -BeLike '*HDTPageHost*'
        }

        It 'hands the host the theme markup, so the shell is styled from one place' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -ThemeXamlPath $script:themePath `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            [string] $wizardHost.LastThemeXaml | Should -BeLike '*ResourceDictionary*'
        }

        It 'hands the host no theme when none was asked for' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            [string] $wizardHost.LastThemeXaml | Should -BeNullOrEmpty
        }

        It 'hands the host the first page, already loaded' {
            # THE HOST NEVER TOUCHES THE FILE SYSTEM. It is a WPF adapter, and
            # an adapter that reads files has something in it worth testing -
            # which is the exemption it would then no longer qualify for.
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            [string] $wizardHost.LastState.Page.Id | Should -BeExactly 'TaskSequence'
            [string] $wizardHost.LastState.Page.Xaml | Should -BeLike '*<Grid*'
        }

        It 'hands the host a rail listing every page' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            @($wizardHost.LastState.Rail).Count | Should -Be 3
        }

        It 'hands the host the title' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -Title 'Hephaestus Deployment' `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            [string] $wizardHost.LastTitle | Should -BeExactly 'Hephaestus Deployment'
        }

        It 'hands the host the fields and panes it was given' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Next'

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) `
                -Field @([pscustomobject] @{ Name = 'HDTComputerNameBox'; Text = 'HDT-01' }) `
                -Pane @([pscustomobject] @{ Name = 'HDTDomainPane'; Visible = $false }) | Out-Null

            [string] @($wizardHost.LastField)[0].Name | Should -BeExactly 'HDTComputerNameBox'
            [string] @($wizardHost.LastPane)[0].Name | Should -BeExactly 'HDTDomainPane'
        }

        It 'opens the shell exactly once, however many pages it has' {
            # THE WHOLE POINT OF THE SHELL. One window, and the page inside it
            # is swapped - not one ShowDialog per page, which would flicker and
            # lose where the technician put the window.
            $wizardHost = New-HDTFakeWizardHost -Action 'Next' -Click @('Next', 'Next', 'Next')

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            @($wizardHost.Operations | Where-Object { $_ -like 'ShowShell*' }).Count | Should -Be 1
        }
    }

    Context 'the technician walking the wizard' {

        It 'visits every page in order when Next is pressed through' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Next' -Click @('Next', 'Next', 'Next')

            $result = Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem)

            (@($wizardHost.Visited) -join ' > ') | Should -BeExactly 'TaskSequence > ComputerName > Summary'
            [string] $result.Action | Should -BeExactly 'Next'
        }

        It 'goes back and forward through the same navigator the real host calls' {
            # THE BENCHMARK: a real click sequence, asserted as an ordered list.
            $wizardHost = New-HDTFakeWizardHost -Action 'Next' -Click @('Next', 'Next', 'Back', 'Next', 'Next')

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            (@($wizardHost.Visited) -join ' > ') | Should -BeExactly (
                'TaskSequence > ComputerName > Summary > ComputerName > Summary')
        }

        It 'answers Next only when Next was pressed on the LAST page' {
            # One click short of the end is not a deployment.
            $wizardHost = New-HDTFakeWizardHost -Action '' -Click @('Next', 'Next')

            $result = Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem)

            [string] $result.Action | Should -BeExactly 'Cancel'
        }
    }

    Context 'a page that validates what is typed into it' {

        # THE RULE IS NOT IN THE SHELL AND NOT IN THE HOST. A page DECLARES
        # which control it validates and by which rule; this command resolves
        # that name to a validator and hands it over. The host runs it on every
        # keystroke and knows nothing about computer names.

        BeforeAll {
            $script:validatingPage = @(
                [pscustomobject] @{
                    Id         = 'ComputerName'
                    Title      = 'ComputerName'
                    Heading    = 'Name this computer'
                    Subheading = ''
                    XamlPath   = 'X:\HDT\UI\ComputerName.xaml'
                    Validate   = [pscustomobject] @{ Control = 'HDTComputerNameBox'; Rule = 'ComputerName' }
                })
        }

        It 'hands the host a validator for a page that declares one' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Cancel'

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page $script:validatingPage `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            $wizardHost.LastState.Page.Validator | Should -Not -BeNullOrEmpty
        }

        It 'hands over the control name to watch' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Cancel'

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page $script:validatingPage `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            [string] $wizardHost.LastState.Page.Validate.Control | Should -BeExactly 'HDTComputerNameBox'
        }

        It 'hands over a validator that actually judges the name' {
            # The point of resolving it here rather than naming a command in the
            # page: what the host receives is a question it can ask, and the
            # rule behind it is Test-HDTComputerName's single copy.
            $wizardHost = New-HDTFakeWizardHost -Action 'Cancel'

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page $script:validatingPage `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            $validator = $wizardHost.LastState.Page.Validator

            [bool] (& $validator 'HDT-01').IsValid | Should -BeTrue
            [bool] (& $validator 'HDT.01').IsValid | Should -BeFalse
            [bool] (& $validator 'ABCDEFGHIJKLMNOP').IsValid | Should -BeFalse

            # A LEGAL NAME DNS CANNOT CARRY IS NOT A REFUSAL. It comes back
            # valid, with a warning - and the Next button is gated on IsValid,
            # so the technician is told and not stopped.
            $underscore = & $validator 'HDT_01'
            [bool] $underscore.IsValid | Should -BeTrue
            [string] $underscore.Severity | Should -BeExactly 'Warning'
        }

        It 'tells the host the keystrokes may be judged too' {
            # WHY A KEYSTROKE AND NOT ONLY A VALUE. A technician asked why the
            # wizard let them type an underscore at all when it was going to
            # refuse it afterwards - and they were right. Refusing after the
            # fact is a message; refusing the keystroke is an answer.
            $wizardHost = New-HDTFakeWizardHost -Action 'Cancel'

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page $script:validatingPage `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            [bool] $wizardHost.LastState.Page.RestrictInput | Should -BeTrue
        }

        It 'judges a single character with the same rule, so there is no second list of legal characters' {
            # THE PROPERTY THAT MAKES KEYSTROKE FILTERING SAFE: a character is
            # typeable exactly when a one-character name of it would be
            # accepted. Nothing anywhere holds a keyboard's own copy of what a
            # computer name may contain.
            $wizardHost = New-HDTFakeWizardHost -Action 'Cancel'

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page $script:validatingPage `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            $validator = $wizardHost.LastState.Page.Validator

            foreach ($allowed in @('A', 'z', '0', '9', '-', '_', '@', '!', '+', ',')) {
                [bool] (& $validator $allowed).IsValid | Should -BeTrue -Because ("'{0}' is legal in a computer name" -f $allowed)
            }

            # THE TEN NetBIOS FORBIDS, AND A SPACE.
            foreach ($refused in @('.', '\', '/', ':', '*', '?', '"', '<', '>', '|', ' ')) {
                [bool] (& $validator $refused).IsValid | Should -BeFalse -Because ("'{0}' is not legal in a computer name" -f $refused)
            }
        }

        It 'hands over no validator for a page that declares none' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Cancel'

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            $wizardHost.LastState.Page.Validator | Should -BeNullOrEmpty
        }

        It 'refuses a rule nobody implements, naming it and the page' {
            # A page on the SHARE can name any rule it likes, so the failure has
            # to be a refusal here rather than a control that silently never
            # validates - which on a bench looks like a wizard that accepts
            # anything.
            $page = @(
                [pscustomobject] @{
                    Id         = 'ComputerName'
                    Title      = 'ComputerName'
                    Heading    = ''
                    Subheading = ''
                    XamlPath   = 'X:\HDT\UI\ComputerName.xaml'
                    Validate   = [pscustomobject] @{ Control = 'HDTComputerNameBox'; Rule = 'NoSuchRule' }
                })

            $record = $null
            try {
                Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page $page `
                    -WizardHost (New-HDTFakeWizardHost -Action 'Cancel') `
                    -FileSystem (New-HDTShellTestFileSystem)
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*NoSuchRule*'
            $record.Exception.Message | Should -BeLike '*ComputerName*'
        }
    }

    Context 'the summary page, built on arrival' {

        # WHY THE NAVIGATOR BUILDS IT AND NOT THIS COMMAND. The summary states
        # what every earlier page ended up holding, and it has to be right at
        # the moment it is SHOWN - a technician who presses Back, changes the
        # name and comes forward again must see the new one. Built once when the
        # wizard opened, it would show what was true before they typed anything.

        BeforeAll {
            $script:summaryPage = @(
                [pscustomobject] @{
                    Id         = 'ComputerName'
                    Title      = 'Computer name'
                    Heading    = ''
                    Subheading = ''
                    XamlPath   = 'X:\HDT\UI\ComputerName.xaml'
                    Collect    = [pscustomobject] @{ Control = 'HDTComputerNameBox'; Variable = 'HDTComputerName' }
                    Skip       = 'HDTSkipComputerName'
                },
                [pscustomobject] @{
                    Id         = 'Summary'
                    Title      = 'Summary'
                    Heading    = ''
                    Subheading = ''
                    XamlPath   = 'X:\HDT\UI\Summary.xaml'
                    Summary    = [pscustomobject] @{ RowControl = 'HDTSummaryList'; SnippetControl = 'HDTSummarySnippet' }
                })
        }

        It 'hands the host the rows once the summary page is reached' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Cancel' -Click @('Next') `
                -Value @{ HDTComputerName = 'HDT-01' }

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page $script:summaryPage `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            @($wizardHost.LastState.SummaryRow).Count | Should -Be 1
            [string] @($wizardHost.LastState.SummaryRow)[0].Variable | Should -BeExactly 'HDTComputerName'
            [string] @($wizardHost.LastState.SummaryRow)[0].Value | Should -BeExactly 'HDT-01'
        }

        It 'hands over the rules.yaml an administrator would paste' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Cancel' -Click @('Next') `
                -Value @{ HDTComputerName = 'HDT-01' }

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page $script:summaryPage `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            [string] $wizardHost.LastState.SummarySnippet | Should -BeLike '*HDTComputerName: HDT-01*'
            [string] $wizardHost.LastState.SummarySnippet | Should -BeLike '*HDTSkipWizard: true*'
        }

        It 'names the control the page said to put them in' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Cancel' -Click @('Next')

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page $script:summaryPage `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            [string] $wizardHost.LastState.Page.Summary.RowControl | Should -BeExactly 'HDTSummaryList'
        }

        It 'builds no summary for a page that is not one' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Cancel'

            Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page $script:summaryPage `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem) | Out-Null

            # The wizard opens on the computer name page, which summarises
            # nothing.
            $wizardHost.LastState.PSObject.Properties['SummaryRow'] | Should -BeNullOrEmpty
        }
    }

    Context 'what the technician filled in' {

        # THE ANSWER IS NOT THE POINT ON ITS OWN. A wizard that reported Next
        # and dropped what was typed would be a wizard that asked a technician
        # for a computer name and deployed the machine without it - which is
        # exactly what this returned until now.
        #
        # THE VALUES COME BACK THROUGH THE HOST, because the host is what read
        # them off the controls. Show-HDTWizardShell hands them on and
        # interprets none of them; the payload puts them into the variable
        # engine as the Wizard source (DESIGN 3.1).

        It 'returns what was collected' {
            $wizardHost = New-HDTFakeWizardHost -Action 'Next' -Click @('Next') `
                -Value @{ HDTComputerName = 'HDT-01' }

            $result = Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem)

            [string] $result.Value['HDTComputerName'] | Should -BeExactly 'HDT-01'
        }

        It 'returns an empty set when nothing was collected' {
            $result = Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost (New-HDTFakeWizardHost -Action 'Cancel') `
                -FileSystem (New-HDTShellTestFileSystem)

            # An empty hashtable is 'empty' to Pester, so the assertion is that
            # it is a SET WITH NOTHING IN IT rather than a null - a caller
            # splatting it as -Wizard must not have to null-check first.
            $result.Value -is [System.Collections.IDictionary] | Should -BeTrue
            @($result.Value.Keys).Count | Should -Be 0
        }

        It 'returns what was collected even when the technician cancelled' {
            # A CANCEL IS NOT AN ERASURE. What was typed before it is worth
            # logging, and the caller decides what a cancel means - this
            # reports rather than judging.
            $wizardHost = New-HDTFakeWizardHost -Action 'Cancel' -Click @('Cancel') `
                -Value @{ HDTComputerName = 'HDT-01' }

            $result = Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem)

            [string] $result.Action | Should -BeExactly 'Cancel'
            [string] $result.Value['HDTComputerName'] | Should -BeExactly 'HDT-01'
        }
    }

    Context 'what it answers' {

        It 'returns <_> when that is what the technician chose' -ForEach @('Next', 'Cancel', 'CommandPrompt') {
            $result = Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost (New-HDTFakeWizardHost -Action $PSItem) `
                -FileSystem (New-HDTShellTestFileSystem)

            [string] $result.Action | Should -BeExactly $PSItem
        }

        It 'treats a shell that answered nothing as Cancel, never as Next' {
            # THE ONE THAT MATTERS, and it is the same rule Show-HDTWizard holds:
            # a dismissed wizard is not consent to partition a disk.
            $result = Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost (New-HDTFakeWizardHost -Action '') `
                -FileSystem (New-HDTShellTestFileSystem)

            [string] $result.Action | Should -BeExactly 'Cancel'
        }

        It 'reads <_> as Cancel, because it is not on the allow-list' -ForEach @('Deploy', 'next', 'Finish', 'Yes') {
            $result = Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost (New-HDTFakeWizardHost -Action $PSItem) `
                -FileSystem (New-HDTShellTestFileSystem)

            [string] $result.Action | Should -BeExactly 'Cancel'
        }

        It 'reports which page the technician was on when they answered' {
            # A Cancel on page one and a Cancel on page five are different
            # facts, and the log is the only place either survives the reboot.
            $wizardHost = New-HDTFakeWizardHost -Action 'Cancel' -Click @('Next', 'Cancel')

            $result = Show-HDTWizardShell -ShellXamlPath $script:shellPath -Page (New-HDTTestShellPage) `
                -WizardHost $wizardHost -FileSystem (New-HDTShellTestFileSystem)

            [string] $result.Action | Should -BeExactly 'Cancel'
            [int] $result.PageCount | Should -Be 3
        }
    }
}
