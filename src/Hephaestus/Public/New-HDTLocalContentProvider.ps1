function New-HDTLocalContentProvider {
    <#
        .SYNOPSIS
            Creates the Local IContentProvider - content on the media the machine
            booted from.

        .DESCRIPTION
            DESIGN 6's provider interface, over a path on this machine. It is what
            standalone media runs on (DESIGN 6.2), and it is what the lab runs on:
            SPIKES S6 records that a VM on the isolated 'HDT Lab' switch cannot
            reach a share on the host, so every end-to-end run in this repository
            reaches its content locally.

            FIVE MEMBERS, AND Connect / Disconnect ARE TWO OF THEM EVEN THOUGH
            THEY DO ALMOST NOTHING HERE:

              ResolveContent(relativePath) -> an absolute path a step can use
              TestContent(relativePath)    -> [bool]
              CopyContent(relativePath, destination) -> the destination
              Connect()                    -> the root that is now reachable
              Disconnect()

            DESIGN 6.2 says media generation is "a content projection plus a
            provider swap, not a parallel code path". A provider where one
            implementation carries two extra methods is a provider a step has to
            branch on, and a step that branches on its transport is the parallel
            code path that sentence exists to prevent. So Connect is here, it
            records like everything else, and it does one useful thing: it
            verifies the root is there. A USB stick that was never inserted must
            fail at Connect, naming the root, rather than three steps later in
            the middle of an apply.

            THE RESOLUTION RULES, IDENTICAL IN EVERY IMPLEMENTATION:

              - a relative path is combined with Root;
              - a ROOTED path is returned unchanged - DESIGN 9.3's media too
                large to bring into the share, registered where it stands;
              - a '..' that escapes Root is refused;
              - an empty path is refused.

            Segments are collapsed here rather than by [IO.Path]::GetFullPath,
            which consults the current directory for a volume-relative root and
            silently clamps '..' at the root of a UNC share instead of reporting
            the escape.

            THE ERROR ID TRAVELS IN THE MESSAGE. A refusal raised inside a
            ScriptMethod reaches its caller as ScriptMethodRuntimeException and
            loses an ErrorRecord's FullyQualifiedErrorId (verified on pwsh 7.5.8
            and Windows PowerShell 5.1.26100.8655), so 'HDTConfigurationError' is
            written into the sentence, where the fake's class method and this
            object's ScriptMethod can both carry it.

            ResolveContent DOES NOT CHECK EXISTENCE - TestContent is that
            question and a step asks it when it wants the answer. Everything that
            does touch the disk goes through the injected IFileSystem
            (PROJECT constraint 4), which is what makes this whole file provable
            with no media attached.

        .PARAMETER Root
            The content root - the media root, or a workspace on this machine.

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
            $content = New-HDTLocalContentProvider -Root 'E:\HDTMedia'
            $content.Connect()
            $content.ResolveContent('OperatingSystems\Win11-LTSC-2024\sources\install.wim')

        .EXAMPLE
            $content = New-HDTLocalContentProvider -Root $mediaRoot -FileSystem $fs
            $catalog = New-HDTServiceCatalog -FileSystem $fs -Clock $clock -Content $content

            The provider as the catalog's twelfth service, which is how a step
            reaches it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) {
        $FileSystem = New-HDTFileSystem
    }

    $service = [pscustomobject] @{
        Root        = $Root
        FileSystem  = $FileSystem
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'ContentProvider'
        IsConnected = $false
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

    $service | Add-Member -MemberType ScriptMethod -Name ResolveContent -Value {
        param([string] $RelativePath)

        $this.Record('ResolveContent', @($RelativePath))
        $this.AssertUsablePath($RelativePath)

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

        if (-not $this.FileSystem.TestPath($this.Root)) {
            throw (New-Object System.IO.DirectoryNotFoundException (
                    "HDTEnvironmentError: the content root '$($this.Root)' is not there. Local content comes from the media this machine booted from, so a stick that was never inserted fails here rather than in the middle of an apply."))
        }

        $this.IsConnected = $true

        return $this.Root
    }

    $service | Add-Member -MemberType ScriptMethod -Name Disconnect -Value {
        # A no-op that records, because that is what makes the recorded ceremony
        # identical to the Smb provider's (DESIGN 6.2). It also never throws:
        # every caller runs it from a finally.
        $this.Record('Disconnect', @())
        $this.IsConnected = $false
    }

    return $service
}
