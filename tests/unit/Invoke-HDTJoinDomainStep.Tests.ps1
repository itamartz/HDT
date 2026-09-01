# The JoinDomain step (DESIGN 4.2, DESIGN 4.5.3).
#
# THE STEP THAT SHOULD HAVE EXISTED ALL ALONG. The shipped Computer Details
# wizard page has collected HDTJoinDomain, HDTMachineObjectOU, HDTJoinWorkgroup,
# HDTDomainAdmin, HDTDomainAdminDomain and a DOMAIN ADMIN PASSWORD since the
# wizard shipped, and nothing consumed any of it: a technician filled that page
# in and the answers went nowhere. DESIGN 4.2 has listed JoinDomain among the v1
# step types since the design was written.
#
# THREE RULES IN THIS FILE MATTER MORE THAN THE REST.
#
#   1. THE PASSWORD REACHES NO LOG. A domain-join account has rights over every
#      machine in the estate; a local administrator password is one machine.
#      Asserted here per record and again over the whole artefact set in
#      tests/contract/JoinCredential.Contract.Tests.ps1.
#
#   2. A REDACTED PASSWORD IS NEVER TRIED. state.json redacts every secret
#      (SecretRedaction.Contract.Tests.ps1), so a JoinDomain step running in the
#      leg AFTER a reboot is handed the literal string '(set, not shown)' where
#      the password was. Handing that to a domain controller is a wrong-password
#      attempt, and a fleet deploying overnight would lock the join account out
#      of the whole estate by breakfast. The step must refuse before it calls
#      anything at all.
#
#   3. THE DOMAIN'S OWN WORDS COME BACK. "Join failed" is not a diagnosis. The
#      message the directory returned is what tells an administrator whether the
#      account is wrong, the OU does not exist or DNS cannot find a controller.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # A PASSWORD THAT LOOKS LIKE ONE AND IS NOT ONE. Realistic in shape so a
    # leak would be a realistic leak; obviously synthetic in content, because a
    # fixture that reads like a credential is a credential to the next person
    # grepping this repository.
    $script:password = 'MARKER-JOIN-Aa1!-not-a-real-password'

    $script:newStep = {
        param([string] $Name, [System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index          = 1
            Name           = $Name
            Type           = 'JoinDomain'
            TimeoutMinutes = 0
            Log            = $null
            Property       = $bag
        }
    }

    $script:newContext = {
        param($Domain, [System.Collections.IDictionary] $Variable, [string] $Level = 'Debug')

        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 9, 1, 10, 0, 0, [System.DateTimeKind]::Utc))

        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock -Domain $Domain

        $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $script:fileSystem -Clock $script:clock -Level $Level

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Variable) {
            foreach ($key in @($Variable.Keys)) { $bag[[string] $key] = $Variable[$key] }
        }

        $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'C:\Deploy' `
            -Variable $bag -Service $catalog -Log $log
        $context.SetStep(1, 'Join Domain', 'JoinDomain', 'C:\HDT\Logs\Steps\001-JoinDomain.log')

        return $context
    }

    # THE SHIPPED TEMPLATE'S OWN PROPERTY BAG, which is what an authored step
    # actually looks like: every value a %HDT% token, none of them literals.
    # A test that wrote 'corp.contoso.com' into domain: would never exercise the
    # expansion the real sequence depends on.
    $script:templateProperty = [ordered] @{
        domain     = '%HDTJoinDomain%'
        ou         = '%HDTMachineObjectOU%'
        workgroup  = '%HDTJoinWorkgroup%'
        userName   = '%HDTDomainAdmin%'
        userDomain = '%HDTDomainAdminDomain%'
    }

    # THE WIZARD'S ANSWERS, under exactly the names the shipped Computer Details
    # page collects. Any drift between this and wizard.yaml is the defect this
    # step exists to close.
    $script:wizardVariable = [ordered] @{
        HDTComputerName        = 'HDT-LAB-01'
        HDTJoinDomain          = 'corp.contoso.com'
        HDTMachineObjectOU     = 'OU=Workstations,DC=corp,DC=contoso,DC=com'
        HDTDomainAdmin         = 'svc-hdt-join'
        HDTDomainAdminDomain   = 'CORP'
        HDTDomainAdminPassword = $script:password

        # AND THE FALLBACK RULE'S WORKGROUP, WHICH IS ALWAYS THERE. New-HDTWorkspace
        # seeds HDTJoinWorkgroup: WORKGROUP into rules.yaml's Fallback rule, and
        # the wizard's domain answer does not remove it - so a real domain
        # deployment arrives here with BOTH set. See the precedence context.
        HDTJoinWorkgroup       = 'WORKGROUP'
    }

    $script:readLog = {
        return [string] $script:fileSystem.ReadAllText('C:\HDT\Logs\HDT.jsonl')
    }
}

Describe 'Invoke-HDTJoinDomainStep' {

    Context 'a step with nothing configured' {

        # THE CLOSED-SET CONTRACT, ASSERTED HERE TOO. StepContract.Tests.ps1
        # hands every type a minimal step and bare fakes; this says what THIS
        # type is supposed to do about it, which is refuse rather than throw.
        It 'fails rather than throwing when the property bag is empty' {
            $step = & $script:newStep 'Join Domain' $null
            $context = & $script:newContext (New-HDTFakeDomainService) $null

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
        }

        It 'names both variables an administrator could set, not one of them' {
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext (New-HDTFakeDomainService) ([ordered] @{})

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Message | Should -BeLike '*HDTJoinDomain*'
            $result.Message | Should -BeLike '*HDTJoinWorkgroup*'
        }

        It 'touches the machine not at all when it has nothing to do' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain ([ordered] @{})

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            @($domain.GetOperationName()) | Should -Not -Contain 'JoinDomain'
            @($domain.GetOperationName()) | Should -Not -Contain 'JoinWorkgroup'
        }
    }

    Context 'the service catalog' {

        It 'fails naming the missing service when the run carries no domain service' {
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $null $script:wizardVariable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*Domain*'
        }
    }

    Context 'joining the domain the wizard asked for' {

        It 'joins it' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($domain.GetOperationName()) | Should -Contain 'JoinDomain'
        }

        It 'joins the domain HDTJoinDomain names' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $join = @($domain.Operations | Where-Object { $_.Operation -eq 'JoinDomain' })[0]
            [string] $join.Arguments[0] | Should -BeExactly 'corp.contoso.com'
        }

        It 'puts the computer in the OU HDTMachineObjectOU names' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $join = @($domain.Operations | Where-Object { $_.Operation -eq 'JoinDomain' })[0]
            [string] $join.Arguments[1] | Should -BeExactly 'OU=Workstations,DC=corp,DC=contoso,DC=com'
        }

        # ONE BOX ON THE WIZARD, TWO VARIABLES UNDERNEATH, AND ONE ACCOUNT HERE.
        # The technician typed CORP\svc-hdt-join; Get-HDTWizardSummary split it
        # into HDTDomainAdmin and HDTDomainAdminDomain, and the join API wants it
        # back in one piece. ZTIDomainJoin.wsf composes exactly this string.
        It 'joins as DOMAIN\user, recomposed from the two variables the wizard split' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $join = @($domain.Operations | Where-Object { $_.Operation -eq 'JoinDomain' })[0]
            [string] $join.Arguments[2] | Should -BeExactly 'CORP\svc-hdt-join'
        }

        It 'joins as a bare account name when no account domain was given' {
            $variable = [ordered] @{}
            foreach ($key in @($script:wizardVariable.Keys)) { $variable[$key] = $script:wizardVariable[$key] }
            $variable['HDTDomainAdminDomain'] = ''

            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $variable

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $join = @($domain.Operations | Where-Object { $_.Operation -eq 'JoinDomain' })[0]
            [string] $join.Arguments[2] | Should -BeExactly 'svc-hdt-join'
        }

        It 'hands the password to the service' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $domain.LastPassword | Should -BeExactly $script:password
        }

        # AN EMPTY OU IS NOT AN OU. ZTIConfigure.xml marks MachineObjectOU
        # removeIfBlank="Self" for exactly this reason: an empty DN is not the
        # same request as no DN, and passing one asks the directory to create the
        # account in a container with no name.
        It 'passes no OU at all when HDTMachineObjectOU is unset' {
            $variable = [ordered] @{}
            foreach ($key in @($script:wizardVariable.Keys)) { $variable[$key] = $script:wizardVariable[$key] }
            $variable.Remove('HDTMachineObjectOU')

            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $variable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'

            $join = @($domain.Operations | Where-Object { $_.Operation -eq 'JoinDomain' })[0]
            [string] $join.Arguments[1] | Should -BeExactly ''
        }

        # THE TOKEN IS NOT THE VALUE. '%HDTMachineObjectOU%' left standing
        # because nothing set it is not a distinguished name, and a step that
        # passed it on would ask the directory for a container called
        # '%HDTMachineObjectOU%'. Expand-HDTVariableToken leaves an unresolved
        # token in place on purpose, so this has to be handled and not assumed.
        It 'treats an unresolved token as unset rather than as a value' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain ([ordered] @{
                    HDTJoinDomain          = 'corp.contoso.com'
                    HDTDomainAdmin         = 'svc-hdt-join'
                    HDTDomainAdminPassword = $script:password
                })

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'

            $join = @($domain.Operations | Where-Object { $_.Operation -eq 'JoinDomain' })[0]
            [string] $join.Arguments[1] | Should -BeExactly ''
            [string] $join.Arguments[2] | Should -BeExactly 'svc-hdt-join'
        }

        It 'records the domain, the OU and the account in Data' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            [string] $result.Data['domain'] | Should -BeExactly 'corp.contoso.com'
            [string] $result.Data['ou'] | Should -BeExactly 'OU=Workstations,DC=corp,DC=contoso,DC=com'
            [string] $result.Data['account'] | Should -BeExactly 'CORP\svc-hdt-join'
        }
    }

    Context 'a machine that is already a member' {

        It 'leaves it alone and completes' {
            $domain = New-HDTFakeDomainService -Membership @{ Domain = 'corp.contoso.com' }
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($domain.GetOperationName()) | Should -Not -Contain 'JoinDomain'
        }

        # A NETBIOS NAME IS NOT ITS DNS NAME, and Windows reports whichever it
        # feels like. ZTIDomainJoin.wsf matches with a case-insensitive substring
        # test - its own comment says "the requested NetBios Domain Name (EngSvc)
        # is not a subset of the actual DNS Domain (Engineering-Services...)".
        It 'recognises the domain by its short name as well as its FQDN' {
            $domain = New-HDTFakeDomainService -Membership @{ Domain = 'corp.contoso.com' }
            $variable = [ordered] @{}
            foreach ($key in @($script:wizardVariable.Keys)) { $variable[$key] = $script:wizardVariable[$key] }
            $variable['HDTJoinDomain'] = 'CORP'

            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $variable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($domain.GetOperationName()) | Should -Not -Contain 'JoinDomain'
        }

        It 'joins anyway when the machine is in a DIFFERENT domain' {
            $domain = New-HDTFakeDomainService -Membership @{ Domain = 'old.example.net' }
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($domain.GetOperationName()) | Should -Contain 'JoinDomain'
        }

        # A MACHINE ALREADY IN THE DOMAIN NEEDS NO CREDENTIAL, and must not be
        # refused for want of one. Leg 2 arrives with a redacted password
        # (see below); if a re-run of the step demanded one before it looked at
        # the machine, a machine that joined perfectly on the first attempt
        # would fail its own retry.
        It 'needs no password to notice that the machine is already a member' {
            $domain = New-HDTFakeDomainService -Membership @{ Domain = 'corp.contoso.com' }
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain ([ordered] @{
                    HDTJoinDomain = 'corp.contoso.com'
                })

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
        }
    }

    Context 'the credential' {

        It 'fails naming HDTDomainAdmin when no account was given' {
            $variable = [ordered] @{}
            foreach ($key in @($script:wizardVariable.Keys)) { $variable[$key] = $script:wizardVariable[$key] }
            $variable.Remove('HDTDomainAdmin')

            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $variable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*HDTDomainAdmin*'
            @($domain.GetOperationName()) | Should -Not -Contain 'JoinDomain'
        }

        It 'fails naming HDTDomainAdminPassword when no password was given' {
            $variable = [ordered] @{}
            foreach ($key in @($script:wizardVariable.Keys)) { $variable[$key] = $script:wizardVariable[$key] }
            $variable.Remove('HDTDomainAdminPassword')

            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $variable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*HDTDomainAdminPassword*'
            @($domain.GetOperationName()) | Should -Not -Contain 'JoinDomain'
        }
    }

    # ------------------------------------------------------------------------
    # THE ONE THAT WOULD LOCK OUT AN ESTATE.
    #
    # Save-HDTRunState writes '(set, not shown)' in place of every secret, and
    # the leg after a reboot rehydrates its whole variable bag from that file.
    # So a JoinDomain step in a State Restore group - which is where DESIGN 4.1
    # puts it, and where MDT puts its own - is handed that literal string where
    # the password was.
    #
    # Trying it is a wrong-password attempt against a privileged account, once
    # per machine, on every machine being built. A lab of forty overnight is a
    # lockout policy tripped forty times on the one account that can join
    # anything to the domain. Refusing is not a nicety here.
    # ------------------------------------------------------------------------
    Context 'a password that did not survive the reboot' {

        BeforeAll {
            # ASKED OF THE REDACTOR RATHER THAN WRITTEN OUT. If the marker ever
            # changes, this test follows it instead of quietly passing over a
            # string nothing produces any more.
            $script:module = Get-Module -Name 'Hephaestus'
            $script:redacted = [string] (& $script:module {
                    Protect-HDTSecretValue -Name 'HDTDomainAdminPassword' -Value 'anything'
                })
        }

        It 'produces a marker that is not the password, so this test is about something' {
            $script:redacted | Should -Not -BeNullOrEmpty
            $script:redacted | Should -Not -BeExactly $script:password
        }

        It 'refuses rather than joining' {
            $variable = [ordered] @{}
            foreach ($key in @($script:wizardVariable.Keys)) { $variable[$key] = $script:wizardVariable[$key] }
            $variable['HDTDomainAdminPassword'] = $script:redacted

            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $variable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
        }

        It 'calls the domain not once, which is the whole point' {
            $variable = [ordered] @{}
            foreach ($key in @($script:wizardVariable.Keys)) { $variable[$key] = $script:wizardVariable[$key] }
            $variable['HDTDomainAdminPassword'] = $script:redacted

            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $variable

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            @($domain.GetOperationName()) | Should -Not -Contain 'JoinDomain'
        }

        # THE MESSAGE NAMES THE CAUSE, NOT THE SYMPTOM. "The password is wrong"
        # would send an administrator to reset an account that is perfectly
        # fine. The cause is the reboot, and it is the same every time.
        It 'says the reboot is what lost it' {
            $variable = [ordered] @{}
            foreach ($key in @($script:wizardVariable.Keys)) { $variable[$key] = $script:wizardVariable[$key] }
            $variable['HDTDomainAdminPassword'] = $script:redacted

            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $variable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Message | Should -BeLike '*restart*'
            $result.Message | Should -BeLike '*HDTDomainAdminPassword*'
        }
    }

    Context 'a domain that refuses' {

        It 'fails' {
            $domain = New-HDTFakeDomainService -Failure @{
                JoinDomain = 'The specified domain either does not exist or could not be contacted.'
            }
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
        }

        It 'repeats what the domain actually said' {
            $domain = New-HDTFakeDomainService -Failure @{
                JoinDomain = 'The specified domain either does not exist or could not be contacted.'
            }
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Message | Should -BeLike '*could not be contacted*'
        }

        It 'names the domain it was trying to join' {
            $domain = New-HDTFakeDomainService -Failure @{ JoinDomain = 'access denied' }
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Message | Should -BeLike '*corp.contoso.com*'
        }

        # MDT'S OU RECOVERY, DERIVED. ZTIDomainJoin.wsf:157 retries a refused
        # join with an empty OU and says why: "The account *may* already exist in
        # a different OU." A pre-staged computer account in a container the
        # sequence does not name is the ordinary case in a managed directory,
        # and it fails the first attempt every time.
        It 'retries once without the OU when a join with one is refused' {
            $domain = New-HDTFakeDomainService -Failure @{ JoinDomain = 'the object already exists' } `
                -FailureCount @{ JoinDomain = 1 }

            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'

            $join = @($domain.Operations | Where-Object { $_.Operation -eq 'JoinDomain' })
            @($join).Count | Should -Be 2
            [string] $join[0].Arguments[1] | Should -Not -BeNullOrEmpty
            [string] $join[1].Arguments[1] | Should -BeExactly ''
        }

        It 'does not retry when there was no OU to drop' {
            $variable = [ordered] @{}
            foreach ($key in @($script:wizardVariable.Keys)) { $variable[$key] = $script:wizardVariable[$key] }
            $variable.Remove('HDTMachineObjectOU')

            $domain = New-HDTFakeDomainService -Failure @{ JoinDomain = 'access denied' }
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $variable

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            @($domain.Operations | Where-Object { $_.Operation -eq 'JoinDomain' }).Count | Should -Be 1
        }

        # AND THE MACHINE IS STILL THERE. A failed join leaves a working
        # workgroup machine somebody can log on to and fix; the step must not
        # leave it half-joined, renamed or unreachable. It changes nothing on
        # the way out.
        It 'leaves the machine in the membership it had' {
            $domain = New-HDTFakeDomainService -Failure @{ JoinDomain = 'access denied' }
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            [bool] $domain.Membership.PartOfDomain | Should -BeFalse
        }

        It 'writes the password into no log record, even in the refusal' {
            $domain = New-HDTFakeDomainService -Failure @{ JoinDomain = 'access denied' }
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            (& $script:readLog) | Should -Not -BeLike ('*{0}*' -f $script:password)
            [string] $result.Message | Should -Not -BeLike ('*{0}*' -f $script:password)
            ($result.Data.Values -join ' ') | Should -Not -BeLike ('*{0}*' -f $script:password)
        }
    }

    Context 'the workgroup half of the same page' {

        It 'joins the workgroup when that is what the technician chose' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Workgroup' $script:templateProperty
            $context = & $script:newContext $domain ([ordered] @{
                    HDTComputerName  = 'HDT-LAB-01'
                    HDTJoinWorkgroup = 'LABTEAM'
                })

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'

            $join = @($domain.Operations | Where-Object { $_.Operation -eq 'JoinWorkgroup' })[0]
            [string] $join.Arguments[0] | Should -BeExactly 'LABTEAM'
        }

        It 'needs no credential to do it' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Workgroup' $script:templateProperty
            $context = & $script:newContext $domain ([ordered] @{ HDTJoinWorkgroup = 'LABTEAM' })

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
        }

        It 'leaves a machine already in that workgroup alone' {
            $domain = New-HDTFakeDomainService -Membership @{ Workgroup = 'LABTEAM' }
            $step = & $script:newStep 'Join Workgroup' $script:templateProperty
            $context = & $script:newContext $domain ([ordered] @{ HDTJoinWorkgroup = 'LABTEAM' })

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($domain.GetOperationName()) | Should -Not -Contain 'JoinWorkgroup'
        }

        It 'takes a domain-joined machine out of its domain when a workgroup is asked for' {
            $domain = New-HDTFakeDomainService -Membership @{ Domain = 'old.example.net' }
            $step = & $script:newStep 'Join Workgroup' $script:templateProperty
            $context = & $script:newContext $domain ([ordered] @{ HDTJoinWorkgroup = 'LABTEAM' })

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($domain.GetOperationName()) | Should -Contain 'JoinWorkgroup'
        }

        It 'reports what the machine said when a workgroup change is refused' {
            $domain = New-HDTFakeDomainService -Failure @{ JoinWorkgroup = 'the workgroup name is invalid' }
            $step = & $script:newStep 'Join Workgroup' $script:templateProperty
            $context = & $script:newContext $domain ([ordered] @{ HDTJoinWorkgroup = 'LABTEAM' })

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*workgroup name is invalid*'
        }
    }

    # ------------------------------------------------------------------------
    # PRECEDENCE, AND WHY IT IS THE OPPOSITE OF MDT'S.
    #
    # ZTIDomainJoin.wsf:107 checks JoinWorkgroup FIRST and declines to join a
    # domain when it is set, because in MDT nothing sets JoinWorkgroup unless
    # somebody asked for a workgroup.
    #
    # IN HDT SOMETHING ALWAYS DOES. New-HDTWorkspace seeds
    # HDTJoinWorkgroup: WORKGROUP into rules.yaml's Fallback rule - MDT's
    # LiteTouch.wsf defaults the same property for the same reason - and the
    # wizard's domain answer does not remove it, because a Fallback rule and a
    # wizard answer are different sources and the wizard only writes what the
    # technician touched. So EVERY domain deployment arrives here with both set,
    # and MDT's precedence would mean HDT never joined a domain at all.
    #
    # The domain therefore wins, and the workgroup is what a machine gets when
    # no domain was asked for. Which is also what the shipped unattend mapping
    # does in MDT: ZTIConfigure.xml's JoinDomain mapping REMOVES JoinWorkgroup.
    # ------------------------------------------------------------------------
    Context 'a domain and a workgroup both set, which is every real deployment' {

        It 'joins the domain' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            @($domain.GetOperationName()) | Should -Contain 'JoinDomain'
            @($domain.GetOperationName()) | Should -Not -Contain 'JoinWorkgroup'
        }

        It 'says in the log that the workgroup was ignored, so nobody has to guess' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            (& $script:readLog) | Should -BeLike '*HDTJoinWorkgroup*'
        }
    }

    Context 'what an authored step can override' {

        It 'takes a domain written into the step over the variable' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' ([ordered] @{ domain = 'other.contoso.com' })
            $context = & $script:newContext $domain $script:wizardVariable

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $join = @($domain.Operations | Where-Object { $_.Operation -eq 'JoinDomain' })[0]
            [string] $join.Arguments[0] | Should -BeExactly 'other.contoso.com'
        }

        It 'takes an OU written into the step over the variable' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' ([ordered] @{
                    domain = '%HDTJoinDomain%'
                    ou     = 'OU=Kiosks,DC=corp,DC=contoso,DC=com'
                })
            $context = & $script:newContext $domain $script:wizardVariable

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $join = @($domain.Operations | Where-Object { $_.Operation -eq 'JoinDomain' })[0]
            [string] $join.Arguments[1] | Should -BeExactly 'OU=Kiosks,DC=corp,DC=contoso,DC=com'
        }

        # THE STEP CARRIES NO PASSWORD KEY AT ALL, and that is a decision rather
        # than an omission. sequence.yaml is displayed in a text box in the
        # console, quoted back in refusals and read by everyone who can read the
        # share; the variable route is redacted end to end by
        # Test-HDTSecretVariable and has been since the secret contract landed.
        It 'has no password property, so a domain credential cannot be authored into a sequence' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' ([ordered] @{
                    domain   = 'corp.contoso.com'
                    userName = 'svc-hdt-join'
                    password = 'NOT-READ-BY-THE-STEP'
                })
            $context = & $script:newContext $domain ([ordered] @{ HDTJoinDomain = 'corp.contoso.com' })

            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*HDTDomainAdminPassword*'
            @($domain.GetOperationName()) | Should -Not -Contain 'JoinDomain'
        }
    }

    Context 'what it writes to the log' {

        It 'names the domain and the account it joined as' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            $text = & $script:readLog
            $text | Should -BeLike '*corp.contoso.com*'
            $text | Should -BeLike '*svc-hdt-join*'
        }

        It 'writes the password nowhere' {
            $domain = New-HDTFakeDomainService
            $step = & $script:newStep 'Join Domain' $script:templateProperty
            $context = & $script:newContext $domain $script:wizardVariable

            $null = Invoke-HDTJoinDomainStep -Step $step -Context $context

            (& $script:readLog) | Should -Not -BeLike ('*{0}*' -f $script:password)
            [string] $script:fileSystem.ReadAllText('C:\HDT\Logs\HDT.log') |
                Should -Not -BeLike ('*{0}*' -f $script:password)
        }
    }
}

Describe 'Get-HDTJoinDomainStepDescription' {

    It 'names the domain the step joins' {
        $step = & $script:newStep 'Join Domain' ([ordered] @{ domain = 'corp.contoso.com' })

        Get-HDTJoinDomainStepDescription -Step $step | Should -BeLike '*corp.contoso.com*'
    }

    It 'names the workgroup when that is what the step does' {
        $step = & $script:newStep 'Join Workgroup' ([ordered] @{ workgroup = 'LABTEAM' })

        Get-HDTJoinDomainStepDescription -Step $step | Should -BeLike '*LABTEAM*'
    }

    It 'says something for a step with an empty bag' {
        $step = & $script:newStep 'Join Domain' $null

        Get-HDTJoinDomainStepDescription -Step $step | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-HDTJoinDomainStepTemplate' {

    It 'declares the type' {
        (Get-HDTJoinDomainStepTemplate) -join "`n" | Should -BeLike '*type: JoinDomain*'
    }

    # THE TEMPLATE IS THE DOCUMENTATION MOST PEOPLE READ. Every variable the
    # wizard collects has to appear in it, or an administrator adding the step
    # in the console gets a page that silently ignores half of what they typed
    # into the wizard.
    It 'names every variable the Computer Details page collects' -ForEach @(
        'HDTJoinDomain', 'HDTMachineObjectOU', 'HDTJoinWorkgroup',
        'HDTDomainAdmin', 'HDTDomainAdminDomain') {

        (Get-HDTJoinDomainStepTemplate) -join "`n" | Should -BeLike ('*{0}*' -f $PSItem)
    }

    It 'runs in the full OS, because a domain join needs a running Windows' {
        (Get-HDTJoinDomainStepTemplate) -join "`n" | Should -BeLike '*runIn: FullOS*'
    }

    It 'carries no password' {
        (Get-HDTJoinDomainStepTemplate) -join "`n" | Should -Not -BeLike '*HDTDomainAdminPassword*'
    }

    It 'takes a name of its own' {
        (Get-HDTJoinDomainStepTemplate -Name 'Join the corp domain') -join "`n" |
            Should -BeLike '*name: Join the corp domain*'
    }
}
