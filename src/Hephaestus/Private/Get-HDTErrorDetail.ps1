function Get-HDTErrorDetail {
    <#
        .SYNOPSIS
            Turns a caught ErrorRecord into the structured diagnostics a log
            record should carry.

        .DESCRIPTION
            WHAT A catch ACTUALLY HAS, AND WHAT THE LOG USED TO GET. Every
            failure path in the engine used to write $_.Exception.Message and
            nothing else. On run-20260830-204613 that produced, as the entire
            record for a fatal step failure:

              The task sequence stopped: Exception calling "SetValue" with "4"
              argument(s): "The running command stopped because the preference
              variable "ErrorActionPreference" or common parameter is set to
              Stop: Cannot delete a subkey tree because the subkey does not
              exist."

            Three quoted layers deep, naming SetValue while the real failure was
            a DELETE inside it, with no exception type, no file, no line and no
            stack. That is not something an administrator can act on, and it is
            not something an engineer can debug either - finding the defect took
            reading the adapter, because the log named the symptom.

            THE OUTERMOST LAYER IS THE LEAST INFORMATIVE ONE, AND IT IS THE ONE
            THAT USED TO WIN. "Exception calling X with N argument(s)" is
            PowerShell describing its own method-call plumbing. The sentence that
            says what went wrong is the INNERMOST. So `cause` comes from the
            bottom of the InnerException chain.

            AND EVERY LAYER IS KEPT, not just the innermost. The chain is itself
            evidence: it is what says the ArgumentException arrived through a
            ScriptMethod, under ErrorActionPreference Stop, rather than being
            thrown directly - which is the difference between "the registry
            refused" and "an adapter called something it should not have".

            Nothing here is trimmed to keep the record small. A deployment log is
            read once, at the worst possible moment, by somebody who was not
            there when it ran; the stack trace that looks like noise today is the
            only thing that will answer the question then.

            IT NEVER THROWS. A record built by hand or rehydrated from a remote
            session may carry no InvocationInfo at all, and a describer that
            failed while describing a failure would replace the real error with
            its own.

        .PARAMETER ErrorRecord
            The ErrorRecord from a catch block.

        .OUTPUTS
            System.Collections.Specialized.OrderedDictionary, ready to hand to
            Write-HDTLog -Data.

        .EXAMPLE
            try { $registry.SetValue($path, 'AutoAdminLogon', '1', 'String') }
            catch {
                Write-HDTLog -Context $log -Severity Error -Event 'step.fail' `
                    -Message (Get-HDTErrorSummary -ErrorRecord $_) `
                    -Data (Get-HDTErrorDetail -ErrorRecord $_)
            }

            The record then names the ArgumentException, the file, the line and
            the call chain instead of "Exception calling SetValue".
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $ErrorRecord
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # READ DEFENSIVELY THROUGHOUT. Under Set-StrictMode -Version Latest a missing
    # property is a terminating error, and this function's whole job is to run on
    # the worst input in the process.
    $readProperty = {
        param([object] $Object, [string] $Name)

        if ($null -eq $Object) { return $null }
        if ($null -eq $Object.PSObject.Properties[$Name]) { return $null }

        return $Object.PSObject.Properties[$Name].Value
    }

    $outer = & $readProperty $ErrorRecord 'Exception'

    # EVERY LAYER, OUTERMOST FIRST. A cycle is not possible through
    # InnerException in practice, but the bound is there because an unbounded
    # walk over attacker- or plugin-supplied exceptions is not a thing to write.
    $chain = [System.Collections.ArrayList]::new()
    $layer = $outer
    $guard = 0

    while ($null -ne $layer -and $guard -lt 32) {
        [void] $chain.Add([ordered] @{
                depth   = $guard
                type    = $layer.GetType().FullName
                message = [string] $layer.Message
            })

        $layer = & $readProperty $layer 'InnerException'
        $guard++
    }

    # The innermost layer is the cause; with no chain at all there is nothing to
    # take it from, and the record still has to come out.
    $innermost = $null
    if ($chain.Count -gt 0) { $innermost = $chain[$chain.Count - 1] }

    $cause = ''
    $innerType = ''
    if ($null -ne $innermost) {
        $cause = [string] $innermost['message']
        $innerType = [string] $innermost['type']
    }

    $outerType = ''
    $outerMessage = ''
    if ($null -ne $outer) {
        $outerType = $outer.GetType().FullName
        $outerMessage = [string] $outer.Message
    }

    $invocation = & $readProperty $ErrorRecord 'InvocationInfo'

    $scriptName = [string] (& $readProperty $invocation 'ScriptName')
    $lineNumber = 0
    $rawLine = & $readProperty $invocation 'ScriptLineNumber'
    if ($null -ne $rawLine) { $lineNumber = [int] $rawLine }

    # PositionMessage IS THE SINGLE MOST USEFUL FIELD and it is multi-line by
    # design - it draws the offending line with a caret under it. It goes in
    # whole. Only the CMTrace twin, which is read by eye, gets the one-line
    # summary instead; see Get-HDTErrorSummary.
    $position = [string] (& $readProperty $invocation 'PositionMessage')

    $commandName = ''
    $myCommand = & $readProperty $invocation 'MyCommand'
    if ($null -ne $myCommand) { $commandName = [string] $myCommand }

    $invocationName = [string] (& $readProperty $invocation 'InvocationName')

    $category = ''
    $categoryInfo = & $readProperty $ErrorRecord 'CategoryInfo'
    if ($null -ne $categoryInfo) { $category = [string] $categoryInfo.ToString() }

    $targetName = ''
    if ($null -ne $categoryInfo) { $targetName = [string] (& $readProperty $categoryInfo 'TargetName') }

    return ([ordered] @{
            cause                 = $cause
            exceptionType         = $innerType
            outerExceptionType    = $outerType
            outerMessage          = $outerMessage
            layerCount            = [int] $chain.Count
            exceptionChain        = [object[]] @($chain)
            scriptName            = $scriptName
            scriptLineNumber      = $lineNumber
            position              = $position
            commandName           = $commandName
            invocationName        = $invocationName
            category              = $category
            targetName            = $targetName
            fullyQualifiedErrorId = [string] (& $readProperty $ErrorRecord 'FullyQualifiedErrorId')
            stackTrace            = [string] (& $readProperty $ErrorRecord 'ScriptStackTrace')
        })
}
