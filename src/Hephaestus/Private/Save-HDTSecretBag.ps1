function Save-HDTSecretBag {
    <#
        .SYNOPSIS
            Carries the run's secrets across a reboot in an LSA secret, so the
            checkpoint never has to.

        .DESCRIPTION
            DESIGN 4.5.2's secret bag: "The durable answer is an LSA-carried
            secret bag written alongside each checkpoint, which is the same
            mechanism this section already chose for the autologon password."

            THE PROBLEM IT SOLVES, AND IT IS NOT HYPOTHETICAL.
            Save-HDTRunState redacts every secret's value on the way into
            state.json - it has to, because that document is copied to the
            deployment share every machine being deployed can read, and moved to
            C:\Windows\Logs\HDT on the deployed machine, where authenticated
            users can read it. The leg that resumes after a restart rehydrates
            its whole variable bag from that file, so it holds '(set, not shown)'
            where a secret was. JoinDomain reached that first, on 2026-09-01: it
            runs in State Restore, one restart after the wizard collected the
            credential, and it REFUSED rather than spending a wrong-password
            attempt per machine on the one account that can join anything to the
            directory.

            SO THE VALUE GOES SOMEWHERE state.json IS NOT. LSA private data is
            admin-only, it is not in a registry backup, it is not in an image
            captured from the machine, and it is the store Windows itself uses
            for the autologon password - which is the precedent this follows
            rather than inventing a second one.

            WHAT GOES IN: every variable Test-HDTSecretVariable classifies
            secret and nothing else, asked of the classifier at run time rather
            than from a list written here. A customer's own HDTJoinPassword is
            carried the first time it is set, because the classifier's name
            pattern catches it - which is the same reason the redaction catches
            it on the way to disk. The two sides cannot disagree about which
            names are secret, because they ask the same function.

            WHAT DOES NOT GO IN:

              - an empty value. Empty and redacted read identically once stored
                and mean opposite things, and 'nothing was set' is not a secret
                worth carrying.
              - THE REDACTION ITSELF, and this is the entry that would quietly
                destroy the feature. A leg that has rehydrated from state.json
                and not yet been restored holds '(set, not shown)'; a checkpoint
                taken then would overwrite the real secret in LSA with the
                marker and lose it for the rest of the deployment. A bag entry
                is never replaced by the thing that replaced it.

            IT NEVER TAKES A RUN DOWN. It is called on every leg, including legs
            where a failure is already unwinding, and LSA can refuse: a
            non-elevated leg, a policy, a machine in a state nobody anticipated. A run that died at step 1 because it could not
            store a credential it might never have needed is a worse outcome than
            a run that reaches the step that does need one and refuses there with
            a sentence naming the cause. So the write is best effort and a
            failure is a Warning - the same reasoning Clear-HDTAutoLogon's
            checklist is built on.

            THE VALUE IS NEVER LOGGED, AT ANY LEVEL. The names are, the count is,
            the secret it was written under is, and how long it lives is - that
            is what an administrator reading the log a week later needs in order
            to explain why a step had a password or did not. ILsaService.SetSecret
            records the name and the literal '<redacted>' for the same reason.

        .PARAMETER Lsa
            An ILsaService - New-HDTLsaService in production,
            New-HDTFakeLsaService in a test.

        .PARAMETER Variable
            The live variable bag. Read only; nothing here mutates it.

        .PARAMETER LogContext
            A log context. Without one this writes no log at all, which is what
            a caller checkpointing before a log exists needs.

        .OUTPUTS
            System.String[] - the names carried, in the order they were read.
            Empty when there was nothing to carry, and empty when the store
            refused.

        .EXAMPLE
            $lsa = New-HDTLsaService
            $variable = [ordered] @{
                HDTComputerName        = 'HDT-LAB-01'
                HDTDomainAdmin         = 'svc-hdt-join'
                HDTDomainAdminPassword = 'whatever the wizard collected'
            }
            Save-HDTSecretBag -Lsa $lsa -Variable $variable

            HDTDomainAdminPassword. The account name and the computer name are
            not secrets and stay out of the bag, because redacting them would
            answer none of the questions a log exists to answer. The engine does
            this at the start of every leg and again immediately before it arms a
            restart, so the bag is current at the moment the machine goes down.

        .EXAMPLE
            @(Save-HDTSecretBag -Lsa $lsa -Variable ([ordered] @{ HDTComputerName = 'HDT-LAB-01' }))

            Nothing, and no LSA call at all. A run with no secrets must not write
            an LSA secret per step on a machine that needs none.

        .LINK
            Restore-HDTSecretBag

        .LINK
            Clear-HDTSecretBag
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
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

    # The redaction's wording from the one place that defines it, so a change to
    # what a redaction looks like cannot leave this comparing against a string
    # nothing produces any more.
    $redaction = [string] (Protect-HDTSecretValue -Name 'HDTAdminPassword' -Value 'a set value')

    $carried = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    $skipped = New-Object -TypeName System.Collections.ArrayList

    foreach ($key in @($Variable.Keys)) {
        $name = [string] $key

        if (-not (Test-HDTSecretVariable -Name $name)) { continue }

        $value = [string] $Variable[$key]

        if ([string]::IsNullOrEmpty($value)) {
            [void] $skipped.Add(('{0} (nothing was set)' -f $name))
            continue
        }

        if ([string]::Equals($value, $redaction, [System.StringComparison]::Ordinal)) {
            [void] $skipped.Add(('{0} (this leg holds the redaction, so the stored value is kept)' -f $name))
            continue
        }

        $carried[$name] = $value
    }

    if ($carried.Count -eq 0) {
        if ($null -ne $LogContext) {
            Write-HDTLog -Context $LogContext -Severity Debug -Component 'SecretBag' `
                -Message ("no secret needs carrying across a restart, so no '{0}' LSA secret was written. {1}" -f
                    $secretName,
                    $(if ($skipped.Count -eq 0) {
                            'Nothing in the variable bag is classified secret by Test-HDTSecretVariable.'
                        } else {
                            'Skipped: ' + (@($skipped) -join '; ') + '.'
                        })) `
                -Data ([ordered] @{
                    secretName = $secretName
                    carried    = [string[]] @()
                    count      = 0
                    skipped    = [string[]] @($skipped)
                })
        }

        return ([string[]] @())
    }

    $document = ConvertTo-Json -InputObject ([pscustomobject] $carried) -Depth 4 -Compress

    if (-not $PSCmdlet.ShouldProcess($secretName, ('Store {0} secret(s) for the next leg' -f $carried.Count))) {
        return ([string[]] @())
    }

    # A WRITE, WITH NO READ IN FRONT OF IT. An earlier cut read the secret back
    # first and skipped an identical write, which was free on a real machine and
    # expensive where it counts: TaskSequence.EndToEnd.Tests.ps1 writes out the
    # exact ordered list of everything HDT does to a machine - DESIGN 12.2.1, and
    # the specification of the engine's side effects - and a GetSecret per
    # checkpoint buried that list in twenty-six lines of bookkeeping. The caller
    # now writes at the two moments the bag can matter instead of at every
    # checkpoint, so there is nothing to skip. See Invoke-HDTTaskSequence.
    try {
        $Lsa.SetSecret($secretName, $document)
    } catch {
        # BEST EFFORT, AND THE WARNING SAYS WHAT IT COSTS. See the header: a run
        # must not die here. The step that actually needs one of these values
        # refuses on its own, by name, with a message an administrator can act
        # on - which is a far better place to find out than step 1 of 40.
        if ($null -ne $LogContext) {
            Write-HDTLog -Context $LogContext -Severity Warning -Component 'SecretBag' `
                -Message ("the {0} secret(s) this leg holds could not be stored in the LSA secret '{1}', so they will NOT survive the next restart and any step after it that needs one will refuse: {2} ({3}: {4})" -f
                    $carried.Count, $secretName, (@($carried.Keys) -join ', '),
                    $_.Exception.GetType().FullName, $_.Exception.Message) `
                -Data ([ordered] @{
                    secretName    = $secretName
                    carried       = [string[]] @($carried.Keys)
                    count         = $carried.Count
                    exceptionType = [string] $_.Exception.GetType().FullName
                })
        }

        return ([string[]] @())
    }

    if ($null -ne $LogContext) {
        Write-HDTLog -Context $LogContext -Component 'SecretBag' `
            -Message ("{0} secret value(s) were stored in the LSA secret '{1}' so they survive the next restart: {2}. The values are in no file this run writes - state.json carries '{3}' for each of them - and Clear-HDTAutoLogon removes this secret when the run ends, succeeded or failed.{4}" -f
                $carried.Count, $secretName, (@($carried.Keys) -join ', '), $redaction,
                $(if ($skipped.Count -eq 0) { '' } else { ' Not carried: ' + (@($skipped) -join '; ') + '.' })) `
            -Data ([ordered] @{
                secretName = $secretName
                carried    = [string[]] @($carried.Keys)
                count      = $carried.Count
                skipped    = [string[]] @($skipped)
                rewritten  = $true
            })
    }

    return ([string[]] @($carried.Keys))
}
