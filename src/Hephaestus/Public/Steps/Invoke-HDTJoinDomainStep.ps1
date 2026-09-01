function Invoke-HDTJoinDomainStep {
    <#
        .SYNOPSIS
            Joins the deployed machine to a domain, or to a workgroup.

        .DESCRIPTION
            DESIGN 4.2's JoinDomain step, behind IDomainService so the whole step
            runs under Pester against a fake rather than against the developer's
            own machine and somebody's directory.

              - name: Join Domain
                type: JoinDomain
                domain: '%HDTJoinDomain%'
                ou: '%HDTMachineObjectOU%'
                workgroup: '%HDTJoinWorkgroup%'
                userName: '%HDTDomainAdmin%'
                userDomain: '%HDTDomainAdminDomain%'
                runIn: FullOS

            IT HAS NEVER JOINED A REAL DOMAIN. There is no domain controller in
            this lab and the isolated switch is isolated by design (ROADMAP M3),
            so every assertion about this step is made against a hand-written
            fake. That is stated here rather than left to be discovered: the
            logic is tested, the wire is not.

            THE VARIABLES ARE THE WIZARD'S, NOT NEW ONES. The shipped Computer
            Details page has collected HDTJoinDomain, HDTMachineObjectOU,
            HDTJoinWorkgroup, HDTDomainAdmin, HDTDomainAdminDomain and
            HDTDomainAdminPassword since the wizard shipped, and until this step
            existed nothing consumed any of them - a technician filled that page
            in and the answers went nowhere. This step reads exactly those names.

            IT JOINS ONLINE, IN THE FULL OS, AND THAT IS THE SECURITY DECISION.
            The other real option is an offline join written into the answer
            file's Microsoft-Windows-UnattendedJoin component, which is MDT's
            primary mechanism and PSD's only one. Three reasons not to:

              * THE CREDENTIAL WOULD BE ON THE DISK IN CLEAR. MDT's
                ZTIConfigure.wsf writes the password into the answer file's
                <Credentials> block and sets the parallel <PlainText> element to
                true. The file lands in Windows\Panther on the deployed machine,
                and MDT's own capture path strips AutoLogon, FirstLogonCommands
                and LocalAccounts out of it without stripping UnattendedJoin - so
                a reference image captured from a machine whose sequence set
                JoinDomain carries the domain password inside the .wim.
              * A FAILED OFFLINE JOIN IS SILENT. Windows writes it to
                NetSetup.LOG and boots anyway, so the deployment reports success
                and the machine is simply not a member. A step has a result.
              * DESIGN 4.5.3 NEEDS THE JOIN TO BE OBSERVABLE. The autologon
                identity is rewritten AFTER the join succeeds and before the next
                restart; an unattend join has no "after it succeeded".

            The tradeoff, stated plainly: an online join needs a reachable
            controller at the moment the step runs, and the machine has already
            booted as a workgroup member by then. A failure therefore leaves a
            WORKING, reachable, unjoined machine somebody can log on to and fix,
            which is the outcome to prefer over a half-configured one.

            THE DOMAIN WINS OVER THE WORKGROUP, WHICH IS THE OPPOSITE OF MDT.
            ZTIDomainJoin.wsf checks JoinWorkgroup first and declines to join a
            domain when it is set, because in MDT nothing sets it unless somebody
            asked for a workgroup. IN HDT SOMETHING ALWAYS DOES: New-HDTWorkspace
            seeds HDTJoinWorkgroup: WORKGROUP into rules.yaml's Fallback rule,
            and the wizard's domain answer does not remove it - a Fallback rule
            and a wizard answer are different sources, and the wizard writes only
            what the technician touched. So every real domain deployment arrives
            here with both set, and MDT's precedence would mean HDT never joined
            a domain at all. The workgroup is what a machine gets when no domain
            was asked for, and the log says so when both were.

            THERE IS NO PASSWORD PROPERTY, AND THAT IS DELIBERATE. sequence.yaml
            is printed into a text box in the console, quoted back in refusals,
            and stored on a share every machine being deployed can read. The
            password comes from HDTDomainAdminPassword in the variable bag, which
            Test-HDTSecretVariable has classified secret since the secret
            contract landed - so every log, checkpoint and report redacts it
            without this step having to ask.

            A REDACTED PASSWORD IS REFUSED WITHOUT BEING TRIED, and this is the
            most important refusal in the file. Save-HDTRunState writes
            '(set, not shown)' in place of every secret, and the leg after a
            restart rehydrates its whole variable bag from that file - so a
            JoinDomain step in a State Restore group, which is where DESIGN 4.1
            and MDT both put it, is handed that literal string. Trying it is a
            wrong-password attempt against a privileged account, once per
            machine, on every machine being built: a lab of forty overnight is a
            lockout policy tripped forty times on the one account that can join
            anything to the directory. DESIGN 4.5.2 already names this as open
            and names the durable answer - an LSA-carried secret bag written
            alongside each checkpoint - which is not built. Until it is, the
            password has to be set in the leg that uses it, and the refusal says
            so in words an administrator can act on.

            MDT'S OU RECOVERY IS DERIVED. A refused join is retried once with no
            OU, because a pre-staged computer account already living in a
            container the sequence does not name is the ordinary case in a
            managed directory and it fails the first attempt every time.
            ZTIDomainJoin.wsf does the same and says why: "The account *may*
            already exist in a different OU."

            RETRYING THE STEP IS THE ENGINE'S JOB, NOT THIS FILE'S. MDT counts
            its own attempts in a task sequence variable and reboots between
            them; HDT already has retry: on every step, so the template declares
            one rather than growing a second retry mechanism inside a step.

            SYSPREP AND CAPTURE: DO NOT JOIN A REFERENCE BUILD. MDT refuses to
            sysprep a domain-joined machine outright - LTISysprep.wsf reports
            failure 7002 on a DomainRole of 1, 3, 4 or 5 - and the shipped
            reference sequence here declares no JoinDomain step at all, which
            tests/contract/JoinCredential.Contract.Tests.ps1 asserts over every
            shipped sequence that captures.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry a
            Domain service.

        .OUTPUTS
            A New-HDTStepResult. Data carries the domain, the OU, the account and
            the workgroup - never the password.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock `
                -Domain (New-HDTDomainService)
            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\STD-CLIENT\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'JoinDomain' })[0]

            Invoke-HDTJoinDomainStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTJoinDomainStep -Step $step -Context $context
            $result.Message

            What the directory actually said. A refused join reports the domain's
            own sentence, because "join failed" sends an administrator to look at
            DNS when the account was wrong.

        .LINK
            New-HDTDomainService
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $property = $Step.Property

    $stepName = 'Join Domain'
    if ($null -ne $Step.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace([string] $Step.Name)) {
        $stepName = [string] $Step.Name
    }

    $fail = {
        param([string] $Message, [System.Collections.IDictionary] $Data)

        $payload = $Data
        if ($null -eq $payload) { $payload = [ordered] @{} }
        if (-not $payload.Contains('errorId')) { $payload['errorId'] = 'HDTConfigurationError' }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component 'JoinDomain' -Data $payload

        return (New-HDTStepResult -Status Failed -Message $Message -Data $payload)
    }

    # A VALUE FROM THE STEP, ELSE FROM THE VARIABLE THE WIZARD FILLED IN.
    #
    # AN UNRESOLVED TOKEN IS UNSET, NOT A VALUE, and that is the whole reason
    # this reads tokens rather than trusting the expansion. Every one of these
    # keys is legitimately absent on some machine - a workgroup deployment sets
    # no domain, most fleets set no OU - and Expand-HDTVariableToken leaves
    # '%HDTMachineObjectOU%' standing when nothing set it. Passed on, that asks
    # the directory for a container named after the token.
    $read = {
        param([string] $Name, [string] $VariableName)

        $written = ''

        if ($null -ne $property -and $property.Contains($Name)) {
            $written = ([string] $property[$Name]).Trim()
        }

        if ($written.Length -eq 0) {
            if (-not [string]::IsNullOrEmpty($VariableName) -and $Context.Variable.Contains($VariableName)) {
                $written = ([string] $Context.Variable[$VariableName]).Trim()
            }
        }

        if ($written.Length -eq 0) { return '' }

        $unresolved = New-Object -TypeName System.Collections.ArrayList
        $expanded = [string] (Expand-HDTVariableToken -Value $written -Scope $Context.Variable -Unresolved $unresolved)

        if (@($unresolved).Count -gt 0) { return '' }

        return $expanded.Trim()
    }

    $domainName = & $read 'domain' 'HDTJoinDomain'
    $organizationalUnit = & $read 'ou' 'HDTMachineObjectOU'
    $workgroupName = & $read 'workgroup' 'HDTJoinWorkgroup'
    $userName = & $read 'userName' 'HDTDomainAdmin'
    $userDomain = & $read 'userDomain' 'HDTDomainAdminDomain'

    # -- neither half of the page was answered --------------------------------

    if ([string]::IsNullOrWhiteSpace($domainName) -and [string]::IsNullOrWhiteSpace($workgroupName)) {
        return (& $fail ("step '{0}' has no domain and no workgroup to put this machine in. The wizard's Computer Details page fills HDTJoinDomain or HDTJoinWorkgroup; a share created by New-HDTWorkspace answers HDTJoinWorkgroup in its Fallback rule, so a run reaching this with neither set has had that rule removed or overridden." -f $stepName) `
            $null)
    }

    try {
        $domainService = $Context.Service.GetRequired('Domain', 'JoinDomain')
    } catch {
        return (& $fail ([string] $_.Exception.Message) $null)
    }

    try {
        $membership = $domainService.GetMembership()
    } catch {
        return (& $fail ("this machine's current domain membership could not be read, so the step cannot tell whether it needs to do anything: {0}" -f
                [string] $_.Exception.Message) $null)
    }

    # -- the workgroup half ---------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($domainName)) {

        $data = [ordered] @{ workgroup = $workgroupName }

        if (-not [bool] $membership.PartOfDomain -and
            [string]::Equals([string] $membership.Workgroup, $workgroupName, [System.StringComparison]::OrdinalIgnoreCase)) {

            $message = 'this machine is already in the workgroup {0}; leaving it alone.' -f $workgroupName

            Write-HDTLog -Context $Context.Log -Message $message -Component 'JoinDomain' -Data $data

            return (New-HDTStepResult -Status Completed -Message $message -Data $data)
        }

        try {
            $domainService.JoinWorkgroup($workgroupName)
        } catch {
            return (& $fail ("this machine could not be put in the workgroup {0}: {1}" -f
                    $workgroupName, [string] $_.Exception.Message) $data)
        }

        $message = 'this machine is now in the workgroup {0}.' -f $workgroupName

        Write-HDTLog -Context $Context.Log -Message $message -Event 'native.exec' `
            -Component 'JoinDomain' -Data $data

        return (New-HDTStepResult -Status Completed -Message $message -Data $data)
    }

    # -- the domain half ------------------------------------------------------

    # SAID OUT LOUD, BECAUSE THE ALTERNATIVE IS SOMEBODY READING rules.yaml AND
    # CONCLUDING THE STEP IS BROKEN. A share this module created answers
    # HDTJoinWorkgroup in its Fallback rule, so the value is nearly always there
    # beside a domain and is nearly always meaningless.
    if (-not [string]::IsNullOrWhiteSpace($workgroupName)) {
        Write-HDTLog -Context $Context.Log -Component 'JoinDomain' `
            -Message ("both a domain and a workgroup are set; joining the domain {0} and ignoring HDTJoinWorkgroup ({1}), which a share seeds in its Fallback rule." -f
                $domainName, $workgroupName) `
            -Data ([ordered] @{ domain = $domainName; workgroup = $workgroupName })
    }

    $data = [ordered] @{
        domain = $domainName
        ou     = $organizationalUnit
    }

    # ALREADY A MEMBER, AND THE COMPARISON IS DELIBERATELY NARROWER THAN MDT'S.
    # ZTIDomainJoin.wsf asks whether the requested name occurs ANYWHERE in the
    # reported one, which its own comment admits gets the NetBIOS-versus-DNS case
    # wrong in both directions; it then leans on the directory returning "already
    # joined" to recover. This matches on equality or on one being the other's
    # leading label - CORP and corp.contoso.com - and does no more, because a
    # needless re-join of the domain the machine is already in is harmless while
    # a needless SKIP leaves a machine nobody notices is unjoined.
    if ([bool] $membership.PartOfDomain) {
        $current = [string] $membership.Domain

        $sameDomain = (
            [string]::Equals($current, $domainName, [System.StringComparison]::OrdinalIgnoreCase) -or
            $current.StartsWith(($domainName + '.'), [System.StringComparison]::OrdinalIgnoreCase) -or
            $domainName.StartsWith(($current + '.'), [System.StringComparison]::OrdinalIgnoreCase)
        )

        if ($sameDomain) {
            $data['currentDomain'] = $current
            $message = 'this machine is already a member of {0}; leaving it alone.' -f $current

            Write-HDTLog -Context $Context.Log -Message $message -Component 'JoinDomain' -Data $data

            return (New-HDTStepResult -Status Completed -Message $message -Data $data)
        }

        $data['currentDomain'] = $current

        Write-HDTLog -Context $Context.Log -Severity Warning -Component 'JoinDomain' `
            -Message ('this machine is a member of {0} and the sequence asks for {1}; moving it.' -f $current, $domainName) `
            -Data $data
    }

    # -- the credential -------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($userName)) {
        return (& $fail ("step '{0}' joins {1} and names no account to join with. The wizard's Computer Details page fills HDTDomainAdmin; HDT will not attempt an anonymous join." -f
                $stepName, $domainName) $data)
    }

    # DOMAIN\user, PUT BACK TOGETHER. The wizard asks for the join account in one
    # box because that is what every Windows credential prompt has ever asked
    # for, and splits CORP\svc-hdt-join into two variables on the way in
    # (DESIGN 4.5.3). The join wants it in one piece again.
    $account = $userName
    if (-not [string]::IsNullOrWhiteSpace($userDomain)) {
        $account = '{0}\{1}' -f $userDomain, $userName
    }

    $data['account'] = $account

    $secret = ''
    if ($Context.Variable.Contains('HDTDomainAdminPassword')) {
        $secret = [string] $Context.Variable['HDTDomainAdminPassword']
    }

    if ([string]::IsNullOrWhiteSpace($secret)) {
        return (& $fail ("step '{0}' joins {1} as {2} and HDTDomainAdminPassword is not set. The wizard's Computer Details page collects it; a page skipped with HDTSkipComputerName is exempt from having to supply it, so a zero-touch run must set it another way." -f
                $stepName, $domainName, $account) $data)
    }

    # THE REFUSAL THAT SAVES AN ESTATE. See the header. The marker is ASKED OF
    # THE REDACTOR rather than written out here, so a change to what redaction
    # looks like cannot leave this comparing against a string nothing produces.
    $marker = [string] (Protect-HDTSecretValue -Name 'HDTDomainAdminPassword' -Value 'not the real value')

    if ([string]::Equals($secret, $marker, [System.StringComparison]::Ordinal)) {
        return (& $fail ("step '{0}' joins {1} as {2}, and the value it has for HDTDomainAdminPassword is the redaction '{3}' rather than a password. A secret does not survive a restart: the checkpoint redacts it and the leg after the restart rehydrates its variables from that file (DESIGN 4.5.2, which names an LSA-carried secret bag as the answer and records that it is not built). HDT has NOT attempted the join - one wrong-password attempt per machine would lock out the account that joins every machine in the estate. Set HDTDomainAdminPassword in the leg that runs this step, with a SetVariable step in the same group or a rule that resolves there." -f
                $stepName, $domainName, $account, $marker) $data)
    }

    # -- the join -------------------------------------------------------------

    Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component 'JoinDomain' `
        -Message ('joining {0} as {1}{2}' -f $domainName, $account,
            $(if ([string]::IsNullOrWhiteSpace($organizationalUnit)) { '' } else { (', into {0}' -f $organizationalUnit) })) `
        -Data $data

    $firstRefusal = ''

    try {
        $domainService.JoinDomain($domainName, $organizationalUnit, $account, $secret)

        $message = 'this machine is now a member of {0}, joined as {1}.' -f $domainName, $account

        Write-HDTLog -Context $Context.Log -Message $message -Event 'native.exec' `
            -Component 'JoinDomain' -Data $data

        return (New-HDTStepResult -Status Completed -Message $message -Data $data)
    } catch {
        $firstRefusal = [string] $_.Exception.Message
    }

    # MDT'S RECOVERY, DERIVED. ZTIDomainJoin.wsf retries a refused join with no
    # OU: "The account *may* already exist in a different OU." A pre-staged
    # computer object in a container the sequence does not name is the ordinary
    # case in a managed directory, and it refuses the first attempt every time.
    if ([string]::IsNullOrWhiteSpace($organizationalUnit)) {
        return (& $fail ("this machine could not be joined to {0} as {1}: {2}" -f
                $domainName, $account, $firstRefusal) $data)
    }

    $data['ouRetry'] = $true

    Write-HDTLog -Context $Context.Log -Severity Warning -Component 'JoinDomain' `
        -Message ("{0} refused the join into {1}: {2}. Retrying without the OU - a computer account that already exists somewhere else in the directory refuses the first attempt every time." -f
            $domainName, $organizationalUnit, $firstRefusal) `
        -Data $data

    try {
        $domainService.JoinDomain($domainName, '', $account, $secret)
    } catch {
        return (& $fail ("this machine could not be joined to {0} as {1}. Into {2}: {3}. Without an OU: {4}" -f
                $domainName, $account, $organizationalUnit, $firstRefusal, [string] $_.Exception.Message) $data)
    }

    $message = 'this machine is now a member of {0}, joined as {1} into the default computers container - {2} refused the OU {3}.' -f
    $domainName, $account, $domainName, $organizationalUnit

    Write-HDTLog -Context $Context.Log -Message $message -Event 'native.exec' `
        -Component 'JoinDomain' -Data $data

    return (New-HDTStepResult -Status Completed -Message $message -Data $data)
}
