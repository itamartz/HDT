# W2 of the WPF-first direction (.planning/WPF-FIRST.md).
#
# WHY THIS COMMAND EXISTS AT ALL. New-HDTWizardHost is exempt from TDD as a thin
# adapter over WPF (CLAUDE.md rule 1), and that exemption is CONDITIONAL: an
# adapter earns it by staying branch-free, "because it is not unit tested". The
# host had stopped being branch-free - it read the network, decided which named
# boxes existed, decided what went in each, and swallowed every failure - and
# the first time it was ever really executed it crashed on a variable that was
# not in scope. That is the exemption's price being paid in the worst possible
# place.
#
# So the DECISIONS moved here, where they can be asserted with no display and no
# WinPE, and the host went back to being plumbing: load, apply, wire, show.
# WPF-FIRST already required exactly this - "the command holds the logic and is
# callable without the window".
#
# THE PASSWORD IS NEVER A FIELD. There is an explicit test for that below, and
# it is not decoration: bootstrap.json can carry a credential, this command can
# see it, and a prefilled PasswordBox would put the share password on screen in
# a room where someone is deploying a machine.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    function New-HDTTestNetwork {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test object; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()] [bool] $HasLease = $true,
            [Parameter()] [string] $IPAddress = '192.168.2.118',
            [Parameter()] [string] $SubnetMask = '255.255.255.0',
            [Parameter()] [string] $Gateway = '192.168.2.1',
            [Parameter()] [string] $DnsServerText = '192.168.2.1'
        )

        return [pscustomobject] @{
            HasLease           = $HasLease
            IPAddress          = $IPAddress
            SubnetMask         = $SubnetMask
            Gateway            = $Gateway
            DnsServer          = [string[]] @($DnsServerText)
            DnsServerText      = $DnsServerText
            AdapterDescription = 'Microsoft Hyper-V Network Adapter'
        }
    }

    function New-HDTTestBootstrap {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test object; it changes no state.')]
        # THE SAME THREE Get-HDTWizardCredential.Tests.ps1 SUPPRESSES, for the
        # same reason: this is a stand-in for the bootstrap document, and the
        # password is a test constant the assertions search for. The real
        # Get-HDTBootstrapConfiguration hands its secret out through
        # GetCredential() and never carries it as a property, which is exactly
        # the shape this fake reproduces.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
            Justification = 'A test fixture standing in for bootstrap.json, which carries both.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
            Justification = 'A test fixture constant, not a credential: it is what the prefill assertion looks for.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
            Justification = 'The only way to build a SecureString from a known test constant.')]
        [CmdletBinding()]
        param(
            [Parameter()] [string] $DeployRoot = '\\192.168.2.108\HDTShare',
            [Parameter()] [string] $UserName = '',
            [Parameter()] [string] $Password = ''
        )

        $bootstrap = [pscustomobject] @{
            DeployRoot = $DeployRoot
            UserName   = $UserName
        }

        # GetCredential(), NOT A Password PROPERTY - that is the shape the real
        # Get-HDTBootstrapConfiguration returns, and deliberately so: the secret
        # is closed over rather than carried, so the object can be written to a
        # log without writing the password with it.
        $secret = $Password
        $bootstrap | Add-Member -MemberType ScriptMethod -Name GetCredential -Value {
            if ([string]::IsNullOrEmpty($secret)) { return $null }

            return New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList 'svc',
            (ConvertTo-SecureString -String $secret -AsPlainText -Force)
        }.GetNewClosure()

        return $bootstrap
    }

    function Get-HDTTestFieldText {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)] [object[]] $Field,
            [Parameter(Mandatory = $true)] [string] $Name
        )

        $match = @($Field | Where-Object { $_.Name -ceq $Name })
        if ($match.Count -eq 0) { return $null }

        return [string] $match[0].Text
    }
}

Describe 'Get-HDTWizardField' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTWizardField' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'takes an injected network configuration, so it needs no adapter' {
            (Get-Command -Name 'Get-HDTWizardField').Parameters.ContainsKey('NetworkConfiguration') | Should -BeTrue
        }

        It 'names every field after a control the shipped window actually has' {
            # NAME DRIFT IS THE FAILURE THIS WHOLE SPLIT EXISTS TO CATCH: the
            # host applies these by FindName, and a name nothing answers to is a
            # box that silently stays empty in WinPE.
            $welcome = [System.IO.File]::ReadAllText(
                (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/HDTWelcome.xaml'))

            $field = @(Get-HDTWizardField -NetworkConfiguration (New-HDTTestNetwork) -Bootstrap (New-HDTTestBootstrap))

            @($field).Count | Should -BeGreaterThan 0
            foreach ($current in $field) {
                $welcome | Should -BeLike ('*x:Name="{0}"*' -f $current.Name) -Because (
                    '{0} is a field with no control to land in' -f $current.Name)
            }
        }
    }

    Context 'the lease, shown rather than guessed' {

        BeforeAll {
            $script:leased = @(Get-HDTWizardField -NetworkConfiguration (New-HDTTestNetwork))
        }

        It 'puts the address the machine actually got in the address box' {
            Get-HDTTestFieldText -Field $script:leased -Name 'HDTIpAddressBox' | Should -BeExactly '192.168.2.118'
        }

        It 'fills the mask, gateway and DNS boxes from the same lease' {
            Get-HDTTestFieldText -Field $script:leased -Name 'HDTSubnetMaskBox' | Should -BeExactly '255.255.255.0'
            Get-HDTTestFieldText -Field $script:leased -Name 'HDTGatewayBox' | Should -BeExactly '192.168.2.1'
            Get-HDTTestFieldText -Field $script:leased -Name 'HDTDnsBox' | Should -BeExactly '192.168.2.1'
        }

        It 'leaves the address boxes empty when there is no lease' {
            # An empty box under "obtain automatically" is the honest answer, and
            # Get-HDTNetworkConfiguration already refuses to call APIPA a lease.
            $field = @(Get-HDTWizardField -NetworkConfiguration (New-HDTTestNetwork -HasLease $false `
                        -IPAddress '' -SubnetMask '' -Gateway '' -DnsServerText ''))

            Get-HDTTestFieldText -Field $field -Name 'HDTIpAddressBox' | Should -BeExactly ''
            Get-HDTTestFieldText -Field $field -Name 'HDTGatewayBox' | Should -BeExactly ''
        }

        It 'asks for no network at all when it was given none' {
            # The Welcome screen must open on a machine whose network read
            # failed. A network read is diagnosis, not a precondition.
            { Get-HDTWizardField -NetworkConfiguration $null -Bootstrap $null } | Should -Not -Throw
        }
    }

    Context 'what bootstrap.json prefills' {

        It 'prefills the share from the image the machine booted' {
            $field = @(Get-HDTWizardField -Bootstrap (New-HDTTestBootstrap -DeployRoot '\\192.168.2.108\HDTShare'))

            Get-HDTTestFieldText -Field $field -Name 'HDTDeployRootBox' | Should -BeExactly '\\192.168.2.108\HDTShare'
        }

        It 'splits a domain-qualified user name across the two boxes' {
            $field = @(Get-HDTWizardField -Bootstrap (New-HDTTestBootstrap -UserName 'CONTOSO\svc-hdt-deploy'))

            Get-HDTTestFieldText -Field $field -Name 'HDTUserIdBox' | Should -BeExactly 'svc-hdt-deploy'
            Get-HDTTestFieldText -Field $field -Name 'HDTUserDomainBox' | Should -BeExactly 'CONTOSO'
        }

        It 'leaves the domain box blank when the domain IS the server, because blank means local' {
            # THE ROUND TRIP. Get-HDTWizardCredential turns a blank domain into
            # SERVER\user, so a local account prefilled as 'HDT01' in the domain
            # box would come back as HDT01\svc either way - but the page's own
            # hint says blank means local, and showing the server name there
            # teaches a technician the opposite.
            $field = @(Get-HDTWizardField -Bootstrap (New-HDTTestBootstrap `
                        -DeployRoot '\\HDT01\HDTShare' -UserName 'HDT01\svc-hdt-deploy'))

            Get-HDTTestFieldText -Field $field -Name 'HDTUserIdBox' | Should -BeExactly 'svc-hdt-deploy'
            Get-HDTTestFieldText -Field $field -Name 'HDTUserDomainBox' | Should -BeExactly ''
        }

        It 'matches the server case-insensitively, the way Windows names accounts' {
            $field = @(Get-HDTWizardField -Bootstrap (New-HDTTestBootstrap `
                        -DeployRoot '\\hdt01\HDTShare' -UserName 'HDT01\svc'))

            Get-HDTTestFieldText -Field $field -Name 'HDTUserDomainBox' | Should -BeExactly ''
        }

        It 'leaves the domain box blank for a bare user name' {
            $field = @(Get-HDTWizardField -Bootstrap (New-HDTTestBootstrap -UserName 'svc-hdt-deploy'))

            Get-HDTTestFieldText -Field $field -Name 'HDTUserIdBox' | Should -BeExactly 'svc-hdt-deploy'
            Get-HDTTestFieldText -Field $field -Name 'HDTUserDomainBox' | Should -BeExactly ''
        }

        It 'produces no account fields when the image carries no user name' {
            $field = @(Get-HDTWizardField -Bootstrap (New-HDTTestBootstrap -UserName ''))

            Get-HDTTestFieldText -Field $field -Name 'HDTUserIdBox' | Should -BeExactly ''
        }
    }

    Context 'the password, which IS prefilled' {

        # AN EARLIER VERSION REFUSED TO PREFILL IT, on the grounds that it would
        # put the share password on a screen in a room where somebody is
        # deploying. Two facts overturned that:
        #
        #   IT IS ALREADY IN THE IMAGE - bootstrap.json inside the boot media
        #   carries this very credential, which is why DESIGN 6.3 says to treat
        #   boot media AS a credential. Withholding it from the screen protects
        #   nothing from anybody holding the media.
        #
        #   A PasswordBox SHOWS DOTS - it is masked until somebody presses the
        #   eye, so it is not readable on screen by default.
        #
        # And the screen is shown when the SHARE CANNOT BE REACHED, which is
        # exactly when a technician needs to try the same account against a
        # corrected UNC. Making them retype a password nobody wrote down is how
        # that attempt fails for a second, unrelated reason.

        It 'emits the embedded password, into the Password property' {
            $field = @(Get-HDTWizardField -NetworkConfiguration (New-HDTTestNetwork) `
                    -Bootstrap (New-HDTTestBootstrap -UserName 'CONTOSO\svc' -Password 'Sup3rSecret!'))

            $row = @($field | Where-Object { $_.Name -eq 'HDTPasswordBox' })

            @($row).Count | Should -Be 1
            $row[0].Text | Should -BeExactly 'Sup3rSecret!'

            # A PasswordBox HAS NO Text AT ALL. Without the property the host
            # would try to set one and the Welcome screen would die on the one
            # machine nobody can debug.
            $row[0].Property | Should -BeExactly 'Password'
        }

        It 'emits no password field for an image built without a credential' {
            # -PromptForCredential builds exactly this image, and it deliberately
            # stops for a human. An empty box is what that human is for.
            $field = @(Get-HDTWizardField -Bootstrap (New-HDTTestBootstrap -UserName ''))

            @($field | Where-Object { $_.Name -eq 'HDTPasswordBox' }) | Should -BeNullOrEmpty
        }

        It 'says Text for every other box, so a TextBox is still filled' {
            $field = @(Get-HDTWizardField -NetworkConfiguration (New-HDTTestNetwork) `
                    -Bootstrap (New-HDTTestBootstrap -UserName 'CONTOSO\svc'))

            foreach ($current in @($field | Where-Object { $_.Name -ne 'HDTPasswordBox' })) {
                $current.Property | Should -BeExactly 'Text'
            }
        }
    }
}
