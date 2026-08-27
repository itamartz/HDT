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

        # EVERY COMMAND THE CONSOLE RUNS PASSES THROUGH HERE, which is why the
        # log is here and not in eighty handlers. It records what was invoked,
        # how long it took, and the whole exception when one is thrown -
        # including the ones a handler catches and turns into a status line,
        # where the message survives and the TYPE and the STACK do not.
        #
        # PARAMETER NAMES, NEVER VALUES. The console is where the local
        # administrator password is set (DESIGN 4.5.2), and a log that
        # helpfully recorded every argument would be the one place that password
        # came to rest in plain text on an administrator's workstation.
        $logName = [string] $args[0]
        $logParameter = @()
        $logArgument = [ordered] @{}

        if ($rest.Count -eq 1 -and $rest[0] -is [System.Collections.IDictionary]) {
            foreach ($key in @($rest[0].Keys)) {
                $logParameter += [string] $key
                $logArgument[[string] $key] = $rest[0][$key]
            }
        } else {
            for ($i = 0; $i -lt $rest.Count; $i++) {
                if (-not ($rest[$i] -is [string])) { continue }
                if (-not ([string] $rest[$i]).StartsWith('-')) { continue }

                $named = ([string] $rest[$i]).TrimStart('-')
                $logParameter += $named

                # A SWITCH HAS NO VALUE AFTER IT, so the next entry is only its
                # argument when it is not itself a parameter name.
                $value = $true
                if ($i + 1 -lt $rest.Count -and -not (($rest[$i + 1] -is [string]) -and ([string] $rest[$i + 1]).StartsWith('-'))) {
                    $value = $rest[$i + 1]
                }

                $logArgument[$named] = $value
            }
        }

        # THE RENDERING - AND THE REDACTION - LIVE IN Format-HDTConsoleLogValue,
        # not here. Inside this closure the only way to exercise a -Password was
        # to invoke a real command that has one, and the tests written that way
        # failed with "a parameter cannot be found that matches parameter name
        # 'Password'" - proving nothing about redaction while looking like they
        # covered it. A private function takes any name and any value.
        $logValue = Get-Command -Name 'Format-HDTConsoleLogValue'

        $logStarted = [datetime]::UtcNow

        # A LOG THAT CANNOT WRITE MUST NOT TAKE THE WINDOW DOWN. Wrapped
        # separately from the command so a broken log never turns into a broken
        # console - which is the defect adding logging would otherwise create.
        $writeConsoleLog = {
            # $EventName, NOT $Event: $Event is an automatic variable, and
            # shadowing it inside a scriptblock that WPF invokes from an event
            # handler is asking for the one confusion nobody would find.
            param([string] $EventName, [string] $Message, [object] $Data, [string] $Severity)

            try {
                if ($null -eq $script:HDTConsoleLogContext) { return }

                Write-HDTLog -Context $script:HDTConsoleLogContext -Event $EventName `
                    -Component 'Console' -Message $Message -Data $Data -Severity $Severity
            } catch {
                Write-Verbose ("the console log refused a write: {0}" -f [string] $_.Exception.Message)
            }
        }

        $logFailed = {
            param([object] $Record)

            $exception = $Record.Exception
            $type = ''
            if ($null -ne $exception) { $type = [string] $exception.GetType().FullName }

            $elapsed = [long] ([datetime]::UtcNow - $logStarted).TotalMilliseconds

            & $writeConsoleLog 'console.error' ('{0} threw after {1} ms: {2} ({3})' -f
                (& $logCall), $elapsed, [string] $Record.Exception.Message, $type) ([ordered] @{
                    command    = $logName
                    parameter  = [string[]] @($logParameter)
                    type       = $type
                    # THE STACK IS THE POINT. A message alone says what broke and
                    # never where, and 'the console crashed' was answered by
                    # reading source for want of exactly this.
                    stack      = [string] $Record.ScriptStackTrace
                    position   = [string] $Record.InvocationInfo.PositionMessage
                    phase      = 'threw'
                    durationMs = $elapsed
                }) 'Error'
        }

        # THE MESSAGE CARRIES THE FACTS, because the message is what a human
        # reads. HDT.log is CMTrace format and shows the MESSAGE; the JSONL
        # beside it keeps the structured copy for a parser. A log of eighty
        # lines all reading 'Get-HDTConsoleTreeNode ran' tells an administrator
        # only that something happened eighty times.
        #
        # PARAMETER NAMES BELONG IN IT for the same reason - which overload of a
        # command ran is half of what "what did the console do" means - and the
        # VALUES still never appear: the console is where the local
        # administrator password is set.
        # THE COMMAND AS SOMEBODY COULD RETYPE IT. Names alone answered "which
        # command ran" and nothing else - and 'Get-HDTConsoleDriverRow ran',
        # eighty times, is a log that records that something happened rather
        # than what. WHICH folder was read, WHICH share, WHICH sequence: those
        # are the facts a report is reconstructed from.
        $logCall = {
            $said = $logName

            foreach ($name in @($logParameter)) {
                $value = $null
                if ($logArgument.Contains($name)) { $value = $logArgument[$name] }

                $rendered = & $logValue -Name $name -Value $value

                # A switch reads as -PerDriver, not as -PerDriver $true.
                if ($rendered -eq '$true') {
                    $said = '{0} -{1}' -f $said, $name
                    continue
                }

                $said = '{0} -{1} {2}' -f $said, $name, $rendered
            }

            return $said
        }

        # LOGGED BEFORE IT RUNS, WHICH IS THE WHOLE POINT OF A CRASH LOG. Only
        # logging on completion means a command that hangs, or one that takes
        # the process down, leaves NO RECORD IT WAS EVER STARTED - so the log
        # is silent about exactly the failure somebody opened it for. The
        # console crash of 2026-08-28 would have left nothing.
        #
        # The pair reads as a story: 'started' with no 'ran' after it is the
        # command that did not come back, and its name is the answer.
        $logBegin = {
            & $writeConsoleLog 'console.action' ('{0} started' -f (& $logCall)) ([ordered] @{
                    command   = $logName
                    parameter = [string[]] @($logParameter)
                    phase     = 'started'
                }) 'Debug'
        }

        $logDone = {
            $elapsed = [long] ([datetime]::UtcNow - $logStarted).TotalMilliseconds

            & $writeConsoleLog 'console.action' ('{0} ran in {1} ms' -f (& $logCall), $elapsed) ([ordered] @{
                    command    = $logName
                    parameter  = [string[]] @($logParameter)
                    phase      = 'ran'
                    durationMs = $elapsed
                }) 'Debug'
        }

        # ONE HASHTABLE IS A SPLAT, AND IT IS THE ONLY FORM THAT CAN CARRY A
        # SWITCH. -Dirty:$book.Dirty does not survive the trip: the colon form
        # is parsed against THIS scriptblock, which has no -Dirty, so the name
        # and the value arrive as two loose arguments and the value binds
        # positionally - "a positional parameter cannot be found that accepts
        # argument 'False'", from inside a window, with nothing naming the
        # switch. A hashtable binds Dirty = $false the way it is meant to.
        # BEFORE THE CALL, which is the whole point and which this did not do:
        # $logBegin was built and never invoked, so the 'started' record existed
        # in the source and never in a file. PSScriptAnalyzer said so -
        # PSUseDeclaredVarsMoreThanAssignments, "assigned, never used" - and a
        # test asserting the record was there said so too. A log that only
        # writes on completion is silent about the command that never completed,
        # which is the failure somebody opens a crash log for.
        [void] (& $logBegin)

        # THE COMMAND IS STILL INVOKED THE SAME WAY. The try only observes: it
        # rethrows every error untouched, so a handler that catches a specific
        # failure and shows a sentence still sees exactly what it saw before.
        try {
            if ($rest.Count -eq 1 -and $rest[0] -is [System.Collections.IDictionary]) {
                $table = $rest[0]

                & $args[0] @table
            } else {
                & $args[0] @rest
            }
        } catch {
            # [void], NOT a bare call. The handlers read this scriptblock's
            # output - '$imported = & $call ''Import-HDTDriver'' @{...}' - so a
            # single stray object from the logging would arrive as part of the
            # command's result and be read as a property off the wrong thing.
            [void] (& $logFailed $_)
            throw
        }

        [void] (& $logDone)
    }
}
