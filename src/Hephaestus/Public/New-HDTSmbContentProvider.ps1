function New-HDTSmbContentProvider {
    <#
        .SYNOPSIS
            Creates the Smb IContentProvider - a deployment share, mapped with
            the deployment account, and refused when it comes back as a guest.

        .DESCRIPTION
            DESIGN 6's provider interface over a UNC share, and DESIGN 6.3's
            refusals in the one place they can be enforced: the moment the
            mapping is made.

            THE REFUSALS, IN ORDER, AND WHY EACH ONE IS HERE:

              1. A root that is not UNC is an HDTConfigurationError. A local path
                 is New-HDTLocalContentProvider's job.
              2. A credential with a username and an EMPTY password is an
                 HDTSecurityError: an empty password is an anonymous logon
                 wearing a name.
              3. NO CREDENTIAL AT ALL is an HDTSecurityError unless
                 -AllowAnonymous was passed explicitly. DESIGN 6.3's refusal to
                 fall back to guest starts here - not supplying a credential IS
                 the fallback, and a provider that shrugged would deploy from
                 whatever the server felt like handing over.
              4. With no credential and EnableInsecureGuestLogons turned on, it
                 refuses before mapping. HDT REPORTS THE MACHINE'S SMB CLIENT
                 POSTURE, IT DOES NOT CHANGE IT: turning a security setting off
                 to make a deployment work is the opposite of what the check is
                 for.

            THEN IT MAPS, AND READS THE ESTABLISHED IDENTITY BACK. That read-back
            is the whole point of this file. A mapping can succeed and still have
            authenticated as nobody:

              - no connection row for the server -> the mapping did not take;
              - a UserName that is empty, 'Guest', anything ending '\Guest', or
                'ANONYMOUS LOGON' (case-insensitive) -> HDTSecurityError naming
                the server, AND THE MAPPING IT JUST MADE IS TORN DOWN, because a
                refusal that left the share attached would be a refusal in name
                only;
              - a dialect beginning '1.' -> SMB1, refused outright;
              - a dialect below 3.0 -> WARN and continue. A 2.1 file server is
                legitimate and refusing it would be HDT deciding a fleet's
                infrastructure for it;
              - an unencrypted connection -> WARN once, naming the server
                (DESIGN 6.3: signing and encryption "where the server supports
                them").

            Connect is re-entrant: calling it twice maps once.

            Disconnect NEVER THROWS. It runs in a finally, and a teardown that
            throws is a teardown that does not finish.

            THE RESOLUTION RULES ARE IDENTICAL TO THE LOCAL PROVIDER'S, which is
            DESIGN 6.2's "a content projection plus a provider swap, not a
            parallel code path" as far as a step is concerned - asserted by
            tests/contract/ContentProvider.Contract.Tests.ps1 over all three
            implementations, and by the operation-list equality test in
            tests/unit/Invoke-HDTApplyImageStep.Tests.ps1.

            Segments are collapsed by hand rather than by
            [IO.Path]::GetFullPath, which SILENTLY CLAMPS '..' AT THE ROOT OF A
            UNC SHARE - GetFullPath('\\server\Share\..\..\Windows') is
            '\\server\Share\Windows' on both engines - and would therefore turn
            an escape into a legal path instead of reporting it.

            THE ERROR ID TRAVELS IN THE MESSAGE. A refusal raised inside a
            ScriptMethod reaches its caller as ScriptMethodRuntimeException and
            loses an ErrorRecord's FullyQualifiedErrorId, so HDTSecurityError and
            HDTConfigurationError are written into the sentence.

            The SmbShare module underneath is reached through New-HDTSmbService,
            which is a dumb adapter; everything above is here, where it is unit
            tested against New-HDTFakeSmbService with nothing mapped.

        .PARAMETER Root
            The deployment share, as a UNC path: \\server\share.

        .PARAMETER Credential
            The deployment account. Read from Control\share-credential.json by
            Get-HDTShareCredential in a real run.

        .PARAMETER AllowAnonymous
            Connect with the caller's own identity and no credential. It exists
            so that "no credential" is something an operator SAYS, rather than
            something that happens by omission.

        .PARAMETER SmbService
            An ISmbService. Defaults to the real adapter.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with the five
            IContentProvider ScriptMethods, plus Root, ServiceName, Operations
            and GetOperationName(). Note that Get-Member -MemberType Method does
            NOT list a ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $secret = Get-HDTShareCredential -WorkspaceRoot 'X:\Deploy'
            $credential = New-Object System.Management.Automation.PSCredential $secret.UserName,
                (ConvertTo-SecureString $secret.Password -AsPlainText -Force)

            $content = New-HDTSmbContentProvider -Root '\\server\HdtShare' -Credential $credential
            try {
                $content.Connect()
                $content.ResolveContent('OperatingSystems\Win11-LTSC-2024\sources\install.wim')
            } finally {
                $content.Disconnect()
            }

        .EXAMPLE
            $content = New-HDTSmbContentProvider -Root '\\localhost\HDTIntegration$' -AllowAnonymous

            The caller's own identity, said out loud.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state. Connect is where a mapping is made, and it is a method.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter()]
        [AllowNull()]
        [pscredential] $Credential,

        [Parameter()]
        [switch] $AllowAnonymous,

        [Parameter()]
        [AllowNull()]
        [object] $SmbService,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $SmbService) { $SmbService = New-HDTSmbService }
    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $service = [pscustomobject] @{
        Root           = $Root
        Credential     = $Credential
        AllowAnonymous = [bool] $AllowAnonymous
        SmbService     = $SmbService
        FileSystem     = $FileSystem
        Operations     = [System.Collections.ArrayList]::new()
        Journal        = $Journal
        ServiceName    = 'ContentProvider'
        IsConnected    = $false
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return , ([string[]] @($this.Operations | ForEach-Object { $_.Operation }))
    }

    $service | Add-Member -MemberType ScriptMethod -Name AssertUsablePath -Value {
        param([string] $Path)

        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw (New-Object System.ArgumentException (
                    "HDTConfigurationError: a content path must not be empty. The provider was asked to resolve nothing against the content root '$($this.Root)'."))
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name Combine -Value {
        param([string] $RelativePath)

        $segment = [System.Collections.ArrayList]::new()

        foreach ($part in ($RelativePath -split '[\\/]+')) {
            if (($part -eq '') -or ($part -eq '.')) { continue }

            if ($part -eq '..') {
                if ($segment.Count -eq 0) {
                    throw (New-Object System.ArgumentException (
                            "HDTConfigurationError: the content path '$RelativePath' escapes the content root '$($this.Root)'. A step asking for content outside the workspace is a defect, not a path to follow."))
                }
                $segment.RemoveAt($segment.Count - 1)
                continue
            }

            [void] $segment.Add($part)
        }

        if ($segment.Count -eq 0) { return $this.Root }

        return ($this.Root.TrimEnd('\', '/') + '\' + ($segment -join '\'))
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetServerName -Value {
        $part = @($this.Root.TrimStart('\', '/') -split '[\\/]+' | Where-Object { $_ -ne '' })
        if ($part.Count -eq 0) { return '' }

        return $part[0]
    }

    $service | Add-Member -MemberType ScriptMethod -Name TestGuestIdentity -Value {
        param([string] $UserName)

        if ([string]::IsNullOrWhiteSpace($UserName)) { return $true }

        $name = $UserName.Trim()
        if ($name -match '(?i)^(.*\\)?guest$') { return $true }
        if ($name -match '(?i)anonymous logon') { return $true }

        return $false
    }

    $service | Add-Member -MemberType ScriptMethod -Name ResolveContent -Value {
        param([string] $RelativePath)

        $this.Record('ResolveContent', @($RelativePath))
        $this.AssertUsablePath($RelativePath)

        # DESIGN 9.3: media registered where it stands is not re-rooted.
        if ([System.IO.Path]::IsPathRooted($RelativePath)) {
            return $RelativePath
        }

        return $this.Combine($RelativePath)
    }

    $service | Add-Member -MemberType ScriptMethod -Name TestContent -Value {
        param([string] $RelativePath)

        $this.Record('TestContent', @($RelativePath))
        $this.AssertUsablePath($RelativePath)

        $path = $RelativePath
        if (-not [System.IO.Path]::IsPathRooted($RelativePath)) {
            $path = $this.Combine($RelativePath)
        }

        return [bool] $this.FileSystem.TestPath($path)
    }

    $service | Add-Member -MemberType ScriptMethod -Name CopyContent -Value {
        param([string] $RelativePath, [string] $Destination)

        $this.Record('CopyContent', @($RelativePath, $Destination))
        $this.AssertUsablePath($RelativePath)

        if ([string]::IsNullOrWhiteSpace($Destination)) {
            throw (New-Object System.ArgumentException (
                    "HDTConfigurationError: CopyContent was given no destination for '$RelativePath'."))
        }

        $source = $RelativePath
        if (-not [System.IO.Path]::IsPathRooted($RelativePath)) {
            $source = $this.Combine($RelativePath)
        }

        if (-not $this.FileSystem.TestPath($source)) {
            throw (New-Object System.IO.FileNotFoundException ("Could not find content '$source'.", $source))
        }

        $parent = [System.IO.Path]::GetDirectoryName($Destination)
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            $this.FileSystem.CreateDirectory($parent)
        }

        $this.FileSystem.CopyItem($source, $Destination)

        return $Destination
    }

    $service | Add-Member -MemberType ScriptMethod -Name Connect -Value {
        $this.Record('Connect', @())

        # Re-entrant: a launcher that connects, and a step that connects again
        # because it cannot know, must produce one mapping.
        if ($this.IsConnected) {
            return $this.Root
        }

        # -- what it refuses before it maps --------------------------------

        if (-not $this.Root.StartsWith('\\')) {
            throw (New-Object System.ArgumentException (
                    "HDTConfigurationError: the content root '$($this.Root)' is not a UNC path. The Smb provider connects to \\server\share; content on this machine is New-HDTLocalContentProvider's job."))
        }

        $userName = ''
        $password = ''

        if ($null -ne $this.Credential) {
            $userName = [string] $this.Credential.UserName
            $password = [string] $this.Credential.GetNetworkCredential().Password

            if ([string]::IsNullOrEmpty($password)) {
                throw (New-Object System.Security.SecurityException (
                        "HDTSecurityError: the credential for '$userName' has an empty password. An empty password is an anonymous logon with a name on it, and HDT does not deploy from a share it authenticated to as nobody (DESIGN 6.3)."))
            }
        } elseif (-not $this.AllowAnonymous) {
            throw (New-Object System.Security.SecurityException (
                    "HDTSecurityError: no credential was supplied for '$($this.Root)'. Not supplying one is exactly the guest fallback DESIGN 6.3 refuses. Pass -Credential, or pass -AllowAnonymous to connect as this machine's own identity on purpose."))
        } else {
            $configuration = $this.SmbService.GetClientConfiguration()

            if ($configuration.EnableInsecureGuestLogons) {
                throw (New-Object System.Security.SecurityException (
                        "HDTSecurityError: this machine has EnableInsecureGuestLogons turned on and no credential was supplied for '$($this.Root)', so the connection could silently become a guest session. HDT reports this setting and does not change it: changing a machine's security posture to make a deployment work is the opposite of what the check is for."))
            }
        }

        # -- the mapping, and the identity it actually produced --------------

        $this.SmbService.NewMapping($this.Root, $userName, $password)

        $server = $this.GetServerName()
        $connection = @($this.SmbService.GetConnection($server))

        if ($connection.Count -eq 0) {
            $this.SafeRemoveMapping()
            throw (New-Object System.InvalidOperationException (
                    "HDTEnvironmentError: the mapping to '$($this.Root)' did not take - no SMB connection to '$server' came back. HDT will not read content from a path it cannot prove it is connected to."))
        }

        $row = $connection[0]

        if ($this.TestGuestIdentity([string] $row.UserName)) {
            $this.SafeRemoveMapping()
            throw (New-Object System.Security.SecurityException (
                    ("HDTSecurityError: the connection to '{0}' came back as '{1}' - it fell back to guest, and HDT will not deploy from a share it did not authenticate to (DESIGN 6.3). The mapping has been removed. Check that the deployment account is enabled and that its password matches the one Set-HDTShareCredential wrote." -f $server, [string] $row.UserName)))
        }

        $dialect = [string] $row.Dialect

        if ($dialect.StartsWith('1.')) {
            $this.SafeRemoveMapping()
            throw (New-Object System.Security.SecurityException (
                    "HDTSecurityError: the connection to '$server' negotiated SMB dialect '$dialect'. SMB1 is refused outright (DESIGN 6.3), and the mapping has been removed."))
        }

        $major = 0
        $part = @($dialect -split '\.')
        if ($part.Count -gt 0) { $major = [int] ($part[0] -as [int]) }

        if ($major -lt 3) {
            Write-Warning ("The connection to '{0}' negotiated SMB dialect '{1}'. HDT continues - a 2.x file server is legitimate - but SMB 3 is where encryption and the strongest signing live." -f $server, $dialect)
        }

        if (-not $row.Encrypted) {
            Write-Warning ("The connection to '{0}' is not encrypted. DESIGN 6.3 uses SMB signing and encryption where the server supports them; this one does not, so the deployment credential and every file it reads cross the network in clear." -f $server)
        }

        $this.IsConnected = $true

        return $this.Root
    }

    $service | Add-Member -MemberType ScriptMethod -Name SafeRemoveMapping -Value {
        try {
            $this.SmbService.RemoveMapping($this.Root)
        } catch {
            # A refusal must not be replaced by the failure of its own cleanup:
            # the sentence the caller needs is the one about the identity.
            $null = $_
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name Disconnect -Value {
        $this.Record('Disconnect', @())

        $this.SafeRemoveMapping()
        $this.IsConnected = $false
    }

    return $service
}
