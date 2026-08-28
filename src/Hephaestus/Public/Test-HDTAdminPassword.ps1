function Test-HDTAdminPassword {
    <#
        .SYNOPSIS
            Judges the local Administrator password a technician typed.

        .DESCRIPTION
            Compares a local Administrator password against its confirmation
            and answers with one judgement object - IsValid, Severity and
            Reason - in the shape the technician wizard paints: Severity
            colours the message, IsValid opens the Next button. It throws
            nothing and prints nothing.

            It takes two values because a password box shows dots, so the only
            way to know what was typed is to type it twice. The confirmation
            box is what catches a typo that would otherwise surface as a
            machine nobody can log into. (MDT administrators know this screen
            as the Administrator Password pane.)

            The complaints come in the order a page is filled in: a missing
            password first, then a mismatch. An empty page opening with "the
            passwords do not match" is true and useless, because nothing has
            been typed yet.

            It never echoes the password, and that is not a style choice. The
            Reason is painted on a screen that gets photographed and written to
            Console.log, so nothing returned here carries the value - not the
            Reason, not a property, not a length.

            It judges what was typed and nothing else. DESIGN 4.5.2 settles the
            policy - "the administrator sets the password; HDT does not invent
            one" - so there is no default, and no strength rule either: the
            domain's policy decides what is strong enough, and a second opinion
            in WinPE would refuse passwords the domain accepts.

        .PARAMETER Password
            What was typed in the password box.

        .PARAMETER Confirmation
            What was typed in the confirmation box. Not named Confirm: that is
            a reserved common parameter and would bind to ShouldProcess.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            PSCustomObject with IsValid, Severity and Reason.

        .EXAMPLE
            Test-HDTAdminPassword -Password $box.Password -Confirmation $confirmBox.Password

            Judges the pair, for the wizard's Next button.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Password,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string] $Confirmation = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $answer = [ordered] @{
        IsValid  = $false
        Severity = 'Error'
        Reason   = ''
    }

    # A PASSWORD OF SPACES IS A PASSWORD NOBODY CAN TYPE TWICE ON PURPOSE, and
    # Windows would accept it - leaving a machine on the network whose local
    # administrator password is four spaces.
    if ([string]::IsNullOrWhiteSpace($Password)) {
        $answer['Reason'] = 'an administrator password is required. Windows would accept a blank one and leave this machine on the network with no password on its local Administrator.'
        return [pscustomobject] $answer
    }

    # ORDINAL, NOT CULTURE. Two strings that a culture considers equal are not
    # the same password, and Windows compares the bytes.
    if (-not [string]::Equals($Password, $Confirmation, [System.StringComparison]::Ordinal)) {
        $answer['Reason'] = 'the two passwords do not match. Type the same password in both boxes.'
        return [pscustomobject] $answer
    }

    $answer['IsValid'] = $true
    $answer['Severity'] = 'Information'

    return [pscustomobject] $answer
}
