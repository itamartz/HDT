# WHICH BOX THE CURSOR IS IN WHEN A PAGE OPENS.
#
# MEASURED FIRST, WITH AN STA PROBE WALKING MoveFocus DOWN Computer Details:
# focus sat on the WINDOW, and Tab 1 and Tab 2 landed on the progress rail and
# the page host before Tab 3 reached HDTComputerNameBox. Those two are fixed in
# the markup; this is the other half - nothing called Focus() anywhere in
# New-HDTWizardHost, so a technician reached for the mouse or pressed Tab three
# times to get into a box already in front of them.
#
# A COMMAND, BECAUSE "FIRST" IS A DECISION. The host walks the answer and
# focuses the first control that is there and is enabled; the ORDER is decided
# here, from what the page itself declares.
#
# THE ORDER IS collect's ORDER, AND THAT IS NOT AN ARBITRARY PICK. A page
# already lists the controls it fills, in the order it fills them, and MDT's
# panes are read top to bottom - so the first thing declared is the first thing
# asked. Nothing new to author, and nothing to keep in step with the markup.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:page = {
        param([object[]] $Collect)

        return [pscustomobject] @{
            Id      = 'A'
            Title   = 'A page'
            Collect = $Collect
        }
    }

    $script:entry = {
        param([string] $Control, [string] $Property)

        $row = [pscustomobject] @{ Control = $Control; Variable = 'HDTThing' }
        if (-not [string]::IsNullOrWhiteSpace($Property)) {
            $row | Add-Member -MemberType NoteProperty -Name 'Property' -Value $Property
        }

        return $row
    }
}

Describe 'Get-HDTWizardFocus' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTWizardFocus' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'names the first control the page collects into' {
        $page = & $script:page @((& $script:entry 'HDTComputerNameBox' ''), (& $script:entry 'HDTJoinDomainBox' ''))

        @(Get-HDTWizardFocus -Page $page)[0] | Should -Be 'HDTComputerNameBox'
    }

    It 'names the rest behind it, so a disabled first control is not a dead end' {
        # COMPUTER DETAILS DISABLES HALF OF ITSELF. Whichever of domain and
        # workgroup was not chosen is disabled, and a control that cannot take
        # focus must not cost the page its focus altogether - the host walks
        # this list and takes the first one that will have it.
        $page = & $script:page @(
            (& $script:entry 'HDTComputerNameBox' ''),
            (& $script:entry 'HDTJoinDomainBox' ''),
            (& $script:entry 'HDTJoinWorkgroupBox' ''))

        @(Get-HDTWizardFocus -Page $page) | Should -Be @('HDTComputerNameBox', 'HDTJoinDomainBox', 'HDTJoinWorkgroupBox')
    }

    It 'answers with nothing for a page that collects nothing' {
        # The Summary page collects nothing and asks for nothing. Deploy is
        # IsDefault, so Enter already works there; stealing focus onto some
        # arbitrary element would be worse than leaving it where WPF put it.
        @(Get-HDTWizardFocus -Page (& $script:page @())).Count | Should -Be 0
    }

    It 'answers with nothing for a null page rather than throwing' {
        # The host calls this on every render, including the first, and a page
        # that failed to load must not turn into a second failure on the way to
        # the screen.
        @(Get-HDTWizardFocus -Page $null).Count | Should -Be 0
    }

    It 'skips an entry with no control name' {
        $page = & $script:page @((& $script:entry '' ''), (& $script:entry 'HDTRealBox' ''))

        @(Get-HDTWizardFocus -Page $page) | Should -Be @('HDTRealBox')
    }

    It 'leaves a page whose only entry is a secret alone at the front of the list' {
        # A PasswordBox is a legitimate first field - the Welcome screen's
        # credential pane is nothing else - so being secret is not a reason to
        # skip it. Only the ORDER is decided here.
        $secret = & $script:entry 'HDTPasswordBox' 'Password'
        $secret | Add-Member -MemberType NoteProperty -Name 'IsSecret' -Value $true

        @(Get-HDTWizardFocus -Page (& $script:page @($secret)))[0] | Should -Be 'HDTPasswordBox'
    }

    It 'names each control once even when a page collects two variables from it' {
        # ComputerDetail's account box fills HDTDomainAdmin and, through the
        # split, HDTDomainAdminDomain. Focus is about controls, not variables,
        # and a list that named one twice would make the host try it twice.
        $page = & $script:page @(
            (& $script:entry 'HDTAccountBox' ''),
            (& $script:entry 'HDTAccountBox' ''),
            (& $script:entry 'HDTOtherBox' ''))

        @(Get-HDTWizardFocus -Page $page) | Should -Be @('HDTAccountBox', 'HDTOtherBox')
    }
}
