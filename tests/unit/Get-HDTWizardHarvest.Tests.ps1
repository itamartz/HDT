# What the Welcome screen answers with.
#
# THE SCREEN WAS DECORATIVE AND A REAL BOOT PROVED IT. HDT-Wizard-01 booted an
# image whose share had moved, showed the Welcome screen, and died on the old
# address anyway - because Show-HDTWizard returned an Action and nothing else,
# so the corrected UNC a technician typed was thrown away:
#
#     FATAL: ... "NewMapping" ... The network path was not found.
#     At X:\HDT\Start-HDTDeployment.ps1:473 char:5
#     + [void] $content.Connect()
#
# THE NAMES ARE ASSERTED AGAINST THE SHIPPED MARKUP, exactly as
# Get-HDTWizardField's are: a harvest naming a control the screen does not have
# is a box that silently answers nothing, which is the defect this file exists
# to stop coming back.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:welcome = [xml] (Get-Content -LiteralPath (Join-Path -Path $script:repoRoot `
                -ChildPath 'src/Hephaestus/UI/HDTWelcome.xaml') -Raw)

    $script:named = @($script:welcome.SelectNodes('//*') | ForEach-Object {
            $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

Describe 'Get-HDTWizardHarvest' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTWizardHarvest' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'reads the deploy root, which is the whole point' {
        # A share that moved is the case this exists for. Everything else on the
        # list is worth having; this one is why the list exists.
        @(Get-HDTWizardHarvest | Where-Object { $_.Name -eq 'HDTDeployRootBox' })[0].Property |
            Should -BeExactly 'Text'
    }

    It 'reads <Name> from its <Property>' -ForEach @(
        @{ Name = 'HDTUseStaticRadio'; Property = 'IsChecked' }
        @{ Name = 'HDTPasswordBox'; Property = 'Password' }
        @{ Name = 'HDTIpAddressBox'; Property = 'Text' }
    ) {
        # NAME AND PROPERTY TOGETHER. A TextBox answers Text, a PasswordBox
        # answers Password and a RadioButton answers IsChecked - and a host that
        # worked that out from the type would be making a decision, which is the
        # thing an untested adapter may not do.
        @(Get-HDTWizardHarvest | Where-Object { $_.Name -eq $Name })[0].Property |
            Should -BeExactly $Property
    }

    It 'names only controls the shipped Welcome screen actually has' {
        $missing = @(Get-HDTWizardHarvest |
                Where-Object { $script:named -notcontains [string] $_.Name } |
                ForEach-Object { [string] $_.Name })

        ($missing -join ', ') | Should -BeExactly ''
    }

    It 'reads back every box Get-HDTWizardField writes into' {
        # THE TWO LISTS ARE A ROUND TRIP. Get-HDTWizardField decides what the
        # screen is SHOWN; this decides what it is READ FOR. A box filled in and
        # never read is exactly the bug that shipped - the deploy root was
        # prefilled from bootstrap.json and then discarded.
        #
        # The password is the deliberate exception in the other direction: it is
        # read here and never prefilled, because prefilling it would put the
        # share password on a screen in a room where somebody is deploying.
        $written = @((Get-HDTWizardField -Bootstrap ([pscustomobject] @{
                        DeployRoot = '\\HDT-HOST\HdtShare'; UserName = 'CORP\svc'
                    })).Name)

        $read = @(Get-HDTWizardHarvest | ForEach-Object { [string] $_.Name })

        $unread = @($written | Where-Object { $read -notcontains $_ })

        ($unread -join ', ') | Should -BeExactly ''
    }
}
