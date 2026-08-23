function Start-HDTWizardDeployment {
    <#
        .SYNOPSIS
            Turns what the technician answered into the variable set the engine
            runs on - or into a refusal.

        .DESCRIPTION
            W5 OF .planning/WPF-FIRST.md: "summary, and a Deploy button - the
            wizard hands the engine a resolved variable set". The button already
            says Deploy on the last page (Step-HDTWizardPage's caption); this is
            what it hands over.

            THE HANDOFF WAS SITTING IN THE ENTRY POINT. Start-HDTDeployment.ps1
            read the answer, decided whether it counted as consent, put the typed
            values back through Resolve-HDTVariable and copied the result into a
            case-insensitive dictionary - four decisions in a file whose own test
            asserts it holds no deployment logic. They are here now, where a test
            can reach them without a booted machine.

            THE SECOND RESOLUTION IS THE POINT, AND IT IS NOT A PATCH. A typed
            value cannot simply be written over the resolved set: that would set
            values with no provenance and no precedence, which is the whole thing
            DESIGN 3.1 exists to prevent. The answers go back through the
            resolver AS THE Wizard SOURCE, so a typed name beats the rule that
            guessed one, a rule still wins where a box was left empty, and
            Provenance says which of those happened for every name.

            AND ONLY WHEN THERE IS SOMETHING TO APPLY. A wizard that asked
            nothing - every page skipped because the rules already answered -
            resolves once, and the first resolution is handed back untouched.

            A DISMISSED WINDOW IS NOT CONSENT TO PARTITION A DISK. The allow-list
            is the same three answers the shell holds, held again here because
            this is the last gate before a disk is wiped: anything that is not
            exactly 'Next' or 'CommandPrompt' is a Cancel. Nothing is resolved
            for a refusal, because the answer to "what would this have deployed"
            is "nothing".

            IT OPENS NO PROMPT AND ENDS NO MACHINE. 'CommandPrompt' is reported,
            and what to do about it belongs to the caller: in WinPE that is
            opening the prompt, restoring the console the wizard hid, and leaving
            the machine running.

        .PARAMETER Answer
            What Show-HDTWizardShell returned: an Action and the collected Value.

        .PARAMETER ResolveArgument
            The arguments the first resolution used. It is COPIED before Wizard
            is added, because the caller keeps it for logging and for a retry -
            a command that quietly added to it would resolve the next attempt
            with this attempt's answers.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Action ('Deploy',
            'Cancel' or 'CommandPrompt'), Variable, Applied and Resolved.

        .EXAMPLE
            $answer = [pscustomobject] @{ Action = 'Next'; Value = @{ HDTComputerName = 'HDT-01' } }
            $deploy = Start-HDTWizardDeployment -Answer $answer

            Turns what the technician chose into variables the engine will run with,
            through an allow-list: a wizard cannot set anything it likes.

        .EXAMPLE
            if ($deploy.Action -ne 'Deploy') { 'cancelled' } else { $deploy.Variable['HDTComputerName'] }

            What the payload does with it. Anything but Deploy stops the run - a closed
            window is not consent to wipe a disk.

    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Resolves variables and reports what was asked for; it changes no state and starts nothing. A confirmation prompt in WinPE, behind a window that has just closed, would hang a deployment.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Answer,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $ResolveArgument
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $empty = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

    $action = ''
    if ($null -ne $Answer.PSObject.Properties['Action']) { $action = [string] $Answer.Action }

    # THE ALLOW-LIST, AND EVERYTHING ELSE IS A CANCEL.
    if ($action -eq 'CommandPrompt') {
        return [pscustomobject] @{
            Action   = 'CommandPrompt'
            Variable = $empty
            Applied  = [string[]] @()
            Resolved = $null
        }
    }

    if ($action -ne 'Next') {
        return [pscustomobject] @{
            Action   = 'Cancel'
            Variable = $empty
            Applied  = [string[]] @()
            Resolved = $null
        }
    }

    # -- what the technician typed ------------------------------------------

    $typed = $null
    if ($null -ne $Answer.PSObject.Properties['Value']) { $typed = $Answer.Value }

    $applied = @()
    if ($null -ne $typed -and $typed -is [System.Collections.IDictionary]) {
        $applied = @(@($typed.Keys) | ForEach-Object { [string] $_ } | Sort-Object)
    }

    # A COPY, NEVER THE CALLER'S OWN HASHTABLE. See the parameter.
    $argument = @{}
    foreach ($key in @($ResolveArgument.Keys)) { $argument[$key] = $ResolveArgument[$key] }

    if (@($applied).Count -gt 0) { $argument['Wizard'] = $typed }

    $resolved = Resolve-HDTVariable @argument

    # THE ENGINE'S BAG IS ITS OWN, and case-insensitive: a step reading
    # %hdtcomputername% and a rule setting HDTComputerName are the same name.
    $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($resolved.Variable.Keys)) {
        $variable[[string] $name] = $resolved.Variable[$name]
    }

    return [pscustomobject] @{
        Action   = 'Deploy'
        Variable = $variable
        Applied  = [string[]] @($applied)
        Resolved = $resolved
    }
}
