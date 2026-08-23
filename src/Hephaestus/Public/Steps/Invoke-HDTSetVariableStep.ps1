function Invoke-HDTSetVariableStep {
    <#
        .SYNOPSIS
            Assigns deployment variables from inside a sequence.

        .DESCRIPTION
            The imperative counterpart to rules.yaml. Where a rule says "this is
            true of this machine", a SetVariable step says "this is true from
            here on":

              - name: Enter the install stage
                type: SetVariable
                variables:
                  HDTStage: install
                  HDTComputerName: PC-%HDTSerialNumber%

            or, for a single assignment, `variable:` and `value:`.

            Values are expanded with Expand-HDTVariableToken against the LIVE
            dictionary, in document order, so a later key in the same step can
            reference an earlier one. An unresolved token is left LITERAL and
            reported (02-03's rule): a token that silently became '' is how a
            machine ends up named 'PC-'.

            IT OVERWRITES, AND THAT IS THE POINT. Add-HDTResolvedVariable refuses
            to - first writer wins, because rule precedence is a precedence order
            rather than a race. This is the opposite case, so it writes
            $Context.Variable directly and does NOT join 02-03's closed
            provenance Source set. Its provenance is the var.resolve record on
            the JSONL stream, carrying data.source = 'Step' and the step name,
            which is what a technician reading the log actually needs.

            The record is written at Info rather than Debug, unlike a rule
            resolution: an authored mid-sequence assignment is a decision
            somebody made, not a derivation.

            IT REFUSES an _HDT* name, which is engine-owned and read-only,
and a name outside ^HDT[A-Za-z0-9_]*$ - both as
            terminating configuration errors, because a sequence that assigns the
            wrong namespace is broken authoring rather than a failed operation.
            A step with no assignment at all is a FAILED step rather than a
            throw: the loop decides what a failed step means.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context.

        .OUTPUTS
            A New-HDTStepResult.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'SetVariable' })[0]

            Invoke-HDTSetVariableStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $null = Invoke-HDTSetVariableStep -Step $step -Context $context
            $context.Variable['HDTStage']

            The value the step assigned. It overwrites, unlike a rule: a SetVariable
            step says "this is true from here on".
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $property = $Step.Property

    $assignment = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($null -ne $property -and $property.Contains('variables') -and
        ($property['variables'] -is [System.Collections.IDictionary])) {

        foreach ($key in @($property['variables'].Keys)) {
            $assignment[[string] $key] = $property['variables'][$key]
        }
    }

    if ($null -ne $property -and $property.Contains('variable')) {
        $value = $null
        if ($property.Contains('value')) {
            $value = $property['value']
        }

        $assignment[[string] $property['variable']] = $value
    }

    if (@($assignment.Keys).Count -eq 0) {
        $message = "step '{0}' declares no assignment. A SetVariable step declares either a variables mapping or a variable and value pair." -f $Step.Name

        Write-HDTLog -Context $Context.Log -Message $message -Severity Error -Event step.fail -Component 'SetVariable'

        return (New-HDTStepResult -Status Failed -Message $message)
    }

    foreach ($name in @($assignment.Keys)) {
        if ($name.StartsWith('_')) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                        -Message ("step '{0}': '{1}' is engine-owned and cannot be assigned. A variable named _HDT* is set by the engine and is read-only." -f $Step.Name, $name)))
        }

        if ($name -cnotmatch '^HDT[A-Za-z0-9_]*$') {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                        -Message ("step '{0}': '{1}' is not an HDT variable name. Every deployment variable is prefixed HDT; run Get-HDTVariableMap for the MDT translation." -f $Step.Name, $name)))
        }
    }

    foreach ($name in @($assignment.Keys)) {
        $unresolved = New-Object -TypeName System.Collections.ArrayList

        $raw = $assignment[$name]
        $value = $raw

        if ($raw -is [string]) {
            $value = Expand-HDTVariableToken -Value $raw -Scope $Context.Variable -Unresolved $unresolved
        }

        # The write is direct and overwriting, which is the whole difference
        # between this and Add-HDTResolvedVariable.
        $Context.Variable[$name] = $value

        $data = [ordered] @{
            name   = $name
            value  = $value
            source = 'Step'
            step   = [string] $Step.Name
        }

        if (@($unresolved).Count -gt 0) {
            $data['unresolved'] = [string[]] @($unresolved)
        }

        Write-HDTLog -Context $Context.Log -Event 'var.resolve' -Component 'SetVariable' `
            -Message ("{0} = '{1}' (Step)" -f $name, $value) -Data $data

        if (@($unresolved).Count -gt 0) {
            Write-HDTLog -Context $Context.Log -Severity Warning -Event 'var.resolve' -Component 'SetVariable' `
                -Message ("{0} variable token(s) were never supplied and are left unexpanded: {1}." -f
                    @($unresolved).Count, (@($unresolved) -join ', ')) `
                -Data ([ordered] @{ name = $name; source = 'Step'; step = [string] $Step.Name; unresolved = [string[]] @($unresolved) })
        }
    }

    return (New-HDTStepResult -Status Completed `
            -Message ("set {0}: {1}" -f @($assignment.Keys).Count, (@($assignment.Keys) -join ', ')))
}
