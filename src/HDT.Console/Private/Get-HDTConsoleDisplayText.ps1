function Get-HDTConsoleDisplayText {
    <#
        .SYNOPSIS
            Answers a stated fallback for a value the share did not supply.

        .DESCRIPTION
            AN EMPTY FIELD ON A SCREEN IS AMBIGUOUS. "Credential:" followed by
            nothing could mean the share names no credential, or that the console
            failed to read one, and an administrator cannot tell which. Every
            optional field the window shows therefore goes through here and comes
            back saying what the emptiness means.

        .PARAMETER Text
            The value, possibly empty or $null.

        .PARAMETER Fallback
            What to show instead when it is.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTConsoleDisplayText -Text $workspace.CredentialUser -Fallback '(none)'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Fallback
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Fallback
    }

    return $Text
}
