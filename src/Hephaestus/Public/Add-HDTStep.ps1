function Add-HDTStep {
    <#
        .SYNOPSIS
            Adds a new step to a task sequence document, or pastes a copied one,
            leaving every other line byte-identical.

        .DESCRIPTION
            The Add and Paste buttons, and the cmdlet an administrator can type
            instead ("the console may not do anything the cmdlets
            can't").

            THIS IS THE ONLY OPERATION THAT INVENTS TEXT, and it therefore has
            to invent it at the right column. YAML is whitespace-significant, so
            a step written two columns out is a document the engine refuses -
            and the administrator's own edit is what broke it. The new lines
            take the indentation of the step they are placed after, which is
            also what puts them in that step's group.

            A PASTED BLOCK IS REINDENTED TO WHERE IT LANDS. Copy from a step
            inside a group and paste beside one at the top level and the block
            arrives with its old indentation; the difference between that and a
            parse error is a couple of spaces. The block's own internal shape is
            preserved by shifting every line by the same amount.

            THE TYPE IS CHECKED AGAINST THE ENGINE'S REGISTRY. Get-HDTStepType
            is what Invoke-HDTTaskSequence would consult, and the authoring lint
            reports an unknown type as an Error finding - so the editor must not
            be able to create one in the first place.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTSequenceDocument is what
            touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER After
            The step or group the new one is placed after.

        .PARAMETER Name
            The new step's name.

        .PARAMETER Type
            The new step's type. Must be one the engine knows.

        .PARAMETER Block
            Lines from Copy-HDTStep, to paste instead of creating a new
            step.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the step added.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'))
            Add-HDTStep -Line $line -After 'Validate' -Name 'Check TPM' -Type Validate

        .EXAMPLE
            $block = Copy-HDTStep -Line $line -Name 'Apply OS'
            Add-HDTStep -Line $line -After 'Prepare Boot' -Block $block
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low', DefaultParameterSetName = 'New')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $After,

        [Parameter(Mandatory = $true, ParameterSetName = 'New')]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory = $true, ParameterSetName = 'New')]
        [ValidateNotNullOrEmpty()]
        [string] $Type,

        [Parameter(Mandatory = $true, ParameterSetName = 'Paste')]
        [AllowEmptyString()]
        [string[]] $Block
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $target = Resolve-HDTStepBlock -Line $Line -Name $After

    # A new step sits where its neighbour sits. Placing it after a GROUP puts it
    # after the whole group, at the group's own indentation, which is where a
    # sibling of that group belongs.
    $indent = ' ' * $target.Indent

    if ($PSCmdlet.ParameterSetName -eq 'New') {
        $known = @(Get-HDTStepType | ForEach-Object { $_.Type })

        if ($known -notcontains $Type) {
            throw (New-HDTErrorRecord -Path $Type -Category InvalidArgument `
                    -Message ("'{0}' is not a step type this engine has. Get-HDTStepType lists the {1} it does." -f $Type, @($known).Count))
        }

        $text = @(
            ('{0}- name: {1}' -f $indent, $Name)
            ('{0}  type: {1}' -f $indent, $Type)
        )
    } else {
        $text = @(Set-HDTBlockIndent -Block $Block -Indent $target.Indent)
    }

    $subject = $Name
    if ($PSCmdlet.ParameterSetName -eq 'Paste') { $subject = 'the copied step' }

    if (-not $PSCmdlet.ShouldProcess($subject, ('Add after {0}' -f $After))) {
        return [string[]] @($Line)
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -le $target.End; $i++) { [void] $result.Add($Line[$i]) }

    # A blank line before it, so the new step is spaced the way the ones around
    # it are rather than being welded to its neighbour.
    [void] $result.Add('')

    foreach ($current in $text) { [void] $result.Add($current) }

    for ($i = $target.End + 1; $i -lt $Line.Count; $i++) { [void] $result.Add($Line[$i]) }

    return [string[]] @($result)
}
