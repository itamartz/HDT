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
            machine nobody can log into.

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

            AND NO CHARACTER RULE, WHICH IS A DECISION RATHER THAN AN OMISSION.
            The password ends up in an XML answer file, so & < > " and ' have to
            survive the trip - and for a while they did not, because the only
            thing protecting the document was the ALPHABET of a command that
            minted passwords. New-HDTDeploymentPassword excluded those five
            characters and the per cent sign on purpose. That command is gone,
            deleted when DESIGN 4.5.2 settled that HDT does not invent
            passwords, and its guarantee went with it while the substitution
            stayed unescaped: 'Pa&ss' produced an answer file Windows Setup
            could not parse, on a machine with the OS already on the disk.

            The fix belongs at substitution, and that is where it is -
            Invoke-HDTApplyUnattendStep escapes every value it puts into the
            document. Refusing the password here instead would protect one
            value out of ten and turn a legal Windows password into a refusal a
            technician cannot argue with, at a bench, holding a password their
            domain requires. Escaping costs nothing and covers the organisation
            name in the same line.

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
            Test-HDTAdminPassword -Password 'Pa$$w0rd!' -Confirmation 'Pa$$w0rd!'

            IsValid  : True
            Severity : Information
            Reason   :

            A matching pair. The wizard opens its Next button on IsValid.

        .EXAMPLE
            Test-HDTAdminPassword -Password 'Pa$$w0rd!' -Confirmation 'Pa$$w0rd'

            IsValid  : False
            Severity : Error
            Reason   : the two passwords do not match. Type the same password in both boxes.

            A typo in the second box, which is the case the confirmation box
            exists to catch. The Reason never quotes either value - it is
            painted on screen and written to the log.
    #>
    # A SecureString HERE WOULD BE THEATRE, and it would not work. The value
    # arrives from a WPF PasswordBox, whose Password property is already a
    # plain String - so converting it would protect nothing that was not
    # already in memory in the clear, and the two values still have to be
    # compared character for character to answer the only question this asks.
    # The unattend the answer ends up in is plain text as well.
    #
    # Set-HDTAutoLogon, New-HDTSmbService and Protect-HDTShareSecret carry the
    # same suppression for the same reason.
    # ONLY Password IS SUPPRESSED, because only Password is flagged - the rule
    # matches the NAME, and Confirmation is not one of the words it looks for.
    # A suppression with no matching diagnostic is itself an analyzer error:
    # "Cannot find any DiagnosticRecord with the Rule Suppression ID".
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'The value comes from a PasswordBox as a String and is compared, not stored; a SecureString would protect nothing and could not be compared.')]
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
    # ONE LINE, BECAUSE THE RAIL GIVES IT ONE. The message sits in a narrow
    # column beside the buttons; the first version of this sentence explained
    # that Windows would accept a blank password and leave the machine on the
    # network without one, and it rendered as four cramped lines under the
    # Cancel button. That reasoning is in the help above, where the next person
    # to change this will read it and a technician at a bench will not.
    if ([string]::IsNullOrWhiteSpace($Password)) {
        $answer['Reason'] = 'an administrator password is required.'
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
