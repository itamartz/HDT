function Assert-HDTMachineDocument {
    <#
        .SYNOPSIS
            Validates a parsed Control\machines\<UUID>.yaml against the
            authoring rules.

        .DESCRIPTION
            The engine's own validator, and the one that actually runs in WinPE:
            Test-Json does not exist under Windows PowerShell 5.1, so
            schemas/machine.schema.json is a gate for the console, editors and
            CI while this is the gate for a deployment.

            It throws on the first violation and returns nothing otherwise. Every
            failure is a terminating error built by New-HDTErrorRecord, so it
            names the file, carries it as its TargetObject and reports
            HDTConfigurationError.

            THIS IS DESIGN 3.1 SOURCE 2 - the per-machine database MDT kept in
            SQL, kept in a file instead. One document per machine, keyed by its
            UUID, and the whole reason it exists is to set variables for a
            machine that nothing else knows anything about.

            The authoring rules, in the order they are checked:

              document   not empty; a mapping; only schemaVersion and variables;
                         schemaVersion present, an integer, and not newer than
                         this engine
              variables  present, a mapping, and not empty
              name       every key prefixed HDT, case sensitively, and none of
                         them engine-owned

            AN OVERRIDE THAT SILENTLY DOES NOTHING IS THE FAILURE THIS CLOSES.
            An MDT database row with a misspelled column name is the classic
            un-debuggable deployment: the machine builds, the value is wrong, and
            nothing anywhere says why. So a key outside the HDT namespace is
            refused at author time rather than ignored at run time, and the
            message names the variable rather than the file alone.

            THE NAMESPACE CHECK IS CASE SENSITIVE, deliberately - -cnotmatch,
            not -notmatch. 'hdtComputerName' would set a variable no step reads,
            which is the same silent nothing spelled differently.

            AN EMPTY variables MAPPING IS REFUSED rather than treated as "no
            override". A file that exists is a statement of intent; an empty one
            is either half-written or a leftover, and both are better reported
            than obeyed.

            EXTRACTED FROM Get-HDTMachineOverride, WORD FOR WORD. The rules and
            every message here were that command's, inline; machine.schema.json
            was then the only schema in the repository with no validator beside
            it, which SchemaPairing.Contract.Tests.ps1 now refuses. The messages
            were not rewritten in the move - they are what an administrator at a
            bench reads, and Get-HDTMachineOverride.Tests.ps1 still asserts them
            from the other side of the call.

        .PARAMETER Document
            The parsed document, as returned by ConvertFrom-HDTYaml. $null is
            accepted and reported as an empty file rather than crashing.

        .PARAMETER Path
            The file the document came from. Used for the message and the
            TargetObject; this function reads nothing.

        .OUTPUTS
            None. It throws or it returns nothing.

        .EXAMPLE
            Assert-HDTMachineDocument -Document (ConvertFrom-HDTYaml -Yaml $text -Path $path) -Path $path

        .NOTES
            The locator in a message is the VARIABLE NAME or the KEY, not a line
            number: the YAML parser does not carry line information onto the
            object graph it returns, so after parsing there is no honest line to
            report. Only ConvertFrom-HDTYaml, which still holds the parser's own
            exception, can name a line.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Document,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $supportedSchemaVersion = 1
    $allowedRootKey = @('schemaVersion', 'variables')

    # -- the document ---------------------------------------------------------

    if ($null -eq $Document) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the file is empty. A machine override must declare schemaVersion and at least one variable.'))
    }

    if (-not ($Document -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the document must be a mapping with schemaVersion and variables keys, but it is a {0}." -f $Document.GetType().Name)))
    }

    foreach ($key in @($Document.Keys)) {
        if ($allowedRootKey -notcontains [string] $key) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is not a key a machine override may declare. The allowed keys are schemaVersion and variables." -f $key)))
        }
    }

    if (-not $Document.Contains('schemaVersion')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'schemaVersion is missing. Every HDT document declares one; this engine understands schemaVersion 1.'))
    }

    $schemaVersion = $Document['schemaVersion']
    if (-not (($schemaVersion -is [int]) -or ($schemaVersion -is [long]))) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("schemaVersion must be an integer, but it is '{0}'." -f $schemaVersion)))
    }

    $supported = $false
    try {
        $supported = Test-HDTSchemaVersion -SchemaVersion ([int] $schemaVersion) -Supported $supportedSchemaVersion
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("schemaVersion {0} is not a valid schema version. It must be 1 or greater." -f $schemaVersion)))
    }

    if (-not $supported) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("schemaVersion {0} is newer than this engine understands (schemaVersion {1}). Upgrade the engine rather than the workspace." -f $schemaVersion, $supportedSchemaVersion)))
    }

    # -- the variables --------------------------------------------------------

    if (-not $Document.Contains('variables')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the variables key is missing. A machine override exists to set variables for this machine.'))
    }

    $declared = $Document['variables']
    if (-not ($declared -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the variables key must be a mapping of variable name to value.'))
    }

    if (@($declared.Keys).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the variables mapping is empty. Delete the file rather than shipping an override that sets nothing.'))
    }

    foreach ($key in @($declared.Keys)) {
        $name = [string] $key

        if ($name.StartsWith('_')) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is engine-owned and cannot be assigned. A variable named _HDT* is set by the engine and is read-only." -f $name)))
        }

        if ($name -cnotmatch '^HDT[A-Za-z0-9_]*$') {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is not an HDT variable name. Every deployment variable is prefixed HDT; run Get-HDTVariableMap for the MDT translation." -f $name)))
        }
    }
}
