# MDT's Skip* properties, under the HDT prefix (.planning/WPF-FIRST.md, W2).
#
# THESE RULES COME FROM bootstrap.json AND NOT FROM rules.yaml, and that is a
# correction to WPF-FIRST recorded in the document itself. rules.yaml lives ON
# THE SHARE, and the Welcome screen is what makes the share reachable -
# configuring the network and collecting the credential is the whole job. A
# HDTSkipWelcome on the share is a rule the machine cannot read until after the
# screen it was meant to skip has been shown. MDT has the same split for the
# same reason: SkipBDDWelcome is in Bootstrap.ini, every other Skip* is in
# CustomSettings.ini.
#
# THE DEFAULT IS SKIPPED, AND THAT IS THE POINT OF THE WHOLE FILE. WPF-FIRST:
# "THE UNATTENDED PATH IS THE DEFAULT, NOT THE EXCEPTION. An image built with an
# embedded credential and a resolved HDTTaskSequenceID must still deploy with
# nobody present: the E2E suite proves zero-keystroke deployment and it must not
# start needing a human."
#
# A wizard that appeared by default would break that the moment it existed -
# every image already built would quietly start waiting for somebody. So an
# unset welcome rule means SKIPPED unless something genuinely has to be asked,
# and the only thing decidable at boot is whether the image can authenticate at
# all. That is promptForCredential, which DESIGN 6.3 already settled.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # Shaped like Get-HDTBootstrapConfiguration's result. $null on a skip key
    # means the image said nothing about it, which is a different fact from
    # $false and is the one the defaults turn on.
    function New-HDTTestSkipBootstrap {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test object; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()] [object] $Welcome = $null,
            [Parameter()] [object] $StaticIp = $null,
            [Parameter()] [object] $DeployRoot = $null,

            # NOT named Credential, and not CredentialRule either:
            # PSAvoidUsingPlainTextForPassword matches the SUBSTRING, so any
            # name containing "Credential" has to be a PSCredential. This one
            # is a skip rule for the account pane, so it is named for the pane.
            [Parameter()] [object] $AccountRule = $null,
            [Parameter()] [bool] $PromptForCredential = $false,
            [Parameter()] [bool] $HasCredential = $true
        )

        return [pscustomobject] @{
            DeployRoot          = '\\192.168.2.108\HDTShare'
            UserName            = '192.168.2.108\svc-hdt-deploy'
            PromptForCredential = $PromptForCredential
            HasCredential       = $HasCredential
            Skip                = [pscustomobject] @{
                Welcome    = $Welcome
                StaticIp   = $StaticIp
                DeployRoot = $DeployRoot
                Credential = $AccountRule
            }
        }
    }

    function Get-HDTTestPaneVisible {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)] [object] $Skip,
            [Parameter(Mandatory = $true)] [string] $Name
        )

        $match = @($Skip.Pane | Where-Object { $_.Name -ceq $Name })
        if ($match.Count -eq 0) { return $null }

        return [bool] $match[0].Visible
    }
}

Describe 'Get-HDTWizardSkip' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTWizardSkip' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'names every pane after a control the shipped window actually has' {
            $welcome = [System.IO.File]::ReadAllText(
                (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/HDTWelcome.xaml'))

            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap)

            @($skip.Pane).Count | Should -BeGreaterThan 0
            foreach ($pane in @($skip.Pane)) {
                $welcome | Should -BeLike ('*x:Name="{0}"*' -f $pane.Name) -Because (
                    '{0} is a pane with nothing to hide' -f $pane.Name)
            }
        }
    }

    Context 'THE UNATTENDED PATH IS THE DEFAULT' {

        It 'skips the Welcome screen when the image said nothing and can authenticate' {
            # THE ONE THAT PROTECTS EVERY IMAGE ALREADY BUILT. A wizard that
            # appeared by default would make each of them start waiting for a
            # human who is not there.
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap -PromptForCredential $false)

            [bool] $skip.Welcome | Should -BeTrue -Because (
                'an image that can reach its share unaided must deploy with nobody present')
        }

        It 'shows the Welcome screen when the image cannot authenticate without a human' {
            # promptForCredential is DESIGN 6.3's "this image stops for a
            # person", and it is the only thing decidable before the share is
            # reachable.
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap -PromptForCredential $true)

            [bool] $skip.Welcome | Should -BeFalse
        }

        It 'records where the answer came from' {
            $default = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap)
            $stated = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap -Welcome $false)

            [string] @($default.Source | Where-Object { $_.Rule -eq 'HDTSkipWelcome' })[0].Source |
                Should -BeExactly 'default'
            [string] @($stated.Source | Where-Object { $_.Rule -eq 'HDTSkipWelcome' })[0].Source |
                Should -BeExactly 'bootstrap.json'
        }
    }

    Context 'what the image explicitly says wins' {

        It 'shows the Welcome screen when the image asked for it, credential or not' {
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap -Welcome $false -PromptForCredential $false)

            [bool] $skip.Welcome | Should -BeFalse -Because 'an explicit rule is not a hint'
        }

        It 'skips the Welcome screen when the image asked to, even though it would have asked' {
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap -Welcome $true -PromptForCredential $true)

            [bool] $skip.Welcome | Should -BeTrue
        }

        It 'hides the <Pane> pane when <Rule> is set' -ForEach @(
            @{ Rule = 'HDTSkipStaticIp'; Pane = 'HDTNetworkPane'; Argument = 'StaticIp' }
            @{ Rule = 'HDTSkipDeployRoot'; Pane = 'HDTDeployRootPane'; Argument = 'DeployRoot' }
            @{ Rule = 'HDTSkipCredential'; Pane = 'HDTCredentialPane'; Argument = 'AccountRule' }) {

            $argument = @{ Welcome = $false; $Argument = $true }
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap @argument)

            Get-HDTTestPaneVisible -Skip $skip -Name $Pane | Should -BeFalse
        }

        It 'shows the <Pane> pane when <Rule> is explicitly false' -ForEach @(
            @{ Rule = 'HDTSkipStaticIp'; Pane = 'HDTNetworkPane'; Argument = 'StaticIp' }
            @{ Rule = 'HDTSkipDeployRoot'; Pane = 'HDTDeployRootPane'; Argument = 'DeployRoot' }
            @{ Rule = 'HDTSkipCredential'; Pane = 'HDTCredentialPane'; Argument = 'AccountRule' }) {

            $argument = @{ Welcome = $false; $Argument = $false }
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap @argument)

            Get-HDTTestPaneVisible -Skip $skip -Name $Pane | Should -BeTrue
        }
    }

    Context 'a pane appears only when it has something to ask' {

        It 'hides the credential pane when the image already carries a credential' {
            # NOTHING TO ASK. The account is embedded and works; a technician
            # staring at an empty password box would reasonably think they had
            # to fill it in.
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap -Welcome $false -PromptForCredential $false)

            Get-HDTTestPaneVisible -Skip $skip -Name 'HDTCredentialPane' | Should -BeFalse
            [bool] $skip.Credential | Should -BeTrue
        }

        It 'shows the credential pane when the image is the one that stops for a person' {
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap -Welcome $false -PromptForCredential $true)

            Get-HDTTestPaneVisible -Skip $skip -Name 'HDTCredentialPane' | Should -BeTrue
        }

        It 'shows the network and share panes by default, because a technician who got here may need them' {
            # These two are NOT inferred away. A machine whose network is wrong
            # is the commonest reason a technician is looking at this screen at
            # all, and inferring the share is fine right up until the prefilled
            # one is unreachable.
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap -Welcome $false)

            Get-HDTTestPaneVisible -Skip $skip -Name 'HDTNetworkPane' | Should -BeTrue
            Get-HDTTestPaneVisible -Skip $skip -Name 'HDTDeployRootPane' | Should -BeTrue
        }
    }

    Context 'a boot with nothing to go on' {

        It 'skips the Welcome screen when there is no bootstrap document at all' {
            # AN IMAGE THIS COMMAND CANNOT READ MUST NOT START WAITING FOR
            # SOMEBODY. Failing towards the unattended path is the safe
            # direction: the deployment either proceeds or fails loudly, rather
            # than sitting on a screen in a room nobody is in.
            $skip = Get-HDTWizardSkip -Bootstrap $null

            [bool] $skip.Welcome | Should -BeTrue
        }

        It 'still describes every pane when there is no bootstrap document' {
            $skip = Get-HDTWizardSkip -Bootstrap $null

            @($skip.Pane).Count | Should -Be 3
        }

        It 'tolerates a bootstrap document with no skip block, which every existing image has' {
            $bootstrap = [pscustomobject] @{
                DeployRoot          = '\\192.168.2.108\HDTShare'
                PromptForCredential = $false
            }

            { Get-HDTWizardSkip -Bootstrap $bootstrap } | Should -Not -Throw
            [bool] (Get-HDTWizardSkip -Bootstrap $bootstrap).Welcome | Should -BeTrue
        }
    }
}
