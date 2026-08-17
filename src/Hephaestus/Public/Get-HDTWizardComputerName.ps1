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
            'LT-%HDTSerialNumber%', which is how an MDT site has always named
            machines - in the rules, per model, per site, per anything. A wizard
            that invented a scheme of its own would be a second answer to a
            question the engine already answers, and the two would disagree the
            first time somebody edited one of them. So the resolved
            HDTComputerName wins whenever there is one.

            THE FALLBACKS ARE FOR A SHARE THAT HAS NOT BEEN SET UP YET, in
            order, and each of them is a suggestion the technician can overtype:

              Serial   HDTSerialNumber, cut to fifteen characters. It is the
                       thing the rules would most likely have been built from,
                       and on a bench it is printed on the case.
              Machine  the name this machine already answers to - MDT's
                       behaviour when rebuilding a named machine - EXCEPT
                       MINWINPC, which is what WinPE calls itself and means
                       nothing about the hardware.
              None     an empty box. Better than a name nobody chose.

            THE VERDICT IS COMPUTED ON THE PREFILLED VALUE, with the same
            Test-HDTComputerName the page validates with when Next is pressed.
            A rule that builds a name out of a seventeen-character serial
            produces something nothing can use, and the technician is the person
            who finds out - so they find out while looking at the box rather
            than after answering every remaining question.

            NOTHING IS EVER REPAIRED. A wizard that quietly trimmed a name to
            fifteen characters would deploy a machine called something nobody
            chose, and the log would say it was asked for. The name is shown as
            it is, and the reason it cannot be used is shown beside it.

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
            Field.

        .EXAMPLE
            Get-HDTWizardComputerName -Variable $resolved.Variable

        .EXAMPLE
            $name = Get-HDTWizardComputerName -Variable $resolved.Variable
            Show-HDTWizardShell -Page $ask.Page -Field (@($field) + @($name.Field)) -Title $title

            What the payload does: the prefilled name is one more field, applied
            by name like every other.
    #>
    [CmdletBinding()]
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

    # -- the verdict, on whatever is in the box now -------------------------

    $severity = 'None'
    $reason = ''

    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $verdict = Test-HDTComputerName -Name $value

        $severity = [string] $verdict.Severity
        $reason = [string] $verdict.Reason
    }

    return [pscustomobject] @{
        Value    = $value
        Source   = $source
        Severity = $severity
        Reason   = $reason

        Field    = [pscustomobject] @{
            Name = $Control
            Text = $value
        }
    }
}
