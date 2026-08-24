function ConvertTo-HDTIcaclsRight {
    <#
        .SYNOPSIS
            Turns a right this toolkit grants into the permission string icacls
            takes.

        .DESCRIPTION
            THE BRANCH THAT MAY NOT LIVE IN THE ADAPTER. Hard rule 1 exempts a
            thin adapter over an external tool from having a test, and pays for
            that by requiring it to stay branch-free. A right-name mapping is a
            branch, so it lives here - where it is unit tested - and
            New-HDTFileSystem's GrantAccess calls it.

            (OI)(CI) IS WHAT MAKES A GRANT REACH THE FILES. Granted without the
            pair, a right applies to the folder object and nothing inside it: the
            deployment account can list the share root and open not one document
            in it. docs/share-account.md carries both flags on every row for the
            same reason, and this is that table in code.

            THE SET IS CLOSED, AND FullControl IS NOT IN IT. Test-HDTShareAcl
            reports FullControl anywhere on a deployment share as Critical - an
            account holding it is the exposure the checker exists to catch - so a
            command able to grant it would hand out the finding it later warns
            about. Write is absent for a smaller reason: the posture the checker
            judges names Modify, and two spellings of nearly the same thing
            invite an ACL that reads as one and was meant as the other.

        .PARAMETER Right
            The right to grant: Read or Modify. Matched without regard to case,
            because a caller types the word rather than a token.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the icacls permission, inheritance flags included.

        .EXAMPLE
            ConvertTo-HDTIcaclsRight -Right 'Read'

            (OI)(CI)(RX) - read and execute, inherited by the folders and files
            below.

        .EXAMPLE
            ConvertTo-HDTIcaclsRight -Right 'Modify'

            (OI)(CI)(M) - what Logs\ and Captures\ need, and the only two folders
            on a deployment share that should have it.

        .LINK
            New-HDTFileSystem

        .LINK
            Test-HDTShareAcl
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Right
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $token = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    $token['Read'] = '(OI)(CI)(RX)'
    $token['Modify'] = '(OI)(CI)(M)'

    if (-not $token.Contains($Right)) {
        throw [System.ArgumentException]::new(
            ("'{0}' is not a right this toolkit grants on a deployment share. It grants {1} - and deliberately not FullControl, which Test-HDTShareAcl reports as Critical wherever it finds it." -f
                $Right, (@($token.Keys) -join ' or ')), 'Right')
    }

    return [string] $token[$Right]
}
