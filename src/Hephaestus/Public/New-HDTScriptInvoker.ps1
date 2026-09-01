function New-HDTScriptInvoker {
    <#
        .SYNOPSIS
            Creates the real IScriptInvoker adapter, which runs a setFrom: script
            and returns its output object.

        .DESCRIPTION
            The one place in HDT that executes a user extension script. When a
            rule needs real logic it calls a script -
            "setFrom: Scripts\Get-ComputerName.ps1" - whose output object becomes
            the variable set. PROJECT constraint 4 keeps that behind an interface
            so the rule engine can be proven without executing anything.

            The script is invoked as & $script -Variable $Variable *>&1, and the
            LAST item that is NOT a stream record is returned, so a script that
            traces to the output stream by accident does not corrupt the variable
            set. A script that emits nothing yields $null, which is a different
            fact from a script that does not exist.

            EVERYTHING IT WROTE IS KEPT, and GetTranscript() returns it - the
            captured output of the LAST Invoke, replaced on the next one. That is
            A hard requirement: "an existing script that only uses
            Write-Host still lands in the log without modification, since real
            fleets carry years of such scripts". Telling a transcript line from a
            result is a type test, not a guess: an InformationRecord, ErrorRecord,
            WarningRecord, VerboseRecord or DebugRecord is transcript, anything
            else is a candidate result. That is a branch inside an adapter, which
            the "adapters stay dumb" rule tolerates only because the IScriptInvoker
            contract proves it on BOTH implementations.

            A relative -Path is resolved against -Root, the workspace root, so
            the same 'Scripts\Get-ComputerName.ps1' written in rules.yaml works
            whether the workspace came from a share or from standalone media.

            A script that is not on disk throws System.IO.FileNotFoundException
            naming it. Note that a caller catches that wrapped: an exception
            thrown inside a ScriptMethod reaches the caller as
            MethodInvocationException -> RuntimeException -> the original, so a
            test asserting the type must unwrap to the innermost exception. The
            message survives unwrapped, because MethodInvocationException.Message
            embeds it.

            Every invocation is recorded in $Operations, before it can throw,
            exactly as the fakes record (tests/helpers/README.md section 4).

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

        .PARAMETER Root
            The workspace root a relative script path is resolved against.
            Defaults to the current location.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with an Invoke
            ScriptMethod. Note that Get-Member -MemberType Method does NOT list a
            ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $invoker = New-HDTScriptInvoker -Root 'C:\HDTLab\Share'
            $invoker.Invoke('Scripts\Get-ComputerName.ps1', @{ HDTSerialNumber = 'FIXTURE-SERIAL-0001' })

            Runs a setFrom: script against the variables resolved so far and returns
            what it emitted. This is how a rule computes a value the engine has no
            way to know.

        .EXAMPLE
            @($invoker.GetOperationName())

            Which scripts ran. A script is user code on the share, so what it was asked
            to run is recorded whether or not it worked.

    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
    # $result is assigned inside a ForEach-Object block and returned after it.
    # ForEach-Object does not open a new scope, so that is one variable and not
    # two - but the analyzer reads the block in isolation and sees a write with
    # no read. The contract tests 'returns the object the script emitted' and
    # 'does not return the host line as the result' both execute this path
    # against the REAL adapter, so the read is proven rather than argued.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'result',
        Justification = 'Assigned inside a ForEach-Object block, which shares the enclosing scope, and returned by the caller.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Root = (Get-Location).Path
    )

    $invoker = [pscustomobject] @{
        ServiceName    = 'ScriptInvoker'
        Root           = $Root
        Operations     = [System.Collections.ArrayList]::new()
        LastTranscript = [string[]] @()
    }

    $invoker | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })
    }

    $invoker | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return , ([string[]] @($this.Operations | ForEach-Object { $_.Operation }))
    }

    $invoker | Add-Member -MemberType ScriptMethod -Name ResolvePath -Value {
        param([string] $Path)

        if ([System.IO.Path]::IsPathRooted($Path)) {
            return $Path
        }

        return (Join-Path -Path $this.Root -ChildPath $Path)
    }

    $invoker | Add-Member -MemberType ScriptMethod -Name Invoke -Value {
        param([string] $Path, [System.Collections.IDictionary] $Variable)

        $this.Record('Invoke', @($Path, $Variable))

        $resolved = $this.ResolvePath($Path)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::new("Could not find script '$resolved'.", $resolved)
        }

        # The transcript belongs to the LAST invoke, so it is replaced rather
        # than appended to.
        $this.LastTranscript = [string[]] @()

        $transcript = New-Object -TypeName System.Collections.ArrayList
        $result = $null

        # THE finally IS THE WHOLE POINT, NOT TIDINESS. This used to assign
        # $LastTranscript after the loop, on the success path only - so a script
        # that threw skipped the assignment and GetTranscript() handed back the
        # PREVIOUS invoke's lines, which on a fresh invoker is nothing at all.
        #
        # Invoke-HDTPowerShellStep reads the transcript on the FAILURE path
        # specifically, so that a step which died still says what it was doing.
        # It was reading an empty array every time, and a failed PowerShell step
        # reached the log carrying its exception and not one line more.
        #
        # Found on a real Server 2025 WSUS build: an eight-hour catalogue sync
        # failed and its step log held exactly one line. The script had written
        # three attempts' worth of progress and every one of them was discarded
        # here; the actual cause had to be dug out of WSUS's own log over a
        # PowerShell Direct session.
        #
        # A step that succeeded can be read from its result. A step that threw
        # can only be read from what it printed on the way down.
        # ForEach-Object, NOT foreach over @(...), AND THE DIFFERENCE IS THE BUG.
        # An array subexpression COLLECTS the whole pipeline before the loop body
        # runs even once, so a script that threw on its last line threw out of
        # @() itself with $transcript still empty - the finally below then
        # faithfully saved nothing. ForEach-Object streams: every line the script
        # emitted before it failed is already in $transcript by the time the
        # exception reaches here.
        #
        # ForEach-Object does not open a new scope, so $result assigned inside the
        # block is the $result declared above.
        try {
            & $resolved -Variable $Variable *>&1 | ForEach-Object {
                $item = $_

                if (($item -is [System.Management.Automation.InformationRecord]) -or
                    ($item -is [System.Management.Automation.ErrorRecord]) -or
                    ($item -is [System.Management.Automation.WarningRecord]) -or
                    ($item -is [System.Management.Automation.VerboseRecord]) -or
                    ($item -is [System.Management.Automation.DebugRecord])) {

                    [void] $transcript.Add([string] $item)
                } else {
                    [void] $transcript.Add(($item | Out-String).Trim())
                    $result = $item
                }
            }
        } finally {
            $this.LastTranscript = [string[]] @($transcript)
        }

        return $result
    }

    $invoker | Add-Member -MemberType ScriptMethod -Name GetTranscript -Value {
        # The unary comma is mandatory: a ScriptMethod returning an array
        # collapses a single-element array to a scalar (README F3), and a
        # one-line transcript is the common case.
        return , ([string[]] @($this.LastTranscript))
    }

    return $invoker
}
