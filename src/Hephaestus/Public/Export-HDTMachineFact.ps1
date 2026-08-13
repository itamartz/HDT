function Export-HDTMachineFact {
    <#
        .SYNOPSIS
            Writes gathered facts to DESIGN 4.4's Gather\facts.json.

        .DESCRIPTION
            DESIGN 4.4 puts "facts.json - resolved facts (3.2)" beside
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

        .PARAMETER Timestamp
            The instant recorded as "generated". Mandatory, and deliberately so:
            the engine has an IClock and must pass its answer, and a test passes a
            fixed one so it can assert an exact document. A default of "now" would
            put a real clock reading inside engine code, which PROJECT constraint
            4 exists to prevent.

        .OUTPUTS
            None.

        .EXAMPLE
            Export-HDTMachineFact -Fact $fact `
                -Path (Join-Path $logPath 'Gather\facts.json') `
                -FileSystem (New-HDTFileSystem) -Timestamp $clock.GetUtcNow()
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

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem,

        [Parameter(Mandatory = $true)]
        [datetime] $Timestamp
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $entry = [ordered] @{}
    foreach ($key in @($Fact.Keys)) {
        $entry[[string] $key] = $Fact[$key]
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
