function Assert-HDTOperatingSystemDocument {
    <#
        .SYNOPSIS
            Validates a parsed os.yaml against the DESIGN 2.1 and 9.2 authoring
            rules.

        .DESCRIPTION
            The engine's own validator, and the one that actually runs in WinPE:
            Test-Json does not exist under Windows PowerShell 5.1, so
            schemas/os.schema.json is a gate for the console, editors and CI
            while this is the gate for a deployment.

            It throws on the first violation and returns nothing otherwise. Every
            failure is a terminating error built by New-HDTErrorRecord, so it
            names the file, carries the file as its TargetObject and reports
            HDTConfigurationError - DESIGN 12.1's "fail fast and point at the
            file".

            The authoring rules, in the order they are checked:

              document   not empty; a mapping; only the ten known keys;
                         schemaVersion present, an integer, and not newer than
                         this engine (delegated to Test-HDTSchemaVersion)
              identity   id present and matching ^[A-Za-z0-9][A-Za-z0-9_.-]*$;
                         name present; type wim or ffu; architecture, if given,
                         one of x86, x64, arm64; sourcePath present
              images     present, a list, not empty; each a mapping with only the
                         six known keys, a positive integer index no other image
                         carries, and a non-empty name
              default    defaultIndex, if given, names an index that exists

            TWO OF THOSE CLOSE A SCHEMA BLIND SPOT rather than duplicating it.
            JSON Schema draft-07 has no cross-field reference, so it cannot check
            defaultIndex against the images array; and uniqueItems compares WHOLE
            items, so it cannot express "no two images share an index" unless the
            duplicated entries are identical in every field. Both are listed in
            tests/contract/OsSchema.Contract.Tests.ps1 with a fixture each.

            THE ID IS PATTERN-CHECKED BECAUSE IT BECOMES A FOLDER NAME. It is the
            ChildPath of Get-HDTWorkspacePath -Kind OperatingSystems, so a
            separator or a '..' in it is a directory traversal into the share.

        .PARAMETER Document
            The parsed document, as returned by ConvertFrom-HDTYaml. $null is
            accepted and reported as an empty file rather than crashing.

        .PARAMETER Path
            The file the document came from. Used for the message and the
            TargetObject; this function reads nothing.

        .OUTPUTS
            None. It throws or it returns nothing.

        .EXAMPLE
            Assert-HDTOperatingSystemDocument -Document (ConvertFrom-HDTYaml -Yaml $text -Path $path) -Path $path

        .NOTES
            The locator in a message is the IMAGE INDEX or the KEY, not a line
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
    $allowedRootKey = @('schemaVersion', 'id', 'name', 'description', 'type',
        'architecture', 'sourcePath', 'importedUtc', 'defaultIndex', 'images')
    $allowedImageKey = @('index', 'name', 'description', 'edition', 'sizeBytes', 'version')
    $allowedType = @('wim', 'ffu')
    $allowedArchitecture = @('x86', 'x64', 'arm64')

    # -- the document ---------------------------------------------------------

    if ($null -eq $Document) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the file is empty. An operating system document must declare schemaVersion, id, name, type, sourcePath and at least one image.'))
    }

    if (-not ($Document -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the document must be a mapping with schemaVersion, id, name, type, sourcePath and images keys, but it is a {0}." -f $Document.GetType().Name)))
    }

    foreach ($key in @($Document.Keys)) {
        if ($allowedRootKey -notcontains [string] $key) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is not a key an operating system document may declare. The allowed keys are {1}." -f $key, ($allowedRootKey -join ', '))))
        }
    }

    if (-not $Document.Contains('schemaVersion')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'schemaVersion is missing. Every HDT document declares one (DESIGN 2.2); this engine understands schemaVersion 1.'))
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
                    -Message 'id is missing. The id is the folder name under OperatingSystems\ and the key a sequence names, so a catalog entry without one cannot be referred to.'))
    }

    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("id '{0}' is not a legal operating system id. It becomes a folder name under OperatingSystems\, so it must start with a letter or a digit and hold only letters, digits, underscore, dot and hyphen." -f $id)))
    }

    $name = ''
    if ($Document.Contains('name')) { $name = [string] $Document['name'] }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'name is missing. The name is what an administrator reads in the console and in a log line.'))
    }

    $type = ''
    if ($Document.Contains('type')) { $type = [string] $Document['type'] }

    if ($allowedType -notcontains $type) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("type '{0}' is not an image type HDT applies. The types are {1}: a wim is applied with Expand-WindowsImage and an ffu with DISM /Apply-Ffu (DESIGN 9.2), and there is no third apply path." -f $type, ($allowedType -join ', '))))
    }

    if ($Document.Contains('architecture')) {
        $architecture = [string] $Document['architecture']

        if ($allowedArchitecture -notcontains $architecture) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("architecture '{0}' is not an architecture HDT deploys. The architectures are {1}." -f $architecture, ($allowedArchitecture -join ', '))))
        }
    }

    $sourcePath = ''
    if ($Document.Contains('sourcePath')) { $sourcePath = [string] $Document['sourcePath'] }

    if ([string]::IsNullOrWhiteSpace($sourcePath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'sourcePath is missing. It names the image file, relative to the operating system folder unless it is rooted.'))
    }

    # -- the images -----------------------------------------------------------

    if (-not $Document.Contains('images')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the images key is missing. An operating system declares the indices its image file carries, read from the image rather than typed by hand.'))
    }

    $image = $Document['images']
    if (-not ($image -is [System.Collections.IList])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the images key must be a list of images.'))
    }

    if (@($image).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the images list is empty. An operating system with no image is an operating system nothing can apply.'))
    }

    $seenIndex = New-Object -TypeName System.Collections.ArrayList
    $position = 0

    foreach ($current in @($image)) {
        $position++
        $locator = 'image {0}' -f $position

        if (-not ($current -is [System.Collections.IDictionary])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: an image must be a mapping with an index and a name." -f $locator)))
        }

        foreach ($key in @($current.Keys)) {
            if ($allowedImageKey -notcontains [string] $key) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: '{1}' is not a key an image may declare. The allowed keys are {2}." -f $locator, $key, ($allowedImageKey -join ', '))))
            }
        }

        if (-not $current.Contains('index')) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: index is missing. An image is applied by its index, so every image declares one." -f $locator)))
        }

        $index = $current['index']
        if (-not (($index -is [int]) -or ($index -is [long]))) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: index must be an integer, but it is '{1}'." -f $locator, $index)))
        }

        if ([int] $index -lt 1) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: index {1} is not a valid image index. Image indices are 1-based; index 0 names no image." -f $locator, $index)))
        }

        if ($seenIndex -contains [int] $index) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: two images declare index {1}, so naming that index does not identify one of them. Image indices must be unique." -f $locator, $index)))
        }
        [void] $seenIndex.Add([int] $index)

        $imageName = ''
        if ($current.Contains('name')) { $imageName = [string] $current['name'] }

        if ([string]::IsNullOrWhiteSpace($imageName)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: name is missing. An image is selectable by name (DESIGN 9.2), so every image declares one." -f $locator)))
        }
    }

    # -- the default ----------------------------------------------------------

    if ($Document.Contains('defaultIndex')) {
        $defaultIndex = $Document['defaultIndex']

        if (-not (($defaultIndex -is [int]) -or ($defaultIndex -is [long]))) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("defaultIndex must be an integer, but it is '{0}'." -f $defaultIndex)))
        }

        if ($seenIndex -notcontains [int] $defaultIndex) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("defaultIndex {0} names an index no image carries. The indices this image file declares are {1}." -f $defaultIndex, (@($seenIndex) -join ', '))))
        }
    }
}
