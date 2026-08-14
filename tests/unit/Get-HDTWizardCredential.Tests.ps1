# W2 of the WPF-first direction (.planning/WPF-FIRST.md): MDT's Bootstrap.ini
# credential quartet, composed and PROVEN before the wizard moves on.
#
#   DeployRoot     \\192.168.2.108\HDTShare   the server we are connecting to
#   UserID         svc-hdt-deploy
#   UserDomain     CONTOSO, or THE SERVER NAME when the account is local
#   UserPassword   never prefilled, never logged
#
# WHY UserDomain IS ITS OWN FIELD. HDT collapsed it into the username string
# ('LAP-AMMSO01\svc-hdt-deploy') until now, which works for a machine but not
# for a human: a technician has to be able to say "this is a LOCAL account on
# that server" without knowing that the convention for saying so is to type the
# server's name where a domain goes. Leaving it blank means local, and this
# command is what turns that into the name Windows actually needs.
#
# WHY NEXT CONNECTS. A form that only collects text moves the failure thirty
# seconds downstream, into a log nobody is reading, on a machine that has
# already started. Validating here means a wrong password is a red line on the
# page a technician is looking at, with the cursor still in the box.
#
# THE PASSWORD IS THE ONE THING THAT MUST NEVER LEAK. It is asserted absent
# from every string this command produces - the composed name, the message, the
# log - because a deployment log is copied around far more freely than a
# password is.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:deployRoot = '\\192.168.2.108\HDTShare'
    $script:secret = 'Sup3rSecret-Deploy-Password!'

    function New-HDTWizardSecret {
        # THE TWO PASSWORD RULES ARE SUPPRESSED HERE AND NOWHERE ELSE. Both are
        # correct about production code and wrong about this function: it exists
        # to turn a KNOWN TEST CONSTANT into the SecureString the command under
        # test takes, and there is no other way to build one from a literal.
        # The constant is a fixture, not a credential - it authenticates to
        # nothing, and the assertions it feeds are the ones that prove the real
        # password never reaches a log.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory SecureString; it changes no state.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
            Justification = 'A test fixture constant, not a credential: it is the input the password-redaction assertions search for.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
            Justification = 'The only way to build a SecureString from a known test constant.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowEmptyString()]
            [string] $Password = $script:secret
        )

        # ConvertTo-SecureString REFUSES an empty string, so the empty case -
        # which is exactly what a technician who tabbed past the box produces -
        # is an empty SecureString built directly.
        if ([string]::IsNullOrEmpty($Password)) {
            return (New-Object -TypeName System.Security.SecureString)
        }

        return (ConvertTo-SecureString -String $Password -AsPlainText -Force)
    }
}

Describe 'Get-HDTWizardCredential' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTWizardCredential' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'takes an injected content provider, so it can be proven with no share' -ForEach @('ContentProvider', 'DeployRoot', 'UserId', 'UserDomain', 'Password') {
            (Get-Command -Name 'Get-HDTWizardCredential').Parameters.ContainsKey($PSItem) | Should -BeTrue
        }
    }

    Context 'composing the account name - MDT UserDomain semantics' {

        It 'uses DOMAIN\UserID when a domain is given' {
            $result = Get-HDTWizardCredential -DeployRoot $script:deployRoot `
                -UserId 'svc-hdt-deploy' -UserDomain 'CONTOSO' -Password (New-HDTWizardSecret) `
                -ContentProvider (New-HDTFakeContentProvider -Root $script:deployRoot)

            [string] $result.UserName | Should -BeExactly 'CONTOSO\svc-hdt-deploy'
        }

        It 'uses the SERVER name when no domain is given, which is how a local account is named' {
            # THE WHOLE REASON THIS FIELD EXISTS. A blank domain means "local to
            # the server we are connecting to", and Windows spells that as
            # SERVER\user - which the technician should not have to know.
            $result = Get-HDTWizardCredential -DeployRoot $script:deployRoot `
                -UserId 'svc-hdt-deploy' -UserDomain '' -Password (New-HDTWizardSecret) `
                -ContentProvider (New-HDTFakeContentProvider -Root $script:deployRoot)

            [string] $result.UserName | Should -BeExactly '192.168.2.108\svc-hdt-deploy'
            [string] $result.Server | Should -BeExactly '192.168.2.108'
            [bool] $result.IsLocalAccount | Should -BeTrue
        }

        It 'reports a domain account as not local' {
            $result = Get-HDTWizardCredential -DeployRoot $script:deployRoot `
                -UserId 'svc-hdt-deploy' -UserDomain 'CONTOSO' -Password (New-HDTWizardSecret) `
                -ContentProvider (New-HDTFakeContentProvider -Root $script:deployRoot)

            [bool] $result.IsLocalAccount | Should -BeFalse
        }

        It 'accepts a UserID already carrying its domain and does not double it' {
            # Technicians type what they know. 'CONTOSO\svc' in the user box
            # must not become 'CONTOSO\CONTOSO\svc'.
            $result = Get-HDTWizardCredential -DeployRoot $script:deployRoot `
                -UserId 'CONTOSO\svc-hdt-deploy' -UserDomain '' -Password (New-HDTWizardSecret) `
                -ContentProvider (New-HDTFakeContentProvider -Root $script:deployRoot)

            [string] $result.UserName | Should -BeExactly 'CONTOSO\svc-hdt-deploy'
        }
    }

    Context 'what it refuses, on the page rather than in a log' {

        It 'refuses a blank user' {
            $result = Get-HDTWizardCredential -DeployRoot $script:deployRoot `
                -UserId '' -UserDomain 'CONTOSO' -Password (New-HDTWizardSecret) `
                -ContentProvider (New-HDTFakeContentProvider -Root $script:deployRoot)

            [bool] $result.Connected | Should -BeFalse
            [string] $result.Message | Should -BeLike '*user*'
        }

        It 'refuses a blank password' {
            $result = Get-HDTWizardCredential -DeployRoot $script:deployRoot `
                -UserId 'svc-hdt-deploy' -UserDomain 'CONTOSO' -Password (New-HDTWizardSecret -Password '') `
                -ContentProvider (New-HDTFakeContentProvider -Root $script:deployRoot)

            [bool] $result.Connected | Should -BeFalse
            [string] $result.Message | Should -BeLike '*password*'
        }

        It 'refuses a deploy root that is not a share' {
            $result = Get-HDTWizardCredential -DeployRoot 'C:\Share' `
                -UserId 'svc-hdt-deploy' -UserDomain 'CONTOSO' -Password (New-HDTWizardSecret) `
                -ContentProvider (New-HDTFakeContentProvider -Root 'C:\Share')

            [bool] $result.Connected | Should -BeFalse
            [string] $result.Message | Should -BeLike '*\\*'
        }

        It 'never connects when it has already refused the input' {
            $provider = New-HDTFakeContentProvider -Root $script:deployRoot

            Get-HDTWizardCredential -DeployRoot $script:deployRoot -UserId '' -UserDomain '' `
                -Password (New-HDTWizardSecret) -ContentProvider $provider | Out-Null

            @($provider.Operations | Where-Object { $_.Operation -eq 'Connect' }) | Should -BeNullOrEmpty
        }
    }

    Context 'it proves the credential by connecting' {

        It 'connects with what the technician typed' {
            $provider = New-HDTFakeContentProvider -Root $script:deployRoot

            $result = Get-HDTWizardCredential -DeployRoot $script:deployRoot `
                -UserId 'svc-hdt-deploy' -UserDomain 'CONTOSO' -Password (New-HDTWizardSecret) `
                -ContentProvider $provider

            [bool] $result.Connected | Should -BeTrue
            @($provider.Operations | Where-Object { $_.Operation -eq 'Connect' }).Count | Should -Be 1
        }

        It 'reports a refused connection instead of throwing' {
            # The wizard has to stay on screen so the technician can retype.
            $provider = New-HDTFakeContentProvider -Root $script:deployRoot -Failure @{
                Connect = 'System error 1326: The user name or password is incorrect.'
            }

            $result = Get-HDTWizardCredential -DeployRoot $script:deployRoot `
                -UserId 'svc-hdt-deploy' -UserDomain 'CONTOSO' -Password (New-HDTWizardSecret) `
                -ContentProvider $provider

            [bool] $result.Connected | Should -BeFalse
            [string] $result.Message | Should -BeLike '*1326*'
        }

        It 'surfaces the guest-fallback refusal as a credential problem' {
            # DESIGN 6.3: HDT will not deploy from a share it did not
            # authenticate to. From the technician's seat that is the same
            # action - fix the account - so it belongs on this page.
            $provider = New-HDTFakeContentProvider -Root $script:deployRoot -Failure @{
                Connect = 'HDTSecurityError: the connection came back as ''Guest'''
            }

            $result = Get-HDTWizardCredential -DeployRoot $script:deployRoot `
                -UserId 'svc-hdt-deploy' -UserDomain 'CONTOSO' -Password (New-HDTWizardSecret) `
                -ContentProvider $provider

            [bool] $result.Connected | Should -BeFalse
            [bool] $result.GuestRefused | Should -BeTrue
        }

        It 'disconnects again, so the wizard leaves no mapping behind' {
            $provider = New-HDTFakeContentProvider -Root $script:deployRoot

            Get-HDTWizardCredential -DeployRoot $script:deployRoot `
                -UserId 'svc-hdt-deploy' -UserDomain 'CONTOSO' -Password (New-HDTWizardSecret) `
                -ContentProvider $provider | Out-Null

            @($provider.Operations | Where-Object { $_.Operation -eq 'Disconnect' }).Count | Should -Be 1
        }
    }

    Context 'the password' {

        It 'comes back as a PSCredential the payload can use' {
            $result = Get-HDTWizardCredential -DeployRoot $script:deployRoot `
                -UserId 'svc-hdt-deploy' -UserDomain 'CONTOSO' -Password (New-HDTWizardSecret) `
                -ContentProvider (New-HDTFakeContentProvider -Root $script:deployRoot)

            $result.Credential | Should -BeOfType [System.Management.Automation.PSCredential]
            [string] $result.Credential.GetNetworkCredential().Password | Should -BeExactly $script:secret
        }

        It 'appears in NOTHING this command returns except the credential itself' {
            # A deployment log is copied around far more freely than a password.
            $result = Get-HDTWizardCredential -DeployRoot $script:deployRoot `
                -UserId 'svc-hdt-deploy' -UserDomain 'CONTOSO' -Password (New-HDTWizardSecret) `
                -ContentProvider (New-HDTFakeContentProvider -Root $script:deployRoot)

            foreach ($field in @('UserName', 'Server', 'Message', 'UserId', 'UserDomain')) {
                [string] $result.$field | Should -Not -BeLike ('*{0}*' -f $script:secret) -Because (
                    '{0} must never carry the password' -f $field)
            }
        }

        It 'keeps the password out of the operation journal the provider recorded' {
            $provider = New-HDTFakeContentProvider -Root $script:deployRoot

            Get-HDTWizardCredential -DeployRoot $script:deployRoot `
                -UserId 'svc-hdt-deploy' -UserDomain 'CONTOSO' -Password (New-HDTWizardSecret) `
                -ContentProvider $provider | Out-Null

            (@($provider.Operations | ForEach-Object { $_.Operation + ' ' + ($_.Arguments -join ' ') }) -join ' ') |
                Should -Not -BeLike ('*{0}*' -f $script:secret)
        }
    }
}
