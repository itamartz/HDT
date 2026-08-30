function Format-HDTRegistryLogValue {
    <#
        .SYNOPSIS
            A registry value as the log may print it - itself, a visible
            redaction, or a generous prefix of something far too long.

        .DESCRIPTION
            WHAT THE REGISTRY ADAPTER WRITES, AND THE REASON IT IS NOT IN THE
            ADAPTER. New-HDTRegistryService is a thin adapter over the registry
            provider and is deliberately branch-free, because it is not unit
            tested (CLAUDE.md rule 1); every decision about what a write may say
            about itself lives here instead, where a Pester test can reach it
            without a registry to write to.

            THREE OUTCOMES, AND EACH ONE IS SAID OUT LOUD.

            SHOWN. The ordinary case, and the one the old adapter got wrong: it
            logged name, type and length and never the value, so
            "registry value 'Make' ... was written as String (9 character(s))"
            was every registry write in the engine. The value is the fact an
            administrator is reading the line for.

            REDACTED, VISIBLY. Test-HDTSecretRegistryValue says the name is a
            secret's, or the caller marked the value with Sensitive. The value
            is replaced by "<redacted, 12 character(s)>" - never by silence and
            never by a blank, because a blank is indistinguishable from a value
            that was empty or absent, and those mean opposite things about the
            machine. The length survives, which is the diagnostic that matters
            when an autologon fails: a password of the wrong length is a
            different fault from no password at all.

            TRUNCATED, GENEROUSLY. A REG_BINARY or a multi-kilobyte string would
            swamp the record around it, so the display stops at 512 characters
            and says how many there were in all. 512 rather than 80 because the
            logging rule is "write too much, never too little" - a value is
            shown whole until it would cost the reader the lines around it.

            REDACTION COMES FIRST. A long secret is never half-shown: it is
            withheld and the length reported, and no prefix of it appears.

            AN EMPTY VALUE IS "<empty>" AND A NULL ONE IS "<null>", which are
            different facts about the write - DefaultDomainName written as an
            empty string is DESIGN 4.5.3's "the local machine", and it is not
            the same event as a caller passing nothing at all.

        .PARAMETER Name
            The registry value name, which is what decides whether the value is
            a secret's. Classification lives in Test-HDTSecretRegistryValue and
            nowhere else.

        .PARAMETER Value
            What was written.

        .PARAMETER Sensitive
            The caller's own word that this value is a secret, whatever it is
            called. It marks a value; there is no switch that un-marks one the
            classifier already refused.

        .INPUTS
            None. This command does not accept pipeline input.

            SENTENCE IS WHAT THE ADAPTER PRINTS, and Display is the value half
            of it. They are separate because the length belongs beside an
            ordinary value - "'Dell Inc.' (9 character(s))" - and is already
            inside the redaction, so an adapter appending it unconditionally
            would write "<redacted, 19 character(s)> (19 character(s))". Saying
            it once is a branch, and the branch belongs here.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Sentence (the whole
            phrase a log line puts after the '='), Display (the value on its
            own), Redacted, Truncated and Length (the full length, before any
            truncation).

        .EXAMPLE
            (Format-HDTRegistryLogValue -Name 'Make' -Value 'Dell Inc.').Display

            'Dell Inc.' - quoted, in full, which is the whole point of the
            change this function exists for.

        .EXAMPLE
            (Format-HDTRegistryLogValue -Name 'DefaultPassword' -Value 'whatever it is').Display

            <redacted, 15 character(s)> - the length is a real diagnostic and
            the value never reaches a file that ends up on the share.

        .LINK
            Test-HDTSecretRegistryValue
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
        [object] $Value,

        [Parameter()]
        [switch] $Sensitive
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # HOW MUCH OF A VALUE FITS IN A LOG LINE. Generous on purpose; see the
    # description. A DWord, a path, a resume command line and every tattoo value
    # this engine writes are well inside it.
    $limit = 512

    $answer = [pscustomobject] @{
        Sentence  = '<null>'
        Display   = '<null>'
        Redacted  = $false
        Truncated = $false
        Length    = 0
    }

    if ($null -eq $Value) {
        return $answer
    }

    $text = [string] $Value
    $answer.Length = $text.Length

    if ($text.Length -eq 0) {
        $answer.Display = '<empty>'
        $answer.Sentence = '<empty>'

        return $answer
    }

    # REDACTION BEFORE TRUNCATION, so no prefix of a long secret is ever shown.
    if ($Sensitive.IsPresent -or (Test-HDTSecretRegistryValue -Name $Name)) {
        $answer.Redacted = $true
        $answer.Display = '<redacted, {0} character(s)>' -f $text.Length

        # The length is already inside it, so it is not said again.
        $answer.Sentence = $answer.Display

        return $answer
    }

    if ($text.Length -gt $limit) {
        $answer.Truncated = $true
        $answer.Display = "'{0}' <truncated, {1} character(s) in all>" -f $text.Substring(0, $limit), $text.Length
        $answer.Sentence = $answer.Display

        return $answer
    }

    $answer.Display = "'{0}'" -f $text
    $answer.Sentence = '{0} ({1} character(s))' -f $answer.Display, $text.Length

    return $answer
}
