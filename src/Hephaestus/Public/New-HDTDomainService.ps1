function New-HDTDomainService {
    <#
        .SYNOPSIS
            The real IDomainService: a thin adapter over Add-Computer and
            Win32_ComputerSystem.

        .DESCRIPTION
            The join port for the JoinDomain step (DESIGN 4.2). Rule 5 forbids
            engine logic from calling Add-Computer directly, so the step receives
            this object and can be handed New-HDTFakeDomainService in a test.

            IT IS BRANCH-LIGHT, WHICH IS WHY IT IS NOT UNIT TESTED (rule 1's
            adapter exception) - AND THERE IS NO SAFE WAY TO TEST IT ANYWAY. Two
            of its three methods change the domain membership of the machine they
            run on, and the machine in front of this code during development is a
            developer's own laptop. There is also no domain controller in this lab
            (ROADMAP M3), so THIS ADAPTER HAS NEVER JOINED A REAL DOMAIN. Every
            behavioural assertion about the interface lives on the fake.

            Every decision - which domain, whether the machine is already a
            member, whether to retry without the OU, whether there is a usable
            password at all - is made by the step. This projects two cmdlets.

            THE PASSWORD IS NEVER ON A COMMAND LINE, and that is the reason this
            file calls Add-Computer in-process rather than shelling out to one of
            the external join tools. Nothing redacts Win32_Process.CommandLine:
            every local account on the machine can read it while the process
            lives, and the account this password belongs to can create computer
            objects in the directory. MDT reached the same answer by a different
            route - ZTIDomainJoin.wsf passes the password as an argument to
            Win32_ComputerSystem.JoinDomainOrWorkgroup and shells nothing.

            tests/contract/JoinCredential.Contract.Tests.ps1 SCANS THIS FILE AS
            RAW TEXT for the names of those tools, comments included, which is
            the same crude and permanent shape StepContract.Tests.ps1 uses for
            the step files - so this comment names none of them. That is the cost
            of a grep nobody can argue their way past, and it is worth paying.

            THE SECURESTRING CONVERSION HAPPENS HERE, AT THE LAST POSSIBLE
            MOMENT, and the interface does not pretend the value was ever secret:
            it arrives from the variable bag as a string, exactly as
            HDTAdminPassword does (DESIGN 4.5.2). Add-Computer requires a
            PSCredential, so the conversion is the adapter's business rather than
            a fiction maintained up the call stack.

            ADD-COMPUTER ALWAYS SETS NETSETUP_ACCT_CREATE, which is MDT's first
            attempt (JoinDomainOrWorkgroup with options 3 - "(1)Join Domain +
            (2)Create"). MDT's second attempt drops that bit as well as the OU;
            Add-Computer offers no way to drop it, and it does not need to - the
            join reuses an existing computer account rather than failing on one.
            The half that matters is dropping the OU, and the STEP does that by
            calling this method a second time with an empty one.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every call
            is appended to it as well as to $Operations.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject carrying GetMembership,
            JoinDomain and JoinWorkgroup, plus Operations, GetOperationName and
            ServiceName.

        .EXAMPLE
            $domain = New-HDTDomainService
            $domain.GetMembership()

            What the machine says about itself, read before anything is changed.

        .EXAMPLE
            @($domain.GetOperationName())

            The order it was asked to work in. A membership read with no join
            after it is the step deciding the machine was already where it
            belongs.

        .LINK
            Invoke-HDTJoinDomainStep
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds the service object; joining is done by the caller through it, and the step that calls it refuses an ambiguous target.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'The join password arrives from the variable bag as a string, exactly as HDTAdminPassword does (DESIGN 4.5.2): a value WinPE and an unattended full-OS leg must use with no human present cannot be protected by a key that also ships on the share. Add-Computer requires a PSCredential, so the conversion happens here, at the last possible moment, rather than the interface pretending the value was ever secret. The real controls are the ones asserted in JoinCredential.Contract.Tests.ps1 - it reaches no log, no command line and no answer file.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'The JoinDomain method takes the account and the password as two strings because that is what it is handed: the values come out of the variable bag, where DESIGN 4.5.2 keeps them as text. A PSCredential up the call stack would be unwrapped again on every call and protect nothing - and the conversion Add-Computer actually needs happens here, at the last possible moment. The real controls are asserted in JoinCredential.Contract.Tests.ps1.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'Same reason: the value arrives as text from the variable bag and a SecureString here would be converted back inside this process anyway. See the comment above.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'DomainService'
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # DomainRole IS CARRIED ALONGSIDE PartOfDomain because they are the two
    # readings of one fact and different code reads different ones: MDT's
    # IsMemberOfDomain switches on DomainRole (0 and 2 stand alone; 1, 3, 4 and 5
    # are joined) while LTISysprep.wsf's refusal reads the same values. Handing
    # both up means the step never has to translate between them.
    $service | Add-Member -MemberType ScriptMethod -Name GetMembership -Value {
        $this.Record('GetMembership', @())

        $system = Get-CimInstance -ClassName Win32_ComputerSystem

        return [pscustomobject] @{
            ComputerName = [string] $system.Name
            Domain       = [string] $system.Domain
            Workgroup    = [string] $system.Workgroup
            DomainRole   = [int] $system.DomainRole
            PartOfDomain = [bool] $system.PartOfDomain
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name JoinDomain -Value {
        param([string] $Domain, [string] $OrganizationalUnit, [string] $UserName, [string] $Password)

        # THE PLACEHOLDER, NOT THE VALUE. The journal is written into artefacts.
        $this.Record('JoinDomain', @($Domain, $OrganizationalUnit, $UserName, '<password>'))

        $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @(
            $UserName,
            (ConvertTo-SecureString -String $Password -AsPlainText -Force)
        )

        $parameter = @{
            DomainName  = $Domain
            Credential  = $credential
            Force       = $true
            ErrorAction = 'Stop'
        }

        # AN EMPTY OU IS NOT AN OU. Passing one asks the directory to create the
        # computer object in a container with no name; omitting it asks for the
        # domain's default, which is what "no OU was specified" means. MDT's
        # answer file mapping marks MachineObjectOU removeIfBlank="Self" for
        # exactly this reason.
        if (-not [string]::IsNullOrWhiteSpace($OrganizationalUnit)) {
            $parameter['OUPath'] = $OrganizationalUnit
        }

        Add-Computer @parameter | Out-Null
    }

    $service | Add-Member -MemberType ScriptMethod -Name JoinWorkgroup -Value {
        param([string] $Workgroup)

        $this.Record('JoinWorkgroup', @($Workgroup))

        Add-Computer -WorkgroupName $Workgroup -Force -ErrorAction Stop | Out-Null
    }

    return $service
}
