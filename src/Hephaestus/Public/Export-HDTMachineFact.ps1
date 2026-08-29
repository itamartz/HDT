function Export-HDTMachineFact {
    <#
        .SYNOPSIS
            Writes gathered facts to Gather\facts.json.

        .DESCRIPTION
            facts.json - the resolved machine facts - sits beside
            provenance.json in the log directory of every deployment. This writes
            it, through the injected IFileSystem rather than a file-writing
            cmdlet, so the whole path is provable with nothing on disk (PROJECT
            constraint 4).

            The sibling of Export-HDTVariableProvenance, and it carries the same
            rule: THE TIMESTAMP IS FORMATTED BEFORE SERIALISATION. ConvertTo-Json
            renders a raw [datetime] as an ISO 8601 string under pwsh 7 and as
            "\/Date(1786579862481)\/" under Windows PowerShell 5.1 - and 5.1 is
            the engine that runs in WinPE, where this file is written. The
            round-trip 'o' format in the invariant culture is identical on both.

            The document:

              { "schemaVersion": 1,
                "generated": "2026-08-13T00:11:02.4810000Z",
                "fact": { "HDTSerialNumber": "...", "HDTMacAddress": [ ... ] } }

            Facts keep the order they were gathered in, so a facts.json diff
            between two machines stays readable. An array-valued fact stays an
            array: a multi-NIC machine has more than one MAC, and collapsing that
            to a scalar would make a driver rule matching on it silently wrong.

        .PARAMETER Fact
            A Get-HDTMachineFact result, or any dictionary of name to value.

        .PARAMETER Path
            Where to write it. Conventionally <_HDTLogPath>\Gather\facts.json.
            Parent directories are created by the filesystem service.

        .PARAMETER FileSystem
            An IFileSystem - New-HDTFileSystem in production,
            New-HDTFakeFileSystem in a test.
            Defaults to the real one.

        .PARAMETER Timestamp
            The instant recorded as "generated". Mandatory, and deliberately so:
            the engine has an IClock and must pass its answer, and a test passes a
            fixed one so it can assert an exact document. A default of "now" would
            put a real clock reading inside engine code, which PROJECT constraint
            4 exists to prevent.

        .OUTPUTS
            None.

        .EXAMPLE
            $fact = Get-HDTMachineFact
            $clock = New-HDTClock
            Export-HDTMachineFact -Fact $fact -Path 'X:\HDT\Logs\Gather\facts.json' -Timestamp $clock.GetUtcNow()

            Writes what the machine said about itself where a technician can read it
            afterwards. A file rather than a log line means it can be diffed
            against the next run.

        .EXAMPLE
            Export-HDTMachineFact -Fact $fact -Path 'X:\HDT\Logs\Gather\facts.json' -Timestamp $clock.GetUtcNow() -WhatIf

            Names the file and writes nothing.

    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Fact,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter(Mandatory = $true)]
        [datetime] $Timestamp
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # THE SAME RULE AS ITS SIBLING, THOUGH NOTHING HAS PUT A SECRET HERE YET.
    # This is a name-and-value serialiser writing into the log directory that
    # SLShare copies to the share, which is the whole shape of the defect that
    # put the local administrator password in HDT.jsonl, HDT.log and state.json:
    # four writers of the same kind, one of which asked whether the name was a
    # secret. A rule script can add a fact under any name it likes, so this one
    # asks too - and the asking is one call, to the one place that knows.
    $entry = [ordered] @{}
    foreach ($key in @($Fact.Keys)) {
        $entry[[string] $key] = Protect-HDTSecretValue -Name ([string] $key) -Value $Fact[$key]
    }

    # A [string], never the [datetime] itself - see the description.
    $generated = $Timestamp.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)

    $document = [ordered] @{
        schemaVersion = 1
        generated     = $generated
        fact          = $entry
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Write machine facts')) {
        $FileSystem.WriteAllText($Path, (ConvertTo-Json -InputObject $document -Depth 6))
    }
}
