function Import-HDTApplication {
    <#
        .SYNOPSIS
            Promotes an installer into the workspace's application catalog.

        .DESCRIPTION
            Import-HDTApplication writes Applications\<id>\app.yaml, and it is the
            only writer of that document. DESIGN 2.1 fixes where it lands and
            DESIGN 8 fixes what it may hold; this command is the twin of
            Import-HDTOperatingSystem, down to the order it works in.

            THE DEFAULTS ARE NOT WRITTEN INTO THE FILE. successCodes,
            rebootCodes, runIn, uninstall, detect and dependencies are all
            optional, and every one of their defaults lives in exactly one place -
            ConvertTo-HDTApplicationCatalog. An importer that stamped 0/3010 into
            every app.yaml would make the file disagree with the projector the
            day either changes, so a key the caller did not ask for does not
            appear on disk at all. A four-key app.yaml is the normal shape.

            THE DOCUMENT IS VALIDATED BEFORE ANYTHING IS WRITTEN. It goes through
            Assert-HDTApplicationDocument - the same validator Get-HDTApplication
            reads through - so a refused import leaves no half-written entry, and
            the error names the file and the offending key rather than the
            parameter. That is what makes -Detect a hashtable rather than four
            parameter sets: the detection rule is a union of four shapes, the
            validator already knows all four, and duplicating that table in a
            param block would be a second place to keep it correct.

            EVERY PATH IS BUILT WITH Get-HDTWorkspacePath. That command exists
            because a plan once did not: Start-HDTResume built its path from the
            literal 'Sequences' while the layout said 'TaskSequences', the unit
            suite was green because nothing in it resolved a real workspace path,
            and a deployment would have died at its first reboot. No literal
            'Applications' appears in this file.

            THE PAYLOAD COMES WITH IT, WHICH IS WHERE THIS PARTS COMPANY WITH THE
            OS IMPORTER. An operating system is registered where it stands
            because copying 4 GB is a real operation; an application is a folder
            of installer files, and a catalog entry whose source\ is empty is one
            the InstallApplications step cannot run - it fails at deployment
            time, which is the worst place to find out. So -SourcePath is
            mandatory, and the CONTENTS of that folder are copied into
            Applications\<id>\source: the folder's own name is discarded, because
            a payload nested one level deeper would break every relative install
            command. SourcePath in the returned catalog is that folder, which
            DESIGN 2.1 makes a convention rather than a key in the file.

            THERE IS NO -Force, on the reasoning that splits the sequence editor
            into Add-HDTStep and Set-HDTStepProperty: an importer that overwrote
            on a flag is one keystroke away from replacing a working catalog entry
            - and its payload - with a typo. Importing over an existing id is
            refused outright; changing one is Set-HDTApplication's job.

        .PARAMETER WorkspaceRoot
            The workspace root - a local path or a UNC share.

        .PARAMETER Id
            The catalog id. Becomes the folder name under Applications\, the key
            a sequence selects and a dependency names, so it must match
            ^[A-Za-z0-9][A-Za-z0-9_.-]*$.

        .PARAMETER Install
            The command line the InstallApplications step runs, resolved against
            the application's source folder. There is no default: an application
            HDT cannot install is a catalog entry with no purpose.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one, which is what an
            administrator wants; a test passes New-HDTFakeFileSystem instead and
            the whole importer is provable with no share and no disk.

        .PARAMETER Name
            The display name. Defaults to the id.

        .PARAMETER Description
            A free-text note for the console.

        .PARAMETER Uninstall
            The command line that removes it. Omitted when not given.

        .PARAMETER SuccessCode
            The exit codes that count as success. Omitted when not given, which
            inherits 0 and 3010.

        .PARAMETER RebootCode
            The exit codes that oblige the sequence to restart. Omitted when not
            given, which inherits 3010.

        .PARAMETER RunIn
            The phase the installer runs in. Omitted when not given, which
            inherits FullOS - an application installer in WinPE is the unusual
            case.

        .PARAMETER Dependency
            Ids that must install first. Resolve-HDTApplicationOrder sorts them.

        .PARAMETER Detect
            The detection rule, as a hashtable in the shape app.yaml declares -
            @{ type = 'msiProduct'; productCode = '{...}' } and so on for file,
            registry and script. Omitted when not given, which is DESIGN 8's
            "install every time".

        .PARAMETER SourcePath
            The folder holding the installer. Its CONTENTS are copied into
            Applications\<id>\source, subfolders and all; its own name is
            discarded, so install commands stay relative to source\.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - the catalog it wrote,
            in the shape Get-HDTApplication returns.

        .EXAMPLE
            Import-HDTApplication -WorkspaceRoot 'X:\Deploy' -Id '7Zip-24.09' `
                -Install 'msiexec.exe /i "7z2409-x64.msi" /qn /norestart' `
                -SourcePath 'C:\Downloads\7Zip'

            The four-key entry: everything else is inherited, including the
            filesystem.

        .EXAMPLE
            Import-HDTApplication -WorkspaceRoot 'X:\Deploy' -Id '7Zip-24.09' `
                -Name '7-Zip 24.09 x64' -Install 'msiexec.exe /i "7z2409-x64.msi" /qn /norestart' `
                -Detect @{ type = 'msiProduct'; productCode = '{23170F69-40C1-2702-2409-000001000000}' } `
                -SourcePath 'C:\Downloads\7Zip'

            With a detection rule, so running the sequence twice installs it once.
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

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Install,

        # DEFAULTED, NOT MANDATORY, on New-HDTWorkspace's reasoning: this is a
        # command an administrator types, not one the engine's hot path calls, so
        # a working call is a short one. A test still passes the fake explicitly,
        # and must - every test in this command's suite does.
        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem),

        [Parameter()]
        [string] $Name,

        [Parameter()]
        [string] $Description,

        [Parameter()]
        [string] $Uninstall,

        [Parameter()]
        [int[]] $SuccessCode,

        [Parameter()]
        [int[]] $RebootCode,

        [Parameter()]
        [ValidateSet('WinPE', 'FullOS', 'Any')]
        [string] $RunIn,

        [Parameter()]
        [string[]] $Dependency,

        [Parameter()]
        [System.Collections.IDictionary] $Detect,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $SourcePath
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                    -Message ("'{0}' is not a legal application id. It becomes a folder name under the workspace's application folder, so it must start with a letter or a digit and hold only letters, digits, underscore, dot and hyphen." -f $Id)))
    }

    $appFolder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Applications -ChildPath $Id
    $catalogPath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Applications -ChildPath $Id, 'app.yaml'

    if ($FileSystem.TestPath($catalogPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $catalogPath `
                    -Message ("an application with the id '{0}' is already in this workspace. Import registers a new entry; it does not replace one. Change the existing entry rather than importing over it." -f $Id)))
    }

    if (-not $FileSystem.TestPath($SourcePath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $SourcePath `
                    -Message 'the application source folder does not exist, so there is no payload to bring into the workspace.' `
                    -Category ObjectNotFound))
    }

    $displayName = $Id
    if (-not [string]::IsNullOrWhiteSpace($Name)) { $displayName = $Name }

    $document = [System.Collections.Specialized.OrderedDictionary]::new()
    $document['schemaVersion'] = 1
    $document['id'] = $Id
    $document['name'] = $displayName
    if (-not [string]::IsNullOrWhiteSpace($Description)) { $document['description'] = $Description }
    $document['install'] = $Install
    if (-not [string]::IsNullOrWhiteSpace($Uninstall)) { $document['uninstall'] = $Uninstall }
    if ($PSBoundParameters.ContainsKey('SuccessCode')) { $document['successCodes'] = [int[]] $SuccessCode }
    if ($PSBoundParameters.ContainsKey('RebootCode')) { $document['rebootCodes'] = [int[]] $RebootCode }
    if (-not [string]::IsNullOrWhiteSpace($RunIn)) { $document['runIn'] = $RunIn }

    if ($PSBoundParameters.ContainsKey('Detect')) {
        # THE RULE IS COPIED KEY BY KEY, NOT HANDED OVER WHOLE, for the reason
        # ConvertTo-HDTYaml states: a hashtable's key order differs between
        # Windows PowerShell 5.1 and pwsh 7, and a document that serialises in a
        # different order on each is a diff nobody can read. 'type' leads, and
        # what follows is the order Get-HDTApplicationDetectKey declares - the
        # same table the validator and the projector read.
        $rule = [System.Collections.Specialized.OrderedDictionary]::new()

        $type = ''
        if ($Detect.Contains('type')) { $type = [string] $Detect['type'] }
        $rule['type'] = $type

        $schema = Get-HDTApplicationDetectKey
        $ordered = @()
        # .Contains, not .ContainsKey: the detect table is an ordered dictionary,
        # which has only the former, and a hashtable answers to both.
        if ($schema.Contains($type)) { $ordered = @($schema[$type].Required + $schema[$type].Optional) }

        foreach ($key in $ordered) {
            if ($Detect.Contains($key)) { $rule[$key] = [string] $Detect[$key] }
        }

        # Anything the schema does not know about is carried across untouched so
        # the validator - not this command - is what refuses it, and names it.
        foreach ($key in @($Detect.Keys)) {
            if ((-not $rule.Contains([string] $key))) { $rule[[string] $key] = $Detect[$key] }
        }

        $document['detect'] = $rule
    }

    if ($PSBoundParameters.ContainsKey('Dependency')) {
        $document['dependencies'] = [string[]] $Dependency
    }

    # The writer is held to the validator, here, before anything is written.
    Assert-HDTApplicationDocument -Document $document -Path $catalogPath

    $text = ConvertTo-HDTYaml -Document $document -Path $catalogPath

    if (-not $PSCmdlet.ShouldProcess($catalogPath, ("Import application '{0}'" -f $Id))) {
        return $null
    }

    $FileSystem.CreateDirectory($appFolder)

    Copy-HDTContentTree -Source $SourcePath -Destination ([System.IO.Path]::Combine($appFolder, 'source')) -FileSystem $FileSystem | Out-Null

    $FileSystem.WriteAllText($catalogPath, $text)

    return (ConvertTo-HDTApplicationCatalog -Document $document -AppFolder $appFolder -CatalogPath $catalogPath)
}
