function Assert-HDTOsReleaseDocument {
    <#
        .SYNOPSIS
            Refuses an os-releases.yaml that HDT would otherwise misread.

        .DESCRIPTION
            The gate that runs everywhere, WinPE included, where Test-Json does
            not exist. schemas/os-releases.schema.json is the gate the console, an
            editor and CI use; the two must agree, and this is where the message
            an administrator reads is held in place.

            THE ONE RULE WORTH ARGUING ABOUT IS THAT build IS OPTIONAL. A release
            whose build number has not been read off media is a real release -
            Windows 11 26H2 ships in the module's own list that way - and
            requiring the key would force whoever added it to invent a number.
            An invented build is worse than no build: it silently refuses every
            correct import filed under that release, and the refusal names the
            package rather than the guess that caused it.

            verified IS ALSO OPTIONAL AND DEFAULTS TO FALSE, which is the safe
            direction. A row that forgot to say is treated as unmeasured and
            warns, rather than being trusted because somebody left a key out.

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
            Assert-HDTOsReleaseDocument -Document (ConvertFrom-HDTYaml -Yaml $text -Path $path) -Path $path
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
    $allowedRootKey = @('schemaVersion', 'releases')
    $allowedReleaseKey = @('id', 'name', 'build', 'branch', 'verified', 'note')
    $idPattern = '^[A-Za-z0-9][A-Za-z0-9_.-]*$'

    if ($null -eq $Document) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the file is empty. An operating system release list must declare schemaVersion and releases.'))
    }

    if (-not ($Document -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the document must be a mapping with schemaVersion and releases keys, but it is a {0}." -f $Document.GetType().Name)))
    }

    foreach ($key in @($Document.Keys)) {
        if ($allowedRootKey -notcontains [string] $key) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is not a key an operating system release list may declare. The allowed keys are {1}." -f $key, ($allowedRootKey -join ', '))))
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

    if (-not $Document.Contains('releases')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'releases is missing. An operating system release list declares one release per operating system an update can be filed under.'))
    }

    $release = @($Document['releases'])

    if ($release.Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'releases is empty. A release list with no releases offers nothing to file an update under.'))
    }

    $seen = New-Object -TypeName System.Collections.ArrayList

    foreach ($entry in $release) {

        if (-not ($entry -is [System.Collections.IDictionary])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("every release must be a mapping with an id, but one is a {0}." -f $entry.GetType().Name)))
        }

        foreach ($key in @($entry.Keys)) {
            if ($allowedReleaseKey -notcontains [string] $key) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("'{0}' is not a key a release may declare. The allowed keys are {1}." -f $key, ($allowedReleaseKey -join ', '))))
            }
        }

        if (-not $entry.Contains('id')) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'a release is missing its id. The id is what an imported update records, so it cannot be omitted.'))
        }

        $id = [string] $entry['id']

        if ($id -notmatch $idPattern) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("the release id '{0}' is not usable. An id starts with a letter or digit and holds only letters, digits, dot, dash and underscore." -f $id)))
        }

        # A DUPLICATE ID IS A LIST THAT CONTRADICTS ITSELF, and the second row
        # would silently never be chosen - the first match wins everywhere it is
        # read.
        if ($seen -contains $id) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("the release id '{0}' is declared more than once. Every release id must be unique; the second would never be reachable." -f $id)))
        }

        [void] $seen.Add($id)

        # build IS OPTIONAL - see the description. When it IS given it has to be
        # a number, because it is compared against a build read out of a package.
        if ($entry.Contains('build')) {
            $build = $entry['build']

            if (-not (($build -is [int]) -or ($build -is [long]))) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("the build for release '{0}' must be an integer, but it is '{1}'. Omit the key entirely when the build is not known - do not guess one." -f $id, $build)))
            }

            if ([long] $build -le 0) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("the build for release '{0}' must be greater than zero, but it is {1}. Omit the key entirely when the build is not known." -f $id, $build)))
            }
        }

        if ($entry.Contains('verified')) {
            $verified = $entry['verified']

            if (-not ($verified -is [bool])) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("verified for release '{0}' must be true or false, but it is '{1}'." -f $id, $verified)))
            }
        }

        # A RELEASE THAT CLAIMS TO BE VERIFIED WITHOUT A BUILD IS THE ONE
        # CONTRADICTION WORTH REFUSING. verified means "the build was measured";
        # with no build there is nothing that was measured, and a row saying both
        # would let an unmeasured release import without the warning that is the
        # whole point of the flag.
        if ($entry.Contains('verified') -and [bool] $entry['verified'] -and -not $entry.Contains('build')) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("release '{0}' is marked verified but declares no build. verified means the build number was read off real media or a real package; with no build there is nothing to have verified." -f $id)))
        }
    }
}
