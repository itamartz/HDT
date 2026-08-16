function Assert-HDTApplicationDocument {
    <#
        .SYNOPSIS
            Validates a parsed app.yaml against the authoring rules.

        .DESCRIPTION
            The engine's own validator, and the one that actually runs in WinPE:
            Test-Json does not exist under Windows PowerShell 5.1, so
            schemas/app.schema.json is a gate for the console, editors and CI
            while this is the gate for a deployment.

            It throws on the first violation and returns nothing otherwise. Every
            failure is a terminating error built by New-HDTErrorRecord, so it
            names the file, carries the file as its TargetObject and reports
            HDTConfigurationError.

            The authoring rules, in the order they are checked:

              document     not empty; a mapping; only the eleven known keys;
                           schemaVersion present, an integer, and not newer than
                           this engine
              identity     id present and matching ^[A-Za-z0-9][A-Za-z0-9_.-]*$;
                           name present; install present
              phase        runIn, if given, one of WinPE, FullOS, Any
              codes        successCodes and rebootCodes, if given, lists of
                           integers
              detect       OPTIONAL; if given, a mapping whose type is one of
                           msiProduct, file, registry, script, carrying the keys
                           that type needs and no others
              dependencies if given, a list of legal ids, none of them this app

            DETECT IS OPTIONAL, AND THAT IS DESIGN 8, NOT AN OVERSIGHT. An
            app.yaml declaring no detection rule installs every time the step
            reaches it - which is MDT's behaviour, and the right one for an
            unconditional installer or a script wrapper whose installed state is
            not observable. The engine never infers a rule for an app that
            declined to declare one: a guessed rule that reports an app installed
            when it is not silently skips work the sequence asked for, which is
            worse than installing twice.

            SELF-DEPENDENCY IS REJECTED HERE, at authoring time, rather than left
            to Resolve-HDTApplicationOrder. It is a cycle of length one, and the
            sort should never have to survive one. It is also the second of the
            two things JSON Schema draft-07 cannot say - it has no cross-field
            reference from dependencies back to id - so it is listed as a blind
            spot in tests/contract/AppSchema.Contract.Tests.ps1 rather than
            quietly excluded.

            THE ID IS PATTERN-CHECKED BECAUSE IT BECOMES A FOLDER NAME. It is the
            ChildPath of Get-HDTWorkspacePath -Kind Applications, so a separator
            or a '..' in it is a directory traversal into the share.

        .PARAMETER Document
            The parsed document, as returned by ConvertFrom-HDTYaml. $null is
            accepted and reported as an empty file rather than crashing.

        .PARAMETER Path
            The file the document came from. Used for the message and the
            TargetObject; this function reads nothing.

        .OUTPUTS
            None. It throws or it returns nothing.

        .EXAMPLE
            Assert-HDTApplicationDocument -Document (ConvertFrom-HDTYaml -Yaml $text -Path $path) -Path $path

        .NOTES
            The locator in a message is the KEY or the DETECTION TYPE, not a line
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
    $allowedRootKey = @('schemaVersion', 'id', 'name', 'description', 'install',
        'uninstall', 'successCodes', 'rebootCodes', 'detect', 'dependencies', 'runIn')
    $allowedPhase = @('WinPE', 'FullOS', 'Any')

    # The keys each detection type may carry, and which of them it must - shared
    # with the projector so a rule type gains a key in one place.
    $detectKey = Get-HDTApplicationDetectKey
    $allowedDetectType = @($detectKey.Keys)

    $idPattern = '^[A-Za-z0-9][A-Za-z0-9_.-]*$'

    # -- the document ---------------------------------------------------------

    if ($null -eq $Document) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the file is empty. An application document must declare schemaVersion, id, name and install.'))
    }

    if (-not ($Document -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the document must be a mapping with schemaVersion, id, name and install keys, but it is a {0}." -f $Document.GetType().Name)))
    }

    foreach ($key in @($Document.Keys)) {
        if ($allowedRootKey -notcontains [string] $key) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is not a key an application document may declare. The allowed keys are {1}." -f $key, ($allowedRootKey -join ', '))))
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

    # -- the identity ---------------------------------------------------------

    $id = ''
    if ($Document.Contains('id')) { $id = [string] $Document['id'] }

    if ([string]::IsNullOrWhiteSpace($id)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'id is missing. The id is the folder name under Applications\ and the key a sequence and a dependency name, so a catalog entry without one cannot be referred to.'))
    }

    if ($id -notmatch $idPattern) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("id '{0}' is not a legal application id. It becomes a folder name under Applications\, so it must start with a letter or a digit and hold only letters, digits, underscore, dot and hyphen." -f $id)))
    }

    $name = ''
    if ($Document.Contains('name')) { $name = [string] $Document['name'] }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'name is missing. The name is what an administrator reads in the console, in the wizard''s application list and in a log line.'))
    }

    $install = ''
    if ($Document.Contains('install')) { $install = [string] $Document['install'] }

    if ([string]::IsNullOrWhiteSpace($install)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'install is missing. It is the command line the step runs, and there is no default to fall back on - an application HDT cannot install is a catalog entry with no purpose.'))
    }

    if ($Document.Contains('uninstall')) {
        $uninstall = [string] $Document['uninstall']

        if ([string]::IsNullOrWhiteSpace($uninstall)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'uninstall is present but empty. Omit the key rather than declaring an empty command.'))
        }
    }

    # -- the phase ------------------------------------------------------------

    if ($Document.Contains('runIn')) {
        $runIn = [string] $Document['runIn']

        if ($allowedPhase -notcontains $runIn) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("runIn '{0}' is not a phase HDT runs a step in. The phases are {1}." -f $runIn, ($allowedPhase -join ', '))))
        }
    }

    # -- the exit codes -------------------------------------------------------

    foreach ($codeKey in @('successCodes', 'rebootCodes')) {
        if (-not $Document.Contains($codeKey)) { continue }

        $code = $Document[$codeKey]

        if (-not ($code -is [System.Collections.IList])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} must be a list of integers." -f $codeKey)))
        }

        foreach ($current in @($code)) {
            if (-not (($current -is [int]) -or ($current -is [long]))) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0} carries '{1}', which is not an integer. These are compared against a process exit code, so a quoted '0' matches nothing." -f $codeKey, $current)))
            }
        }
    }

    # -- the detection rule ---------------------------------------------------

    if ($Document.Contains('detect')) {
        $detect = $Document['detect']

        if (-not ($detect -is [System.Collections.IDictionary])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'detect must be a mapping declaring a type and the keys that type needs. Omit it entirely for an application that installs every time.'))
        }

        $detectType = ''
        if ($detect.Contains('type')) { $detectType = [string] $detect['type'] }

        if ([string]::IsNullOrWhiteSpace($detectType)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("detect declares no type. The detection types are {0}." -f ($allowedDetectType -join ', '))))
        }

        # The type is checked before the keys, so an unrecognised type is reported
        # as an unrecognised type rather than as a list of keys that type does not
        # allow - which would be true and useless.
        if ($allowedDetectType -notcontains $detectType) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("detect type '{0}' is not a detection rule HDT can run. The types are {1}." -f $detectType, ($allowedDetectType -join ', '))))
        }

        $allowedKey = @('type') + $detectKey[$detectType].Required + $detectKey[$detectType].Optional

        foreach ($key in @($detect.Keys)) {
            if ($allowedKey -notcontains [string] $key) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("detect: '{0}' is not a key a {1} detection rule may declare. The allowed keys are {2}." -f $key, $detectType, ($allowedKey -join ', '))))
            }
        }

        foreach ($key in @($detectKey[$detectType].Required)) {
            $value = ''
            if ($detect.Contains($key)) { $value = [string] $detect[$key] }

            if ([string]::IsNullOrWhiteSpace($value)) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("detect: a {0} rule needs {1}, and this one does not declare it. A detection rule that cannot run is found at deploy time, after the disk is wiped." -f $detectType, $key)))
            }
        }
    }

    # -- the dependencies -----------------------------------------------------

    if ($Document.Contains('dependencies')) {
        $dependency = $Document['dependencies']

        if (-not ($dependency -is [System.Collections.IList])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'dependencies must be a list of application ids.'))
        }

        $seen = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in @($dependency)) {
            $dependencyId = [string] $current

            if ([string]::IsNullOrWhiteSpace($dependencyId)) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message 'dependencies carries an empty entry. Every dependency names an application id.'))
            }

            if ($dependencyId -notmatch $idPattern) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("dependency '{0}' is not a legal application id. A dependency names the folder under Applications\ that holds the other app." -f $dependencyId)))
            }

            if ($dependencyId -eq $id) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("'{0}' depends on itself. That is a cycle of length one: it can never be ordered, so it is refused here rather than hanging the install plan." -f $id)))
            }

            if ($seen -contains $dependencyId) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("dependencies names '{0}' twice. Installing it once is what the second entry would have asked for." -f $dependencyId)))
            }
            [void] $seen.Add($dependencyId)
        }
    }
}
