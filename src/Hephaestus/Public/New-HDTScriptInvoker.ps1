function New-HDTScriptInvoker {
    <#
        .SYNOPSIS
            Creates the real IScriptInvoker adapter, which runs a setFrom: script
            and returns its output object.

        .DESCRIPTION
            The one place in HDT that executes a user extension script. DESIGN
            3.3: when a rule needs real logic it calls a script -
            "setFrom: Scripts\Get-ComputerName.ps1" - whose output object becomes
            the variable set. PROJECT constraint 4 keeps that behind an interface
            so the rule engine can be proven without executing anything.

            The script is invoked as & $script -Variable $Variable and its LAST
            output object is returned, so a script that traces to the output
            stream by accident does not corrupt the variable set. A script that
            emits nothing yields $null, which is a different fact from a script
            that does not exist.

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
            $invoker.Invoke('Scripts\Get-ComputerName.ps1', @{ HDTSerialNumber = 'PF3EKMR0' })

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
        Root       = $Root
        Operations = [System.Collections.ArrayList]::new()
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

        return (& $resolved -Variable $Variable | Select-Object -Last 1)
    }

    return $invoker
}
