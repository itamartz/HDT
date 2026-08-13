function Get-HDTLogRecord {
    <#
        .SYNOPSIS
            Reads HDT.jsonl back out of an IFileSystem and parses it into
            objects.

        .DESCRIPTION
            Every assertion about what the engine DID is an assertion about the
            JSONL stream (DESIGN 4.4.2): the ordered step names, the skip
            reasons, one reboot.arm record, the seq continuing across a leg
            boundary. Each of those otherwise starts with the same
            split-and-parse, so it lives here once.

            A log that was never written returns nothing rather than throwing: a
            run that failed before its first log call is a legitimate case to
            assert about.

            NEVER -AsHashtable. ConvertFrom-Json -AsHashtable is PowerShell 6+
            only, and this helper runs under Windows PowerShell 5.1 like
            everything else in the suite.

            THE READ IS RECORDED by the service, so call this after any assertion
            about the operation list rather than before - the same caveat
            Get-HDTAutoLogonArtifact carries.

        .PARAMETER FileSystem
            An IFileSystem - a fake in a unit test, the real adapter against a
            machine.

        .PARAMETER Path
            The JSONL file, conventionally the log context's JsonlPath.

        .PARAMETER Event
            Keep only records whose event is one of these.

        .PARAMETER Severity
            Keep only records whose level is one of these.

        .PARAMETER Raw
            Return the file's text instead of parsed records, for an assertion
            that a secret appears nowhere in it.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[], or System.String with
            -Raw.

        .EXAMPLE
            Get-HDTLogRecord -FileSystem $harness.FileSystem -Path $harness.Log.JsonlPath -Event step.start |
                ForEach-Object { $_.stepName }

        .EXAMPLE
            Get-HDTLogRecord -FileSystem $fs -Path $log.JsonlPath -Raw | Should -Not -BeLike "*$password*"
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Event',
        Justification = 'DESIGN 4.4.2 names this field event; it is never PowerShell eventing''s automatic variable.')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem,

        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [AllowNull()]
        [string[]] $Event,

        [Parameter()]
        [AllowNull()]
        [string[]] $Severity,

        [Parameter()]
        [switch] $Raw
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not $FileSystem.TestPath($Path)) {
        if ($Raw) {
            return ''
        }

        return @()
    }

    $text = [string] $FileSystem.ReadAllText($Path)

    if ($Raw) {
        return $text
    }

    $record = New-Object -TypeName System.Collections.ArrayList

    foreach ($line in @($text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        [void] $record.Add((ConvertFrom-Json -InputObject $line))
    }

    $result = @($record)

    if ($PSBoundParameters.ContainsKey('Event') -and $null -ne $Event) {
        $result = @($result | Where-Object { $Event -contains [string] $_.event })
    }

    if ($PSBoundParameters.ContainsKey('Severity') -and $null -ne $Severity) {
        $result = @($result | Where-Object { $Severity -contains [string] $_.level })
    }

    return [object[]] $result
}
