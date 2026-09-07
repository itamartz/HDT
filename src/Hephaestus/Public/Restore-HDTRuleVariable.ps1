function Restore-HDTRuleVariable {
    <#
        .SYNOPSIS
            Re-resolves rules.yaml into the variable bag of a leg that
            rehydrated from a redacted checkpoint, filling in only what the
            checkpoint could not carry.

        .DESCRIPTION
            The source of last resort for a full-OS leg, and the answer to a
            gap that made a whole step type untestable on real hardware.

            WHAT WAS MISSING. Start-HDTResume.ps1 - the RunOnce agent that runs
            every full-OS leg - built its variable bag from state.json and from
            nothing else; it never read rules.yaml at all. Save-HDTRunState
            writes '(set, not shown)' in place of every secret on the way to
            that file, because the file travels to the deployment share and to
            C:\Windows\Logs\HDT. DESIGN 4.5.2's LSA secret bag gives those
            values back across a full-OS -> full-OS restart, but it CANNOT cross
            the WinPE -> full-OS boundary: WinPE's LSA is a RAM disk, so the bag
            the WinPE leg writes is gone by the time the deployed OS starts.

            So on a NewComputer run, every secret a full-OS step needed arrived
            as the redaction, and no source could supply it. Both steps that
            need one refused - correctly, and with messages naming exactly this:

              * Invoke-HDTJoinDomainStep, which is why JoinDomain had never
                joined a real domain;
              * AD-DC-2025's promotion, on HDTDsrmPassword.

            The refusals were right. What was missing was a SOURCE, and
            rules.yaml is the source DESIGN 4.5.2 names for it. This reads it.

            THE PRECEDENCE IS Restore-HDTSecretBag's, WORD FOR WORD. A name is
            filled in only when it is MISSING, EMPTY, or holding the REDACTION.
            A live value always wins, and that is not a courtesy: state.json is
            what the run ALREADY DECIDED - a wizard answer, a command line, a
            per-machine override, a SetVariable step - and every one of those
            beat rules.yaml on leg one under DESIGN 3.1. A refill that overruled
            them would quietly promote the lowest-priority source to the
            highest, one reboot in.

            EMPTY IS SAFE TO FILL, and it is worth saying why rather than
            trusting it. An empty value in the bag cannot be a technician's
            answer that beat a rule, because Resolve-HDTVariable lets the rule
            win where a wizard box was left blank. An empty here therefore means
            the rule was empty or absent on leg one too, so refilling it is a
            no-op or a correction, never an override.

            THE FACTS COME OUT OF THE BAG, NOT OFF THIS MACHINE, and this is the
            subtlest thing in the file. Re-gathering in the full OS would
            resolve the rules against DIFFERENT facts than leg one used - the
            operating system has changed underneath the run - so a rule keyed on
            HDTOSVersion, HDTIsUEFI or HDTMake could answer differently on the
            second reading than on the first, and the leg would act on a
            decision the run never made. Leg one's facts are already in the bag,
            carried there by the checkpoint, so they are what this re-resolution
            is given and the answer is the answer leg one would have got.

            IT NEVER TAKES A RUN DOWN, for the reason Restore-HDTSecretBag does
            not: it runs at the start of a leg, on machines in states nobody
            anticipated, and a share that has gone away or a rules document that
            will not parse must cost the refill and nothing else. A leg that
            died in its own recovery mechanism would be a deployment stopped by
            the thing meant to save it. A leg that carries on reaches the step
            that needs the value and refuses THERE, naming the variable, which
            is where an administrator can act on it.

            NO VALUE IS EVER LOGGED, AT ANY LEVEL - only the names, the count,
            and for each one whether it was missing, empty or redacted before.
            That last part is the fact worth having: 'filled over a redaction'
            says the checkpoint round trip worked and the secret simply could
            not cross the boundary, while 'filled a name this leg did not have'
            says the variable was never in the checkpoint at all, which are
            different faults with different fixes.

        .PARAMETER RuleDocument
            The document Import-HDTRuleDocument produced from rules.yaml. Null
            is not an error: a leg whose share went away has none, and it fills
            in nothing and says so.

        .PARAMETER Variable
            The leg's live variable bag. MUTATED IN PLACE - it is the object the
            execution context hands to every step, so replacing it would leave
            the steps reading the old one.

        .PARAMETER ScriptInvoker
            An optional script invoker for setFrom: rules, as
            Resolve-HDTVariable takes.

        .PARAMETER LogContext
            A log context. Without one this writes no log at all.

        .OUTPUTS
            System.String[] - the names whose values were filled in. Empty when
            there was no rule document, when the resolution failed, and when the
            bag already held an answer for everything the rules offer.

        .EXAMPLE
            $fileSystem = New-HDTFileSystem
            $rules = Import-HDTRuleDocument -Path '\\host\HDTShare\rules.yaml' -FileSystem $fileSystem
            $variable = [ordered] @{ HDTDsrmPassword = '(set, not shown)' }

            Restore-HDTRuleVariable -RuleDocument $rules -Variable $variable

            HDTDsrmPassword - the name it put back. This is the bag a full-OS
            leg rehydrated from state.json, where the value was replaced on the
            way to disk and where the LSA bag could not reach it.

        .EXAMPLE
            $variable = [ordered] @{ HDTTaskSequenceID = 'WIZARD-CLIENT' }
            $fileSystem = New-HDTFileSystem
            $rules = Import-HDTRuleDocument -Path '\\host\HDTShare\rules.yaml' -FileSystem $fileSystem

            Restore-HDTRuleVariable -RuleDocument $rules -Variable $variable
            $variable['HDTTaskSequenceID']

            WIZARD-CLIENT - unchanged, even though rules.yaml offers a sequence
            id of its own. The technician typed this one on leg one and it went
            into the checkpoint; a rule that lost to it then does not win it
            back after a reboot. Nothing is returned, because nothing was filled.

        .LINK
            Restore-HDTSecretBag

        .LINK
            Resolve-HDTVariable
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes nothing on the machine: it fills in an in-memory dictionary this process already owns.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object] $RuleDocument,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Variable,

        [Parameter()]
        [AllowNull()]
        [object] $ScriptInvoker,

        [Parameter()]
        [AllowNull()]
        [object] $LogContext
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $RuleDocument) {
        if ($null -ne $LogContext) {
            Write-HDTLog -Context $LogContext -Severity Debug -Component 'RuleVariable' `
                -Message 'there is no rule document on this leg, so nothing was re-resolved. That is the normal state of a leg whose deployment share is unreachable; any secret a step needs must then already be in the bag, and the step refuses by name if it is not.' `
                -Data ([ordered] @{ filled = [string[]] @(); count = 0 })
        }

        return ([string[]] @())
    }

    # THE REDACTION'S WORDING FROM THE ONE PLACE THAT DEFINES IT, so a change to
    # what a redaction looks like cannot leave this comparing against a stale
    # copy of the literal.
    $redaction = [string] (Protect-HDTSecretValue -Name 'HDTAdminPassword' -Value 'a set value')

    # LEG ONE'S FACTS, OUT OF THE BAG. See the header: re-gathering here would
    # resolve the rules against a machine that is no longer the machine leg one
    # measured.
    #
    # AND THE ENGINE'S OWN NAMES ARE LEFT OUT OF THEM, WHICH IS NOT A DETAIL.
    # A resumed bag carries _HDTRunId and _HDTLogPath - the engine publishes
    # them on every leg - and Add-HDTResolvedVariable REFUSES any attempt to
    # assign a _HDT* name: "engine-owned and cannot be assigned". Handing the
    # whole bag over as -Fact is such an attempt, so the resolution throws and
    # this command fills in NOTHING. That is not hypothetical: it is what
    # happened on the first hardware run of AD-DC-2025 on 2026-09-07, where the
    # promotion then refused on the redaction three legs later - the exact
    # failure this command exists to prevent, caused by the command itself.
    # Dropping them loses nothing, because the engine sets them on every leg and
    # no rule may supply one.
    $fact = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($Variable.Keys)) {
        if ([string] $name -like '_HDT*') { continue }

        $fact[[string] $name] = $Variable[$name]
    }

    $resolved = $null
    try {
        $resolveArgument = @{
            RuleDocument = $RuleDocument
            Fact         = $fact
        }
        if ($null -ne $ScriptInvoker) { $resolveArgument['ScriptInvoker'] = $ScriptInvoker }

        $resolved = Resolve-HDTVariable @resolveArgument
    } catch {
        if ($null -ne $LogContext) {
            Write-HDTLog -Context $LogContext -Severity Warning -Component 'RuleVariable' `
                -Message ("rules.yaml could not be re-resolved on this leg, so nothing was filled in and any secret a step needs must already be in the bag: {0}: {1}" -f
                    $_.Exception.GetType().FullName, $_.Exception.Message) `
                -Data ([ordered] @{ exceptionType = [string] $_.Exception.GetType().FullName })
        }

        return ([string[]] @())
    }

    $filled = New-Object -TypeName System.Collections.ArrayList
    $kept = New-Object -TypeName System.Collections.ArrayList

    foreach ($name in @($resolved.Variable.Keys)) {
        $value = [string] $resolved.Variable[$name]

        # A rule that resolved to nothing has nothing to give back.
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
                [void] $kept.Add([string] $name)
                continue
            }
        }

        $Variable[[string] $name] = $value
        [void] $filled.Add([pscustomobject] @{ Name = [string] $name; Reason = $reason })
    }

    if ($null -ne $LogContext) {
        if ($filled.Count -eq 0) {
            Write-HDTLog -Context $LogContext -Severity Debug -Component 'RuleVariable' `
                -Message ("rules.yaml was re-resolved and nothing needed filling in: this leg already holds a value for every name the rules offer{0}." -f
                    $(if ($kept.Count -eq 0) { '' } else { ' (' + (@($kept) -join ', ') + ')' })) `
                -Data ([ordered] @{
                    filled = [string[]] @()
                    count  = 0
                    kept   = [string[]] @($kept)
                })
        } else {
            Write-HDTLog -Context $LogContext -Component 'RuleVariable' `
                -Message ("{0} variable(s) were filled in from rules.yaml, so the steps in this leg see the value the rules supply rather than '{1}' or nothing: {2}.{3} The values themselves are not written here at any level." -f
                    $filled.Count, $redaction,
                    (@($filled | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Reason }) -join ', '),
                    $(if ($kept.Count -eq 0) { '' } else {
                            ' Left alone because this leg already decided them: ' + (@($kept) -join ', ') + '.'
                        })) `
                -Data ([ordered] @{
                    filled = [string[]] @($filled | ForEach-Object { [string] $_.Name })
                    count  = $filled.Count
                    reason = [string[]] @($filled | ForEach-Object { [string] $_.Reason })
                    kept   = [string[]] @($kept)
                })
        }
    }

    return ([string[]] @($filled | ForEach-Object { [string] $_.Name }))
}
