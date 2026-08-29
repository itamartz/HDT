function Export-HDTVariableProvenance {
    <#
        .SYNOPSIS
            Writes a resolution's provenance to Gather\provenance.json.

        .DESCRIPTION
            provenance.json - every variable and which source set
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

            A SECRET'S VALUE IS NOT IN IT. Every variable Get-HDTVariableMap
            marks IsSecret is written with its name, its source and its rule
            intact and its value replaced by "(set, not shown)" - the same words
            the wizard summary uses. This file was found on a deployed machine
            carrying the local administrator password in clear, and SLShare
            copies it to the deployment share.

        .PARAMETER Resolution
            A Resolve-HDTVariable result.

        .PARAMETER Path
            Where to write it. Conventionally <_HDTLogPath>\Gather\provenance.json.
            Parent directories are created by the filesystem service.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production, New-HDTFakeFileSystem
            in a test.
            Defaults to the real one.

        .PARAMETER Timestamp
            The instant recorded as "generated". Defaults to now, in UTC; a test
            supplies a fixed one so it can assert on an exact document.

        .OUTPUTS
            None.

        .EXAMPLE
            $fact = Get-HDTMachineFact -CimProvider (New-HDTCimProvider) `
                -RegistryService (New-HDTRegistryService) -EnvironmentProvider (New-HDTEnvironmentProvider)
            $resolution = Resolve-HDTVariable -Fact $fact
            Export-HDTVariableProvenance -Resolution $resolution -Path 'X:\HDT\Logs\Gather\provenance.json'

            Not just what each variable ended up as, but which of the five sources set
            it and which rule won. That is the question somebody actually has
            when a machine comes out named wrong.

        .EXAMPLE
            Export-HDTVariableProvenance -Resolution $resolution -Path 'X:\HDT\Logs\Gather\provenance.json' -WhatIf

            Names the file and writes nothing.

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

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [datetime] $Timestamp = [datetime]::UtcNow
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # THE SECRETS, FROM THE ONE PLACE THAT KNOWS WHICH THEY ARE. Read on a
    # deployed machine's C:\HDT\Logs\<run>\Gather\provenance.json:
    # HDTAdminPassword and its actual value, side by side. SLShare then copies
    # that file to the deployment share, where every machine being deployed can
    # read it.
    #
    # Get-HDTVariableMap RATHER THAN A WORD LIST HERE. Three writers already
    # needed to know which variables are secret and each answered it its own
    # way; a fourth private list is a fourth thing to forget to update, and this
    # file is the one that gets it wrong silently.
    $secret = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($mapped in @(Get-HDTVariableMap)) {
        if ($mapped.IsSecret) { $secret[[string] $mapped.HDTName] = $true }
    }

    $entry = New-Object -TypeName System.Collections.ArrayList

    foreach ($record in @(Get-HDTVariableProvenance -Resolution $Resolution)) {
        $value = $record.Value
        $rawValue = $record.RawValue

        # THE NAME AND THE PROVENANCE STAY; ONLY THE VALUE GOES. "Which source
        # set the administrator password" is exactly the question this file
        # exists to answer, and dropping the entry would answer it with silence.
        #
        # AND SO DOES THE FACT THAT IT WAS SET. A redaction and an empty string
        # read identically in JSON and mean opposite things - the second is a
        # deployment that had no password and was going to fail - so the same
        # words the wizard summary uses are written instead of a blank.
        if ($secret.ContainsKey([string] $record.Name)) {
            if (-not [string]::IsNullOrEmpty([string] $value)) { $value = '(set, not shown)' }
            if (-not [string]::IsNullOrEmpty([string] $rawValue)) { $rawValue = '(set, not shown)' }
        }

        [void] $entry.Add([pscustomobject] ([ordered] @{
                    name      = $record.Name
                    value     = $value
                    source    = $record.Source
                    rule      = $record.Rule
                    ruleIndex = $record.RuleIndex
                    file      = $record.File
                    rawValue  = $rawValue
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
