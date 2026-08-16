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
    [string] $XamlPath = '',

    # THE RESOLVED VARIABLES, for 'Shell' mode. Pass a skip key to watch a page
    # leave the rail: -Variable @{ HDTSkipLocaleSelection = $true }, which is
    # exactly what a rule on the share would do to a real deployment.
    [Parameter()]
    [AllowNull()]
    [hashtable] $Variable = @{}
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

    # THE SAMPLE SHARE, READ THE WAY WinPE READS IT. This used to carry its own
    # copy of the page list - ids, titles, skip keys, what each collects - which
    # meant the preview could agree with itself and disagree with the product.
    # It now goes through Import-HDTWizardDocument against a real content
    # provider, so what is on screen here is what Scripts\UI\wizard.yaml says,
    # and a mistake in that file shows up on this desktop rather than on a VM.
    $shareRoot = Join-Path -Path $repoRoot -ChildPath 'samples/workspace'
    $provider = New-HDTLocalContentProvider -Root $shareRoot -FileSystem (New-HDTFileSystem)

    $wizard = Import-HDTWizardDocument -Provider $provider

    if ($null -eq $wizard) {
        Write-Information ("no Scripts\UI\wizard.yaml under {0} - nothing to show." -f $shareRoot) -InformationAction Continue
        return
    }

    # AND THE SAME FILTER THE PAYLOAD USES. Pass -Variable to watch a skip key
    # take a page out: @{ HDTSkipLocaleSelection = $true } and the rail is three
    # rows instead of four.
    $ask = Get-HDTWizardPage -Page $wizard.Page -Variable $Variable

    Write-Information ("{0} page(s) to ask, {1} skipped" -f @($ask.Page).Count, @($ask.Skipped).Count) -InformationAction Continue

    if (-not $ask.IsWizardNeeded) {
        Write-Information 'every page is skipped - a deployment here would show no wizard at all.' -InformationAction Continue
        return
    }
    $shellAnswer = Show-HDTWizardShell `
        -ShellXamlPath (Join-Path -Path $repoRoot -ChildPath 'src/Hephaestus/UI/HDTWizardShell.xaml') `
        -ThemeXamlPath (Join-Path -Path $repoRoot -ChildPath 'src/Hephaestus/UI/HDTTheme.xaml') `
        -Page $ask.Page `
        -Title $wizard.Title `
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
