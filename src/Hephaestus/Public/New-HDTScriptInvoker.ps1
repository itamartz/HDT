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

            Runs a setFrom: script against the variables resolved so far and
            returns the object it emitted.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
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

        foreach ($item in @(& $resolved -Variable $Variable *>&1)) {
            if (($item -is [System.Management.Automation.InformationRecord]) -or
                ($item -is [System.Management.Automation.ErrorRecord]) -or
                ($item -is [System.Management.Automation.WarningRecord]) -or
                ($item -is [System.Management.Automation.VerboseRecord]) -or
                ($item -is [System.Management.Automation.DebugRecord])) {

                [void] $transcript.Add([string] $item)
                continue
            }

            [void] $transcript.Add(($item | Out-String).Trim())
            $result = $item
        }

        $this.LastTranscript = [string[]] @($transcript)

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
