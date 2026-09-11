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
            $fileSystem = New-HDTFileSystem
            $fileSystem.TestPath('C:\HDTLab\Share\workspace.yaml')

            The real filesystem, which is what every command defaults to. It is a
            parameter at all so the engine can run under Pester against a
            hand-written fake instead of a disk.

        .EXAMPLE
            @($fileSystem.GetChildItem('C:\HDTLab\Share\Applications'))

            Reading through the adapter rather than through Get-ChildItem is what
            lets the same code run against a share, a fake, and the content
            projection standalone media uses.
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

    # THE RECURSIVE DELETE, WRITTEN OUT BECAUSE THE FRAMEWORK'S ONE FOLLOWS
    # JUNCTIONS. See RemoveItem below for the machine and the day that proved it.
    # It is one level of directory at a time: files here, then each child, then
    # this directory - and a child that is a reparse point is unlinked rather
    # than descended into.
    $service | Add-Member -MemberType ScriptMethod -Name IsReparsePoint -Value {
        param([string] $Full)

        if (-not [System.IO.Directory]::Exists($Full)) { return $false }

        $attribute = [System.IO.File]::GetAttributes($Full)

        return (($attribute -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)
    }

    $service | Add-Member -MemberType ScriptMethod -Name RemoveTree -Value {
        param([string] $Full)

        # THE DOOR, NOT THE ROOM. $false is deliberate and is the whole fix:
        # it unlinks the junction and never touches what it points at.
        if ($this.IsReparsePoint($Full)) {
            [System.IO.Directory]::Delete($Full, $false)
            return
        }

        # GetFiles WITHOUT AllDirectories is this directory only, which is what
        # makes the walk ours rather than the framework's.
        foreach ($item in [System.IO.Directory]::GetFiles($Full)) {
            [System.IO.File]::SetAttributes($item, [System.IO.FileAttributes]::Normal)
            [System.IO.File]::Delete($item)
        }

        foreach ($child in [System.IO.Directory]::GetDirectories($Full)) {
            $this.RemoveTree($child)
        }

        # A FOLDER HAS ATTRIBUTES TOO, AND Directory.Delete REFUSES ON THEM.
        #
        # The files above have had ReadOnly cleared since the ADK's autorun.inf
        # forced it; the FOLDER never did. A directory marked ReadOnly or System
        # throws UnauthorizedAccessException from Directory.Delete - "Access to
        # the path ... is denied", the SAME SENTENCE a permissions refusal
        # produces, and that collision cost four runs on 2026-09-10 taking
        # ownership of C:\Program Files and granting Administrators Modify over
        # it. takeown and icacls succeeded every single time. Nothing was ever
        # wrong with the ACL: C:\Program Files\Internet Explorer\images carries
        # the System bit, as plenty of Windows folders do, and that alone
        # stopped a wipe-and-load at "the volume is only half cleaned".
        #
        # THE Directory BIT STAYS. Assigning Normal to a directory is not
        # meaningful - what is wanted is ReadOnly, System and Hidden gone and
        # the thing still a directory, which is exactly what this says.
        $info = New-Object -TypeName System.IO.DirectoryInfo -ArgumentList $Full
        $info.Attributes = [System.IO.FileAttributes]::Directory

        [System.IO.Directory]::Delete($Full, $false)
    }

    $service | Add-Member -MemberType ScriptMethod -Name RemoveItem -Value {
        param([string] $Path, [bool] $Recurse)

        $this.Record('RemoveItem', @($Path, $Recurse))
        $full = $this.NormalizePath($Path)

        # THE READ-ONLY ATTRIBUTE IS CLEARED FIRST, WHICH IS Remove-Item -Force's
        # BEHAVIOUR AND NOT System.IO's. [System.IO.File]::Delete and
        # ::Directory.Delete both throw UnauthorizedAccessException on a
        # read-only file; Remove-Item clears the bit and deletes.
        #
        # THE ADK SHIPS ONE, AND IT BROKE EVERY SECOND MEDIA BUILD. Its WinPE
        # Media tree carries autorun.inf read-only, Update-HDTMediaContent copies
        # that tree into scratch and clears the tree before the next build, and
        # the second build died on
        #   Access to the path 'autorun.inf' is denied.
        # Watched 2026-09-03. tests/integration/FileSystemReadOnly.Integration.Tests.ps1
        # holds it, as an integration test because only a real NTFS enforces the
        # attribute a fake cannot reproduce.
        #
        # A READ-ONLY BIT IS NOT A PERMISSION. Every caller here is deleting
        # something it created in this run - a scratch tree, a staging directory,
        # a mount folder - and the attribute arrived by being copied off a
        # vendor's file rather than being chosen by anybody.
        if ([System.IO.File]::Exists($full)) {
            [System.IO.File]::SetAttributes($full, [System.IO.FileAttributes]::Normal)
            [System.IO.File]::Delete($full)
            return
        }

        if (-not [System.IO.Directory]::Exists($full)) {
            return
        }

        # ONLY WHEN RECURSING. A non-recursive delete of a populated directory
        # must still throw, so there is nothing to clear and walking the tree
        # would be work done to reach an exception.
        #
        # AND IT WALKS THE TREE ITSELF, BECAUSE .NET's WALK GOES THROUGH DOORS.
        # This was [System.IO.Directory]::GetFiles($full, '*', AllDirectories)
        # followed by Directory::Delete($full, $true), and both follow reparse
        # points. Two things went wrong on the first real Refresh, 2026-09-10:
        #
        #   IT NEVER FINISHED. C:\Documents and Settings is a junction to
        #   C:\Users, and under it AppData\Local\Application Data is a junction
        #   to its own parent. AllDirectories walked the loop until the path ran
        #   past MAX_PATH and threw "Could not find a part of the path
        #   'C:\Documents and Settings\Administrator\AppData\Local\Application
        #   Data\Application Data\...\IconCache.db'". CleanVolume reported
        #   "the volume is only half cleaned", which is the worst outcome a
        #   wipe-and-load has: the old installation is neither kept nor gone.
        #
        #   AND IT REACHED OUTSIDE THE TREE, which is the half nobody saw. A
        #   junction pointing off the volume is followed just as happily, so
        #   deleting a directory that merely CONTAINS one would clear attributes
        #   on, and then delete, files somewhere else entirely. On a volume being
        #   wiped that is invisible. Anywhere else it is data loss.
        #
        # A REPARSE POINT IS A DOOR, AND THE DOOR IS WHAT GETS DELETED - never
        # the room behind it. Directory::Delete(link, $false) removes the
        # junction and leaves its target alone, which is what rd and Remove-Item
        # do and what anybody deleting a tree means.
        if ($Recurse) {
            $this.RemoveTree($full)
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

    # RENAMING IS HOW AN ARTIFACT IS PUBLISHED. A boot image build writes its
    # .wim and .iso beside their final names and moves both into place only once
    # both exist - same directory, so same volume, so this is a rename rather
    # than half a gigabyte of copying, and a build that dies half way leaves the
    # previous pair intact instead of a new .wim beside a stale .iso.
    $service | Add-Member -MemberType ScriptMethod -Name MoveItem -Value {
        param([string] $Source, [string] $Destination)

        $this.Record('MoveItem', @($Source, $Destination))

        $this.EnsureParent($Destination)

        # -Force overwrites the destination, which is the whole point: the file
        # being replaced is the previous build's.
        Move-Item -LiteralPath $this.NormalizePath($Source) `
            -Destination $this.NormalizePath($Destination) -Force -ErrorAction Stop
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

        # SOMETHING THAT IS NOT THERE STAYS AN EXCEPTION, and it is stated here
        # rather than left to the tools: takeown reports a missing target on
        # stderr with an exit code, and "ERROR: The system cannot find the file"
        # is a worse answer than the type every other method on this service
        # throws for the same mistake.
        #
        # A FOLDER COUNTS. This read -PathType Leaf, which is FILES ONLY, so
        # every directory reached it and threw - and CleanVolume's whole reason
        # for calling this is a directory: C:\Program Files, owned by
        # TrustedInstaller. On 2026-09-10 that produced "Could not find
        # 'C:\Program Files' to take ownership of." about a folder the delete
        # had just walked into, which reads as a missing path and was a wrong
        # question.
        #
        # THAT IS THE THIRD PLACE THIS ONE ASSUMPTION HID: the takeown call
        # itself was file-only, the fake accepted only files, and so did this
        # guard. Rule 8's point exactly - a thing is not added until every
        # surface that must know about it does.
        if (-not (Test-Path -LiteralPath $full)) {
            throw [System.IO.FileNotFoundException]::new(
                "Could not find '$full' to take ownership of.", $full)
        }

        # takeown.exe AND icacls.exe, NOT .NET's SetOwner - AND ELEVATION IS NOT
        # WHAT DECIDES IT. Taking ownership of somebody else's file needs
        # SeTakeOwnershipPrivilege, and that privilege is present but DISABLED
        # in an elevated token until a process enables it. SetAccessControl
        # never does, so it failed with "Attempted to perform an unauthorized
        # operation" against \Windows\System32\winpe.jpg in a mounted image on a
        # fully elevated build - an error that reads exactly like "run as
        # administrator", which is what it had already been. takeown.exe enables
        # the privilege itself; that is the whole reason the tool exists.
        #
        # OWNERSHIP GOES TO THE CALLER, NOT TO Administrators. Assigning it to a
        # group is takeown /A, which needs SeRestorePrivilege as well - a second
        # privilege to be defeated by. Owning it is enough to grant the rest.
        #
        # 5.1 TRAP, NOT TIDINESS. Under Windows PowerShell 5.1 the 2>&1 below
        # wraps every stderr line in an ErrorRecord, and the ErrorActionPreference
        # Stop that engine code sets makes the FIRST one terminating - so a tool
        # that merely printed a warning kills the call before its exit code is
        # ever consulted (SPIKES S13.5). Local to this method scope.
        $ErrorActionPreference = 'Continue'

        # A DIRECTORY IS TAKEN WHOLE. /R walks it and /D Y answers the prompt
        # takeown asks when it cannot read a folder's current ACL - without that
        # answer the tool blocks for ever on a machine nobody is standing at.
        #
        # THIS WAS FILE-ONLY UNTIL 2026-09-10, AND CleanVolume PAID FOR IT. A
        # Refresh empties a deployed Windows, and C:\Program Files and its
        # children are owned by TrustedInstaller - Administrators are not granted
        # delete on them. Taking the top folder alone changes nothing about the
        # children, and icacls /grant then fails SILENTLY on each of them,
        # because /C means "carry on past errors" and the exit code stays 0. The
        # delete that follows then refuses on the first one it reaches:
        #
        #   Access to the path 'C:\Program Files\Internet Explorer\images' is denied.
        #   step 'Clean the OS volume': C:\Program Files could not be deleted
        #   from C:\, so the volume is only half cleaned.
        #
        # A FILE GETS NO /R, because takeown rejects it there - and a caller
        # asking for one file wants exactly one file.
        $takeArgument = [System.Collections.ArrayList]::new()
        [void] $takeArgument.AddRange(@('/F', $full))

        $isDirectory = [System.IO.Directory]::Exists($full)
        if ($isDirectory) { [void] $takeArgument.AddRange(@('/R', '/D', 'Y')) }

        $takeOutput = @(& "$env:SystemRoot\System32\takeown.exe" @takeArgument 2>&1)

        # IT SAYS WHAT THE TOOL SAID, AND THAT IS THE POINT OF THIS LINE.
        #
        # This used to swallow a non-zero exit for a directory as "best effort",
        # on the reasoning that a Windows installation always has a few items
        # takeown cannot claim and the delete afterwards is the real test. That
        # reasoning is fine right up until the delete FAILS - and then the log
        # says "Access to the path 'C:\Program Files\Internet Explorer\images'
        # is denied", with nothing at all about the repair that was supposed to
        # prevent it. Three runs on 2026-09-10 died that way, and each one left
        # the question "did takeown work?" unanswerable.
        #
        # SO A FAILED TAKE IS AN ERROR THAT CARRIES ITS OWN EVIDENCE. The
        # caller's catch has somewhere to put it, and CLAUDE.md asks for the
        # command, its exit code and what that code means rather than a
        # flattened sentence. A repair that half worked and a delete that then
        # refused are two different faults and want two different fixes.
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                ("takeown.exe exited {0} for '{1}'{2}{3}" -f $LASTEXITCODE, $full,
                    [System.Environment]::NewLine, (@($takeOutput) -join [System.Environment]::NewLine)))
        }

        # S-1-5-32-544 IS Administrators IN EVERY LANGUAGE. 'BUILTIN\Administrators'
        # is not: icacls resolves names against the local system's locale, and a
        # German build host has 'VORDEFINIERT\Administratoren'.
        $grantOutput = @(& "$env:SystemRoot\System32\icacls.exe" $full '/grant' '*S-1-5-32-544:(F)' 2>&1)

        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                ("icacls.exe exited {0} for '{1}'{2}{3}" -f $LASTEXITCODE, $full,
                    [System.Environment]::NewLine, (@($grantOutput) -join [System.Environment]::NewLine)))
        }
    }

    # NTFS, THE HALF A SHARE PERMISSION IS NOT. SMB gates the connection and
    # NTFS gates the file; the effective right is the more restrictive of the
    # two, so a share granted to the deployment account and an NTFS tree that
    # never heard of it produces a share the machine can reach and cannot read.
    # That was HDT's behaviour until this existed: New-HDTWorkspaceShare granted
    # the share half and left the other to three icacls lines in
    # docs/share-account.md that nothing ran.
    #
    # icacls.exe, NOT SetAccessControl, FOR TakeOwnership'S REASON ONE STEP ON:
    # writing an ACL on a tree somebody else owns needs privileges that are
    # present but disabled in an elevated token, and the tool enables them
    # itself. It also applies to the whole tree in one call, which .NET does not.
    #
    # THE RIGHT IS TRANSLATED BY ConvertTo-HDTIcaclsRight, which is where the
    # branch lives - hard rule 1 lets this method skip a unit test only while it
    # has none of its own. What is left here is the existence guard and the
    # exit-code check, exactly as TakeOwnership has.
    $service | Add-Member -MemberType ScriptMethod -Name GrantAccess -Value {
        param([string] $Path, [string] $Account, [string] $Right)

        $this.Record('GrantAccess', @($Path, $Account, $Right))

        $full = $this.NormalizePath($Path)

        # Refused before the tool is reached, so the message names the right
        # rather than icacls naming a parameter.
        $permission = ConvertTo-HDTIcaclsRight -Right $Right

        if (-not (Test-Path -LiteralPath $full)) {
            throw [System.IO.DirectoryNotFoundException]::new(
                "Could not find '$full' to grant access on.")
        }

        # SPIKES S13.5, as above: under 5.1 the 2>&1 wraps every stderr line in
        # an ErrorRecord and an ErrorActionPreference of Stop makes the first one
        # terminating - so a tool that merely printed a warning would kill the
        # call before its exit code is read. Local to this method scope.
        $ErrorActionPreference = 'Continue'

        $output = @(& "$env:SystemRoot\System32\icacls.exe" $full `
                '/grant' ('{0}:{1}' -f $Account, $permission) '/T' '/C' '/Q' 2>&1)

        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                ("icacls.exe exited {0} granting {1} to '{2}' on '{3}'{4}{5}" -f $LASTEXITCODE,
                    $Right, $Account, $full,
                    [System.Environment]::NewLine, (@($output) -join [System.Environment]::NewLine)))
        }
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

    # WHEN IT LAST CHANGED, which is what makes a cache safe rather than a bet.
    # Parsing the driver store costs 2.5 seconds for 211 .inf files and the
    # console re-reads it every time somebody selects a folder; a cache is the
    # difference between a list that appears and one you wait for. But a cache
    # with no invalidation shows an administrator the drivers that USED to be in
    # a folder they have just re-imported, which is worse than the wait.
    #
    # UTC, because the value is compared and not displayed, and a share crossing
    # a daylight-saving boundary must not invalidate every entry at once.
    $service | Add-Member -MemberType ScriptMethod -Name GetLastWriteTimeUtc -Value {
        param([string] $Path)

        $this.Record('GetLastWriteTimeUtc', @($Path))
        $full = $this.NormalizePath($Path)

        if (-not [System.IO.File]::Exists($full)) {
            throw (New-Object -TypeName System.IO.FileNotFoundException -ArgumentList "Could not find file '$full'.", $full)
        }

        return [datetime] [System.IO.File]::GetLastWriteTimeUtc($full)
    }

    # WHAT THE FILE SAYS IT IS, added because a vendor driver pack will not say
    # so any other way. A Dell Update Package and an HP SoftPaq are both
    # 'a self-extracting .exe' to every other test available - same extension,
    # both PE files, both self-extracting - and they take INCOMPATIBLE switches.
    # Guessing wrong does not fail cleanly: a Dell pack handed HP's switches
    # opens its interactive installer and blocks until the timeout, which is
    # exactly the bug this exists to remove.
    #
    # Reading it off the filename was the cheaper option and it is not good
    # enough: 'sp150000.exe' is a convention, not a guarantee, and the file
    # already carries the answer in a field the vendor set on purpose -
    # CompanyName 'Dell Inc.', FileDescription 'Dell Update Package: ...'.
    #
    # A file with no version block answers empty strings rather than throwing.
    # Plenty of legitimate archives carry none, and 'unknown vendor' is a case
    # the caller has to handle anyway.
    $service | Add-Member -MemberType ScriptMethod -Name GetVersionInfo -Value {
        param([string] $Path)

        $this.Record('GetVersionInfo', @($Path))
        $full = $this.NormalizePath($Path)

        if (-not [System.IO.File]::Exists($full)) {
            throw (New-Object -TypeName System.IO.FileNotFoundException -ArgumentList "Could not find file '$full'.", $full)
        }

        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($full)

        return [pscustomobject] @{
            CompanyName     = [string] $info.CompanyName
            ProductName     = [string] $info.ProductName
            FileDescription = [string] $info.FileDescription
            FileVersion     = [string] $info.FileVersion
        }
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
