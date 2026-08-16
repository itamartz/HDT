function Get-HDTBootstrapConfiguration {
    <#
        .SYNOPSIS
            Reads bootstrap.json - the file in the boot image that says where the
            content is and which provider reaches it.

        .DESCRIPTION
            THE ONLY FILE THAT TELLS THE ENGINE WHERE IT IS. It is written into
            the image at X:\HDT\bootstrap.json by Update-HDTBootImage (05-04) and
            read here, before anything else exists: no share, no workspace, no
            variables, no rules. Everything the engine does afterwards follows
            from it.

            The shape:

              {
                "schemaVersion": 1,
                "workspaceId":   "HDT-LAB",
                "provider":      "Smb",
                "deployRoot":    "\\\\server\\HdtShare",
                "contentMarker": "rules.yaml",
                "sequenceId":    "",
                "credential":    { "username": "...", "protected": "..." },
                "promptForCredential": false,
                "logLevel":      "Info",
                "buildId":       "...",
                "builtUtc":      "..."
              }

            EVERY REFUSAL IS A SENTENCE NAMING THE FILE, never a raw
            ConvertFrom-Json exception. This document is read on a machine with
            nobody at the keyboard, and its failure is the last thing anyone will
            ever see about the run - "Invalid JSON primitive" names no file, no
            key and no fix.

            THE RULES:

              - provider outside Smb|Local is refused, naming the file, the value
                and the two legal names;
              - deployRoot missing or empty is refused;
              - provider Smb with a deployRoot that is not UNC is refused, naming
                both. Volume-relative is a LOCAL idea and does not weaken this;
              - credential absent AND promptForCredential false AND provider Smb
                is refused, because that image cannot authenticate and the fact
                is decidable at build time;
              - promptForCredential true means the credential block may be
                absent, and the caller stops for a human;
              - provider Local with a VOLUME-RELATIVE deployRoot (\Share) is
                legal, and it is the form a boot image should carry. In the lab
                WinPE gave the content disk C: and the RAM disk X:, so a letter
                written at build time is a guess about a machine that has not
                booted yet. Resolve-HDTDeployRoot turns it into a real path at
                boot; this reader accepts it and hands it on;
              - provider Local with a ROOTED deployRoot is legal too - it is what
                a build host uses - and it is not an error for it to be absent at
                boot, because the resolver falls back to the probe;
              - sequenceId empty is legal: the sequence then comes from the rules,
                which is the answer to "which task sequence does this
                machine get";
              - contentMarker defaults to rules.yaml, the rules file, which is
                what identifies a workspace root when the volume is discovered
                rather than configured.

            THE PROTECTED SECRET IS NOT A PROPERTY. The result is written into
            RESULT.json and into log records, so a property holding the share
            password would put it on the share. The credential is built on demand
            by GetCredential(), from a value closed over rather than carried.

            It reads through an injected IFileSystem, never Get-Content, so the
            whole path is provable under Pester with no boot image.

        .PARAMETER Path
            The bootstrap document. X:\HDT\bootstrap.json in WinPE.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with SchemaVersion,
            WorkspaceId, Provider, DeployRoot, ContentMarker, SequenceId,
            PromptForCredential, LogLevel, UserName, HasCredential, BuildId,
            BuiltUtc and Path, plus a GetCredential() ScriptMethod.

        .EXAMPLE
            $bootstrap = Get-HDTBootstrapConfiguration -Path 'X:\HDT\bootstrap.json'
            $bootstrap.DeployRoot

        .EXAMPLE
            $bootstrap = Get-HDTBootstrapConfiguration -Path $path -FileSystem $fs
            $provider = New-HDTContentProvider -Provider $bootstrap.Provider `
                -Root $resolved.Path -Credential $bootstrap.GetCredential()

            The two commands that turn a boot image into a connected machine.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) {
        $FileSystem = New-HDTFileSystem
    }

    if (-not $FileSystem.TestPath($Path)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'there is no bootstrap document here. Update-HDTBootImage writes one into the boot image; without it the engine has no way to know where its content is.' `
                    -Category ObjectNotFound))
    }

    $text = $FileSystem.ReadAllText($Path)

    if ([string]::IsNullOrWhiteSpace($text)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the bootstrap document is empty. Rebuild the boot image with Update-HDTBootImage.'))
    }

    try {
        # Assigned first, wrapped second: under Windows PowerShell 5.1
        # ConvertFrom-Json does not enumerate a top-level array (helpers README
        # F12), and it bit 04-04 twice.
        $document = ConvertFrom-Json -InputObject $text
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the bootstrap document could not be read as JSON: {0}. Rebuild the boot image with Update-HDTBootImage." -f $_.Exception.Message)))
    }

    if ($null -eq $document) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the bootstrap document parsed to nothing. Rebuild the boot image with Update-HDTBootImage.'))
    }

    $valueOf = {
        param([string] $Name, [object] $Default)

        if ($null -eq $document.PSObject.Properties[$Name]) {
            return $Default
        }

        $raw = $document.$Name
        if ($null -eq $raw) {
            return $Default
        }

        return $raw
    }

    $schemaVersion = [int] (& $valueOf 'schemaVersion' 1)
    $workspaceId = [string] (& $valueOf 'workspaceId' '')
    $provider = [string] (& $valueOf 'provider' '')
    $deployRoot = [string] (& $valueOf 'deployRoot' '')
    $contentMarker = [string] (& $valueOf 'contentMarker' 'rules.yaml')
    $sequenceId = [string] (& $valueOf 'sequenceId' '')
    $logLevel = [string] (& $valueOf 'logLevel' 'Info')
    $buildId = [string] (& $valueOf 'buildId' '')
    $prompt = [bool] (& $valueOf 'promptForCredential' $false)

    # THE TWO ENGINES DISAGREE ABOUT builtUtc, and it is not a detail: under
    # pwsh 7 ConvertFrom-Json coerces an ISO 8601 string to [datetime], under
    # Windows PowerShell 5.1 it does not. Casting the pwsh 7 result to [string]
    # yields '08/13/2026 09:14:22' - a machine-local rendering of a timestamp
    # that RESULT.json is meant to carry verbatim. Round-tripped explicitly, both
    # engines produce the same sentence.
    $rawBuilt = & $valueOf 'builtUtc' ''
    $builtUtc = [string] $rawBuilt
    if ($rawBuilt -is [datetime]) {
        $builtUtc = $rawBuilt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',
            [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ([string]::IsNullOrWhiteSpace($contentMarker)) {
        $contentMarker = 'rules.yaml'
    }

    if ([string]::IsNullOrWhiteSpace($logLevel)) {
        $logLevel = 'Info'
    }

    if (-not (Test-HDTSchemaVersion -SchemaVersion $schemaVersion -Supported 1)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the bootstrap document declares schemaVersion {0}, which this engine does not understand. It supports schemaVersion 1." -f $schemaVersion)))
    }

    if (@('Smb', 'Local') -notcontains $provider) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("provider '{0}' is not a transport HDT can build. The provider must be Smb or Local." -f $provider)))
    }

    if ([string]::IsNullOrWhiteSpace($deployRoot)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'deployRoot is missing. It is the only thing in the boot image that says where the content is, so a machine that boots this image would have nowhere to go.'))
    }

    if ($provider -eq 'Smb' -and -not $deployRoot.StartsWith('\\')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("provider is Smb and deployRoot '{0}' is not a UNC path. An Smb deployRoot names a share (\\server\share); a volume-relative or drive-qualified root is a Local idea and the transports are not interchangeable." -f $deployRoot)))
    }

    $userName = ''
    $protected = ''
    if ($null -ne $document.PSObject.Properties['credential'] -and $null -ne $document.credential) {
        $credential = $document.credential

        if ($null -ne $credential.PSObject.Properties['username']) { $userName = [string] $credential.username }
        if ($null -ne $credential.PSObject.Properties['protected']) { $protected = [string] $credential.protected }
    }

    $hasCredential = -not ([string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrWhiteSpace($protected))

    if ($provider -eq 'Smb' -and -not $hasCredential -and -not $prompt) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'this boot image was built without a credential and without promptForCredential, so a machine booting it can neither authenticate to the share nor ask anybody. Rebuild it with Set-HDTShareCredential, or with -PromptForCredential if the image is meant to stop for a human.' `
                    -Category AuthenticationError))
    }

    # UNPROTECTED EAGERLY, so a corrupt blob fails HERE - naming this file - and
    # not four steps later inside a provider. The plain value is closed over by
    # GetCredential() rather than carried as a property: this object is written
    # into RESULT.json and into log records.
    $plain = ''
    if ($hasCredential) {
        try {
            $plain = Unprotect-HDTShareSecret -Protected $protected
        } catch {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("the embedded credential could not be decoded: {0}. Rebuild the boot image with Update-HDTBootImage." -f $_.Exception.Message)))
        }
    }

    $result = [pscustomobject] ([ordered] @{
            SchemaVersion       = $schemaVersion
            WorkspaceId         = $workspaceId
            Provider            = $provider
            DeployRoot          = $deployRoot
            ContentMarker       = $contentMarker
            SequenceId          = $sequenceId
            PromptForCredential = $prompt
            LogLevel            = $logLevel
            UserName            = $userName
            HasCredential       = $hasCredential
            BuildId             = $buildId
            BuiltUtc            = $builtUtc
            Path                = $Path
        })

    # GetNewClosure captures $userName and $plain; nothing inside the method
    # calls a module-private command, so the closure's session state does not
    # have to reach back into the module.
    $result | Add-Member -MemberType ScriptMethod -Name GetCredential -Value {
        if ([string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrEmpty($plain)) {
            return $null
        }

        $secure = New-Object -TypeName System.Security.SecureString
        foreach ($character in $plain.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()

        return (New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $userName, $secure)
    }.GetNewClosure()

    return $result
}
