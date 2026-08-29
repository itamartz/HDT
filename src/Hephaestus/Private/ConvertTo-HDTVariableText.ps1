function ConvertTo-HDTVariableText {
    <#
        .SYNOPSIS
            Renders a variable's value as the one line of text a person reads
            and a rule matches.

        .DESCRIPTION
            FOUND ON A LIVE MACHINE, IN ITS OWN RESOLVED-VARIABLE OUTPUT:

                HDTIPAddress = 'System.Object[]' (GatheredFact)

            which is a multi-homed machine's own addresses printed as the name
            of their type. The cause is the format operator: `'{1}' -f $name,
            $value, $source` builds an argument ARRAY, and an array argument
            NESTS rather than flattening, so {1} holds an Object[] and
            ToString() on one of those is 'System.Object[]'. The arguments after
            it shift too, so the source can be printed as the machine's second
            address.

            EVERY OTHER WAY OF WRITING IT IS ALSO WRONG, DIFFERENTLY. A [string]
            cast SPACE-joins ($OFS), and so does string interpolation - which is
            the exact incident Get-HDTUsableAddress exists for, where a payload
            split a space-joined array on commas and waited out a two-minute
            timeout for an address it was already holding. Three renderings of
            one value, none of them the one the rule engine substitutes.

            THE RULE ENGINE ALREADY HAD THE ANSWER, WRITTEN DOWN TWICE.
            Expand-HDTVariableToken comma-joins a list so %HDTDefaultGateway%
            substitutes '10.20.30.254,10.20.30.1', and Invoke-HDTApplyUnattendStep
            carried a copy of the same four lines under a comment saying it had
            to "or the two disagree about what a multi-valued variable is". This
            is that rendering held ONCE, so a fourth caller cannot invent a
            fifth answer.

            COMMA IS MDT'S SHAPE FOR THIS FACT, not a preference. ZTIGather.xml
            declares the gathered adapter settings as type="string":
            OSDAdapter0IPAddressList (line 195) is described "Comma delimited
            list of IPAddress Lists", and SubnetMask, Gateways and DNSServerList
            (196-199) the same way. MDT reserves type="list" - the shape that
            surfaces as Applications001, Applications002 - for authored inputs
            like Applications, DriverPaths and DomainOUs (lines 334-351), never
            for a gathered address. So the fact stays a LIST, because
            Test-HDTRuleMatch matches a list on any element and that is what
            lets `when: { HDTDefaultGateway: "10.20.30.1" }` fire on a machine
            whose second adapter carries it; only the TEXT is comma delimited.

            $null RENDERS AS $null, not as an empty string, exactly as
            ConvertTo-HDTComparableString does - the caller distinguishes "no
            such value" from "an empty value". An empty LIST renders as an empty
            string, because a machine with no IP-enabled adapter has the
            variable and it holds nothing.

        .PARAMETER Value
            The value to render. Any type; $null is allowed.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String, or $null for $null.

        .EXAMPLE
            ConvertTo-HDTVariableText -Value ([string[]] @('10.20.30.101', '10.20.30.102'))

            Returns '10.20.30.101,10.20.30.102' - the same text %HDTIPAddress%
            expands to, and never 'System.Object[]'.

        .LINK
            ConvertTo-HDTComparableString
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [object] $Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Value) {
        return $null
    }

    # A STRING IS ENUMERABLE AND IS NOT A LIST, and the guard is kept explicit
    # anyway: both call sites this replaces carried it, and a [string] slipping
    # into the list branch would comma-join its characters.
    if (($Value -is [System.Collections.IList]) -and -not ($Value -is [string])) {
        return (@(@($Value) | ForEach-Object { ConvertTo-HDTComparableString -Value $_ }) -join ',')
    }

    return (ConvertTo-HDTComparableString -Value $Value)
}
