function Get-HDTRunLogRecord {
    <#
        .SYNOPSIS
            Reads a run's JSONL back into records.

        .DESCRIPTION
            ONE READER, TWO SCREENS. The progress window and the failure window
            are both derived from the JSONL the engine writes anyway (DESIGN
            11.1: one source of truth, so the screen and the log cannot
            disagree) - and until this existed, reading it was fifteen lines
            copied into whichever command needed them. Two copies of "read the
            log" is two answers about a half-written line.

            A HALF-WRITTEN LINE IS SKIPPED, NEVER FATAL. A JSONL whose last line
            is a fragment is exactly what a machine that died mid-step leaves
            behind, and that is precisely the run somebody wants to read. JSON
            Lines is one object per physical line so that a reader can do this.

            IT NEVER THROWS FOR A MISSING LOG. A run that failed before the log
            context existed has nothing to read, and a reader that threw would
            replace the real failure with its own.

        .PARAMETER Context
            The log context from New-HDTLogContext. Its JsonlPath and FileSystem
            are the only things read.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] - the records, oldest
            first. An empty array when there is nothing to read.

        .EXAMPLE
            $record = Get-HDTRunLogRecord -Context $log
            Get-HDTDeploymentProgress -Record $record
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $record = New-Object -TypeName System.Collections.ArrayList

    try {
        if ($null -eq $Context) { return [pscustomobject[]] @() }
        if ($null -eq $Context.PSObject.Properties['JsonlPath'] -or
            $null -eq $Context.PSObject.Properties['FileSystem']) {
            return [pscustomobject[]] @()
        }

        $path = [string] $Context.JsonlPath
        if ([string]::IsNullOrWhiteSpace($path)) { return [pscustomobject[]] @() }

        $fileSystem = $Context.FileSystem
        if ($null -eq $fileSystem -or -not $fileSystem.TestPath($path)) { return [pscustomobject[]] @() }

        $text = [string] $fileSystem.ReadAllText($path)
        if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject[]] @() }

        foreach ($line in ($text -split "`n")) {

            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

            # PER LINE, BECAUSE ONE BAD LINE MUST NOT COST THE OTHERS.
            try {
                [void] $record.Add((ConvertFrom-Json -InputObject $trimmed))
            } catch {
                continue
            }
        }
    } catch {
        # See the header: a reader that threw would replace the failure it was
        # called to explain.
        Write-Verbose ("the run log could not be read: {0}" -f [string] $_.Exception.Message)
    }

    return [pscustomobject[]] @($record)
}
