function ConvertTo-HDTRuleMapLine {
    <#
        .SYNOPSIS
            Writes a rule's when: or set: mapping as the lines it occupies in the
            file.

        .DESCRIPTION
            THE ONLY PLACE THE RULES EDITOR INVENTS TEXT, so it is the only place
            that has to get the column right. YAML is whitespace-significant: a
            set: written two columns out belongs to the rule above it, or to
            nothing, and the administrator's own edit is what broke the file.

            IT WRITES A BLOCK MAPPING RATHER THAN A FLOW ONE. A hand-written
            rules.yaml often puts when: on one line as { A: x, B: y }, and
            nothing here reformats a line it was not asked to change - but a
            mapping this command generates is written a key to a line, because a
            flow mapping needs a value quoted the moment it contains a comma or a
            brace and a generated document should not depend on that being got
            right. One key per line also gives a one-line diff when one key
            changes.

            A LIST VALUE BECOMES A YAML SEQUENCE. HDTApplication is a list of
            applications, and writing it as a comma-joined string would hand the
            engine one application with commas in its name.

        .PARAMETER Key
            The mapping's own key - 'when' or 'set'.

        .PARAMETER Map
            The entries, in the order they should be written.

        .PARAMETER Indent
            The column Key is written at.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the key line and one line per entry.

        .EXAMPLE
            ConvertTo-HDTRuleMapLine -Key 'set' -Map ([ordered] @{ HDTJoinWorkgroup = 'WORKGROUP' }) -Indent 4
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Key,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Map,

        [Parameter(Mandatory = $true, Position = 2)]
        [int] $Indent
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $pad = ' ' * $Indent
    $inner = ' ' * ($Indent + 2)
    $item = ' ' * ($Indent + 4)

    $result = New-Object -TypeName System.Collections.ArrayList

    [void] $result.Add(('{0}{1}:' -f $pad, $Key))

    foreach ($name in @($Map.Keys)) {
        $value = $Map[$name]

        if (($null -ne $value) -and ($value -is [System.Collections.IList]) -and -not ($value -is [string])) {
            [void] $result.Add(('{0}{1}:' -f $inner, $name))

            foreach ($element in @($value)) {
                [void] $result.Add(('{0}- {1}' -f $item, (ConvertTo-HDTRuleScalarText -Value $element)))
            }

            continue
        }

        [void] $result.Add(('{0}{1}: {2}' -f $inner, $name, (ConvertTo-HDTRuleScalarText -Value $value)))
    }

    return [string[]] @($result)
}
