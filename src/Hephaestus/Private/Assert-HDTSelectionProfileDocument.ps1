function Assert-HDTSelectionProfileDocument {
    <#
        .SYNOPSIS
            Validates a parsed selection-profiles.yaml against the authoring
            rules.

        .DESCRIPTION
            The engine's own validator, and the one that actually runs in WinPE:
            Test-Json does not exist under Windows PowerShell 5.1, so
            schemas/selection-profile.schema.json is a gate for the console,
            editors and CI while this is the gate for a build.

            It throws on the first violation and returns nothing otherwise. Every
            failure is a terminating error built by New-HDTErrorRecord, so it
            names the file, carries it as its TargetObject and reports
            HDTConfigurationError.

            The authoring rules, in the order they are checked:

              document   not empty; a mapping; only schemaVersion and profiles;
                         schemaVersion present, an integer, and not newer than
                         this engine
              profiles   present and a list; each entry a mapping carrying only
                         id, name and include
              identity   id present and matching ^[A-Za-z0-9][A-Za-z0-9_.-]*$;
                         not one a built-in owns; not declared twice
              name       present and not blank
              include    present and a list of strings, each of them a relative
                         path under a content folder of the share

            AN INCLUDE PATH IS THE SECURITY BOUNDARY OF THIS WHOLE FEATURE, and
            most of the rules above exist for it. Expand-HDTSelectionProfile
            turns each one into a folder under the share, and the boot image
            build hands that folder to Add-WindowsDriver WITH -Recurse. A rooted
            path or a '..' segment is therefore a directory traversal whose
            payload ends up inside a WIM that is transferred to every machine
            that PXE boots. Three rules close it: the path may not be rooted, it
            may not contain a '..' segment, and its first segment must be one of
            the content folders below.

            THE CONTENT FOLDERS ARE A SUBSET OF Get-HDTWorkspacePath's KINDS, on
            purpose. Boot\, Logs\ and Captures\ are generated or written to
            during a deployment - a profile that included one would project this
            build's own output. Control\ holds this very document, and including
            it would be circular. What is left is the five folders content is
            authored into: Applications\, OperatingSystems\, Drivers\,
            TaskSequences\ and Scripts\.

            A RESERVED ID IS REFUSED RATHER THAN SHADOWED. An authored profile
            called 'all-drivers' either beats the built-in or loses to it, and
            both answers leave a share where the name on the Windows PE tab does
            not mean what it says.

            AN EMPTY include IS LEGAL. It is a profile that selects nothing,
            which is a useful thing to name, and a profile being built up over
            an afternoon must not be a document the engine refuses to load.

        .PARAMETER Document
            The parsed document, as returned by ConvertFrom-HDTYaml. $null is
            accepted and reported as an empty file rather than crashing.

        .PARAMETER Path
            The file the document came from. Used for the message and the
            TargetObject; this function reads nothing.

        .OUTPUTS
            None. It throws or it returns nothing.

        .EXAMPLE
            Assert-HDTSelectionProfileDocument -Document (ConvertFrom-HDTYaml -Yaml $text -Path $path) -Path $path

        .NOTES
            The locator in a message is the PROFILE ID or the KEY, not a line
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
    $allowedRootKey = @('schemaVersion', 'profiles')
    $allowedProfileKey = @('id', 'name', 'include')
    $idPattern = '^[A-Za-z0-9][A-Za-z0-9_.-]*$'

    $reservedId = @(Get-HDTSelectionProfileBuiltIn | ForEach-Object { [string] $_.Id })
    $contentFolder = Get-HDTSelectionProfileContentFolder

    # -- the document ---------------------------------------------------------

    if ($null -eq $Document) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the file is empty. A selection profile document must declare schemaVersion and profiles.'))
    }

    if (-not ($Document -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the document must be a mapping with schemaVersion and profiles keys, but it is a {0}." -f $Document.GetType().Name)))
    }

    foreach ($key in @($Document.Keys)) {
        if ($allowedRootKey -notcontains [string] $key) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is not a key a selection profile document may declare. The allowed keys are {1}." -f $key, ($allowedRootKey -join ', '))))
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
                    -Message ("schemaVersion {0} is newer than this engine understands, which is {1}." -f $schemaVersion, $supportedSchemaVersion)))
    }

    if (-not $Document.Contains('profiles')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'profiles is missing. A selection profile document declares a profiles list, even an empty one.'))
    }

    $profileList = $Document['profiles']

    # An empty list parses to $null rather than to an empty collection, and a
    # document that declares no profiles yet is a legitimate one.
    if ($null -eq $profileList) { return }

    if (($profileList -is [string]) -or ($profileList -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'profiles must be a list of profiles, each with an id, a name and an include list.'))
    }

    # -- each profile ---------------------------------------------------------

    $seenId = New-Object -TypeName System.Collections.ArrayList

    foreach ($entry in @($profileList)) {

        if (-not ($entry -is [System.Collections.IDictionary])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("every entry under profiles must be a mapping with id, name and include, but one is a {0}." -f $entry.GetType().Name)))
        }

        foreach ($key in @($entry.Keys)) {
            if ($allowedProfileKey -notcontains [string] $key) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("'{0}' is not a key a profile may declare. The allowed keys are {1}." -f $key, ($allowedProfileKey -join ', '))))
            }
        }

        if (-not $entry.Contains('id')) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'a profile has no id. Every profile needs one; it is what workspace.yaml and a sequence step name it by.'))
        }

        $id = [string] $entry['id']

        if ($id -notmatch $idPattern) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is not a legal profile id. An id starts with a letter or a digit and carries only letters, digits, dot, dash and underscore." -f $id)))
        }

        if ($reservedId -contains $id) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is a built-in profile and cannot be redeclared. The built-in ids are {1}." -f $id, ($reservedId -join ', '))))
        }

        if ($seenId -contains $id) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("the profile id '{0}' is declared twice. An id names one profile." -f $id)))
        }

        [void] $seenId.Add($id)

        if ((-not $entry.Contains('name')) -or [string]::IsNullOrWhiteSpace([string] $entry['name'])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("the profile '{0}' has no name. The name is what the console's picker shows; the id is what documents reference." -f $id)))
        }

        if (-not $entry.Contains('include')) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("the profile '{0}' declares no include list. Write 'include: []' for a profile that includes nothing yet." -f $id)))
        }

        $include = $entry['include']

        if ($null -eq $include) { continue }

        if (($include -is [string]) -or ($include -is [System.Collections.IDictionary])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("the profile '{0}' must declare include as a LIST of share-relative folders, one per line." -f $id)))
        }

        # THE REFUSAL IS BUILT WHERE EVERY OTHER ONE IS. The check itself returns
        # a sentence rather than throwing, so a nested ThrowTerminatingError
        # cannot rewrite the error id this document's failures are asserted on.
        foreach ($current in @($include)) {
            $failure = Get-HDTSelectionProfilePathFailure -Include ([string] $current) `
                -ContentFolder $contentFolder

            if (-not [string]::IsNullOrEmpty($failure)) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("the profile '{0}' includes '{1}': {2}" -f $id, $current, $failure)))
            }
        }
    }
}
