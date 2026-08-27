function ConvertTo-HDTDriverVersion {
    <#
        .SYNOPSIS
            A driver's DriverVer version as something that sorts.

        .DESCRIPTION
            10.10 IS NEWER THAN 10.2, AND A STRING COMPARISON SAYS IT IS NOT.
            That is the whole reason this exists: driver versions are dotted
            numbers, they are compared as dotted numbers, and the tie-break in
            Get-HDTDriverMatch decides which of two packs claiming the same
            hardware id the machine actually gets. Sorting those as text puts
            an A02 pack ahead of an A10 one.

            A VERSION THAT WILL NOT PARSE SORTS LAST rather than throwing. A
            single vendor .inf with a version of 'NT_x86' - and they exist -
            must not take out the match for every other driver on the share.
            Last, not first, because an unreadable version is not evidence of
            being newer.

            [version] NEEDS TWO PARTS. '10' alone throws where '10.0' does not,
            so a single number is padded rather than rejected: a driver
            versioned '3' is a driver, not a parse failure.

        .PARAMETER Value
            The version as read out of the .inf, or anything else.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Version. [version]::new(0, 0) for anything unparseable.

        .EXAMPLE
            ConvertTo-HDTDriverVersion -Value '10.10.0.1'

        .EXAMPLE
            (ConvertTo-HDTDriverVersion -Value '10.10') -gt (ConvertTo-HDTDriverVersion -Value '10.2')

            True - which is the comparison the tie-break is made of.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $floor = New-Object -TypeName System.Version -ArgumentList 0, 0

    $text = ''
    if ($null -ne $Value) { $text = ([string] $Value).Trim() }

    if ([string]::IsNullOrEmpty($text)) { return $floor }

    if ($text -notmatch '\.') { $text = '{0}.0' -f $text }

    $parsed = $floor
    if ([System.Version]::TryParse($text, [ref] $parsed)) { return $parsed }

    return $floor
}
