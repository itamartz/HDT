function Get-HDTWizardComputerName {
    <#
        .SYNOPSIS
            What the computer name box should say before the technician types,
            and whether that name can be used.

        .DESCRIPTION
            W4 OF .planning/WPF-FIRST.md: "prefilled from the rules, with the
            15-character NetBIOS refusal visible".

            THE CONVENTION BELONGS TO rules.yaml AND NOT TO THIS COMMAND.
            Add-HDTRule's own examples are 'PC-%HDTSerialNumber%' and
            'LT-%HDTSerialNumber%', which is how a site names machines - in the
            rules, per model, per site, per anything. A wizard that invented a
            scheme of its own would be a second answer to a question the engine
            already answers, and the two would disagree the first time somebody
            edited one of them. So the resolved HDTComputerName wins whenever
            there is one.

            THE FALLBACKS ARE FOR A SHARE THAT HAS NOT BEEN SET UP YET, in
            order, and each of them is a suggestion the technician can overtype:

              Serial   HDTSerialNumber, cut to fifteen characters. It is the
                       thing the rules would most likely have been built from,
                       and on a bench it is printed on the case.
              Machine  the name this machine already answers to, which is what
                       rebuilding a named machine should offer - EXCEPT
                       MINWINPC, which is what WinPE calls itself and means
                       nothing about the hardware.
              None     an empty box. Better than a name nobody chose.

            THE VERDICT IS COMPUTED ON THE PREFILLED VALUE, with the same
            Test-HDTComputerName the page validates with when Next is pressed.
            A rule that builds a name out of a seventeen-character serial
            produces something nothing can use, and the technician is the person
            who finds out - so they find out while looking at the box rather
            than after answering every remaining question.

            FIFTEEN CHARACTERS, WHATEVER IT CAME FROM, AND THE CUT IS SAID
            OUT LOUD. A real VM is why: the lab rule builds
            PC-%HDTSerialNumber% and that machine's serial is a 32-character
            UUID, so the box opened holding a 35-character name in a control
            whose own MaxLength is 15 - because MaxLength governs TYPING and a
            prefilled value walks straight past it. The technician was left
            holding a name that cannot be used with no clue which part to
            delete.

            So it is cut, and the name BEFORE the cut goes into the reason: a
            silent trim would deploy a machine under a name nobody chose and
            nothing recorded. What is never done is repair of any other kind -
            an illegal character or a name that is not DNS-safe is reported and
            left exactly as it is.

        .PARAMETER Variable
            The resolved variables. HDTComputerName and HDTSerialNumber are read
            and nothing else.

        .PARAMETER Environment
            An IEnvironmentProvider, for COMPUTERNAME. Null is not an error and
            means the machine has no name worth offering.

        .PARAMETER Control
            The control the field names. Defaults to HDTComputerNameBox, which
            is what the shipped page calls it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Value, Source
            ('Rules', 'Serial', 'Machine' or 'None'), Severity, Reason and
            Field. The Field carries Seed, which is true only for 'Rules' -
            the other three are this command's own suggestion, and a host that
            remembered one as a seed would drop the technician's acceptance of
            it.

        .EXAMPLE
            $title = 'Computer Details'
            $field = @()
            $fact = Get-HDTMachineFact -CimProvider (New-HDTCimProvider) `
                -RegistryService (New-HDTRegistryService) -EnvironmentProvider (New-HDTEnvironmentProvider)
            $resolved = Resolve-HDTVariable -Fact $fact
            $ask = Get-HDTWizardPage -Page @() -Variable $resolved.Variable
            Get-HDTWizardComputerName -Variable $resolved.Variable

        .EXAMPLE
            $name = Get-HDTWizardComputerName -Variable $resolved.Variable
            Show-HDTWizardShell -Page $ask.Page -Field (@($field) + @($name.Field)) -Title $title

            What the payload does: the prefilled name is one more field, applied
            by name like every other.
    #>
    [CmdletBinding()]
    # $Variable is read inside the $read closure below, which the analyzer does
    # not follow - the same suppression Start-HDTDeployment.ps1 carries.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Used inside a closure, which PSReviewUnusedParameter does not follow.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [System.Collections.IDictionary] $Variable,

        [Parameter()]
        [AllowNull()]
        [object] $Environment,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Control = 'HDTComputerNameBox'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $read = {
        param([string] $Name)

        if ($null -eq $Variable) { return '' }
        if (-not $Variable.Contains($Name)) { return '' }

        return ([string] $Variable[$Name]).Trim()
    }

    $value = ''
    $source = 'None'
    $untrimmed = ''

    # -- 1. what the rules said ---------------------------------------------

    $resolved = & $read 'HDTComputerName'
    if (-not [string]::IsNullOrWhiteSpace($resolved)) {
        $value = $resolved
        $source = 'Rules'
    }

    # -- 2. the serial, which is what a rule would have been built from ------

    if ($source -eq 'None') {
        $serial = & $read 'HDTSerialNumber'

        if (-not [string]::IsNullOrWhiteSpace($serial)) {
            # FIFTEEN IS THE NetBIOS LIMIT, and cutting here is a SUGGESTION
            # being made to fit rather than a name being repaired: nothing has
            # been chosen yet.
            if ($serial.Length -gt 15) { $serial = $serial.Substring(0, 15) }

            $value = $serial
            $source = 'Serial'
        }
    }

    # -- 3. the name this machine already answers to ------------------------

    if ($source -eq 'None' -and $null -ne $Environment) {
        $current = ''
        try {
            $current = ([string] $Environment.GetVariable('COMPUTERNAME')).Trim()
        } catch {
            # A provider that cannot answer is a machine with no name to offer,
            # which is the same as not having one. The reason is kept where a
            # debugger can reach it and the wizard still opens.
            Write-Verbose ("COMPUTERNAME could not be read: {0}" -f [string] $_.Exception.Message)
        }

        # MINWINPC IS WinPE'S OWN NAME and says nothing about this hardware.
        # Deploying a machine under it would be worse than asking.
        if (-not [string]::IsNullOrWhiteSpace($current) -and $current -ne 'MINWINPC') {
            $value = $current
            $source = 'Machine'
        }
    }

    # -- fifteen characters, whatever it came from --------------------------
    #
    # A REAL MACHINE IS WHY THIS EXISTS. The lab's rule builds
    # PC-%HDTSerialNumber% and the VM's serial is a 32-character UUID, so the
    # box opened holding PC-2333-7717-4451-0293-3355-6067-32 - thirty-five
    # characters in a control whose own MaxLength is 15. MaxLength only governs
    # TYPING; a prefilled value walks straight past it, and the technician is
    # left holding a name that cannot be used and no clue which part to delete.
    #
    # AND IT IS SAID OUT LOUD. Cutting silently would deploy a machine under a
    # name nobody chose and nothing recorded, so the name before the cut goes
    # into the reason, onto the log and onto the summary.
    if ($value.Length -gt 15) {
        $untrimmed = $value
        $value = $value.Substring(0, 15)
    }

    # -- the verdict, on whatever is in the box now -------------------------

    $severity = 'None'
    $reason = ''

    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $verdict = Test-HDTComputerName -Name $value

        $severity = [string] $verdict.Severity
        $reason = [string] $verdict.Reason
    }

    # THE CUT OUTRANKS A DNS WARNING and never a hard refusal: a name that was
    # too long AND carries an illegal character still has to say so.
    if (-not [string]::IsNullOrWhiteSpace($untrimmed) -and $severity -ne 'Error') {
        $severity = 'Warning'
        $reason = ("'{0}' is {1} characters and a computer name may be 15, so it was cut to '{2}'. Check it before deploying." -f
            $untrimmed, $untrimmed.Length, $value)
    }

    return [pscustomobject] @{
        Value    = $value
        Source   = $source
        Severity = $severity
        Reason   = $reason

        Field    = [pscustomobject] @{
            Name = $Control
            Text = $value

            # ONLY THE RULES PUT A REAL SEED IN THIS BOX, AND THE FIELD HAS TO
            # SAY SO. New-HDTWizardHost records a seed for any field that claims
            # one, and its harvest DROPS an answer equal to its seed - because a
            # rule shown back to a technician is not something they typed, and
            # collecting it would overwrite the rule's own provenance.
            #
            # THE OTHER THREE SOURCES ARE THE WIZARD'S OWN SUGGESTIONS. A name
            # cut out of the serial, or the name the machine already answers to,
            # was chosen by this command and by nothing on the share: there is no
            # provenance to protect, and calling it a seed made a technician who
            # ACCEPTED the suggestion indistinguishable from one who answered
            # nothing. That is the same defect the task sequence picker shipped
            # with, and it cost a deployment that failed before its first step.
            Seed = ($source -eq 'Rules')
        }
    }
}
