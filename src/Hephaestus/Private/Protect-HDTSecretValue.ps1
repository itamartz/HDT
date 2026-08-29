function Protect-HDTSecretValue {
    <#
        .SYNOPSIS
            A variable's value as it may be written down - itself, or the
            redaction when the name says it is a secret.

        .DESCRIPTION
            THE ONE FUNCTION EVERY WRITER CALLS. Give it the name and the value
            and write what comes back. A writer that decides for itself is the
            defect this exists to prevent - three of them already decided
            differently on the same run.

            THE NAME AND THE PROVENANCE STAY; ONLY THE VALUE GOES. "Which rule
            set the administrator password" is exactly what a log exists to
            answer, and dropping the entry would answer it with silence. The
            record keeps its name, its source, its rule and its file, and loses
            only the one field that must not travel.

            AND THE FACT THAT IT WAS SET SURVIVES. A redaction and an empty
            string read identically once written and mean opposite things - the
            second is a deployment with no password that is about to fail - so
            an empty value is returned untouched and a set one becomes
            "(set, not shown)". Those are the words Gather\provenance.json and
            the wizard's summary page already use; a second phrasing would make
            one redaction look like a different thing from the other.

        .PARAMETER Name
            The variable's name, which is what decides. Classification lives in
            Test-HDTSecretVariable and nowhere else.

        .PARAMETER Value
            What was resolved. Returned unchanged unless the name is a secret's.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Object - the value, or the redaction string.

        .EXAMPLE
            Protect-HDTSecretValue -Name 'HDTComputerName' -Value 'HDT-LAB-01'

            HDT-LAB-01. Nothing to hide, and a redacted computer name would make
            the log useless.

        .EXAMPLE
            Protect-HDTSecretValue -Name 'HDTAdminPassword' -Value 'whatever it is'

            (set, not shown)

        .EXAMPLE
            Protect-HDTSecretValue -Name 'HDTAdminPassword' -Value ''

            An empty string, unchanged. Nothing was set, and saying "(set, not
            shown)" about it would hide the reason the next step fails.

        .LINK
            Test-HDTSecretVariable
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Name,

        [Parameter(Position = 1)]
        [AllowNull()]
        [object] $Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not (Test-HDTSecretVariable -Name $Name)) {
        return $Value
    }

    if ($null -eq $Value) {
        return $Value
    }

    if ([string]::IsNullOrEmpty([string] $Value)) {
        return $Value
    }

    return '(set, not shown)'
}
