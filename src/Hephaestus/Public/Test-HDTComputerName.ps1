function Test-HDTComputerName {
    <#
        .SYNOPSIS
            Judges a computer name against the limit Windows enforces silently.

        .DESCRIPTION
            DESIGN 4.5's rule, and the length half of it exists because of a
            real deployment. rules.yaml built HDTComputerName from a Hyper-V
            serial number, the result was 35 characters, and WINDOWS SETUP
            DISCARDED IT WITHOUT COMPLAINT - every step reported Completed, the
            run reported Succeeded, and the machine came up called
            WIN-N91191NN153 (SPIKES S9.11). That is the worst shape a defect can
            take: nothing anywhere said a word.

            SO THE RULE IS ENFORCED WHERE THE VALUE IS ENTERED AND WHERE IT IS
            APPLIED. Invoke-HDTApplyUnattendStep refuses it as the name is about
            to become a machine's identity; the wizard refuses it as a
            technician types it. Two callers, ONE COPY OF THE RULE - it was
            inline in the step until the wizard needed it, and a rule with two
            copies is a rule that drifts.

            TWO RULES, AND THE DIFFERENCE BETWEEN THEM IS THE POINT.

            NetBIOS FORBIDS TEN CHARACTERS AND ONLY TEN:

                .  \  /  :  *  ?  "  <  >  |

            Those are refused. A space is refused with them - it is not on
            Microsoft's list because a computer name cannot contain one at all,
            and a trailing space is invisible in every place a technician would
            look for it.

            DNS IS STRICTER THAN NetBIOS, and a name can be a perfectly legal
            NetBIOS name that DNS cannot carry. An underscore is the everyday
            case: HDT_01 is legal, and misbehaves on domain join and DNS
            registration. So anything outside letters, digits and hyphens is
            ACCEPTED AND FLAGGED - IsDnsSafe false, Severity 'Warning'. A
            warning states a real consequence; a refusal would state a rule that
            does not exist, in front of a technician who has read Microsoft's
            list.

            THIS REPLACED A STRICTER RULE, and DESIGN 4.5 was updated to match
            rather than being quietly diverged from. The old one refused
            anything but letters, digits and hyphens, which conflated the two
            rules above and refused legal names.

            IT DOES NOT TRUNCATE, AND MUST NEVER LEARN TO. A silently shortened
            name is the same failure this rule exists to stop, with a different
            spelling. The name comes back exactly as it was handed over.

            ONE MESSAGE AT A TIME, WORST FIRST: empty, then too long, then an
            illegal character, then the DNS warning. A technician can act on
            one; a list of everything wrong with a half-typed name is noise.

        .PARAMETER Name
            The proposed computer name.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with:

              IsValid     the name may be used. False only for a real refusal.
              IsDnsSafe   letters, digits and hyphens only.
              Severity    'None', 'Warning' or 'Error'.
              Reason      what to tell the technician. Empty when Severity is
                          'None'.
              Name        exactly what was handed in. Never repaired.

        .EXAMPLE
            Test-HDTComputerName -Name 'HDT-01'

            IsValid true, IsDnsSafe true, Severity None.

        .EXAMPLE
            Test-HDTComputerName -Name 'HDT_01'

            IsValid TRUE, IsDnsSafe false, Severity Warning - a legal NetBIOS
            name that DNS cannot carry.

        .EXAMPLE
            $judgement = Test-HDTComputerName -Name $typed
            $message.Text = $judgement.Reason
            $next.IsEnabled = $judgement.IsValid

            What the wizard does on every keystroke.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # MICROSOFT'S LIST, AND A SPACE. The ten are the documented NetBIOS
    # refusals; the space is here because a computer name cannot contain one and
    # a trailing space is invisible everywhere a technician would look for it.
    $forbidden = @('.', '\', '/', ':', '*', '?', '"', '<', '>', '|', ' ')

    $answer = [ordered] @{
        IsValid   = $false
        IsDnsSafe = $false
        Severity  = 'Error'
        Name      = [string] $Name
        Reason    = ''
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $answer['Reason'] = 'a computer name is required.'
        return [pscustomobject] $answer
    }

    # 15 IS THE NETBIOS LIMIT, and it is a limit rather than the first refusal -
    # a name of exactly 15 is fine.
    if ($Name.Length -gt 15) {
        $answer['Reason'] = ('the computer name ''{0}'' is {1} characters. Windows Setup silently ignores a ComputerName over 15 and names the machine itself, so the deployment would appear to succeed and produce a machine nobody named.' -f
            $Name, $Name.Length)
        return [pscustomobject] $answer
    }

    # NAMED, NOT JUST DETECTED. "contains an illegal character" leaves the
    # technician hunting through their own typing for it.
    foreach ($character in $forbidden) {
        if ($Name.Contains($character)) {

            $shown = $character
            if ($character -eq ' ') { $shown = 'a space' } else { $shown = ('''{0}''' -f $character) }

            $answer['Reason'] = ('a computer name cannot contain {0}. These are not allowed: . \ / : * ? " < > | or spaces.' -f $shown)
            return [pscustomobject] $answer
        }
    }

    # LEGAL. What is left is whether DNS can carry it, which is a warning and
    # never a refusal - see the header.
    $answer['IsValid'] = $true

    if ($Name -notmatch '^[A-Za-z0-9\-]+$') {
        $answer['Severity'] = 'Warning'
        $answer['Reason'] = ('''{0}'' is a legal computer name, but it is not a valid DNS name - only letters, digits and hyphens are. Domain join and DNS registration may misbehave.' -f $Name)
        return [pscustomobject] $answer
    }

    $answer['IsDnsSafe'] = $true
    $answer['Severity'] = 'None'
    return [pscustomobject] $answer
}
