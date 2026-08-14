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

return $answer
