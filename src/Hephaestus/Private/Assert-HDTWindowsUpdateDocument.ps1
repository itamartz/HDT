function Assert-HDTWindowsUpdateDocument {
    <#
        .SYNOPSIS
            Refuses an update.yaml that HDT would otherwise misread.

        .DESCRIPTION
            The gate that runs everywhere, WinPE included, where Test-Json does
            not exist. schemas/update.schema.json is the gate the console, an
            editor and CI use; the two must agree, and this is where the message
            an administrator reads is held in place.

            THE REQUIRED SET IS DELIBERATELY SMALL, and the split is the point of
            the file. id, kb, name, kind, architecture and fileName are things
            the package said about itself and cannot be missing. release is the
            ADMINISTRATOR'S and is required for a different reason: nothing inside
            an update package distinguishes Windows 11 24H2 from Server 2025 - both
            report Product="Desktop", build 26100 and baseline 10.0.26100.1742 -
            so an update with no release is an update nothing can safely apply.

            EVERYTHING FROM baselineVersion DOWN IS OPTIONAL, because a package
            HDT could not read metadata out of is still importable. That case is
            real: the metadata cab is a Microsoft convention, not a guarantee, and
            an update that carries none is better recorded with the KB and the
            file than refused outright. The ApplyUpdates step orders such an
            update last and says why.

            UNKNOWN KEYS ARE REFUSED, for the reason every other HDT validator
            refuses them: a key nobody reads is a setting an administrator
            believes they have configured.

        .PARAMETER Document
            The parsed document, as ConvertFrom-HDTYaml returns it. $null is
            accepted and reported as an empty file rather than crashing.

        .PARAMETER Path
            The file the document came from. Used for the message and the
            TargetObject; this function reads nothing.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            None. It throws or it returns nothing.

        .EXAMPLE
            Assert-HDTWindowsUpdateDocument -Document (ConvertFrom-HDTYaml -Yaml $text -Path $path) -Path $path
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
    $allowedRootKey = @('schemaVersion', 'id', 'kb', 'name', 'description', 'release', 'kind',
        'architecture', 'fileName', 'sizeBytes', 'baselineVersion', 'targetVersion', 'build',
        'revision', 'packageId', 'sourceBranch', 'bundledSsuKb', 'bundledSsuVersion',
        'createdUtc', 'importedUtc', 'enabled', 'note')
    $requiredKey = @('id', 'kb', 'name', 'release', 'kind', 'architecture', 'fileName')
    $allowedKind = @('CumulativeUpdate', 'ServicingStackUpdate', 'Other')
    $allowedArchitecture = @('x86', 'x64', 'arm64')
    $idPattern = '^[A-Za-z0-9][A-Za-z0-9_.-]*$'

    if ($null -eq $Document) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the file is empty. A Windows update document must declare schemaVersion, id, kb, name, release, kind, architecture and fileName.'))
    }

    if (-not ($Document -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the document must be a mapping with schemaVersion, id, kb, name and release keys, but it is a {0}." -f $Document.GetType().Name)))
    }

    foreach ($key in @($Document.Keys)) {
        if ($allowedRootKey -notcontains [string] $key) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is not a key a Windows update document may declare. The allowed keys are {1}." -f $key, ($allowedRootKey -join ', '))))
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

    foreach ($key in $requiredKey) {
        if (-not $Document.Contains($key)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} is missing. A Windows update document must declare {1}." -f $key, ($requiredKey -join ', '))))
        }

        if ([string]::IsNullOrWhiteSpace([string] $Document[$key])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} is empty. A Windows update document must declare a value for it." -f $key)))
        }
    }

    $id = [string] $Document['id']
    if ($id -notmatch $idPattern) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the id '{0}' is not usable as a folder name. An id starts with a letter or digit and holds only letters, digits, dot, dash and underscore." -f $id)))
    }

    $release = [string] $Document['release']
    if ($release -notmatch $idPattern) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the release '{0}' is not a usable release id. It names a release in Control\os-releases.yaml." -f $release)))
    }

    # THE KB IS THE PACKAGE'S OWN, READ OUT OF ITS CompDB, so a value that is not
    # shaped like one means somebody hand-edited it into something the console
    # will show and nothing can look up.
    $kb = [string] $Document['kb']
    if ($kb -notmatch '^KB[0-9]+$') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the kb '{0}' is not a KB number. It is read from the package's own metadata and looks like KB5094126." -f $kb)))
    }

    $kind = [string] $Document['kind']
    if ($allowedKind -notcontains $kind) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("'{0}' is not a Windows update kind. The kinds are {1}; kind is read from the package's Feature/@Type and is what decides servicing order." -f $kind, ($allowedKind -join ', '))))
    }

    $architecture = [string] $Document['architecture']
    if ($allowedArchitecture -notcontains $architecture) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("'{0}' is not an architecture HDT deploys. The architectures are {1}." -f $architecture, ($allowedArchitecture -join ', '))))
    }

    foreach ($key in @('build', 'revision', 'sizeBytes')) {
        if (-not $Document.Contains($key)) { continue }

        $value = $Document[$key]
        if (-not (($value -is [int]) -or ($value -is [long]))) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} must be an integer, but it is '{1}'." -f $key, $value)))
        }

        if ([long] $value -lt 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} must not be negative, but it is {1}." -f $key, $value)))
        }
    }

    if ($Document.Contains('enabled') -and -not ($Document['enabled'] -is [bool])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("enabled must be true or false, but it is '{0}'." -f $Document['enabled'])))
    }
}
