function Export-HDTVariableProvenance {
    <#
        .SYNOPSIS
            Writes a resolution's provenance to DESIGN 4.4's
            Gather\provenance.json.

        .DESCRIPTION
            DESIGN 4.4 puts "provenance.json - every variable + which source set
            it (3.1)" in the log directory of every deployment. This writes it,
            through the injected IFileSystem rather than Set-Content, so the whole
            path is provable with nothing on disk.

            THE TIMESTAMP IS FORMATTED BEFORE SERIALISATION, and that is not a
            style choice. ConvertTo-Json renders a raw [datetime] as an ISO 8601
            string under pwsh 7 and as "\/Date(1786579862481)\/" under Windows
            PowerShell 5.1 - and 5.1 is the engine that runs in WinPE, so a raw
            [datetime] would make this file unreadable exactly where it matters.
            The value is rendered with the round-trip 'o' format in the invariant
            culture, which both engines produce identically. The same rule holds
            for every DateTime HDT ever writes to JSON.

            The document:

              { "schemaVersion": 1,
                "generated": "2026-08-13T00:11:02.4810000Z",
                "variable": [ { "name", "value", "source", "rule", "ruleIndex",
                                "file", "rawValue", "expanded", "order" } ] }

            Entries are in resolution order, so the file reads as a transcript of
            what the engine did.

        .PARAMETER Resolution
            A Resolve-HDTVariable result.

        .PARAMETER Path
            Where to write it. Conventionally <_HDTLogPath>\Gather\provenance.json.
            Parent directories are created by the filesystem service.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production, New-HDTFakeFileSystem
            in a test.

        .PARAMETER Timestamp
            The instant recorded as "generated". Defaults to now, in UTC; a test
            supplies a fixed one so it can assert on an exact document.

        .OUTPUTS
            None.

        .EXAMPLE
            Export-HDTVariableProvenance -Resolution $result `
                -Path (Join-Path $logPath 'Gather\provenance.json') `
                -FileSystem (New-HDTFileSystem)
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Resolution,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem,

        [Parameter()]
        [datetime] $Timestamp = [datetime]::UtcNow
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $entry = New-Object -TypeName System.Collections.ArrayList

    foreach ($record in @(Get-HDTVariableProvenance -Resolution $Resolution)) {
        [void] $entry.Add([pscustomobject] ([ordered] @{
                    name      = $record.Name
                    value     = $record.Value
                    source    = $record.Source
                    rule      = $record.Rule
                    ruleIndex = $record.RuleIndex
                    file      = $record.File
                    rawValue  = $record.RawValue
                    expanded  = $record.Expanded
                    order     = $record.Order
                }))
    }

    # A [string], never the [datetime] itself - see the description.
    $generated = $Timestamp.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)

    $document = [pscustomobject] ([ordered] @{
            schemaVersion = 1
            generated     = $generated
            variable      = @($entry)
        })

    if ($PSCmdlet.ShouldProcess($Path, 'Write variable provenance')) {
        $FileSystem.WriteAllText($Path, (ConvertTo-Json -InputObject $document -Depth 6))
    }
}
