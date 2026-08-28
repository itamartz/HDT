function Split-HDTAccountName {
    <#
        .SYNOPSIS
            Splits an account a technician typed into the user and the domain
            it lives in.

        .DESCRIPTION
            ONE BOX ON THE SCREEN, TWO VARIABLES UNDERNEATH. The Computer
            Details page asked for the join account in two boxes because that is
            the shape of the two variables underneath - DomainAdmin and
            DomainAdminDomain, names carried over from MDT - and a technician
            joining a domain does not think in two boxes. They
            think CORP\svc-hdt-join, which is what every Windows credential
            prompt has ever asked them for.

            WHY THE SECOND BOX WAS RIGHT ELSEWHERE AND WRONG HERE.
            Get-HDTWizardCredential keeps UserDomain separate deliberately: for
            a SHARE, a blank domain means the account is LOCAL to the server, and
            a technician has to be able to say that without knowing the
            convention is to type a server name where a domain goes. Joining a
            domain has no such case - blank can only mean the domain being
            joined - so the second box was asking a question with one possible
            answer.

            BOTH FORMS, BECAUSE BOTH ARE TYPED. 'CORP\svc' is what a Windows
            logon prompt teaches; 'svc@corp.contoso.com' is what a UPN teaches.
            Refusing either would be this wizard telling a technician their own
            credential is malformed.

            THE BACKSLASH WINS WHEN SOMEHOW GIVEN BOTH. 'CORP\svc@corp.com' is
            not a form anything asks for, and preferring the at sign there would
            silently change WHICH domain authenticates the join.

            AN EMPTY DOMAIN IS AN ANSWER, NOT A GAP. It means the domain being
            joined, and that is resolved where the join happens - not guessed
            here, where the domain being joined is not in scope.

        .PARAMETER Name
            What the technician typed. 'CORP\svc', 'svc@corp.contoso.com' or a
            bare 'svc'.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with User and Domain.
            Either may be empty.

        .EXAMPLE
            Split-HDTAccountName -Name 'CORP\svc-hdt-join'

            User svc-hdt-join, Domain CORP.

        .EXAMPLE
            Split-HDTAccountName -Name 'svc-hdt-join'

            User svc-hdt-join, Domain empty - meaning the domain being joined.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $text = ([string] $Name).Trim()

    $user = ''
    $domain = ''

    if (-not [string]::IsNullOrWhiteSpace($text)) {

        $backslash = $text.IndexOf('\')

        if ($backslash -ge 0) {
            # THE FIRST SEPARATOR IS THE BOUNDARY. Nothing legitimate carries
            # two, but a paste can, and everything after the first one belongs
            # to the account rather than to the domain.
            $domain = $text.Substring(0, $backslash)
            $user = $text.Substring($backslash + 1)
        } else {
            $at = $text.IndexOf('@')

            if ($at -ge 0) {
                $user = $text.Substring(0, $at)
                $domain = $text.Substring($at + 1)
            } else {
                $user = $text
            }
        }
    }

    return [pscustomobject] @{
        User   = $user.Trim()
        Domain = $domain.Trim()
    }
}
