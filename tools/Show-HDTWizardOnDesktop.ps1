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
        Which page to show. 'Welcome' is W1's, 'Credential' is W2's.

    .PARAMETER XamlPath
        An explicit XAML file, overriding -Page.

    .EXAMPLE
        ./tools/Show-HDTWizardOnDesktop.ps1 -Page Credential

        Opens the credentials page and reports which button was pressed.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Welcome', 'Credential', 'Simple')]
    [string] $Page = 'Credential',

    [Parameter()]
    [AllowEmptyString()]
    [string] $XamlPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force

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

# OPEN CMD IS MDT'S "EXIT TO COMMAND PROMPT", and MDT's behaviour is what it
# does: the wizard closes and the technician is left AT A PROMPT. In WinPE that
# prompt is the console startnet.cmd is running in, which the payload hid to put
# the wizard on screen - so restoring it is not decoration, it IS the feature.
# Without this the window vanishes and a technician who asked for a prompt is
# looking at nothing.
#
# ON THIS DESKTOP IT IS A NO-OP AND THAT IS CORRECT: Hide-HDTShellWindow answers
# false when there is no console to act on, and the terminal this tool was
# started from is already the prompt being asked for. The point of calling it
# here is that the tool and the payload take the SAME path, which is the whole
# reason this tool exists.
if ($answer.Action -eq 'CommandPrompt') {
    [void] (Hide-HDTShellWindow -Restore)
}

return $answer
