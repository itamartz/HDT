function Invoke-HDTPowerShellStep {
    <#
        .SYNOPSIS
            Runs a user PowerShell script from the workspace.

        .DESCRIPTION
            The extensibility point:

              - name: Vendor BIOS Update
                type: PowerShell
                script: Scripts\Update-VendorBios.ps1
                log: BiosUpdate.log

            The script runs through the injected IScriptInvoker - never with a
            bare call operator and never by launching a process - so a sequence
            carrying a PowerShell step is provable under Pester with nothing
            executed. The step contract test greps this
            file for the cmdlet names that would break that, which is why they do
            not appear even in prose.
            It receives the LIVE variable dictionary as -Variable, so a script may
            read every resolved variable and, being live, an assignment a previous
            step made is visible to it.

            A relative script path is resolved against the workspace root here, so
            the invoker is handed an absolute path and the same sequence works
            from a share or from standalone media.

            EVERYTHING THE SCRIPT WROTE IS LOGGED. GetTranscript() returns what
            the invoker captured, and each line is written through Write-HDTLog,
            which puts it in HDT.jsonl, HDT.log and the executing step's own log
            at once. That is a hard requirement - "an existing script
            that only uses Write-Host still lands in the log without
            modification" - and it is why IScriptInvoker has a transcript at all.

            A SCRIPT THAT THREW IS A FAILED STEP, NOT A FAILED RUN. The exception
            is caught, logged and returned as Failed with its message.
            continueOnError, the retry policy and the failure classification
            all belong to the loop, which cannot make any of those
            decisions about an exception that flew past it.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument. Its Property carries
            `script`.

        .PARAMETER Context
            A New-HDTExecutionContext context.

        .OUTPUTS
            A New-HDTStepResult. Data carries whatever object the script emitted.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'PowerShell' })[0]

            Invoke-HDTPowerShellStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTPowerShellStep -Step $step -Context $context
            $result.Data.ExitCode

            The script's exit code. The script runs from the workspace's Scripts\
            folder, which is why the engine's own commands are in scope for it.
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

    $scriptPath = ''
    if ($null -ne $property -and $property.Contains('script')) {
        $scriptPath = [string] $property['script']
    }

    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $message = "step '{0}' declares no script. A PowerShell step names a script relative to the workspace root." -f $Step.Name

        Write-HDTLog -Context $Context.Log -Message $message -Severity Error -Event step.fail -Component 'PowerShell'

        return (New-HDTStepResult -Status Failed -Message $message)
    }

    $invoker = $Context.Service.GetRequired('ScriptInvoker', 'PowerShell')

    # [System.IO.Path]::Combine, not Join-Path: Join-Path resolves the drive
    # qualifier through the PowerShell provider and throws "Cannot find drive"
    # for a workspace on a drive this session cannot see - which is every
    # WinPE-side path evaluated from a technician's desk, and every test.
    $resolved = $scriptPath
    if (-not [System.IO.Path]::IsPathRooted($scriptPath)) {
        $resolved = [System.IO.Path]::Combine([string] $Context.WorkspaceRoot, $scriptPath)
    }

    $result = $null
    $failure = $null

    try {
        $result = $invoker.Invoke($resolved, $Context.Variable)
    } catch {
        $failure = $_
    }

    foreach ($line in @($invoker.GetTranscript())) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        Write-HDTLog -Context $Context.Log -Message $line -Component 'PowerShell' -Source $scriptPath
    }

    if ($null -ne $failure) {
        Write-HDTLog -Context $Context.Log -Message $failure.Exception.Message -Severity Error `
            -Event step.fail -Component 'PowerShell' `
            -Data ([ordered] @{ script = $resolved })

        return (New-HDTStepResult -Status Failed -Message $failure.Exception.Message)
    }

    Write-HDTLog -Context $Context.Log -Message ("ran {0}" -f $resolved) -Event step.complete `
        -Component 'PowerShell' -Data ([ordered] @{ script = $resolved })

    return (New-HDTStepResult -Status Completed -Message ("ran {0}" -f $resolved) -Data $result)
}
