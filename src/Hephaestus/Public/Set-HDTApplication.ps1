function Set-HDTApplication {
    <#
        .SYNOPSIS
            Changes an application already in the workspace catalog, leaving
            every other line of its app.yaml byte-identical.

        .DESCRIPTION
            The other half of Import-HDTApplication. Import registers an entry
            and refuses to replace one; this changes an entry that exists. That
            split is why there is no -Force on the importer: an importer that
            overwrote on a flag is one keystroke away from replacing a working
            catalog entry - and its payload - with a typo.

            IT SPLICES, IT NEVER RE-SERIALISES. app.yaml is hand-edited from the
            day it is written, and a parse-then-write round trip drops every
            comment in the file - the sample catalog is half commentary, and the
            comments are where the reasoning lives. So only the keys named are
            rewritten, through Set-HDTApplicationLine, and everything else comes
            back exactly as it went in. Set-HDTWorkspaceProperty and
            Set-HDTStepProperty follow the same rule for the same reason.

            THE ID IS NOT SETTABLE, and that is deliberate. It is the folder name
            under Applications\, the key a sequence selects and the name a
            dependency refers to; changing it in the file alone would leave an
            entry whose id and folder disagree, and Get-HDTApplication enumerates
            by folder. Import the application you meant.

            AN EMPTY VALUE REMOVES THE KEY, which is how a setting goes back to
            its default rather than to a copied-out value that then goes stale.
            -Detect @{ } removes the detection rule, which is DESIGN 8's "install
            every time". -Install cannot be cleared: an application HDT cannot
            install is a catalog entry with no purpose.

            THE DETECTION RULE IS REPLACED WHOLE, never key by key. Swapping an
            msiProduct rule for a file rule has to take productCode with it, or
            the file would carry a key the new type does not allow.

            EVERY EDIT IS HELD TO Assert-HDTApplicationDocument BEFORE ANYTHING
            IS WRITTEN, so a refused change leaves the file exactly as it was
            rather than half-edited.

            THE PAYLOAD IS NOT ITS BUSINESS. source\ is a folder of files, not a
            key in a document; replace what is in it, or import the application
            again under the id you meant.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Id
            The catalog id, which is the folder name under Applications\.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one, which is what an
            administrator wants; a test passes New-HDTFakeFileSystem instead.

        .PARAMETER Name
            The display name. Cannot be cleared - it is what an administrator
            reads in the console, in the wizard's application list and in a log
            line.

        .PARAMETER Description
            A free-text note for the console. Empty removes it.

        .PARAMETER Install
            The command line the step runs. Cannot be cleared.

        .PARAMETER Uninstall
            The command line that removes it. Empty removes the key.

        .PARAMETER SuccessCode
            The exit codes that count as success. An empty list removes the key,
            which inherits 0 and 3010.

        .PARAMETER RebootCode
            The exit codes that oblige the sequence to restart. An empty list
            removes the key, which inherits 3010.

        .PARAMETER RunIn
            The phase the installer runs in. Empty removes the key, which
            inherits FullOS.

        .PARAMETER Dependency
            Ids that must install first. An empty list removes the key.

        .PARAMETER Detect
            The detection rule, as a hashtable in the shape app.yaml declares -
            @{ type = 'msiProduct'; productCode = '{...}' } and so on for file,
            registry and script. An empty hashtable removes the rule.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - the changed catalog, in
            the shape Get-HDTApplication returns.

        .EXAMPLE
            Set-HDTApplication -WorkspaceRoot 'X:\Deploy' -Id '7Zip-24.09' `
                -Install 'msiexec.exe /i "7z2409-x64.msi" /qn /norestart /log install.log'

            Fixes the install command line and touches nothing else in the file.

        .EXAMPLE
            Set-HDTApplication -WorkspaceRoot 'X:\Deploy' -Id '7Zip-24.09' `
                -Detect @{ type = 'file'; path = '%ProgramFiles%\7-Zip\7z.exe'; version = '24.09' }

            Swaps the detection rule whole; the keys the old type carried go with
            it.

        .EXAMPLE
            Set-HDTApplication -WorkspaceRoot 'X:\Deploy' -Id 'Corp-Baseline' -Detect @{ }

            Removes the rule, so the application installs on every deployment.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        # DEFAULTED, NOT MANDATORY, on New-HDTWorkspace's reasoning: this is a
        # command an administrator types, not one the engine's hot path calls.
        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem),

        [Parameter()]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Description,

        # WHICH FOLDER THE CONSOLE DRAWS IT UNDER. Empty takes it out of every
        # folder; the application never moves on disk either way - see the key's
        # note in Import-HDTSequenceDocument for why HDT's folders are labels
        # rather than the real directories Workbench uses.
        [Parameter()]
        [AllowEmptyString()]
        [string] $Folder,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Install,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Uninstall,

        [Parameter()]
        [AllowEmptyCollection()]
        [int[]] $SuccessCode,

        [Parameter()]
        [AllowEmptyCollection()]
        [int[]] $RebootCode,

        # The empty string is in the set because it is how the key is removed,
        # and a value outside the set is refused naming what was typed.
        [Parameter()]
        [ValidateSet('WinPE', 'FullOS', 'Any', '')]
        [string] $RunIn,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]] $Dependency,

        [Parameter()]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Detect
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $settable = @('Name', 'Description', 'Folder', 'Install', 'Uninstall', 'SuccessCode',
        'RebootCode', 'RunIn', 'Dependency', 'Detect')

    $asked = @($settable | Where-Object { $PSBoundParameters.ContainsKey($_) })

    if ($asked.Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id -Category InvalidArgument `
                    -Message ("nothing was asked of application '{0}'. Name at least one of {1}." -f $Id, ($settable -join ', '))))
    }

    foreach ($required in @('Name', 'Install')) {
        if ($PSBoundParameters.ContainsKey($required) -and [string]::IsNullOrWhiteSpace($PSBoundParameters[$required])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id -Category InvalidArgument `
                        -Message ("an application's {0} cannot be cleared - app.yaml requires it, and an entry without one is a catalog entry with no purpose." -f $required.ToLowerInvariant())))
        }
    }

    $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Applications -ChildPath $Id, 'app.yaml'
    $appFolder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Applications -ChildPath $Id

    if (-not $FileSystem.TestPath($catalogPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath -Category ObjectNotFound `
                    -Message ("no application with the id '{0}' is in this workspace. Import-HDTApplication registers a new one." -f $Id)))
    }

    # A FOLDER IS DRAWN FROM ITS OWN TEXT, so a leading or trailing separator
    # produces a nameless level in the tree and a doubled one produces two.
    if ($PSBoundParameters.ContainsKey('Folder') -and -not [string]::IsNullOrWhiteSpace($Folder) -and
        ($Folder -match '^\\|\\$|\\\\' -or $Folder -match '/')) {

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Folder -Category InvalidArgument `
                    -Message ("'{0}' is not a folder path this window can draw. Separate levels with a single backslash - 'Line of business\Finance' - with nothing before the first or after the last." -f $Folder)))
    }

    $line = [string[]] @($FileSystem.ReadAllText($catalogPath) -split "`r?`n")

    # The keys in document order, so a file that gains one gains it in the place
    # app.yaml is written in everywhere else.
    $keyForParameter = [ordered] @{
        Name        = 'name'
        Description = 'description'
        Folder      = 'folder'
        Install     = 'install'
        Uninstall   = 'uninstall'
        SuccessCode = 'successCodes'
        RebootCode  = 'rebootCodes'
        RunIn       = 'runIn'
        Dependency  = 'dependencies'
        Detect      = 'detect'
    }

    foreach ($parameter in @($keyForParameter.Keys)) {
        if (-not $PSBoundParameters.ContainsKey($parameter)) { continue }

        $key = [string] $keyForParameter[$parameter]
        $text = @()

        switch ($parameter) {
            'Detect' {
                if ($Detect.Count -gt 0) { $text = @(Get-HDTApplicationDetectText -Detect $Detect -Key $key) }
            }

            { $_ -in @('SuccessCode', 'RebootCode', 'Dependency') } {
                $value = @($PSBoundParameters[$parameter])

                # A FLOW LIST, because that is how app.yaml writes these
                # everywhere else and a one-line list is one line of diff.
                if ($value.Count -gt 0) {
                    $text = @('{0}: [{1}]' -f $key, (($value | ForEach-Object { [string] $_ }) -join ', '))
                }
            }

            default {
                $value = [string] $PSBoundParameters[$parameter]

                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $text = @('{0}: {1}' -f $key, (Get-HDTConsoleScalarText -Value $value))
                }
            }
        }

        $line = Set-HDTApplicationLine -Line $line -Key $key -Text $text
    }

    $newLine = [System.Environment]::NewLine
    $written = ($line -join $newLine)

    # HELD TO THE VALIDATOR BEFORE ANYTHING IS WRITTEN, so a refused change
    # leaves the file as it was rather than half-edited.
    $document = ConvertFrom-HDTYaml -Yaml $written -Path $catalogPath
    Assert-HDTApplicationDocument -Document $document -Path $catalogPath

    if (-not $PSCmdlet.ShouldProcess($catalogPath, ("Set {0} on application '{1}'" -f ($asked -join ', '), $Id))) {
        return $null
    }

    $FileSystem.WriteAllText($catalogPath, $written)

    return (ConvertTo-HDTApplicationCatalog -Document $document -AppFolder $appFolder -CatalogPath $catalogPath)
}
