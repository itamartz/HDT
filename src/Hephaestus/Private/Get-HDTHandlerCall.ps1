function Get-HDTHandlerCall {
    <#
        .SYNOPSIS
            The scriptblock a window handler calls a private helper through.

        .DESCRIPTION
            EVERY HANDLER IN A WINDOW IS A CLOSURE, AND A CLOSURE CANNOT SEE
            A PRIVATE FUNCTION. .GetNewClosure() rebinds a scriptblock to the
            session state of whoever called the method it was built in - the
            console's, not the module's - so a command named inside a button
            handler is resolved out there, where only an exported function
            exists.

            THAT IS WHY THIRTY-THREE VIEW-MODEL HELPERS USED TO BE EXPORTED. Not
            a judgement about the public surface: a side effect of how the
            windows are wired - the admin console's and the WinPE wizard's alike.
            An administrator running Get-Command against this
            module met Get-HDTConsoleStepOption and Get-HDTConsolePartitionRow
            sitting beside New-HDTWorkspace, and nothing told them which of the
            two they were meant to type.

            A SCRIPTBLOCK MADE HERE KEEPS THE MODULE'S SESSION STATE. This
            function is dot-sourced into the module, so the block below resolves
            commands the way the module does - private ones included - and it
            goes on doing that after a closure has captured it as a variable,
            because invoking a scriptblock uses the scriptblock's own state and
            not the caller's. So a handler does

                $call = Get-HDTHandlerCall          # in the method body
                $handler = { & $call 'Get-HDTConsoleTreeNode' -Workspace $w }.GetNewClosure()

            and the helper it names never has to be public.

            REBINDING THE HANDLER INSTEAD DOES NOT WORK, and was tried:
            $module.NewBoundScriptBlock($closure) returns a scriptblock with the
            module's command resolution and none of the variables the closure
            captured - which, for a handler, is the window it was built around.

        .OUTPUTS
            System.Management.Automation.ScriptBlock. Call it with the command
            name first and that command's own arguments after.

        .EXAMPLE
            $call = Get-HDTHandlerCall
            & $call 'Get-HDTConsoleTheme'

        .EXAMPLE
            $call = Get-HDTHandlerCall
            & $call 'Get-HDTConsoleTreeNode' -Workspace $where -FileSystem $fileSystem

        .EXAMPLE
            $call = Get-HDTHandlerCall
            & $call 'Get-HDTConsoleClosePrompt' @{ DocumentPath = $path; Dirty = $true }

            A switch whose value is in a variable has to travel as a hashtable;
            -Dirty:$value binds against this scriptblock rather than the command.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE COMMAND IS INVOKED BY NAME, NOT AS A DETACHED SCRIPTBLOCK, so it stays
    # a function call: $PSCmdlet, ShouldProcess, the error records it throws and
    # the name in a stack trace are all what they would have been.
    #
    # $args[0] is the name and the rest is spread back over the call. A named
    # argument arrives as two entries - '-Workspace' and its value - and
    # splatting an array of those binds them as named parameters again.
    return {
        $rest = @()
        if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }

        # ONE HASHTABLE IS A SPLAT, AND IT IS THE ONLY FORM THAT CAN CARRY A
        # SWITCH. -Dirty:$book.Dirty does not survive the trip: the colon form
        # is parsed against THIS scriptblock, which has no -Dirty, so the name
        # and the value arrive as two loose arguments and the value binds
        # positionally - "a positional parameter cannot be found that accepts
        # argument 'False'", from inside a window, with nothing naming the
        # switch. A hashtable binds Dirty = $false the way it is meant to.
        if ($rest.Count -eq 1 -and $rest[0] -is [System.Collections.IDictionary]) {
            $table = $rest[0]

            & $args[0] @table
            return
        }

        & $args[0] @rest
    }
}
