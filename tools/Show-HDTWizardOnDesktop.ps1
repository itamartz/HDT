<#
    .SYNOPSIS
        Shows an HDT wizard page on THIS desktop, so it can be looked at without
        building a boot image.

    .DESCRIPTION
        THE ITERATION LOOP. A boot image build is about two and a half minutes,
        and booting a VM to look at a window is another two. That is far too
        slow a loop for laying out a page, and it is not how MDT works either -
        MDT's wizard panes live on the deployment share in Scripts\ and are read
        after connecting, precisely so they can be changed without rebuilding
        anything.

        So the loop is: lay the page out here, look at it, THEN boot WinPE to
        confirm it renders there too. The only difference between the two is the
        machine - the XAML and the loading technique are identical, because both
        go through New-HDTWizardHost.

        IT IS A TOOL, NOT PRODUCT CODE. It lives in tools\ and ships in no boot
        image. What it proves is that the markup lays out correctly; whether WPF
        exists at all in WinPE is a different question, and W1 answered it.

    .PARAMETER Page
        Which page to show. 'Welcome' is W1's, 'Credential' is W2's, and
        'Shell' is the MULTI-PAGE wizard - one window whose page is swapped by
        Back and Next, driven by Show-HDTWizardShell exactly as WinPE drives it.

        THE THREE PAGES IN 'Shell' MODE ARE PREVIEW SCAFFOLDING, from
        tools\preview\, and they ship in no boot image. DESIGN 11.2's real pages
        live on the SHARE under Scripts\UI; these exist so the SHELL - the rail,
        the heading, the swap, Back, and Next becoming Deploy - can be looked at
        before any of them are designed.

    .PARAMETER XamlPath
        An explicit XAML file, overriding -Page. Ignored in 'Shell' mode.

    .EXAMPLE
        ./tools/Show-HDTWizardOnDesktop.ps1 -Page Credential

        Opens the credentials page and reports which button was pressed.

    .EXAMPLE
        ./tools/Show-HDTWizardOnDesktop.ps1 -Page Shell

        Opens the multi-page shell. Next and Back walk the rail; Next on the
        last page answers 'Next' and closes it.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Welcome', 'Credential', 'Simple', 'Shell')]
    [string] $Page = 'Credential',

    [Parameter()]
    [AllowEmptyString()]
    [string] $XamlPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force

# -- the multi-page shell ----------------------------------------------------
#
# A DIFFERENT COMMAND, NOT A DIFFERENT FILE. Show-HDTWizard shows one window;
# Show-HDTWizardShell opens HDTWizardShell.xaml ONCE and swaps the page inside
# it. Both go through New-HDTWizardHost, which is what makes "it looked right
# here" evidence about WinPE rather than about this machine.

if ($Page -eq 'Shell') {

    $previewRoot = Join-Path -Path $PSScriptRoot -ChildPath 'preview'

    # THE RAIL LISTS WHAT THIS DEPLOYMENT WILL ACTUALLY ASK. A skipped page is
    # not in this list and does not appear in the rail either (DESIGN 11.2), so
    # the list IS the wizard - there is no catalogue of pages to filter later.
    # NOT $page. PowerShell variable names are case-insensitive, so $page IS the
    # -Page parameter - and assigning a list to it runs the parameter's own
    # ValidateSet against that list, which fails before the window is ever
    # reached. It cost one silent launch to notice.
    $previewPage = @(
        [pscustomobject] @{
            Id         = 'TaskSequence'
            Title      = 'Task sequence'
            Heading    = 'Choose a task sequence'
            Subheading = 'What this machine will be deployed with.'
            XamlPath   = (Join-Path -Path $previewRoot -ChildPath 'HDTPreviewTaskSequence.xaml')

            # WHAT THIS PAGE FILLS IN, AND WHERE TO READ IT FROM. Property is
            # what lets one host serve a ListBox and a TextBox without knowing
            # the difference: it reads the named property off the named control.
            Collect    = [pscustomobject] @{ Control = 'HDTTaskSequenceList'; Variable = 'HDTTaskSequenceID'; Property = 'SelectedValue' }
            Skip       = 'HDTSkipTaskSequence'
        },
        [pscustomobject] @{
            Id         = 'ComputerDetail'
            Title      = 'Computer details'
            Heading    = 'Name this computer'
            Subheading = 'The name it will carry after deployment, and what it joins.'
            XamlPath   = (Join-Path -Path $previewRoot -ChildPath 'HDTPreviewComputerDetail.xaml')

            # THE PAGE NAMES A CONTROL AND A RULE, NEVER A COMMAND. Pages live
            # on the share and are edited by administrators; one that could name
            # a command would be one that could run one. Show-HDTWizardShell
            # resolves 'ComputerName' to Test-HDTComputerName - the same single
            # copy of the rule Invoke-HDTApplyUnattendStep enforces.
            Validate   = [pscustomobject] @{ Control = 'HDTComputerNameBox'; Rule = 'ComputerName' }

            # MDT'S COMPUTER DETAILS PANE COLLECTS SEVERAL THINGS, so Collect is
            # a list. The workgroup and the domain are both read: a machine
            # joins one or the other, and the summary writes out only what was
            # actually filled in - a rule setting the other to nothing would
            # RESOLVE it and stop any later rule supplying a real value.
            Collect    = @(
                [pscustomobject] @{ Control = 'HDTComputerNameBox'; Variable = 'HDTComputerName' },
                [pscustomobject] @{ Control = 'HDTJoinDomainBox'; Variable = 'HDTJoinDomain' },
                [pscustomobject] @{ Control = 'HDTMachineObjectOuBox'; Variable = 'HDTMachineObjectOU' },
                [pscustomobject] @{ Control = 'HDTJoinWorkgroupBox'; Variable = 'HDTJoinWorkgroup' },
                # THE ACCOUNT DOMAIN BOX IS COLLECTED FIRST, ON PURPOSE. The
                # account box below may also carry a domain - CORP\svc - and the
                # split has to be able to see what this box held to decide
                # whether to keep it. Collect is walked in order.
                [pscustomobject] @{ Control = 'HDTDomainAdminDomainBox'; Variable = 'HDTDomainAdminDomain' },

                # ONE BOX THAT MAY FILL TWO VARIABLES. Both ways of saying it
                # work: CORP\svc-hdt-join with the domain box empty, or
                # svc-hdt-join with CORP in the box. Precedence, most specific
                # first: the typed prefix, then the box, then the domain being
                # joined - which is what SplitDefaultFrom names.
                #
                # AND IT IS NOT THE SHARE ACCOUNT. HDTUserID reaches the
                # deployment share; HDTDomainAdmin has rights in the directory.
                # Two accounts, two sets of variables, never shared.
                [pscustomobject] @{
                    Control          = 'HDTDomainAdminBox'
                    Variable         = 'HDTDomainAdmin'
                    Split            = 'AccountName'
                    SplitVariable    = 'HDTDomainAdminDomain'
                    SplitDefaultFrom = 'HDTJoinDomain'
                },

                # IsSecret KEEPS IT OFF THE SCREEN AND OUT OF THE FILE.
                # Get-HDTVariableMap already says of this variable: "never
                # written to a log", and a YAML block on a share is worse than
                # one. Property is Password because a PasswordBox has no Text.
                [pscustomobject] @{
                    Control  = 'HDTPasswordBox'
                    Variable = 'HDTDomainAdminPassword'
                    Property = 'Password'
                    IsSecret = $true
                }
            )
            Skip       = 'HDTSkipComputerName'
        },
        [pscustomobject] @{
            Id         = 'LocaleTime'
            Title      = 'Locale and time'
            Heading    = 'Specify locale and time preferences'
            Subheading = 'What the deployed machine speaks, types and reads the clock in.'
            XamlPath   = (Join-Path -Path $previewRoot -ChildPath 'HDTPreviewLocaleTime.xaml')

            # FOUR SETTINGS, READ FROM SelectedValue SO THE TAG IS COLLECTED
            # RATHER THAN THE LABEL. The deployed machine wants en-US and
            # 'Israel Standard Time'; the technician reads 'English (United
            # States)' and '(UTC+02:00) Jerusalem'.
            Collect    = @(
                [pscustomobject] @{ Control = 'HDTUILanguageBox'; Variable = 'HDTUILanguage'; Property = 'SelectedValue' },
                [pscustomobject] @{ Control = 'HDTUserLocaleBox'; Variable = 'HDTUserLocale'; Property = 'SelectedValue' },
                [pscustomobject] @{ Control = 'HDTKeyboardLocaleBox'; Variable = 'HDTKeyboardLocale'; Property = 'SelectedValue' },
                [pscustomobject] @{ Control = 'HDTTimeZoneNameBox'; Variable = 'HDTTimeZoneName'; Property = 'SelectedValue' }
            )

            # MDT HAS TWO SKIP PROPERTIES FOR THIS ONE PANE, and so does DESIGN
            # 11.2: HDTSkipLocaleSelection hides the language group,
            # HDTSkipTimeZone the time group. Skip names the one that hides the
            # WHOLE page; the panes are collapsed by name, as on the Welcome
            # screen.
            Skip       = 'HDTSkipLocaleSelection'
        },
        [pscustomobject] @{
            Id         = 'Summary'
            Title      = 'Summary'
            Heading    = 'Ready to deploy'
            Subheading = 'Check what was chosen - and what to set so nobody has to choose it again.'
            XamlPath   = (Join-Path -Path $previewRoot -ChildPath 'HDTPreviewSummary.xaml')

            # THE SUMMARY NAMES TWO CONTROLS AND AUTHORS NOTHING.
            # Get-HDTWizardSummary builds every row and the snippet, on arrival,
            # from what the earlier pages were actually filled in with.
            Skip       = 'HDTSkipSummary'
            Summary    = [pscustomobject] @{ RowControl = 'HDTSummaryList'; SnippetControl = 'HDTSummarySnippet' }
        }
    )

    $shellAnswer = Show-HDTWizardShell `
        -ShellXamlPath (Join-Path -Path $repoRoot -ChildPath 'src/Hephaestus/UI/HDTWizardShell.xaml') `
        -ThemeXamlPath (Join-Path -Path $repoRoot -ChildPath 'src/Hephaestus/UI/HDTTheme.xaml') `
        -Page $previewPage `
        -Title 'Hephaestus Deployment Toolkit' `
        -Field @([pscustomobject] @{ Name = 'HDTComputerNameBox'; Text = 'HDT-01' })

    Write-Information ("the technician chose: {0}" -f $shellAnswer.Action) -InformationAction Continue

    if ($shellAnswer.Action -eq 'CommandPrompt') {
        $prompt = Start-HDTCommandPrompt
        Write-Information ("the prompt: started {0}, {1} (pid {2}) {3}" -f
            $prompt.Started, $prompt.FilePath, $prompt.ProcessId, $prompt.Message) -InformationAction Continue

        [void] (Hide-HDTShellWindow -Restore)
    }

    return $shellAnswer
}

if ([string]::IsNullOrWhiteSpace($XamlPath)) {
    $file = 'HDTWelcome.xaml'
    if ($Page -eq 'Credential') { $file = 'HDTWizardCredential.xaml' }
    if ($Page -eq 'Simple') { $file = 'HDTWizard.xaml' }

    $XamlPath = Join-Path -Path $repoRoot -ChildPath ('src/Hephaestus/UI/{0}' -f $file)
}

Write-Information ("showing {0}" -f $XamlPath) -InformationAction Continue

# THE LEASE, THE SAME WAY THE PAYLOAD GETS IT. The host does not read the
# network any more - Get-HDTWizardField decides what goes in every box, and both
# this tool and the WinPE payload ask it the same question. That is what makes
# "it looked right on the desktop" evidence about WinPE rather than about this
# machine.
#
# BEST EFFORT: a network read that fails leaves the boxes empty and the window
# still opens. On a build host it will show whichever adapter has a gateway,
# which is this machine's real lease and not the deployment one.
$network = $null
try {
    $network = Get-HDTNetworkConfiguration
} catch {
    Write-Information ("no network configuration could be read: {0}" -f $_.Exception.Message) -InformationAction Continue
}

$field = @(Get-HDTWizardField -NetworkConfiguration $network)

# THE PRODUCT PATH, not a private one: the same command and the same host the
# payload uses in WinPE, so what is on screen here is what is on screen there.
$answer = Show-HDTWizard -XamlPath $XamlPath -Title 'Hephaestus Deployment Toolkit' -Field $field

Write-Information ("the technician chose: {0}" -f $answer.Action) -InformationAction Continue

# OPEN CMD IS MDT'S "EXIT TO COMMAND PROMPT": the wizard closes and the
# technician gets a prompt. TWO THINGS HAPPEN, AND BOTH ARE NEEDED.
#
# Start-HDTCommandPrompt opens a prompt IN A WINDOW OF ITS OWN, so something
# visibly happens on any machine. Restoring the console alone was not enough:
# the first version did only that, and on a desktop - where there is no hidden
# console - pressing the button made the window vanish and produced nothing at
# all. Which is exactly what the dead button did.
#
# Hide-HDTShellWindow -Restore then puts back the console the payload hid in
# WinPE, so nothing is left invisible behind a window that has just closed. On
# a desktop it answers false and does nothing, which is correct.
if ($answer.Action -eq 'CommandPrompt') {
    $prompt = Start-HDTCommandPrompt
    Write-Information ("the prompt: started {0}, {1} (pid {2}) {3}" -f
        $prompt.Started, $prompt.FilePath, $prompt.ProcessId, $prompt.Message) -InformationAction Continue

    [void] (Hide-HDTShellWindow -Restore)
}

return $answer
