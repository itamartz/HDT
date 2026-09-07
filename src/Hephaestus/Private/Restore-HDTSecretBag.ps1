function Restore-HDTSecretBag {
    <#
        .SYNOPSIS
            Puts the run's secrets back into the variable bag of a leg that
            rehydrated from a redacted checkpoint.

        .DESCRIPTION
            The read half of DESIGN 4.5.2's secret bag. A leg that resumes after
            a restart builds its variable bag from state.json, where every
            secret's value was replaced with '(set, not shown)' on the way to
            disk. This reads the LSA secret Save-HDTSecretBag wrote before the
            restart and puts the real values back over those markers, before the
            first step runs.

            THE LIVE LEG WINS, ALWAYS. A name this leg already holds a real value
            for is left alone: a rule that resolved on this leg, a wizard answer,
            a SetVariable step earlier in the same sequence are all NEWER than
            the bag, and a restore that overruled them would quietly turn a
            carry-across into a source of truth it was never meant to be. Only a
            name that is missing, empty, or holding the redaction is filled in.

            IT NEVER TAKES A RUN DOWN, for the reason the writer does not: this
            runs at the start of every leg, on machines in states nobody
            anticipated, and the bag can be unreadable - an LSA that refuses a
            non-elevated read, a document written by an older engine, a secret
            somebody else put under the name. A leg that died here would be a
            deployment stopped by its own recovery mechanism. A leg that carries
            on reaches the step that needs the value and refuses THERE, naming
            the variable, which is where an administrator can act on it.

            THE VALUE IS NEVER LOGGED, AT ANY LEVEL - the names, the count, and
            for each one whether it was missing or redacted before. That last
            part is the fact worth having: 'restored over a redaction' says the
            checkpoint round trip worked, and 'restored a name this leg did not
            have' says the variable was never in the checkpoint at all, which are
            different faults with different fixes.

        .PARAMETER Lsa
            An ILsaService.

        .PARAMETER Variable
            The leg's live variable bag. MUTATED IN PLACE - it is the object the
            execution context hands to every step, so replacing it would leave
            the steps reading the old one.

        .PARAMETER LogContext
            A log context. Without one this writes no log at all.

        .OUTPUTS
            System.String[] - the names whose values were put back. Empty when
            there was no bag, when nothing in it was needed, and when the store
            could not be read.

        .EXAMPLE
            $lsa = New-HDTLsaService
            $variable = [ordered] @{ HDTDomainAdminPassword = '(set, not shown)' }
            Restore-HDTSecretBag -Lsa $lsa -Variable $variable

            HDTDomainAdminPassword - the name it put back. This is the bag a
            resumed leg rehydrated from state.json, where the value was replaced
            on the way to disk.

        .EXAMPLE
            $variable['HDTDomainAdminPassword']

            The password the wizard collected two legs ago, back in the bag. It
            is why the JoinDomain step in State Restore can join at all, instead
            of refusing on a redaction.

        .LINK
            Save-HDTSecretBag

        .LINK
            Clear-HDTSecretBag
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes nothing on the machine: it fills in an in-memory dictionary this process already owns.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Lsa,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Variable,

        [Parameter()]
        [AllowNull()]
        [object] $LogContext
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $secretName = Get-HDTSecretBagName
    $redaction = [string] (Protect-HDTSecretValue -Name 'HDTAdminPassword' -Value 'a set value')

    $document = ''
    try {
        $document = [string] $Lsa.GetSecret($secretName)
    } catch {
        if ($null -ne $LogContext) {
            Write-HDTLog -Context $LogContext -Severity Warning -Component 'SecretBag' `
                -Message ("the LSA secret '{0}' could not be read, so any secret this leg needs must be set in this leg: {1}: {2}" -f
                    $secretName, $_.Exception.GetType().FullName, $_.Exception.Message) `
                -Data ([ordered] @{ secretName = $secretName; exceptionType = [string] $_.Exception.GetType().FullName })
        }

        return ([string[]] @())
    }

    if ([string]::IsNullOrEmpty($document)) {
        if ($null -ne $LogContext) {
            Write-HDTLog -Context $LogContext -Severity Debug -Component 'SecretBag' `
                -Message ("there is no '{0}' LSA secret on this machine, so nothing was restored. That is the normal state of a first leg - the bag is written before a restart, not before the run." -f $secretName) `
                -Data ([ordered] @{ secretName = $secretName; restored = [string[]] @(); count = 0 })
        }

        return ([string[]] @())
    }

    # ConvertFrom-Json AND NOT -AsHashtable: the engine runs in WinPE under
    # Windows PowerShell 5.1, which does not have that switch (CLAUDE.md rule 2).
    $entry = $null
    try {
        $entry = ConvertFrom-Json -InputObject $document
    } catch {
        if ($null -ne $LogContext) {
            Write-HDTLog -Context $LogContext -Severity Warning -Component 'SecretBag' `
                -Message ("the LSA secret '{0}' is not a document this engine wrote and was ignored, so any secret this leg needs must be set in this leg. It may have been left by an older engine or by something else on this machine; it is not removed here, because removing a secret HDT did not write is not this command's decision. {1}: {2}" -f
                    $secretName, $_.Exception.GetType().FullName, $_.Exception.Message) `
                -Data ([ordered] @{ secretName = $secretName; exceptionType = [string] $_.Exception.GetType().FullName })
        }

        return ([string[]] @())
    }

    $restored = New-Object -TypeName System.Collections.ArrayList
    $kept = New-Object -TypeName System.Collections.ArrayList

    foreach ($property in @($entry.PSObject.Properties)) {
        $name = [string] $property.Name
        $value = [string] $property.Value

        if ([string]::IsNullOrEmpty($value)) { continue }

        $reason = 'this leg did not have it at all'

        if ($Variable.Contains($name)) {
            $current = [string] $Variable[$name]

            if ([string]::Equals($current, $redaction, [System.StringComparison]::Ordinal)) {
                $reason = 'the checkpoint carried the redaction'
            } elseif ([string]::IsNullOrEmpty($current)) {
                $reason = 'this leg had it empty'
            } else {
                # THE LIVE VALUE WINS. See the header.
                [void] $kept.Add($name)
                continue
            }
        }

        $Variable[$name] = $value
        [void] $restored.Add([pscustomobject] @{ Name = $name; Reason = $reason })
    }

    if ($null -ne $LogContext) {
        if ($restored.Count -eq 0) {
            Write-HDTLog -Context $LogContext -Severity Debug -Component 'SecretBag' `
                -Message ("the LSA secret '{0}' was read and nothing needed putting back: this leg already holds a value for every name in it{1}." -f
                    $secretName,
                    $(if ($kept.Count -eq 0) { '' } else { ' (' + (@($kept) -join ', ') + ')' })) `
                -Data ([ordered] @{
                    secretName = $secretName
                    restored   = [string[]] @()
                    count      = 0
                    kept       = [string[]] @($kept)
                })
        } else {
            Write-HDTLog -Context $LogContext -Component 'SecretBag' `
                -Message ("{0} secret value(s) were restored from the LSA secret '{1}', so the steps in this leg see the value the leg before the restart resolved rather than '{2}': {3}.{4}" -f
                    $restored.Count, $secretName, $redaction,
                    (@($restored | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Reason }) -join ', '),
                    $(if ($kept.Count -eq 0) { '' } else {
                            ' Left alone because this leg resolved its own, newer value: ' + (@($kept) -join ', ') + '.'
                        })) `
                -Data ([ordered] @{
                    secretName = $secretName
                    restored   = [string[]] @($restored | ForEach-Object { [string] $_.Name })
                    count      = $restored.Count
                    reason     = [string[]] @($restored | ForEach-Object { [string] $_.Reason })
                    kept       = [string[]] @($kept)
                })
        }
    }

    return ([string[]] @($restored | ForEach-Object { [string] $_.Name }))
}
