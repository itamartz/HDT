function Get-HDTMachineOverride {
    <#
        .SYNOPSIS
            Reads the per-machine variable override for a UUID, if one exists.

        .DESCRIPTION
            DESIGN 3.1 source 2: Control\machines\<UUID>.yaml, "the MDT-database
            equivalent, but file-based; a SQL or REST provider can be plugged in
            later behind the same interface". This is that provider's file
            implementation.

            NO FILE IS THE NORMAL CASE. Most machines have no override, so an
            absent file returns $null rather than throwing, and an empty -Uuid
            returns $null without touching the filesystem at all - the engine
            asks before it necessarily knows the UUID.

            A file that EXISTS but is wrong is a different matter and fails fast,
            naming the file. An override that silently does nothing
            is precisely the MDT-database debugging problem HDT exists to end, so
            an unknown key, a variable outside the HDT namespace or an attempt to
            assign an engine-owned _HDT* variable are all refused rather than
            ignored.

            The file is read through the injected IFileSystem, never Get-Content,
            so the whole path is provable with no share and no disk (PROJECT
            constraint 4, DESIGN 12.2.1).

            The returned variables are re-materialised into an ordered,
            case-insensitive dictionary for the same reason Import-HDTRuleDocument
            does it: resolution applies them in document order and looks them up
            without caring how the author spelled the case.

        .PARAMETER WorkspaceRoot
            The workspace root. The override is at
            <WorkspaceRoot>\Control\machines\<Uuid>.yaml.

        .PARAMETER Uuid
            The machine UUID, as HDTUUID reports it. Empty or $null returns $null.
            Matching is case-insensitive because Windows paths are.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production, New-HDTFakeFileSystem
            in a test.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path and Variable, or
            $null when there is no override. Path comes back with the variables
            because provenance names the file that supplied each value.

        .EXAMPLE
            $override = Get-HDTMachineOverride -WorkspaceRoot 'X:\Deploy' `
                -Uuid $fact['HDTUUID'] -FileSystem (New-HDTFileSystem)

        .EXAMPLE
            Resolve-HDTVariable -MachineOverride $override.Variable `
                -MachineOverridePath $override.Path -Fact $fact

            How the result is handed to the resolution engine.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Uuid,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $supportedSchemaVersion = 1

    # A machine whose UUID is unknown has no override to find, and asking the
    # filesystem about '<root>\Control\machines\.yaml' would be a lie.
    if ([string]::IsNullOrWhiteSpace($Uuid)) {
        return $null
    }

    $control = Join-Path -Path $WorkspaceRoot -ChildPath 'Control'
    $machine = Join-Path -Path $control -ChildPath 'machines'
    $path = Join-Path -Path $machine -ChildPath ('{0}.yaml' -f $Uuid)

    if (-not $FileSystem.TestPath($path)) {
        return $null
    }

    $document = ConvertFrom-HDTYaml -Yaml $FileSystem.ReadAllText($path) -Path $path

    # -- the document ---------------------------------------------------------

    if ($null -eq $document) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message 'the file is empty. A machine override must declare schemaVersion and at least one variable.'))
    }

    if (-not ($document -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message ("the document must be a mapping with schemaVersion and variables keys, but it is a {0}." -f $document.GetType().Name)))
    }

    foreach ($key in @($document.Keys)) {
        if (@('schemaVersion', 'variables') -notcontains [string] $key) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                        -Message ("'{0}' is not a key a machine override may declare. The allowed keys are schemaVersion and variables." -f $key)))
        }
    }

    if (-not $document.Contains('schemaVersion')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message 'schemaVersion is missing. Every HDT document declares one (DESIGN 2.2); this engine understands schemaVersion 1.'))
    }

    $schemaVersion = $document['schemaVersion']
    if (-not (($schemaVersion -is [int]) -or ($schemaVersion -is [long]))) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message ("schemaVersion must be an integer, but it is '{0}'." -f $schemaVersion)))
    }

    $supported = $false
    try {
        $supported = Test-HDTSchemaVersion -SchemaVersion ([int] $schemaVersion) -Supported $supportedSchemaVersion
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message ("schemaVersion {0} is not a valid schema version. It must be 1 or greater." -f $schemaVersion)))
    }

    if (-not $supported) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message ("schemaVersion {0} is newer than this engine understands (schemaVersion {1}). Upgrade the engine rather than the workspace." -f $schemaVersion, $supportedSchemaVersion)))
    }

    # -- the variables --------------------------------------------------------

    if (-not $document.Contains('variables')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message 'the variables key is missing. A machine override exists to set variables for this machine.'))
    }

    $declared = $document['variables']
    if (-not ($declared -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message 'the variables key must be a mapping of variable name to value.'))
    }

    if (@($declared.Keys).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                    -Message 'the variables mapping is empty. Delete the file rather than shipping an override that sets nothing.'))
    }

    $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($key in @($declared.Keys)) {
        $name = [string] $key

        if ($name.StartsWith('_')) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                        -Message ("'{0}' is engine-owned and cannot be assigned. A variable named _HDT* is set by the engine and is read-only (DESIGN 3.2)." -f $name)))
        }

        if ($name -cnotmatch '^HDT[A-Za-z0-9_]*$') {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                        -Message ("'{0}' is not an HDT variable name. Every deployment variable is prefixed HDT (DESIGN 3.2); run Get-HDTVariableMap for the MDT translation." -f $name)))
        }

        $variable[$name] = $declared[$key]
    }

    return [pscustomobject] ([ordered] @{
            Path     = $path
            Variable = $variable
        })
}
