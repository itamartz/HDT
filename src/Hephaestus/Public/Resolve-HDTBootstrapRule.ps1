function Resolve-HDTBootstrapRule {
    <#
        .SYNOPSIS
            Chooses the deployment share from the machine's own facts, before it
            has connected to one.

        .DESCRIPTION
            ONE BOOT IMAGE, MANY SHARES - MDT's Bootstrap.ini, and the thing HDT
            could not do. The machine has already been gathered by the time this
            runs: it knows its default gateway, its MAC, its model and its UUID,
            and none of that needed a share. Those facts are what the rules match
            on, exactly as MDT's Priority=DefaultGateway, MACAddress does.

            THE FALLBACK IS WHAT THE IMAGE WAS BUILT WITH, which is MDT's
            [Default] DeployRoot. An image whose rules match nothing still
            deploys, from the share it was built for; an image with no rules at
            all behaves exactly as it did before this existed. Both of those
            matter more than the feature does.

            IT RESOLVES, IT DOES NOT CONNECT. What comes back is a decision and
            its provenance - which rule chose it, or that none did. Reaching the
            share, resolving a volume-relative path and authenticating are the
            caller's, and stay where they were.

            THE PROVENANCE IS THE POINT, as everywhere else in the variable
            engine: "the single biggest debugging pain in MDT is not knowing why
            HDTComputerName ended up as it did" applies twice over to a share,
            because a machine that reached the wrong one fails in a way that
            looks like a network fault.

        .PARAMETER RuleDocument
            What Import-HDTBootstrapRuleDocument returned, or $null when the
            image carries no such file - which is most of them.

        .PARAMETER Fact
            The gathered facts, from Get-HDTMachineFact.

        .PARAMETER DeployRoot
            What bootstrap.json says. Used when no rule chooses one.

        .OUTPUTS
            System.Management.Automation.PSCustomObject

              DeployRoot        the share to connect to
              Source            'Rule' or 'BootImage'
              RuleName          which rule chose it, '' when none did
              UserName          the account to open it with, composed as
                                DOMAIN\user - empty when no rule set one
              Password          that account's password, empty likewise
              CredentialSource  'Rule' or 'BootImage'
              Variable          everything the bootstrap rules resolved
              Provenance        where each of those came from

        .EXAMPLE
            $document = Import-HDTBootstrapRuleDocument -Path 'X:\HDT\bootstrap-rules.yaml'
            $fact = Get-HDTMachineFact
            $answer = Resolve-HDTBootstrapRule -RuleDocument $document -Fact $fact -DeployRoot '\\LAP-AMMSO01\HDTShare$'

            Works out which share this machine connects to before it can read any
            share. Everything else in HDT resolves against rules.yaml on the
            share; this one cannot.

        .EXAMPLE
            $answer.DeployRoot

            Where it will connect. -DeployRoot is the fallback the boot image was built
            with, and a rule that matches overrides it.

        .LINK
            Import-HDTBootstrapRuleDocument
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $RuleDocument,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Fact,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $DeployRoot
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $empty = [ordered] @{}

    if ($null -eq $RuleDocument) {
        return [pscustomobject] @{
            DeployRoot       = $DeployRoot
            Source           = 'BootImage'
            RuleName         = ''
            UserName         = ''
            Password         = ''
            CredentialSource = 'BootImage'
            Variable         = $empty
            Provenance       = $empty
        }
    }

    # THE SAME ENGINE, WITH TWO OF ITS FIVE SOURCES. There is no command line
    # here, no machine override to read (that file is on the share) and no
    # sequence to take defaults from - so a bootstrap resolution is rules over
    # facts, which is the same first-match-wins walk with the same %Var%
    # expansion and the same provenance record.
    $resolved = Resolve-HDTVariable -RuleDocument $RuleDocument -Fact $Fact

    $chosen = $DeployRoot
    $source = 'BootImage'
    $ruleName = ''

    if ($resolved.Variable.Contains('HDTDeployRoot')) {
        $candidate = [string] $resolved.Variable['HDTDeployRoot']

        # AN EMPTY ANSWER IS NOT AN ANSWER. A rule that resolved to '' would
        # otherwise disconnect the image from the share it was built for, which
        # is the one failure this feature must not be able to cause.
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $chosen = $candidate
            $source = 'Rule'

            if ($resolved.Provenance.Contains('HDTDeployRoot')) {
                $ruleName = [string] $resolved.Provenance['HDTDeployRoot'].Rule
            }
        }
    }

    # THE ACCOUNT, COMPOSED HERE SO THE PAYLOAD DECIDES NOTHING. MDT's
    # Bootstrap.ini carries UserID, UserDomain and UserPassword as three keys
    # and joins them at the point of use; a payload that did the joining would
    # be a payload with a rule in it.
    #
    # A DOMAIN IS OPTIONAL, because an account local to the file server has
    # none - 'CONTOSO\svc' and 'svc' are both answers, and 'svc' with an empty
    # domain must not become '\svc'.
    $userName = ''
    $password = ''
    $credentialSource = 'BootImage'

    if ($resolved.Variable.Contains('HDTUserId')) {
        $userId = [string] $resolved.Variable['HDTUserId']

        if (-not [string]::IsNullOrWhiteSpace($userId)) {
            $userName = $userId
            $credentialSource = 'Rule'

            if ($resolved.Variable.Contains('HDTUserDomain')) {
                $domain = [string] $resolved.Variable['HDTUserDomain']
                if (-not [string]::IsNullOrWhiteSpace($domain)) {
                    $userName = '{0}\{1}' -f $domain, $userId
                }
            }

            if ($resolved.Variable.Contains('HDTUserPassword')) {
                $password = [string] $resolved.Variable['HDTUserPassword']
            }
        }
    }

    return [pscustomobject] @{
        DeployRoot       = $chosen
        Source           = $source
        RuleName         = $ruleName
        UserName         = $userName
        Password         = $password
        CredentialSource = $credentialSource
        Variable         = $resolved.Variable
        Provenance       = $resolved.Provenance
    }
}
