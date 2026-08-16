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
            [Parameter()] [bool] $HasCredential = $true,

            # The share the image carries, if any. Empty is the case the hint
            # exists for.
            [Parameter()] [string] $DeployRootValue = '\\HDT-HOST\HDTShare'
        )

        return [pscustomobject] @{
            DeployRoot          = $DeployRootValue
            UserName            = 'HDT-HOST\svc-hdt-deploy'
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

    Context 'a pane with an answer already in it is SHOWN, not hidden' {

        # THE CHANGE, AND THE REASONING BEHIND IT. Collapsing the account pane
        # because the image carries a credential hides the one fact a
        # technician most wants to confirm before pressing Next: WHICH ACCOUNT
        # this machine is about to deploy as. The pane is not a question when
        # the answer is known - it is a statement - and a statement worth
        # reading.
        #
        # HIDING IS NOW SOMETHING THE IMAGE ASKS FOR, never something inferred
        # from having an answer.

        It 'shows the account pane even though the image carries a credential' {
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap -PromptForCredential $false -HasCredential $true)

            [bool] $skip.Credential | Should -BeFalse
            Get-HDTTestPaneVisible -Skip $skip -Name 'HDTCredentialPane' | Should -BeTrue
        }

        It 'shows the share pane' {
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap)

            Get-HDTTestPaneVisible -Skip $skip -Name 'HDTDeployRootPane' | Should -BeTrue
        }

        It 'still hides the account pane when the image explicitly asks' {
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap -AccountRule $true)

            Get-HDTTestPaneVisible -Skip $skip -Name 'HDTCredentialPane' | Should -BeFalse
        }
    }

    Context 'an image with no share says so on the screen' {

        # An empty box reads as "optional". This is the line that says it is
        # not, and it is the only reason a missing deployRoot is no longer a
        # refusal in Get-HDTBootstrapConfiguration: the person who can fix it
        # is standing right there.

        It 'shows the hint when the boot image carried no share' {
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap -DeployRootValue '')

            Get-HDTTestPaneVisible -Skip $skip -Name 'HDTDeployRootHint' | Should -BeTrue
        }

        It 'hides the hint when the boot image carried one' {
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap -DeployRootValue '\\HDT-HOST\HDTShare')

            Get-HDTTestPaneVisible -Skip $skip -Name 'HDTDeployRootHint' | Should -BeFalse
        }

        It 'hides the hint when there is no bootstrap at all, because nothing is known' {
            # A boot with no bootstrap document skips the whole screen anyway;
            # asserting the hint is off keeps "unknown" from rendering as "wrong".
            $skip = Get-HDTWizardSkip -Bootstrap $null

            Get-HDTTestPaneVisible -Skip $skip -Name 'HDTDeployRootHint' | Should -BeFalse
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

        It 'shows the credential pane even when the image already carries a credential' {
            # REVERSED DELIBERATELY. This used to hide the pane on the grounds
            # that an embedded account has nothing to ask - but a pane with the
            # answer already in it is a STATEMENT, and which account this
            # machine deploys as is the fact a technician most wants to confirm
            # before pressing Next. Hiding is now something the image asks for.
            $skip = Get-HDTWizardSkip -Bootstrap (New-HDTTestSkipBootstrap -Welcome $false -PromptForCredential $false)

            Get-HDTTestPaneVisible -Skip $skip -Name 'HDTCredentialPane' | Should -BeTrue
            [bool] $skip.Credential | Should -BeFalse
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

            # Four: the three panes, plus HDTDeployRootHint.
            @($skip.Pane).Count | Should -Be 4
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
