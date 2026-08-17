function New-HDTFileSystem {
    <#
        .SYNOPSIS
            Creates the real IFileSystem adapter over System.IO.

        .DESCRIPTION
            The one place in HDT that touches the filesystem. PROJECT constraint
            4 forbids engine logic from doing it directly, so the log writer, the
            state document and every step receive this object and can be swapped
            for New-HDTFakeFileSystem in a test.

            It implements the eleven IFileSystem methods - TestPath, ReadAllText,
            WriteAllText, AppendAllText, CreateDirectory, RemoveItem, CopyItem,
            GetChildItem, GetLength, GetHash, GetVersion - and lets System.IO
            throw its own exception
            types, because those types are what the contract asserts and what the
            fake reproduces.

            IT WRITES UTF-8 WITHOUT A BYTE ORDER MARK, THROUGH System.IO.File.
            Set-Content -Encoding UTF8 emits 239 187 191 under Windows PowerShell
            5.1 and nothing under pwsh 7, and the engine writes its logs under 5.1
            in WinPE and its tests under 7 on a desk - so a BOM would appear in
            exactly the files a parser reads. [System.IO.File]::WriteAllText and
            ::AppendAllText with UTF8Encoding($false) are BOM-free on both. This
            is SPIKES.md S6's UTF-16 Tee-Object trap in a different disguise.
            Set-Content and Add-Content are banned in this file.

            WriteAllText and AppendAllText create the parent directory first:
            ::AppendAllText creates a missing file but throws for a missing
            directory, and a log writer that has to know whether today is the
            first write is a log writer with a bug in it.

            Paths are normalised with [System.IO.Path]::GetFullPath and stripped
            of a trailing separator, matching the fake.

            Every call is recorded in $Operations, before it can throw, exactly
            as the fakes record (tests/helpers/README.md section 4).

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03). An array-returning
            ScriptMethod returns with the unary comma, or a single-element result
            collapses to a scalar.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with the nine IFileSystem
            ScriptMethods. Note that Get-Member -MemberType Method does NOT list
            a ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $fs = New-HDTFileSystem
            $fs.AppendAllText('C:\HDT\Logs\HDT.jsonl', $record + "`n")

            One JSONL record appended, UTF-8, no BOM, directory created if absent.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'FileSystem'
        Encoding    = (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false)
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

    $service | Add-Member -MemberType ScriptMethod -Name NormalizePath -Value {
        param([string] $Path)

        $full = [System.IO.Path]::GetFullPath($Path)

        # 'C:\' is three characters and its separator is part of the root.
        if ($full.Length -gt 3) {
            $full = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        }

        return $full
    }

    $service | Add-Member -MemberType ScriptMethod -Name EnsureParent -Value {
        param([string] $NormalizedPath)

        $parent = [System.IO.Path]::GetDirectoryName($NormalizedPath)
        if ($parent) {
            [void] [System.IO.Directory]::CreateDirectory($parent)
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name TestPath -Value {
        param([string] $Path)

        $this.Record('TestPath', @($Path))
        $full = $this.NormalizePath($Path)

        return ([System.IO.File]::Exists($full) -or [System.IO.Directory]::Exists($full))
    }

    $service | Add-Member -MemberType ScriptMethod -Name ReadAllText -Value {
        param([string] $Path)

        $this.Record('ReadAllText', @($Path))

        return [System.IO.File]::ReadAllText($this.NormalizePath($Path))
    }

    $service | Add-Member -MemberType ScriptMethod -Name WriteAllText -Value {
        param([string] $Path, [string] $Content)

        $this.Record('WriteAllText', @($Path, $Content))
        $full = $this.NormalizePath($Path)
        $this.EnsureParent($full)

        [System.IO.File]::WriteAllText($full, $Content, $this.Encoding)
    }

    $service | Add-Member -MemberType ScriptMethod -Name AppendAllText -Value {
        param([string] $Path, [string] $Content)

        $this.Record('AppendAllText', @($Path, $Content))
        $full = $this.NormalizePath($Path)
        $this.EnsureParent($full)

        [System.IO.File]::AppendAllText($full, $Content, $this.Encoding)
    }

    $service | Add-Member -MemberType ScriptMethod -Name CreateDirectory -Value {
        param([string] $Path)

        $this.Record('CreateDirectory', @($Path))

        [void] [System.IO.Directory]::CreateDirectory($this.NormalizePath($Path))
    }

    $service | Add-Member -MemberType ScriptMethod -Name RemoveItem -Value {
        param([string] $Path, [bool] $Recurse)

        $this.Record('RemoveItem', @($Path, $Recurse))
        $full = $this.NormalizePath($Path)

        if ([System.IO.File]::Exists($full)) {
            [System.IO.File]::Delete($full)
            return
        }

        if (-not [System.IO.Directory]::Exists($full)) {
            return
        }

        # Directory.Delete throws IOException for a populated directory when
        # recursion was not asked for, which is the contract.
        [System.IO.Directory]::Delete($full, $Recurse)
    }

    $service | Add-Member -MemberType ScriptMethod -Name CopyItem -Value {
        param([string] $Source, [string] $Destination)

        $this.Record('CopyItem', @($Source, $Destination))
        $destinationPath = $this.NormalizePath($Destination)
        $this.EnsureParent($destinationPath)

        [System.IO.File]::Copy($this.NormalizePath($Source), $destinationPath, $true)
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetChildItem -Value {
        param([string] $Path)

        $this.Record('GetChildItem', @($Path))

        $child = [string[]] @([System.IO.Directory]::GetFileSystemEntries($this.NormalizePath($Path)))
        [array]::Sort($child, [System.StringComparer]::Ordinal)

        # The unary comma is mandatory: a ScriptMethod collapses a single-element
        # array to a scalar without it.
        return , ([string[]] $child)
    }

    # OWNERSHIP AND FULL CONTROL FOR ADMINISTRATORS, WHICH IS THE ONLY WAY TO
    # REPLACE A FILE INSIDE A MOUNTED IMAGE. \Windows\System32\winpe.jpg - the
    # WinPE background - is owned by TrustedInstaller and denies write even to
    # an elevated build: a straight copy over it fails with "Access to the path
    # is denied", which is exactly what a real build reported. Microsoft's own
    # instructions for changing that background are take ownership, grant
    # Administrators full control, then replace, and this is that pair.
    #
    # IT NEEDS ELEVATION, and every build that mounts an image already has it -
    # DISM will not mount without it. A caller that is not elevated gets the
    # framework's own exception, which says so.
    $service | Add-Member -MemberType ScriptMethod -Name TakeOwnership -Value {
        param([string] $Path)

        $this.Record('TakeOwnership', @($Path))

        $full = $this.NormalizePath($Path)
        $administrators = New-Object -TypeName System.Security.Principal.SecurityIdentifier `
            -ArgumentList ([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid), $null

        # THE OWNER IS SET IN ITS OWN Set-Acl, BEFORE THE ACE IS ADDED. Writing
        # a DACL onto a file you do not own is itself denied, so the two cannot
        # be one call: ownership first buys the right to change the rest.
        $file = Get-Item -LiteralPath $full -Force
        $owner = $file.GetAccessControl('Owner')
        $owner.SetOwner($administrators)
        $file.SetAccessControl($owner)

        $access = $file.GetAccessControl('Access')
        $access.AddAccessRule((New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule `
                    -ArgumentList $administrators,
                ([System.Security.AccessControl.FileSystemRights]::FullControl),
                ([System.Security.AccessControl.AccessControlType]::Allow)))
        $file.SetAccessControl($access)
    }

    # THE FOLDERS ONLY, because a caller frequently means folders. A driver
    # group is a FOLDER under Drivers\, and a flat list of paths cannot be
    # filtered back down to folders without guessing from the name - which fails
    # on 'Dell Latitude 7450 v2.1' the first time somebody names one after a
    # driver version.
    $service | Add-Member -MemberType ScriptMethod -Name GetDirectory -Value {
        param([string] $Path)

        $this.Record('GetDirectory', @($Path))

        $child = [string[]] @([System.IO.Directory]::GetDirectories($this.NormalizePath($Path)))
        [array]::Sort($child, [System.StringComparer]::Ordinal)

        return , ([string[]] $child)
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetLength -Value {
        param([string] $Path)

        $this.Record('GetLength', @($Path))
        $full = $this.NormalizePath($Path)

        if (-not [System.IO.File]::Exists($full)) {
            throw (New-Object -TypeName System.IO.FileNotFoundException -ArgumentList "Could not find file '$full'.", $full)
        }

        return [long] (New-Object -TypeName System.IO.FileInfo -ArgumentList $full).Length
    }

    # THE TENTH METHOD, ADDED IN 05-04. DESIGN 6.1.1's claim - "the WIM inside
    # the ISO and the standalone WIM have identical hashes" - has to be written
    # into the boot image manifest so an operator can check it without the test
    # suite. Hashing a 500 MB ISO through ReadAllText would be wrong twice over
    # (it is not text, and it would be held in memory), so the interface grew a
    # method rather than Update-HDTBootImage growing a Get-FileHash call that no
    # fake could answer.
    #
    # The existence guard is the same one GetLength carries, for the same reason:
    # Get-FileHash reports a path error that does not plainly say "that file is
    # not there", and the fake throws FileNotFoundException.
    $service | Add-Member -MemberType ScriptMethod -Name GetHash -Value {
        param([string] $Path)

        $this.Record('GetHash', @($Path))
        $full = $this.NormalizePath($Path)

        if (-not [System.IO.File]::Exists($full)) {
            throw (New-Object -TypeName System.IO.FileNotFoundException -ArgumentList "Could not find file '$full'.", $full)
        }

        return [string] (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetVersion -Value {
        param([string] $Path)

        $this.Record('GetVersion', @($Path))
        $full = $this.NormalizePath($Path)

        if (-not [System.IO.File]::Exists($full)) {
            throw (New-Object -TypeName System.IO.FileNotFoundException -ArgumentList "Could not find file '$full'.", $full)
        }

        # THE FOUR PARTS, NOT THE FileVersion STRING. FileVersion is free text a
        # vendor fills in and regularly holds things like '4.2.0.0 (release)',
        # which no version comparison can parse. The four integer parts are the
        # numbers Windows itself compares, and a file with no version resource
        # reports 0.0.0.0 through them rather than $null - so the caller casts to
        # [version] with no special case.
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($full)

        return [string] ('{0}.{1}.{2}.{3}' -f $info.FileMajorPart, $info.FileMinorPart,
            $info.FileBuildPart, $info.FilePrivatePart)
    }

    return $service
}
