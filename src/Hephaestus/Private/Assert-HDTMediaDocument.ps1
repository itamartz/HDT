function Assert-HDTMediaDocument {
    <#
        .SYNOPSIS
            Validates a parsed media.yaml against the authoring rules.

        .DESCRIPTION
            The engine's own validator, and the one that actually runs in WinPE:
            Test-Json does not exist under Windows PowerShell 5.1, so
            schemas/media.schema.json is a gate for the console, editors and CI
            while this is the gate for a build.

            It throws on the first violation and returns nothing otherwise. Every
            failure is a terminating error built by New-HDTErrorRecord, so it
            names the file, carries it as its TargetObject and reports
            HDTConfigurationError.

            A MEDIA DEFINITION IS MDT'S MEDIA ITEM, as YAML. Deployment Workbench
            keeps one under Advanced Configuration carrying a selection profile,
            a media path and an enabled tick, and Update Media Content
            regenerates it. HDT keeps the same object at Media\<id>\media.yaml
            and Update-HDTMediaContent regenerates it.

            The authoring rules, in the order they are checked:

              document          not empty; a mapping; only the seven known keys;
                                schemaVersion present, an integer, and not newer
                                than this engine
              identity          id present and matching
                                ^[A-Za-z0-9][A-Za-z0-9_.-]*$; matching the folder
                                it was read from when one was named; name present
                                and not blank
              projection        selectionProfile present, not blank, and a legal
                                profile id; output present, not blank, naming an
                                .iso, and carrying no '..' segment
              enabled           OPTIONAL; a boolean when it is there

            THE ID IS CHECKED AS A FOLDER NAME AND NOT AS A DISPLAY NAME, and the
            reason is Remove-HDTMedia: it deletes the folder this id names. A
            separator, a wildcard, a space, '.' or '..' in it is a delete target
            built out of a string somebody typed, so it is refused here, at the
            point the value is authored, rather than at the point it is used.
            Remove-HDTMedia checks it a second time anyway - once as typed and
            once as resolved - because two cheap checks are what a recursive
            delete is worth.

            output IS THE OTHER PATH, and it is checked for the same reason.
            Update-HDTMediaContent writes a multi-gigabyte ISO to it, and a '..'
            segment in a share-relative path is a write outside the share.

            A ROOTED output IS LEGAL, and deliberately so: media is routinely
            built onto another disk or another server because a share's own
            volume has no room for a 6 GB ISO. A relative one resolves against
            the workspace root at READ time, in ConvertTo-HDTMediaCatalog, never
            at write time - a share is authored on one machine and built on
            another, so a path expanded to a drive letter when the item was
            created is the one value that is certainly wrong later.

            enabled IS A REFUSAL, NOT A FILTER, and that decision is spent in
            Update-HDTMediaContent rather than here. A disabled item validates
            perfectly well; what it does not do is build.

        .PARAMETER Document
            The parsed document, as returned by ConvertFrom-HDTYaml. $null is
            accepted and reported as an empty file rather than crashing.

        .PARAMETER Path
            The file the document came from. Used for the message and the
            TargetObject; this function reads nothing.

        .PARAMETER Id
            The folder the document was read from, when the caller knows it. The
            document's own id must match it, because the folder is what every
            other command addresses the item by. Omitted, that one check is
            skipped - a document being validated before it is written has no
            folder yet.

        .OUTPUTS
            None. It throws or it returns nothing.

        .EXAMPLE
            Assert-HDTMediaDocument -Document (ConvertFrom-HDTYaml -Yaml $text -Path $path) -Path $path

        .NOTES
            The locator in a message is the KEY, not a line number: the YAML
            parser does not carry line information onto the object graph it
            returns, so after parsing there is no honest line to report. Only
            ConvertFrom-HDTYaml, which still holds the parser's own exception,
            can name a line.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Document,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Position = 2)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Id
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $supportedSchemaVersion = 1

    # THE SEVEN KEYS, and the one place they are written down in the engine.
    # schemas/media.schema.json says the same thing to the console and to CI.
    $allowedKey = @('schemaVersion', 'id', 'name', 'description', 'selectionProfile',
        'output', 'enabled')

    $idPattern = '^[A-Za-z0-9][A-Za-z0-9_.-]*$'

    # -- the document ---------------------------------------------------------

    if ($null -eq $Document) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the file is empty. A media document must declare schemaVersion, id, name, selectionProfile and output.'))
    }

    if (-not ($Document -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the document must be a mapping with schemaVersion, id, name, selectionProfile and output keys, but it is a {0}." -f $Document.GetType().Name)))
    }

    foreach ($key in @($Document.Keys)) {
        if ($allowedKey -notcontains [string] $key) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is not a key a media document may declare. The allowed keys are {1}." -f $key, ($allowedKey -join ', '))))
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
                    -Message ("schemaVersion {0} is newer than this engine understands, which is {1}. Upgrade the engine rather than the workspace." -f $schemaVersion, $supportedSchemaVersion)))
    }

    # -- the identity ---------------------------------------------------------

    $documentId = ''
    if ($Document.Contains('id')) { $documentId = [string] $Document['id'] }

    if ([string]::IsNullOrWhiteSpace($documentId)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'id is missing. The id is the folder name under Media\ and the key Update-HDTMediaContent names the item by, so a media definition without one cannot be referred to.'))
    }

    if ($documentId -notmatch $idPattern) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("id '{0}' is not a legal media id. It becomes a folder name under Media\ and Remove-HDTMedia deletes that folder, so it must start with a letter or a digit and hold only letters, digits, underscore, dot and hyphen - no separators, no spaces, and never '.' or '..'." -f $documentId)))
    }

    if ((-not [string]::IsNullOrWhiteSpace($Id)) -and
        (-not [string]::Equals($documentId, $Id, [System.StringComparison]::OrdinalIgnoreCase))) {

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("id is '{0}' but the document was read from the folder '{1}'. Every other command addresses this item by its folder, so the two disagreeing means one of them is naming something that is not there." -f $documentId, $Id)))
    }

    $name = ''
    if ($Document.Contains('name')) { $name = [string] $Document['name'] }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'name is missing. The name is what an administrator reads in the console''s Media node and in a build log; the id is what documents reference.'))
    }

    # -- the projection -------------------------------------------------------

    $selectionProfile = ''
    if ($Document.Contains('selectionProfile')) { $selectionProfile = [string] $Document['selectionProfile'] }

    if ([string]::IsNullOrWhiteSpace($selectionProfile)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'selectionProfile is missing. The whole projection is that one value: it decides which of the share''s content travels onto the disc. Write ''everything'' for a whole share, which is what MDT defaults a media item to.'))
    }

    if ($selectionProfile -notmatch $idPattern) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("selectionProfile '{0}' is not a legal selection profile id. It names a profile from Control\selection-profiles.yaml or a built-in one, so it holds only letters, digits, underscore, dot and hyphen." -f $selectionProfile)))
    }

    $output = ''
    if ($Document.Contains('output')) { $output = [string] $Document['output'] }

    if ([string]::IsNullOrWhiteSpace($output)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'output is missing. It is the file the build writes, and there is no default to fall back on once the item exists - New-HDTMedia composed one when it was created.'))
    }

    if (-not $output.EndsWith('.iso', [System.StringComparison]::OrdinalIgnoreCase)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("output '{0}' does not name an .iso. HDT emits exactly one artifact for a media item and it is an ISO: a stick is made by writing that ISO to one, because HDT never partitions a disk it was not asked to." -f $output)))
    }

    # A '..' SEGMENT IS REFUSED WHEREVER IT SITS, rooted or not. This path is
    # where a multi-gigabyte file gets written, and a relative one is resolved
    # against the share - so '..' in it is a write outside the share, decided by
    # a string somebody typed a year ago.
    foreach ($segment in @($output -split '[\\/]')) {
        if ($segment -eq '..') {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("output '{0}' carries a '..' segment. A relative output resolves against the share, so '..' writes the ISO outside it; name the other location outright instead." -f $output)))
        }
    }

    # -- the tick -------------------------------------------------------------

    if ($Document.Contains('enabled')) {
        $enabled = $Document['enabled']

        if (-not ($enabled -is [bool])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("enabled must be true or false, but it is '{0}'. Quoting it makes it a string, and a string is not a tick box." -f $enabled)))
        }
    }
}
