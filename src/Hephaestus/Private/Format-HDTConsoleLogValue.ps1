function Format-HDTConsoleLogValue {
    <#
        .SYNOPSIS
            One argument, rendered for the console log, with secrets removed.

        .DESCRIPTION
            THE CONSOLE LOG RECORDS THE COMMAND AS SOMEBODY COULD RETYPE IT,
            because 'Get-HDTConsoleDriverRow ran', eighty times, records that
            something happened rather than what. WHICH share, WHICH folder,
            WHICH sequence - those are the facts a report is rebuilt from.

            AND THE LOG LIVES ON THE SHARE, which every machine being deployed
            can read. The console is where HDTAdminPassword is set (DESIGN
            4.5.2), so a log that wrote values verbatim would put the local
            administrator password on a file the whole fleet can open. That is
            not a theoretical risk; it is the one secret this application
            handles.

            SO A SECRET IS SPOTTED TWO WAYS, because either alone leaks.

            BY NAME catches the ordinary case - anything matching pass, pwd,
            secret, credential, token, key or passphrase. BY TYPE catches a
            PSCredential or a SecureString handed under a name nobody thought
            of, which is exactly the one that would otherwise get through: the
            name list can only contain words somebody remembered.

            IT IS ITS OWN COMMAND SO IT CAN BE TESTED. This logic lived in a
            closure inside Get-HDTHandlerCall, where the only way to exercise it
            was to invoke a real command with a -Password parameter - and the
            tests written that way failed with "a parameter cannot be found
            that matches parameter name 'Password'", proving nothing at all
            about redaction. A private function takes any name and any value.

        .PARAMETER Name
            The parameter's name, which is what decides whether it is a secret.

        .PARAMETER Value
            What was passed.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String, ready to sit in a log line.

        .EXAMPLE
            Format-HDTConsoleLogValue -Name 'Root' -Value 'C:\HDTLab\Share'

            'C:\HDTLab\Share'

        .EXAMPLE
            Format-HDTConsoleLogValue -Name 'AdminPassword' -Value 'hunter2'

            <redacted>

        .LINK
            Get-HDTHandlerCall
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter(Position = 1)]
        [AllowNull()]
        [object] $Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Name -match '(?i)pass|pwd|secret|credential|token|\bkey\b|passphrase') { return '<redacted>' }

    if ($null -eq $Value) { return '$null' }

    # BY TYPE, whatever it was called. A credential under a name the list above
    # does not know is the leak the list cannot prevent.
    if ($Value -is [System.Management.Automation.PSCredential] -or
        $Value -is [System.Security.SecureString]) {
        return '<redacted>'
    }

    if ($Value -is [bool] -or $Value -is [System.Management.Automation.SwitchParameter]) {
        return ('${0}' -f ([bool] $Value).ToString().ToLowerInvariant())
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return ('@{{{0}}}' -f ((@($Value.Keys) | ForEach-Object { [string] $_ }) -join '; '))
    }

    # A STRING IS ENUMERABLE AND IS NOT A COLLECTION, which is the check that
    # has to come first or every path renders as '@(1 item(s))'.
    if ($Value -isnot [string] -and $Value -is [System.Collections.IEnumerable]) {
        return ('@({0} item(s))' -f @($Value).Count)
    }

    $text = [string] $Value

    # A LOG LINE IS READ, NOT PARSED. An .inf pasted into a parameter would
    # otherwise put a screenful into one entry and bury the eighty after it.
    if ($text.Length -gt 120) { $text = $text.Substring(0, 117) + '...' }

    return ("'{0}'" -f $text)
}
