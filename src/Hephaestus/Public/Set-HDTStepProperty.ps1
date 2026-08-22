function Set-HDTStepProperty {
    <#
        .SYNOPSIS
            Changes one property of a step or group - what it does, rather than
            whether it does it.

        .DESCRIPTION
            THE PROPERTIES TAB'S CMDLET. Options carries the three keys that
            decide whether a step runs; this carries the rest - the index
            ApplyImage installs, the minRamMB Validate insists on, the name on
            the row. The console may not do anything the cmdlets
            can't, and it shows the invocation for what it does.

            IT SPLICES, and it is the same three-way splice as the flags:
            rewrite the line if the key is there, insert one under `type:` if it
            is not, remove it if the value is cleared. Get-HDTStepKey
            finds all three cases, and stops at a group's `steps:` so setting a
            property on 'Install' cannot rewrite a line belonging to the first
            step inside it.

            THE NAME IS A PROPERTY LIKE ANY OTHER, and it lives on the entry
            line - `- name: Apply OS`. The dash is part of the list, not part of
            the key, so a rename rewrites what follows it and leaves the
            indentation and the marker alone.

            A NAME CANNOT BE CLEARED. Every editing cmdlet here resolves its
            target by name; a step with none could not be found again, by this
            console or by an administrator reading the file. Removing a step is
            Remove-HDTStep, where it is what was asked for.

            THE TYPE CANNOT BE CHANGED AT ALL. A step's properties belong to its
            type - `index` means something to ApplyImage and nothing to Restart -
            so retyping one leaves a step carrying keys the new type has never
            heard of, which the engine will either ignore silently or refuse at
            the worst moment. Workbench does not offer it either. The answer
            there and here is to delete the step and add the one you meant.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The step or group to change. Ambiguous names are refused rather
            than guessed - see Resolve-HDTStepBlock.

        .PARAMETER Property
            The YAML key, exactly as it is written in the file.

        .PARAMETER Value
            What it becomes. Empty removes the key.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document, with one line changed.

        .EXAMPLE
            Set-HDTStepProperty -Line $line -Name 'Apply OS' -Property 'index' -Value '2'

        .EXAMPLE
            Set-HDTStepProperty -Line $line -Name 'Apply OS' -Property 'name' -Value 'Apply Windows 11'

            Renames the step, on its own entry line.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        # WHICH OF THE SAME-NAMED STEPS, 1-BASED, IN DOCUMENT ORDER. Omitted, an
        # ambiguous name is refused rather than guessed at. The console passes
        # it because it has a selected row; a person typing a name has not said
        # which one they mean, and is told so.
        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $Occurrence = 0,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Property,

        [Parameter(Mandatory = $true, Position = 3)]
        [AllowEmptyString()]
        [string] $Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Property -eq 'type') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Name -Category InvalidOperation `
                    -Message ("a step's type cannot be changed, because its properties belong to that type and would be left behind. Remove '{0}' and add the step you meant." -f $Name)))
    }

    $naming = @('name', 'group')
    $clear = [string]::IsNullOrWhiteSpace($Value)

    if ($clear -and $naming -contains $Property) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Name -Category InvalidArgument `
                    -Message ("a step's name cannot be cleared - every edit here finds its target by name, and one with none could not be found again. Use Remove-HDTStep to delete it.")))
    }

    $target = Resolve-HDTStepBlock -Line $Line -Name $Name -Occurrence $Occurrence

    $found = Get-HDTStepKey -Line $Line -Block $target -Key $Property

    if ($clear -and $found.Index -lt 0) {
        return [string[]] @($Line)
    }

    $action = "Set {0} to {1}" -f $Property, $Value
    if ($clear) { $action = 'Remove {0}' -f $Property }

    if (-not $PSCmdlet.ShouldProcess($Name, $action)) {
        return [string[]] @($Line)
    }

    $written = '{0}{1}: {2}' -f (' ' * $found.Indent), $Property, (Get-HDTConsoleScalarText -Value $Value)

    # THE ENTRY LINE KEEPS ITS DASH. `- name: X` is a list item whose first key
    # happens to be the name; rewriting it as a plain key would fold the step
    # into the one above it.
    if ($found.Index -eq [int] $target.Entry) {
        $written = '{0}- {1}: {2}' -f (' ' * [int] $target.Indent), $Property, (Get-HDTConsoleScalarText -Value $Value)
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($found.Index -ge 0 -and $i -eq $found.Index) {
            if (-not $clear) { [void] $result.Add($written) }
            continue
        }

        [void] $result.Add($Line[$i])

        if ($found.Index -lt 0 -and $i -eq $found.Insert) {
            [void] $result.Add($written)
        }
    }

    return [string[]] @($result)
}
