Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
    Hand-written service doubles for the HDT test suite (DESIGN 12.2.3: fake,
    don't mock, the services).

    Classes are defined inline in this file rather than dot-sourced from .ps1
    files. Class definitions that arrive by dot-sourcing are the known-flaky path
    across -Force re-imports; inline definitions are not.

    Tests obtain a fake only through its New-HDTFake* factory and never write the
    class name as a type literal, because a type literal binds to whichever
    dynamic assembly was loaded first and breaks on module reload.

    Every fake records what it was asked to do. See tests/helpers/README.md for
    the conventions phases 02-09 follow.
#>

class HDTFakeFileSystem {

    # Path -> content. Case-insensitive, matching Windows filesystem semantics.
    [hashtable] $File

    # Path -> $true. A set, held separately so an empty directory still exists.
    [hashtable] $Directory

    # Path -> the message a write to it throws. DESIGN 4.5.3's teardown runs from
    # a finally block, so it has to survive the checkpoint that block just tried
    # and could not make - which needs a filesystem where one path, and only one,
    # refuses to be written.
    [hashtable] $WriteFailure

    # Path -> the hash GetHash answers with, whatever the content says. THE ONE
    # FILESYSTEM CONDITION NO AMOUNT OF SEEDED CONTENT CAN EXPRESS: a copy that
    # landed corrupt. CopyItem copies content exactly - as the real one does when
    # it works - so "the destination does not hash equal to the source" has to be
    # stated rather than arranged. New-HDTPxePayload verifies every copy by hash
    # because a truncated boot.sdi on a TFTP server is a machine that hangs at
    # boot with no message, and this is what makes that check provable.
    [hashtable] $HashOverride

    # Path -> the four-part version GetVersion answers with. THE SECOND CONDITION
    # SEEDED CONTENT CANNOT EXPRESS: a version resource is metadata a real file
    # carries and a string in a hashtable does not, so a test that needs
    # "agent.exe is there and it is 4.1" has to say so. Unseeded paths answer
    # 0.0.0.0, which is what the real adapter returns for a file with no version
    # resource - so DESIGN 8's file detection rule reads the same shape from both.
    [hashtable] $VersionOverride

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    HDTFakeFileSystem() {
        $this.File = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Directory = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.WriteFailure = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.HashOverride = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.VersionOverride = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'FileSystem'
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        # The shared journal is numbered globally, across every service, so a
        # test can assert one ordered cross-service operation list. The per-fake
        # Operations numbering above stays independent of it.
        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- path handling -----------------------------------------------------

    hidden [string] Normalize([string] $Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw [System.ArgumentException]::new('Path must not be empty.', 'Path')
        }

        $full = [System.IO.Path]::GetFullPath($Path)

        # 'C:\' is three characters and its separator is part of the root.
        if ($full.Length -gt 3) {
            $full = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        }

        return $full
    }

    hidden [void] AddDirectory([string] $NormalizedPath) {
        $current = $NormalizedPath
        while ($current) {
            if (-not $this.Directory.ContainsKey($current)) {
                $this.Directory[$current] = $true
            }
            $current = [System.IO.Path]::GetDirectoryName($current)
        }
    }

    hidden [void] AddFile([string] $NormalizedPath, [string] $Content) {
        $parent = [System.IO.Path]::GetDirectoryName($NormalizedPath)
        if ($parent) {
            $this.AddDirectory($parent)
        }
        $this.File[$NormalizedPath] = $Content
    }

    hidden [string[]] Descendant([string] $NormalizedPath) {
        $prefix = $NormalizedPath + [System.IO.Path]::DirectorySeparatorChar
        $found = [System.Collections.ArrayList]::new()

        foreach ($key in @($this.File.Keys)) {
            if ($key.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void] $found.Add($key)
            }
        }
        foreach ($key in @($this.Directory.Keys)) {
            if ($key.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void] $found.Add($key)
            }
        }

        return [string[]] @($found)
    }

    # -- seeding (never recorded: seeding is not an operation the code under
    #    test performed) ---------------------------------------------------

    [void] SeedFile([string] $Path, [string] $Content) {
        $this.AddFile($this.Normalize($Path), $Content)
    }

    [void] SeedDirectory([string] $Path) {
        $this.AddDirectory($this.Normalize($Path))
    }

    [void] SeedWriteFailure([string] $Path, [string] $Message) {
        $this.WriteFailure[$this.Normalize($Path)] = $Message
    }

    # THE CORRUPT COPY. See $HashOverride above: the path still holds whatever
    # content it holds, so every other method behaves normally and only GetHash
    # disagrees - which is exactly what a truncated or bit-rotted file looks like
    # to code that verifies by hash.
    [void] SeedHash([string] $Path, [string] $Hash) {
        $this.HashOverride[$this.Normalize($Path)] = $Hash
    }

    # THE VERSION RESOURCE. See $VersionOverride above.
    [void] SeedVersion([string] $Path, [string] $Version) {
        $this.VersionOverride[$this.Normalize($Path)] = $Version
    }

    # Checked by WriteAllText and AppendAllText AFTER they record, because the
    # attempt is evidence about what the code under test tried.
    hidden [void] AssertWritable([string] $NormalizedPath) {
        if ($this.WriteFailure.ContainsKey($NormalizedPath)) {
            throw [System.IO.IOException]::new([string] $this.WriteFailure[$NormalizedPath])
        }
    }

    # -- IFileSystem -------------------------------------------------------

    [bool] TestPath([string] $Path) {
        $this.Record('TestPath', @($Path))
        $full = $this.Normalize($Path)
        return ($this.File.ContainsKey($full) -or $this.Directory.ContainsKey($full))
    }

    [string] ReadAllText([string] $Path) {
        $this.Record('ReadAllText', @($Path))
        $full = $this.Normalize($Path)

        if ($this.Directory.ContainsKey($full)) {
            throw [System.UnauthorizedAccessException]::new("Access to the path '$full' is denied: it is a directory.")
        }
        if (-not $this.File.ContainsKey($full)) {
            throw [System.IO.FileNotFoundException]::new("Could not find file '$full'.", $full)
        }

        return $this.File[$full]
    }

    [void] WriteAllText([string] $Path, [string] $Content) {
        $this.Record('WriteAllText', @($Path, $Content))
        $full = $this.Normalize($Path)

        if ($this.Directory.ContainsKey($full)) {
            throw [System.UnauthorizedAccessException]::new("Access to the path '$full' is denied: it is a directory.")
        }

        $this.AssertWritable($full)

        $this.AddFile($full, $Content)
    }

    [void] AppendAllText([string] $Path, [string] $Content) {
        $this.Record('AppendAllText', @($Path, $Content))
        $full = $this.Normalize($Path)

        if ($this.Directory.ContainsKey($full)) {
            throw [System.UnauthorizedAccessException]::new("Access to the path '$full' is denied: it is a directory.")
        }

        $this.AssertWritable($full)

        # [System.IO.File]::AppendAllText creates a missing file, so this does
        # too; AddFile creates the parent directories the real call would need
        # created first.
        $existing = ''
        if ($this.File.ContainsKey($full)) {
            $existing = [string] $this.File[$full]
        }

        $this.AddFile($full, ($existing + $Content))
    }

    [void] CreateDirectory([string] $Path) {
        $this.Record('CreateDirectory', @($Path))
        $this.AddDirectory($this.Normalize($Path))
    }

    [void] RemoveItem([string] $Path, [bool] $Recurse) {
        $this.Record('RemoveItem', @($Path, $Recurse))
        $full = $this.Normalize($Path)

        if ($this.File.ContainsKey($full)) {
            $this.File.Remove($full)
            return
        }

        if (-not $this.Directory.ContainsKey($full)) {
            return
        }

        $child = @($this.Descendant($full))
        if (($child.Count -gt 0) -and (-not $Recurse)) {
            throw [System.IO.IOException]::new("The directory '$full' is not empty.")
        }

        foreach ($item in $child) {
            $this.File.Remove($item)
            $this.Directory.Remove($item)
        }
        $this.Directory.Remove($full)
    }

    [void] CopyItem([string] $Source, [string] $Destination) {
        $this.Record('CopyItem', @($Source, $Destination))
        $sourcePath = $this.Normalize($Source)
        $destinationPath = $this.Normalize($Destination)

        if (-not $this.File.ContainsKey($sourcePath)) {
            throw [System.IO.FileNotFoundException]::new("Could not find file '$sourcePath'.", $sourcePath)
        }

        # A COPY IS A WRITE, so a destination seeded to fail fails here too - as
        # Copy-Item onto a full disk does. DESIGN 4.4.1's log relocation mirrors
        # a whole tree with CopyItem and is required never to throw; without this
        # that failure path could not be staged at all.
        $this.AssertWritable($destinationPath)

        $this.AddFile($destinationPath, $this.File[$sourcePath])
    }

    [string[]] GetChildItem([string] $Path) {
        $this.Record('GetChildItem', @($Path))
        $full = $this.Normalize($Path)

        if (-not $this.Directory.ContainsKey($full)) {
            throw [System.IO.DirectoryNotFoundException]::new("Could not find a part of the path '$full'.")
        }

        $child = [System.Collections.ArrayList]::new()
        foreach ($item in @($this.Descendant($full))) {
            if ([System.IO.Path]::GetDirectoryName($item) -eq $full) {
                [void] $child.Add($item)
            }
        }

        $result = [string[]] @($child)
        [array]::Sort($result, [System.StringComparer]::Ordinal)
        return $result
    }

    [long] GetLength([string] $Path) {
        $this.Record('GetLength', @($Path))
        $full = $this.Normalize($Path)

        if (-not $this.File.ContainsKey($full)) {
            throw [System.IO.FileNotFoundException]::new("Could not find file '$full'.", $full)
        }

        return [long] ([System.Text.Encoding]::UTF8.GetByteCount([string] $this.File[$full]))
    }

    # SHA256 OVER THE SAME BYTES THE REAL ADAPTER WOULD HASH. The real one runs
    # Get-FileHash over the file; this one hashes the UTF-8 bytes of the content
    # it holds, which are the bytes New-HDTFileSystem would have written for the
    # same WriteAllText. So the two implementations return the SAME NUMBER for
    # the same content, not merely the same shape - and DESIGN 6.1.1's "the WIM
    # inside the ISO hashes identical to the standalone WIM" is provable against
    # the fake, where a copy is a copy.
    [string] GetHash([string] $Path) {
        $this.Record('GetHash', @($Path))
        $full = $this.Normalize($Path)

        if (-not $this.File.ContainsKey($full)) {
            throw [System.IO.FileNotFoundException]::new("Could not find file '$full'.", $full)
        }

        # Checked AFTER the existence check: a hash override describes a file
        # that is there and wrong, not one that is absent.
        if ($this.HashOverride.ContainsKey($full)) {
            return [string] $this.HashOverride[$full]
        }

        # Declared before the try: a PowerShell class method refuses to compile a
        # variable it cannot see assigned on every path ("Variable is not
        # assigned in the method"), and an assignment inside a try is not one.
        [byte[]] $byte = @()

        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $byte = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string] $this.File[$full]))
        } finally {
            $sha.Dispose()
        }

        return [System.BitConverter]::ToString($byte).Replace('-', '')
    }

    # THE FOUR-PART VERSION THE REAL ADAPTER WOULD READ. A seeded content string
    # carries no version resource, so an unseeded file answers 0.0.0.0 - exactly
    # what [System.Diagnostics.FileVersionInfo] reports for a file that has none.
    # Both implementations therefore return something a caller can cast to
    # [version] without a special case for "no version".
    [string] GetVersion([string] $Path) {
        $this.Record('GetVersion', @($Path))
        $full = $this.Normalize($Path)

        if (-not $this.File.ContainsKey($full)) {
            throw [System.IO.FileNotFoundException]::new("Could not find file '$full'.", $full)
        }

        # Checked AFTER the existence check: a version override describes a file
        # that is there, not one that is absent.
        if ($this.VersionOverride.ContainsKey($full)) {
            return [string] $this.VersionOverride[$full]
        }

        return '0.0.0.0'
    }
}

function New-HDTFakeFileSystem {
    <#
        .SYNOPSIS
            Creates an in-memory IFileSystem that records every operation performed
            against it.

        .DESCRIPTION
            The hand-written double behind every filesystem-dependent test
            (DESIGN 12.2.1: engine logic receives injected services so it can run
            with no machine attached; DESIGN 12.2.3: fake, don't mock).

            It implements the eleven IFileSystem methods - TestPath, ReadAllText,
            WriteAllText, AppendAllText, CreateDirectory, RemoveItem, CopyItem,
            GetChildItem, GetLength, GetHash, GetVersion - and throws the same
            exception types the real
            adapter throws, so tests assert on the type rather than on a message.

            AppendAllText creates a missing file and the parent directories of a
            missing one, matching [System.IO.File]::AppendAllText, which creates
            the file but throws when the directory is absent.

            Paths are normalised with [System.IO.Path]::GetFullPath, stripped of a
            trailing separator and compared case-insensitively, matching Windows
            semantics. Nothing in this fake ever reaches the real filesystem.

            Every call appends a record to $Operations - Sequence (1-based),
            Operation (the method name), Arguments - including the read-only calls,
            because provenance and query-order assertions need them. Seeding
            performed by this factory is deliberately not recorded.

        .PARAMETER File
            Seed files. Keys are paths, values are the file content. The parent
            directories of every seeded file are created implicitly.

        .PARAMETER Directory
            Seed directories, including their intermediate parents.

        .PARAMETER WriteFailure
            Paths that refuse to be written. Keys are paths, values are the
            message the System.IO.IOException carries. Every other path stays
            writable, which is what makes "the checkpoint failed and the teardown
            still ran" provable. A path seeded here refuses WriteAllText,
            AppendAllText and a CopyItem that names it as the DESTINATION - a
            copy is a write, and DESIGN 4.4.1's log mirror is made of copies.

        .PARAMETER Hash
            Paths whose GetHash answers with a stated value rather than with the
            hash of their content. THE CORRUPT COPY, which no amount of seeded
            content can express: CopyItem copies exactly, so a destination that
            does not hash equal to its source has to be declared. It is what
            makes New-HDTPxePayload's "fails rather than warns on a hash
            mismatch" provable - and a truncated boot.sdi on a TFTP server is a
            machine that hangs at boot with no message.

        .PARAMETER Version
            Paths whose GetVersion answers with a stated four-part version. A
            seeded content string carries no version resource, so this is how a
            test says "agent.exe is installed and it is 4.1" - which is what
            DESIGN 8's file detection rule compares against. Unseeded files
            answer 0.0.0.0, exactly as the real adapter does for a file with no
            version resource.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeFileSystem. Never write the class name as a type literal in a
            test: it binds to whichever dynamic assembly loaded first and breaks
            across a module reload. Use this factory.

        .EXAMPLE
            $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\rules.yaml' = 'schemaVersion: 1' }
            $fs.ReadAllText('C:\ws\rules.yaml')

            Seeds a workspace file and reads it back without touching the disk.

        .EXAMPLE
            $fs = New-HDTFakeFileSystem
            Invoke-SomethingUnderTest -FileSystem $fs
            $fs.GetOperationName() | Should -Be @('CreateDirectory', 'WriteAllText')

            The DESIGN 12.2.1 assertion shape: the ordered list of operations the
            code under test would have performed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [hashtable] $File,

        [Parameter()]
        [string[]] $Directory,

        [Parameter()]
        [hashtable] $WriteFailure,

        [Parameter()]
        [hashtable] $Hash,

        [Parameter()]
        [hashtable] $Version,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeFileSystem]::new()
    $fake.Journal = $Journal

    if ($PSBoundParameters.ContainsKey('Hash')) {
        foreach ($key in @($Hash.Keys)) {
            $fake.SeedHash([string] $key, [string] $Hash[$key])
        }
    }

    if ($PSBoundParameters.ContainsKey('Version')) {
        foreach ($key in @($Version.Keys)) {
            $fake.SeedVersion([string] $key, [string] $Version[$key])
        }
    }

    if ($PSBoundParameters.ContainsKey('WriteFailure')) {
        foreach ($key in @($WriteFailure.Keys)) {
            $fake.SeedWriteFailure([string] $key, [string] $WriteFailure[$key])
        }
    }

    if ($PSBoundParameters.ContainsKey('Directory')) {
        foreach ($item in @($Directory)) {
            $fake.SeedDirectory($item)
        }
    }

    if ($PSBoundParameters.ContainsKey('File')) {
        foreach ($key in @($File.Keys)) {
            $fake.SeedFile([string] $key, [string] $File[$key])
        }
    }

    return $fake
}

class HDTFakeCimProvider {

    # "namespace|class", lower case, separators normalised -> object[] of instances.
    [hashtable] $Instance

    # Method name -> the ReturnValue InvokeMethod should answer with. Absent
    # means 0, which is what a machine that did what it was told returns.
    [hashtable] $MethodReturnValue

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    HDTFakeCimProvider() {
        $this.Instance = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.MethodReturnValue = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'CimProvider'
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        # The shared journal is numbered globally, across every service, so a
        # test can assert one ordered cross-service operation list. The per-fake
        # Operations numbering above stays independent of it.
        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- key handling ------------------------------------------------------

    hidden [string] NormalizeNamespace([string] $Namespace) {
        if ([string]::IsNullOrWhiteSpace($Namespace)) {
            throw [System.ArgumentException]::new('Namespace must not be empty.', 'Namespace')
        }

        # root\cimv2 and root/cimv2 name the same namespace.
        return $Namespace.Replace('\', '/').Trim('/').ToLowerInvariant()
    }

    hidden [string] Key([string] $Namespace, [string] $ClassName) {
        if ([string]::IsNullOrWhiteSpace($ClassName)) {
            throw [System.ArgumentException]::new('ClassName must not be empty.', 'ClassName')
        }

        return ('{0}|{1}' -f $this.NormalizeNamespace($Namespace), $ClassName.ToLowerInvariant())
    }

    # -- ICimProvider ------------------------------------------------------

    [object[]] GetInstance([string] $ClassName) {
        return $this.GetInstance('root/cimv2', $ClassName)
    }

    [object[]] GetInstance([string] $Namespace, [string] $ClassName) {
        $this.Record('GetInstance', @($Namespace, $ClassName))
        $key = $this.Key($Namespace, $ClassName)

        if (-not $this.Instance.ContainsKey($key)) {
            # Get-CimInstance names the invalid class; a vaguer message would hide
            # a typo in a fact gatherer. A class seeded with an empty array is a
            # different fact - "class exists, no instances" - and returns @().
            throw [System.ArgumentException]::new(
                "Invalid class '$ClassName' in namespace '$Namespace': it was never seeded on this fake.")
        }

        return [object[]] @($this.Instance[$key])
    }

    [void] AddInstance([string] $Namespace, [string] $ClassName, [object[]] $Instance) {
        $this.Instance[$this.Key($Namespace, $ClassName)] = [object[]] @($Instance)
    }

    # -- ICimProvider: invoking a method on an instance --------------------
    #
    # WMI IS HOW WinPE CONFIGURES A NETWORK. SPIKES S14: NetTCPIP is not in an
    # ADK image, so Win32_NetworkAdapterConfiguration's EnableStatic,
    # SetGateways and SetDNSServerSearchOrder are the only route to a static
    # address on the one machine that matters. Reading CIM was never enough.
    #
    # The operation is recorded AS 'InvokeMethod(EnableStatic)' rather than a
    # bare 'InvokeMethod', because the ordered operation list is the assertion
    # these tests are built on and "three method calls happened" is not a fact
    # about which three or in what order.

    [int] InvokeMethod([object] $Instance, [string] $MethodName, [hashtable] $Argument) {
        if ([string]::IsNullOrWhiteSpace($MethodName)) {
            throw [System.ArgumentException]::new('MethodName must not be empty.', 'MethodName')
        }

        $this.Record(('InvokeMethod({0})' -f $MethodName), @($MethodName, $this.Flatten($Argument), $Argument))

        if ($this.MethodReturnValue.ContainsKey($MethodName)) {
            return [int] $this.MethodReturnValue[$MethodName]
        }

        return 0
    }

    # Fake-only: make a method answer the way a refusing machine would. 0 is
    # success and 1 is "success, reboot required"; everything else is a WMI
    # error code, and a wizard has to say so rather than report a network it
    # did not configure.
    [void] SetMethodReturnValue([string] $MethodName, [int] $ReturnValue) {
        $this.MethodReturnValue[$MethodName] = $ReturnValue
    }

    # Arguments in a stable, readable order, so an assertion on them does not
    # depend on hashtable enumeration order.
    hidden [string] Flatten([hashtable] $Argument) {
        if ($null -eq $Argument) { return '' }

        $part = @()
        foreach ($name in @($Argument.Keys | Sort-Object)) {
            $part += ('{0}={1}' -f $name, (@($Argument[$name]) -join ','))
        }

        return ($part -join ';')
    }
}

function New-HDTFakeCimProvider {
    <#
        .SYNOPSIS
            Creates an ICimProvider seeded from captured fixture data, with no
            machine attached.

        .DESCRIPTION
            The hand-written double behind every fact-gathering test (DESIGN 3.2.1
            gathers Win32_ComputerSystem, Win32_ComputerSystemProduct,
            Win32_BaseBoard, Win32_BIOS and Win32_Tpm; DESIGN 12.2.1 requires that
            to be testable with no machine attached).

            It implements GetInstance in both its one-argument form - defaulting to
            root/cimv2 - and its two-argument form, which fact gathering needs for
            root/cimv2/security/microsofttpm. AddInstance is fake-only seeding.

            A class that was never seeded throws, naming the class, the way
            Get-CimInstance does for an invalid class. A class seeded with an empty
            array returns an empty array: "the class exists but this machine has no
            instances" is a different fact and a fact gatherer must tell them apart.

            Namespaces are compared case-insensitively with separators normalised,
            so root\cimv2 and root/cimv2 are the same namespace.

            Every query appends a record to $Operations - Sequence (1-based),
            Operation, Arguments as (namespace, class) - including a query that went
            on to throw, because query order is evidence about what the code under
            test tried. Seeding is deliberately not recorded.

        .PARAMETER Instance
            Seed instances. Keys are class names in -Namespace, values are the
            instance arrays.

        .PARAMETER Namespace
            The namespace -Instance seeds into. Defaults to root/cimv2.

        .PARAMETER FixturePath
            A directory of captured *.json files. Each file seeds root/cimv2 under
            its own base name, so tests/fixtures/cim/Win32_BIOS.json becomes
            Win32_BIOS. Subdirectories are ignored - a second namespace is a
            second directory named by -NamespaceFixturePath, not a nested folder.
            See tests/fixtures/README.md for the capture and sanitisation rules.

        .PARAMETER NamespaceFixturePath
            Additional fixture directories, keyed by the namespace they seed.
            Each directory is loaded exactly as -FixturePath is, but into that
            namespace, so tests/fixtures/cim-microsofttpm/Win32_Tpm.json becomes
            Win32_Tpm in root/cimv2/security/microsofttpm. A missing directory
            throws, naming it.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeCimProvider. Never write the class name as a type literal in a
            test: it binds to whichever dynamic assembly loaded first and breaks
            across a module reload. Use this factory.

        .EXAMPLE
            $cim = New-HDTFakeCimProvider -FixturePath ./tests/fixtures/cim
            $cim.GetInstance('Win32_BIOS')[0].SerialNumber

            Reads real-shaped, sanitised BIOS data without touching WMI.

        .EXAMPLE
            $cim = New-HDTFakeCimProvider
            $cim.AddInstance('root/cimv2/security/microsofttpm', 'Win32_Tpm', @([pscustomobject] @{ IsEnabled_InitialValue = $true }))

            Seeds the TPM namespace DESIGN 3.2.1 gathers from.

        .EXAMPLE
            $cim = New-HDTFakeCimProvider -FixturePath ./tests/fixtures/cim `
                -NamespaceFixturePath @{ 'root/cimv2/security/microsofttpm' = './tests/fixtures/cim-microsofttpm' }
            $cim.GetInstance('root/cimv2/security/microsofttpm', 'Win32_Tpm')[0].SpecVersion

            Seeds both namespaces Get-HDTMachineFact queries, from captured
            fixtures, with no machine attached.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [hashtable] $Instance,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Namespace = 'root/cimv2',

        [Parameter()]
        [string] $FixturePath,

        [Parameter()]
        [hashtable] $NamespaceFixturePath,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    # One directory -> one namespace. Both -FixturePath and -NamespaceFixturePath
    # go through this, so a namespace fixture and a root/cimv2 fixture can never
    # drift apart in how they are loaded.
    $loadFixtureDirectory = {
        param($Fake, [string] $Directory, [string] $IntoNamespace)

        if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
            throw "FixturePath '$Directory' does not exist or is not a directory."
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File)) {
            $text = Get-Content -LiteralPath $file.FullName -Raw

            # Never -AsHashtable: it is PowerShell 6+ only and banned outright.
            $content = ConvertFrom-Json -InputObject $text

            $Fake.AddInstance($IntoNamespace, $file.BaseName, [object[]] @($content))
        }
    }

    $fake = [HDTFakeCimProvider]::new()
    $fake.Journal = $Journal

    if ($PSBoundParameters.ContainsKey('FixturePath')) {
        & $loadFixtureDirectory $fake $FixturePath 'root/cimv2'
    }

    if ($PSBoundParameters.ContainsKey('NamespaceFixturePath')) {
        foreach ($key in @($NamespaceFixturePath.Keys)) {
            & $loadFixtureDirectory $fake ([string] $NamespaceFixturePath[$key]) ([string] $key)
        }
    }

    if ($PSBoundParameters.ContainsKey('Instance')) {
        foreach ($key in @($Instance.Keys)) {
            $fake.AddInstance($Namespace, [string] $key, [object[]] @($Instance[$key]))
        }
    }

    return $fake
}

class HDTFakeRegistryService {

    # Normalised key path -> hashtable of value name -> value. Both levels are
    # case-insensitive, matching registry semantics.
    [hashtable] $Key

    # The same shape again, holding the New-ItemProperty -PropertyType name each
    # value was written with. Kept beside the values rather than boxed with them
    # so GetValue stays exactly what it was before the write half arrived.
    [hashtable] $ValueTypeName

    # The registry's value types, as New-ItemProperty -PropertyType names.
    [string[]] $KnownValueType

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    HDTFakeRegistryService() {
        $this.Key = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.ValueTypeName = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'RegistryService'
        $this.KnownValueType = @('String', 'ExpandString', 'DWord', 'QWord', 'Binary', 'MultiString')
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        # The shared journal is numbered globally, across every service, so a
        # test can assert one ordered cross-service operation list. The per-fake
        # Operations numbering above stays independent of it.
        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- path handling -----------------------------------------------------

    hidden [string] Normalize([string] $Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw [System.ArgumentException]::new('Path must not be empty.', 'Path')
        }

        # HKEY_LOCAL_MACHINE\... and HKLM:\... name the same key. So do the other
        # long-form hive names a rules file or a runbook might use.
        $normalized = $Path
        $normalized = $normalized -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM:\'
        $normalized = $normalized -replace '^HKEY_CURRENT_USER\\', 'HKCU:\'
        $normalized = $normalized -replace '^HKEY_CLASSES_ROOT\\', 'HKCR:\'
        $normalized = $normalized -replace '^HKEY_USERS\\', 'HKU:\'

        return $normalized.TrimEnd('\')
    }

    # -- seeding (never recorded) ------------------------------------------

    [void] SeedValue([string] $Path, [string] $Name, [object] $Value) {
        $full = $this.Normalize($Path)

        if (-not $this.Key.ContainsKey($full)) {
            $this.Key[$full] = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        }

        $this.Key[$full][$Name] = $Value
    }

    [void] SeedKey([string] $Path) {
        $full = $this.Normalize($Path)

        if (-not $this.Key.ContainsKey($full)) {
            $this.Key[$full] = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
    }

    # -- IRegistryService, read subset -------------------------------------

    [bool] TestPath([string] $Path) {
        $this.Record('TestPath', @($Path))
        return $this.Key.ContainsKey($this.Normalize($Path))
    }

    [object] GetValue([string] $Path, [string] $Name) {
        $this.Record('GetValue', @($Path, $Name))
        $full = $this.Normalize($Path)

        # Absence is normal, not exceptional: a BIOS machine has no
        # SecureBoot\State key at all, and a fact gatherer that had to catch
        # would swallow real errors too.
        if (-not $this.Key.ContainsKey($full)) {
            return $null
        }
        if (-not $this.Key[$full].ContainsKey($Name)) {
            return $null
        }

        return $this.Key[$full][$Name]
    }

    # -- IRegistryService, write half (03-03, DESIGN 4.5) ------------------
    #
    # All four record. Removing something that is not there is deliberately not
    # an error: DESIGN 4.5.3's teardown runs on machines in unknown states, and a
    # teardown that throws on the first absent value is one that does not finish.

    [void] NewKey([string] $Path) {
        $this.Record('NewKey', @($Path))
        $this.SeedKey($Path)
    }

    [void] SetValue([string] $Path, [string] $Name, [object] $Value, [string] $Type) {
        # Recorded before it can throw: query order is evidence about what the
        # code under test tried, not only about what succeeded.
        $this.Record('SetValue', @($Path, $Name, $Value, $Type))

        if ($this.KnownValueType -notcontains $Type) {
            throw [System.ArgumentException]::new(
                ("'{0}' is not a registry value type. Expected one of: {1}." -f $Type, ($this.KnownValueType -join ', ')),
                'Type')
        }

        # New-ItemProperty fails on a key that does not exist, so the real
        # adapter creates it first and this must not be more forgiving.
        $this.SeedKey($Path)
        $this.SeedValue($Path, $Name, $Value)

        $full = $this.Normalize($Path)
        if (-not $this.ValueTypeName.ContainsKey($full)) {
            $this.ValueTypeName[$full] = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        $this.ValueTypeName[$full][$Name] = $Type
    }

    [void] RemoveValue([string] $Path, [string] $Name) {
        $this.Record('RemoveValue', @($Path, $Name))
        $full = $this.Normalize($Path)

        if ($this.Key.ContainsKey($full)) {
            $this.Key[$full].Remove($Name)
        }
        if ($this.ValueTypeName.ContainsKey($full)) {
            $this.ValueTypeName[$full].Remove($Name)
        }
    }

    [void] RemoveKey([string] $Path, [bool] $Recurse) {
        $this.Record('RemoveKey', @($Path, $Recurse))
        $full = $this.Normalize($Path)

        $prefix = $full + '\'
        $child = @($this.Key.Keys | Where-Object { $_.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) })

        if ($child.Count -gt 0 -and -not $Recurse) {
            throw [System.InvalidOperationException]::new(
                ("The registry key '{0}' has {1} child key(s) and Recurse was not requested." -f $Path, $child.Count))
        }

        foreach ($key in $child) {
            $this.Key.Remove($key)
            $this.ValueTypeName.Remove($key)
        }

        $this.Key.Remove($full)
        $this.ValueTypeName.Remove($full)
    }

    # -- inspection, for assertions only (never recorded) ------------------

    # Not part of IRegistryService: it exists so a test can prove
    # AutoLogonCount was written as a DWord rather than as the string '3',
    # which Winlogon would ignore. Returns $null when the value is not there.
    [string] GetValueType([string] $Path, [string] $Name) {
        $full = $this.Normalize($Path)

        if (-not $this.ValueTypeName.ContainsKey($full)) {
            return $null
        }
        if (-not $this.ValueTypeName[$full].ContainsKey($Name)) {
            return $null
        }

        return $this.ValueTypeName[$full][$Name]
    }
}

function New-HDTFakeRegistryService {
    <#
        .SYNOPSIS
            Creates an in-memory IRegistryService that records every read
            performed against it.

        .DESCRIPTION
            The hand-written double behind every registry-dependent test
            (DESIGN 12.2.1: engine logic receives injected services; DESIGN
            12.2.3: fake, don't mock).

            It implements the read subset the fact gatherer needs - TestPath and
            GetValue - which today is the SecureBoot state key of DESIGN 3.2.1.
            Phase 03 extends the same interface with the write half for the
            autologon lifecycle in DESIGN 4.5.

            GetValue returns $null for a missing key and for a missing value
            name, and never throws: on a BIOS machine
            HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State genuinely
            does not exist, so absence is a fact rather than a failure.

            Paths are compared case-insensitively with a trailing backslash
            trimmed, and HKEY_LOCAL_MACHINE\ is accepted as a synonym for HKLM:\
            (likewise HKCU, HKCR and HKU). Nothing in this fake ever reaches the
            real registry.

            Every call appends a record to $Operations - Sequence (1-based),
            Operation, Arguments - including calls that returned $null, because
            provenance needs the attempt and not only the successes. Seeding,
            whether by this factory or by SeedValue/SeedKey, is deliberately not
            recorded - which is why those two are named Seed* and the recorded
            interface method is SetValue.

        .PARAMETER Value
            Seed keys and values. Keys are registry paths, values are hashtables
            of value name to value. An empty hashtable seeds a key that exists
            and holds nothing, which is a different fact from a key that does not
            exist.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeRegistryService. Never write the class name as a type literal
            in a test: it binds to whichever dynamic assembly loaded first and
            breaks across a module reload. Use this factory.

        .EXAMPLE
            $registry = New-HDTFakeRegistryService -Value @{
                'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' = @{ UEFISecureBootEnabled = 1 }
            }
            $registry.GetValue('HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State', 'UEFISecureBootEnabled')

            Seeds a Secure Boot enabled machine and reads it back without
            touching the real registry.

        .EXAMPLE
            $registry = New-HDTFakeRegistryService
            Get-HDTMachineFact -RegistryService $registry -CimProvider $cim -EnvironmentProvider $environment

            The BIOS machine case: no SecureBoot key at all, and
            HDTSecureBootEnabled resolves to $false instead of throwing.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [hashtable] $Value,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeRegistryService]::new()
    $fake.Journal = $Journal

    if ($PSBoundParameters.ContainsKey('Value')) {
        foreach ($path in @($Value.Keys)) {
            $fake.SeedKey([string] $path)

            $entry = $Value[$path]
            foreach ($name in @($entry.Keys)) {
                $fake.SeedValue([string] $path, [string] $name, $entry[$name])
            }
        }
    }

    return $fake
}

class HDTFakeLsaService {

    # Secret name -> value. Case-insensitive: LSA private data names are.
    [hashtable] $Secret

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null.
    [System.Collections.ArrayList] $Journal

    [string] $ServiceName

    HDTFakeLsaService() {
        $this.Secret = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'LsaService'
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
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

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- seeding (never recorded) ------------------------------------------

    [void] SeedSecret([string] $Name, [string] $Value) {
        $this.Secret[$Name] = $Value
    }

    # -- ILsaService -------------------------------------------------------

    [void] SetSecret([string] $Name, [string] $Value) {
        # The NAME is recorded and the VALUE is not. $Operations is printed
        # verbatim in a Pester failure message, and the one secret HDT holds
        # (DESIGN 4.5.2) does not belong in a test report any more than it
        # belongs in the registry.
        $this.Record('SetSecret', @($Name, '<redacted>'))
        $this.Secret[$Name] = $Value
    }

    [string] GetSecret([string] $Name) {
        $this.Record('GetSecret', @($Name))

        if (-not $this.Secret.ContainsKey($Name)) {
            return $null
        }

        return $this.Secret[$Name]
    }

    [void] RemoveSecret([string] $Name) {
        $this.Record('RemoveSecret', @($Name))

        # Idempotent: DESIGN 4.5.3 teardown runs on machines in unknown states.
        $this.Secret.Remove($Name)
    }
}

function New-HDTFakeLsaService {
    <#
        .SYNOPSIS
            Creates an in-memory ILsaService that records every call and never
            touches real LSA private data.

        .DESCRIPTION
            The double behind every autologon test (DESIGN 4.5.2: the deployment
            password is stored as an LSA secret named DefaultPassword, not as
            registry cleartext).

            Three methods - SetSecret, GetSecret, RemoveSecret. GetSecret returns
            $null for a name that was never set and RemoveSecret is idempotent,
            because DESIGN 4.5.3's teardown runs on machines in unknown states.

            Two properties make it safe to lean on:

            - It never reads or writes the host's real secrets. This machine may
              genuinely carry a DefaultPassword LSA secret - SPIKES.md S7's test
              machine did - and a fake that fell through to it would make every
              test above it a lie.
            - SetSecret records the secret NAME and the literal '<redacted>' in
              place of the value. $Operations is printed verbatim when an
              assertion fails.

        .PARAMETER Secret
            Seed secrets. Keys are secret names, values are the secret strings.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeLsaService. Never write the class name as a type literal in a
            test - use this factory.

        .EXAMPLE
            $lsa = New-HDTFakeLsaService -Secret @{ DefaultPassword = 'Sw0rdfish!' }
            $lsa.GetSecret('DefaultPassword')

            The armed machine, without arming anything.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [hashtable] $Secret,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeLsaService]::new()
    $fake.Journal = $Journal

    if ($PSBoundParameters.ContainsKey('Secret')) {
        foreach ($name in @($Secret.Keys)) {
            $fake.SeedSecret([string] $name, [string] $Secret[$name])
        }
    }

    return $fake
}

class HDTFakeRandomNumberGenerator {

    # The byte stream handed out by GetBytes, in order, wrapping when exhausted.
    [byte[]] $Byte

    # How far into $Byte the next call starts.
    [int] $Position

    [System.Collections.ArrayList] $Operations

    [System.Collections.ArrayList] $Journal

    [string] $ServiceName

    HDTFakeRandomNumberGenerator() {
        $this.Byte = [byte[]] @(0)
        $this.Position = 0
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'RandomNumberGenerator'
    }

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
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

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    [void] SeedByte([byte[]] $Value) {
        $this.Byte = $Value
        $this.Position = 0
    }

    # The one method of System.Security.Cryptography.RandomNumberGenerator that
    # New-HDTDeploymentPassword uses. The COUNT is recorded, not the bytes: a
    # test asserts that bytes are drawn one at a time, which is what makes
    # rejection sampling cost exactly one byte per rejection.
    [void] GetBytes([byte[]] $Buffer) {
        $this.Record('GetBytes', @($Buffer.Length))

        for ($index = 0; $index -lt $Buffer.Length; $index++) {
            $Buffer[$index] = $this.Byte[$this.Position % $this.Byte.Length]
            $this.Position++
        }
    }
}

function New-HDTFakeRandomNumberGenerator {
    <#
        .SYNOPSIS
            Creates a deterministic stand-in for
            System.Security.Cryptography.RandomNumberGenerator.

        .DESCRIPTION
            New-HDTDeploymentPassword takes its randomness as a parameter, so the
            mapping from bytes to characters is testable: the same byte stream
            twice must yield the same password, and a byte in the rejection
            window must be discarded rather than folded with a modulo that would
            bias the low end of the alphabet.

            It doubles a .NET type rather than an HDT service, but it follows the
            same conventions as every other fake - a New-HDTFake* factory,
            $Operations, GetOperationName(), -Journal and a ServiceName - so
            there is one shape to copy and no second one.

            GetBytes fills the caller's buffer from -Byte in order, wrapping when
            the stream is exhausted. Seed a stream long enough that it does not
            wrap when the test cares about the exact output.

        .PARAMETER Byte
            The byte stream to hand out. Defaults to a single zero byte.

        .PARAMETER Journal
            The shared cross-service operation journal.

        .OUTPUTS
            HDTFakeRandomNumberGenerator. Use this factory, never the class name
            as a type literal.

        .EXAMPLE
            $rng = New-HDTFakeRandomNumberGenerator -Byte ([byte[]] (0..255))
            New-HDTDeploymentPassword -RandomNumberGenerator $rng
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [byte[]] $Byte,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeRandomNumberGenerator]::new()
    $fake.Journal = $Journal

    if ($PSBoundParameters.ContainsKey('Byte')) {
        $fake.SeedByte($Byte)
    }

    return $fake
}

class HDTFakeEnvironmentProvider {

    # Variable name -> value. Case-insensitive, matching Windows semantics.
    [hashtable] $Variable

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    HDTFakeEnvironmentProvider() {
        $this.Variable = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'EnvironmentProvider'
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        # The shared journal is numbered globally, across every service, so a
        # test can assert one ordered cross-service operation list. The per-fake
        # Operations numbering above stays independent of it.
        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- seeding (never recorded) ------------------------------------------

    [void] SetVariable([string] $Name, [string] $Value) {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            throw [System.ArgumentException]::new('Name must not be empty.', 'Name')
        }

        $this.Variable[$Name] = $Value
    }

    # -- IEnvironmentProvider ----------------------------------------------

    [string] GetVariable([string] $Name) {
        $this.Record('GetVariable', @($Name))

        if (-not $this.Variable.ContainsKey($Name)) {
            return $null
        }

        return $this.Variable[$Name]
    }
}

function New-HDTFakeEnvironmentProvider {
    <#
        .SYNOPSIS
            Creates an in-memory IEnvironmentProvider that records every lookup
            performed against it.

        .DESCRIPTION
            The hand-written double behind every test that depends on the process
            environment (DESIGN 3.2.1 reads firmware_type and
            PROCESSOR_ARCHITECTURE; PROJECT constraint 4 forbids engine logic
            from touching $env: directly).

            It implements the single method GetVariable, which returns $null for
            a variable that is not set and compares names case-insensitively, the
            way Windows does - DESIGN 3.2.1 reads firmware_type in lower case and
            everything else in upper.

            Seeding it rather than setting real environment variables is what
            lets a BIOS machine, an ARM machine and a machine with neither
            variable set all be proven from one desk with none of them. Nothing
            in this fake ever reads the real environment.

            Every lookup appends a record to $Operations - Sequence (1-based),
            Operation, Arguments. Seeding is deliberately not recorded.

        .PARAMETER Variable
            Seed environment variables. Keys are names, values are values.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeEnvironmentProvider. Never write the class name as a type
            literal in a test: it binds to whichever dynamic assembly loaded
            first and breaks across a module reload. Use this factory.

        .EXAMPLE
            $environment = New-HDTFakeEnvironmentProvider -Variable @{
                firmware_type = 'UEFI'; PROCESSOR_ARCHITECTURE = 'AMD64'
            }
            $environment.GetVariable('FIRMWARE_TYPE')

            A UEFI x64 machine, with no such machine required.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [hashtable] $Variable,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeEnvironmentProvider]::new()
    $fake.Journal = $Journal

    if ($PSBoundParameters.ContainsKey('Variable')) {
        foreach ($name in @($Variable.Keys)) {
            $fake.SetVariable([string] $name, [string] $Variable[$name])
        }
    }

    return $fake
}

class HDTFakeScreen {

    # The usable desktop, excluding the taskbar - what a window has to fit in.
    [int] $Width
    [int] $Height

    # When true, GetWorkArea throws the way a display query can when the session
    # has no desktop at all: a service, a remote session being torn down, or a
    # console started before the shell.
    [bool] $Fail

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    HDTFakeScreen() {
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'Screen'
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
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

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- the interface -----------------------------------------------------

    [pscustomobject] GetWorkArea() {
        $this.Record('GetWorkArea', @())

        if ($this.Fail) {
            throw 'the display configuration could not be read.'
        }

        return [pscustomobject] @{
            Width  = $this.Width
            Height = $this.Height
        }
    }
}

function New-HDTFakeScreen {
    <#
        .SYNOPSIS
            Creates an in-memory IScreen reporting a desktop of a chosen size.

        .DESCRIPTION
            The hand-written double behind every test about a window fitting the
            screen it has to open on. It implements the single method
            GetWorkArea, which answers the usable desktop - the screen minus the
            taskbar - as Width and Height.

            SEEDING A SIZE IS WHAT MAKES THE 1280x800 LAPTOP TESTABLE FROM THE
            2560x1440 DESK, and the other way round. The console's remembered
            size is clamped to this, so a test that could only run on the machine
            with the offending monitor would not be a test.

            A screen reporting zero is a display that answered without answering,
            and -Throw is a display query that failed outright. Both exist because
            neither may stop a window opening.

        .PARAMETER Width
            The usable desktop width.

        .PARAMETER Height
            The usable desktop height.

        .PARAMETER Throw
            Make GetWorkArea throw, as it can in a session with no desktop.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeScreen. Never write the class name as a type literal in a
            test: it binds to whichever dynamic assembly loaded first and breaks
            across a module reload. Use this factory.

        .EXAMPLE
            $screen = New-HDTFakeScreen -Width 1280 -Height 770

            The laptop that produced the defect, on any machine.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [int] $Width,

        [Parameter()]
        [int] $Height,

        [Parameter()]
        [switch] $Throw,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeScreen]::new()
    $fake.Width = $Width
    $fake.Height = $Height
    $fake.Fail = [bool] $Throw
    $fake.Journal = $Journal

    return $fake
}

class HDTFakeProcessService {

    # Normalised command line -> the result Start returns.
    [hashtable] $Result

    # Makes StartInteractive throw the way Process.Start does when the shell is
    # not there. The path a wizard takes when the prompt it just promised the
    # technician does not open is one nobody exercises by accident.
    [bool] $FailInteractive

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    HDTFakeProcessService() {
        $this.Result = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'ProcessService'
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        # The shared journal is numbered globally, across every service, so a
        # test can assert one ordered cross-service operation list.
        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- key handling ------------------------------------------------------

    # The seed key is the command line a technician would read: the file and its
    # arguments joined by one space, with no trailing space when there are none.
    hidden [string] Normalize([string] $FilePath, [string] $Argument) {
        return (('{0} {1}' -f $FilePath, $Argument).Trim())
    }

    # -- seeding (never recorded) ------------------------------------------

    [void] SetResult([string] $CommandLine, [System.Collections.IDictionary] $Value) {
        $this.Result[$CommandLine.Trim()] = $Value
    }

    # -- IProcessService ---------------------------------------------------

    [object] Start([string] $FilePath, [string] $Argument, [string] $WorkingDirectory, [int] $TimeoutMillisecond) {
        $this.Record('Start', @($FilePath, $Argument, $WorkingDirectory, $TimeoutMillisecond))

        $commandLine = $this.Normalize($FilePath, $Argument)

        # A command nobody seeded is a command that does not exist, and
        # Process.Start throws exactly this for a missing executable. Returning
        # exit 0 instead would make a typo in a step look like success.
        if (-not $this.Result.ContainsKey($commandLine)) {
            throw [System.ComponentModel.Win32Exception]::new(
                "The system cannot find the file specified: '$commandLine' was never seeded on this fake.")
        }

        $seed = $this.Result[$commandLine]

        $exitCode = 0
        if ($seed.Contains('ExitCode')) { $exitCode = [int] $seed['ExitCode'] }

        $standardOutput = ''
        if ($seed.Contains('StandardOutput')) { $standardOutput = [string] $seed['StandardOutput'] }

        $standardError = ''
        if ($seed.Contains('StandardError')) { $standardError = [string] $seed['StandardError'] }

        $timedOut = $false
        if ($seed.Contains('TimedOut')) { $timedOut = [bool] $seed['TimedOut'] }

        $durationMs = 0
        if ($seed.Contains('DurationMs')) { $durationMs = [long] $seed['DurationMs'] }

        return [pscustomobject] @{
            ExitCode       = $exitCode
            StandardOutput = $standardOutput
            StandardError  = $standardError
            TimedOut       = $timedOut
            DurationMs     = $durationMs
        }
    }

    # A SEPARATE VERB, AND THE DIFFERENCE IS THE POINT. Start redirects both
    # pipes, hides the window and waits for exit. An interactive prompt has no
    # output to capture, must HAVE a window, and must not block the thread that
    # opened it - so it cannot be Start with different flags.
    #
    # NOTHING IS SEEDED HERE. Start refuses a command line no test seeded
    # because a typo must not look like success; there is no result to seed for
    # a process nobody waits on, so this records and answers.
    [object] StartInteractive([string] $FilePath, [string] $Argument, [string] $WorkingDirectory) {
        $this.Record('StartInteractive', @($FilePath, $Argument, $WorkingDirectory))

        if ($this.FailInteractive) {
            throw [System.ComponentModel.Win32Exception]::new(
                "The system cannot find the file specified: '$FilePath'.")
        }

        return [pscustomobject] @{
            ProcessId = 4242
            FilePath  = $FilePath
        }
    }
}

function New-HDTFakeProcessService {
    <#
        .SYNOPSIS
            Creates an IProcessService that returns seeded results and never
            starts a process.

        .DESCRIPTION
            The double behind every CommandLine step test. It implements the
            single method Start, keyed by the COMMAND LINE - the file and its
            arguments joined by one space - so a test reads the way the
            sequence.yaml it stands for reads.

            A command line that was never seeded throws
            System.ComponentModel.Win32Exception naming it, which is what
            Process.Start throws for a missing executable (the error-parity rule
            in tests/helpers/README.md section 5). A fake that returned exit 0
            for an unseeded command would make a typo in a step look like
            success.

            Every call appends to $Operations - before it can throw - as
            (file, arguments, workingDirectory, timeoutMillisecond). Seeding is
            deliberately not recorded.

        .PARAMETER Result
            Seed results. Keys are command lines; values are hashtables carrying
            any of ExitCode, StandardOutput, StandardError, TimedOut and
            DurationMs. Anything omitted takes its default.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeProcessService. Never write the class name as a type literal
            in a test: it binds to whichever dynamic assembly loaded first and
            breaks across a module reload. Use this factory.

        .EXAMPLE
            $process = New-HDTFakeProcessService -Result @{ 'cmd.exe /c exit 3010' = @{ ExitCode = 3010 } }
            $process.Start('cmd.exe', '/c exit 3010', '', 0)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [hashtable] $Result,

        [Parameter()]
        [switch] $FailInteractive,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeProcessService]::new()
    $fake.Journal = $Journal
    $fake.FailInteractive = [bool] $FailInteractive

    if ($PSBoundParameters.ContainsKey('Result')) {
        foreach ($commandLine in @($Result.Keys)) {
            $fake.SetResult([string] $commandLine, $Result[$commandLine])
        }
    }

    return $fake
}

class HDTFakeFeatureService {

    # Feature name -> InstallState: Installed, Available or Removed. Ordinal
    # case-insensitive, because Install-WindowsFeature matches names that way.
    [hashtable] $Feature

    # Feature name -> the result InstallFeature answers with for a call naming
    # it. THE ONE CONDITION SEEDED STATE CANNOT EXPRESS: an install that reaches
    # the OS and comes back refused - a feature blocked by policy, a source path
    # the servicing stack would not accept. Without it a test can only prove the
    # happy path, and the interesting half of DESIGN 10.2 is the other one.
    [hashtable] $Outcome

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    HDTFakeFeatureService() {
        $this.Feature = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Outcome = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'FeatureService'
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
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

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- seeding -----------------------------------------------------------

    [void] SeedFeature([string] $Name, [string] $InstallState) {
        $this.Feature[$Name] = $InstallState
    }

    [void] SeedOutcome([string] $Name, [hashtable] $Result) {
        $this.Outcome[$Name] = $Result
    }

    # -- IFeatureService ---------------------------------------------------

    # FLAT AND UNFILTERED, for the reason IDiskService's listings are: deciding
    # whether a name is real, whether it is already installed and which ones are
    # left is pure logic that can be tested, rather than an adapter argument that
    # cannot.
    [object[]] GetFeature() {
        $this.Record('GetFeature', @())

        $row = [System.Collections.ArrayList]::new()

        $name = [string[]] @($this.Feature.Keys)
        [array]::Sort($name, [System.StringComparer]::Ordinal)

        foreach ($current in $name) {
            [void] $row.Add([pscustomobject] @{
                    Name         = $current
                    DisplayName  = ('{0} display name' -f $current)
                    InstallState = [string] $this.Feature[$current]
                })
        }

        return [object[]] @($row)
    }

    [object] InstallFeature([string[]] $Name, [bool] $IncludeManagementTools, [string] $Source) {
        $this.Record('InstallFeature', @($Name, $IncludeManagementTools, $Source))

        # A seeded outcome for ANY of the names wins: Install-WindowsFeature takes
        # the whole list in one call and reports one result for it, so one blocked
        # feature is one failed call.
        foreach ($current in @($Name)) {
            if ($this.Outcome.ContainsKey($current)) {
                $seeded = $this.Outcome[$current]

                $success = $true
                if ($seeded.ContainsKey('Success')) { $success = [bool] $seeded['Success'] }

                $restart = $false
                if ($seeded.ContainsKey('RestartNeeded')) { $restart = [bool] $seeded['RestartNeeded'] }

                $exitCode = 0
                if ($seeded.ContainsKey('ExitCode')) { $exitCode = [int] $seeded['ExitCode'] }

                $message = ''
                if ($seeded.ContainsKey('Message')) { $message = [string] $seeded['Message'] }

                return [pscustomobject] @{
                    Success       = $success
                    RestartNeeded = $restart
                    ExitCode      = $exitCode
                    Message       = $message
                    FeatureResult = [string[]] @($Name)
                }
            }
        }

        foreach ($current in @($Name)) {
            $this.Feature[$current] = 'Installed'
        }

        return [pscustomobject] @{
            Success       = $true
            RestartNeeded = $false
            ExitCode      = 0
            Message       = ''
            FeatureResult = [string[]] @($Name)
        }
    }
}

function New-HDTFakeFeatureService {
    <#
        .SYNOPSIS
            Creates an in-memory IFeatureService that records every call.

        .DESCRIPTION
            The hand-written double for DESIGN 10.2's Install-WindowsFeature
            wrapper. It implements the two IFeatureService methods - GetFeature
            and InstallFeature - and it is where every behavioural assertion about
            the interface lives, because the real adapter needs the ServerManager
            module and this repository is developed on a client SKU.

            InstallFeature MUTATES THE SEEDED STATE: a feature it installs reports
            Installed on the next GetFeature. That is what makes "the step does
            not reinstall what is already there" provable across two calls rather
            than only within one.

            Every call appends a record to $Operations - Sequence (1-based),
            Operation, Arguments - including GetFeature, because query-order
            assertions need them.

        .PARAMETER Feature
            Seed features. Keys are feature names, values are the install state:
            Installed, Available or Removed.

        .PARAMETER Outcome
            Seed install results. Keys are feature names, values are hashtables
            with any of Success, RestartNeeded, ExitCode and Message. A call
            naming a seeded feature answers with that result and installs
            nothing - the refusal an install can come back with, which seeded
            state alone cannot express.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeFeatureService. Never write the class name as a type literal in
            a test: it binds to whichever dynamic assembly loaded first and breaks
            across a module reload. Use this factory.

        .EXAMPLE
            $feature = New-HDTFakeFeatureService -Feature @{ 'Web-Server' = 'Available' }
            $feature.InstallFeature([string[]] @('Web-Server'), $true, '')

        .EXAMPLE
            New-HDTFakeFeatureService -Feature @{ 'Web-Server' = 'Available' } -Outcome @{ 'Web-Server' = @{ Success = $false; ExitCode = 1 } }

            An install the OS refuses.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [hashtable] $Feature,

        [Parameter()]
        [hashtable] $Outcome,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeFeatureService]::new()
    $fake.Journal = $Journal

    if ($PSBoundParameters.ContainsKey('Feature')) {
        foreach ($key in @($Feature.Keys)) {
            $fake.SeedFeature([string] $key, [string] $Feature[$key])
        }
    }

    if ($PSBoundParameters.ContainsKey('Outcome')) {
        foreach ($key in @($Outcome.Keys)) {
            $fake.SeedOutcome([string] $key, $Outcome[$key])
        }
    }

    return $fake
}

class HDTFakePowerService {

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    HDTFakePowerService() {
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'PowerService'
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
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

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- IPowerService -----------------------------------------------------

    [void] Restart([int] $DelaySecond) {
        $this.Record('Restart', @($DelaySecond))
    }

    [void] Stop([int] $DelaySecond) {
        $this.Record('Stop', @($DelaySecond))
    }
}

function New-HDTFakePowerService {
    <#
        .SYNOPSIS
            Creates an IPowerService that records a restart and performs none.

        .DESCRIPTION
            The reason the reboot ceremony (DESIGN 4.3, 4.5) can be asserted
            without ending the test run. Restart and Stop record their delay and
            return; there is nothing else to assert, and that is the point.

        .PARAMETER Journal
            The shared cross-service operation journal.

        .OUTPUTS
            HDTFakePowerService. Never write the class name as a type literal in
            a test. Use this factory.

        .EXAMPLE
            $power = New-HDTFakePowerService
            $power.Restart(30)
            $power.GetOperationName()
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state and restarts nothing.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakePowerService]::new()
    $fake.Journal = $Journal

    return $fake
}

class HDTFakeScriptInvoker {

    # Normalised script path -> the object Invoke returns. A path present with a
    # $null value means "the script ran and emitted nothing".
    [hashtable] $Result

    # Normalised script path -> the lines GetTranscript returns after that path
    # is invoked. DESIGN 4.4.4: a script that only writes to Write-Host must
    # still land in the log.
    [hashtable] $Transcript

    # The transcript of the LAST Invoke. @() before the first one, and @() for a
    # path seeded without a transcript - "the script wrote nothing" is a
    # different fact from "no script has run yet" only to the caller, and both
    # render the same.
    [string[]] $LastTranscript

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    HDTFakeScriptInvoker() {
        $this.Result = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Transcript = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.LastTranscript = [string[]] @()
        $this.ServiceName = 'ScriptInvoker'
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        # The shared journal is numbered globally, across every service, so a
        # test can assert one ordered cross-service operation list. The per-fake
        # Operations numbering above stays independent of it.
        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- path handling -----------------------------------------------------

    hidden [string] Normalize([string] $Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw [System.ArgumentException]::new('Path must not be empty.', 'Path')
        }

        # rules.yaml writes 'Scripts\Get-ComputerName.ps1'; a test that seeded the
        # forward-slash form must still match, or every setFrom: test becomes a
        # test of which separator the author happened to type.
        $normalized = $Path.Replace('\', '/')
        while ($normalized.StartsWith('./')) {
            $normalized = $normalized.Substring(2)
        }

        return $normalized
    }

    # -- seeding (never recorded) ------------------------------------------

    [void] SetResult([string] $Path, [object] $Value) {
        $this.Result[$this.Normalize($Path)] = $Value
    }

    # Transcript seed keys are normalised exactly as -Result keys are, so one key
    # serves both hashtables.
    [void] SeedTranscript([string] $Path, [string[]] $Line) {
        $this.Transcript[$this.Normalize($Path)] = [string[]] @($Line)
    }

    # -- IScriptInvoker ----------------------------------------------------

    [object] Invoke([string] $Path, [System.Collections.IDictionary] $Variable) {
        $this.Record('Invoke', @($Path, $Variable))
        $full = $this.Normalize($Path)

        # A path that was never seeded is a script that does not exist, and the
        # real adapter throws exactly this for it.
        if (-not $this.Result.ContainsKey($full)) {
            throw [System.IO.FileNotFoundException]::new("Could not find script '$Path'.", $Path)
        }

        # The transcript belongs to the LAST invoke, so it is replaced rather
        # than appended to - which is what makes it usable as "what did THIS step
        # print".
        $this.LastTranscript = [string[]] @()
        if ($this.Transcript.ContainsKey($full)) {
            $this.LastTranscript = [string[]] @($this.Transcript[$full])
        }

        return $this.Result[$full]
    }

    [string[]] GetTranscript() {
        return $this.LastTranscript
    }
}

function New-HDTFakeScriptInvoker {
    <#
        .SYNOPSIS
            Creates an IScriptInvoker that returns seeded results and never
            executes anything.

        .DESCRIPTION
            The hand-written double behind every test of a setFrom: rule
            (DESIGN 3.3: when a rule needs real logic it calls a script whose
            output object becomes the variable set).

            It implements the single method Invoke, which returns the object
            seeded for that path, throws System.IO.FileNotFoundException naming
            the script for a path that was not seeded - exactly as the real
            adapter does for a script that is not on disk - and returns $null for
            a path seeded with $null, because "the script ran and emitted
            nothing" is a different fact from "no such script".

            Paths are matched case-insensitively with backslashes normalised to
            forward slashes and a leading ./ trimmed, so the
            'Scripts\Get-ComputerName.ps1' a rules file writes matches the
            'Scripts/Get-ComputerName.ps1' a test seeds.

            Every invocation appends a record to $Operations - Sequence
            (1-based), Operation, Arguments as (path, variables) - including one
            that went on to throw, and including the variable dictionary, so a
            test can assert what the engine actually handed the script. Seeding
            is deliberately not recorded.

        .PARAMETER Result
            Seed results. Keys are script paths, values are the object Invoke
            returns for that path. Seed $null for a script that emits nothing.

        .PARAMETER Transcript
            Seed transcripts. Keys are script paths - normalised exactly as
            -Result keys are, so one key serves both - and values are the lines
            GetTranscript returns after that path is invoked. A path seeded
            without one yields an empty transcript.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeScriptInvoker. Never write the class name as a type literal in
            a test: it binds to whichever dynamic assembly loaded first and
            breaks across a module reload. Use this factory.

        .EXAMPLE
            $invoker = New-HDTFakeScriptInvoker -Result @{
                'Scripts/Get-ComputerName.ps1' = [pscustomobject] @{ HDTComputerName = 'PC-FIXTURE-SERIAL-0001' }
            }
            $invoker.Invoke('Scripts\Get-ComputerName.ps1', @{ HDTSerialNumber = 'FIXTURE-SERIAL-0001' })

            A setFrom: rule proven without running a script, and with the
            separator the rules file actually uses.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [hashtable] $Result,

        [Parameter()]
        [hashtable] $Transcript,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeScriptInvoker]::new()
    $fake.Journal = $Journal

    if ($PSBoundParameters.ContainsKey('Result')) {
        foreach ($path in @($Result.Keys)) {
            $fake.SetResult([string] $path, $Result[$path])
        }
    }

    if ($PSBoundParameters.ContainsKey('Transcript')) {
        foreach ($path in @($Transcript.Keys)) {
            $fake.SeedTranscript([string] $path, [string[]] @($Transcript[$path]))
        }
    }

    return $fake
}

class HDTFakeDiskService {

    # Three flat listings, exactly as IDiskService exposes them. No filters and
    # no joins: a partition row carries its DiskNumber and a volume row carries
    # its DriveLetter, so the pure logic in 04-02 does the joining and the real
    # adapter stays a projection of three cmdlets.
    [System.Collections.ArrayList] $Disk
    [System.Collections.ArrayList] $Partition
    [System.Collections.ArrayList] $Volume

    # GPT partition type GUID -> the Type name Get-Partition reports for it.
    # The GUIDs are PSDPartition.ps1's, cross-checked against this machine's own
    # captured tests/fixtures/disk/host-partition.json.
    [hashtable] $GptTypeName

    # Method name -> the message that method throws. A step's failure path is
    # only provable if the service it depends on can be told to fail, and this
    # one cannot be made to fail by accident: ClearDisk leaves the disk RAW, so
    # every later call finds exactly the state it wanted.
    [hashtable] $Failure

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    HDTFakeDiskService() {
        $this.Disk = [System.Collections.ArrayList]::new()
        $this.Partition = [System.Collections.ArrayList]::new()
        $this.Volume = [System.Collections.ArrayList]::new()
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'DiskService'
        $this.Failure = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

        $this.GptTypeName = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.GptTypeName['{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'] = 'System'
        $this.GptTypeName['{e3c9e316-0b5c-4db8-817d-f92df00215ae}'] = 'Reserved'
        $this.GptTypeName['{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'] = 'Basic'
        $this.GptTypeName['{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'] = 'Recovery'
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        # The shared journal is numbered globally, across every service, so a
        # test can assert one ordered cross-service operation list. The per-fake
        # Operations numbering above stays independent of it.
        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- row handling ------------------------------------------------------

    # Reads a property off a seeded row, whether it arrived as a pscustomobject
    # (a fixture, deserialised) or as a hashtable (a test, typed by hand), and
    # falls back to the documented default when it is absent or null.
    hidden [object] Property([object] $Row, [string] $Name, [object] $Default) {
        if ($null -eq $Row) {
            return $Default
        }

        if ($Row -is [System.Collections.IDictionary]) {
            if (-not $Row.Contains($Name)) {
                return $Default
            }
            if ($null -eq $Row[$Name]) {
                return $Default
            }
            return $Row[$Name]
        }

        $member = $Row.PSObject.Properties[$Name]
        if ($null -eq $member) {
            return $Default
        }
        if ($null -eq $member.Value) {
            return $Default
        }

        return $member.Value
    }

    hidden [object] NewDiskRow([object] $Row) {
        return [pscustomobject] @{
            Number            = [int] $this.Property($Row, 'Number', 0)
            FriendlyName      = [string] $this.Property($Row, 'FriendlyName', '')
            SerialNumber      = [string] $this.Property($Row, 'SerialNumber', '')
            SizeBytes         = [long] $this.Property($Row, 'SizeBytes', [long] 0)
            BusType           = [string] $this.Property($Row, 'BusType', '')
            PartitionStyle    = [string] $this.Property($Row, 'PartitionStyle', 'RAW')
            IsBoot            = [bool] $this.Property($Row, 'IsBoot', $false)
            IsSystem          = [bool] $this.Property($Row, 'IsSystem', $false)
            IsReadOnly        = [bool] $this.Property($Row, 'IsReadOnly', $false)
            IsOffline         = [bool] $this.Property($Row, 'IsOffline', $false)
            OperationalStatus = [string] $this.Property($Row, 'OperationalStatus', 'Online')
        }
    }

    hidden [object] NewPartitionRow([object] $Row) {
        return [pscustomobject] @{
            DiskNumber      = [int] $this.Property($Row, 'DiskNumber', 0)
            PartitionNumber = [int] $this.Property($Row, 'PartitionNumber', 0)
            DriveLetter     = [string] $this.Property($Row, 'DriveLetter', '')
            SizeBytes       = [long] $this.Property($Row, 'SizeBytes', [long] 0)
            OffsetBytes     = [long] $this.Property($Row, 'OffsetBytes', [long] 0)
            Type            = [string] $this.Property($Row, 'Type', 'Basic')
            GptType         = [string] $this.Property($Row, 'GptType', '')
            IsActive        = [bool] $this.Property($Row, 'IsActive', $false)
            IsHidden        = [bool] $this.Property($Row, 'IsHidden', $false)
            IsBoot          = [bool] $this.Property($Row, 'IsBoot', $false)
            IsSystem        = [bool] $this.Property($Row, 'IsSystem', $false)
        }
    }

    hidden [object] NewVolumeRow([object] $Row) {
        return [pscustomobject] @{
            DriveLetter        = [string] $this.Property($Row, 'DriveLetter', '')
            FileSystem         = [string] $this.Property($Row, 'FileSystem', '')
            FileSystemLabel    = [string] $this.Property($Row, 'FileSystemLabel', '')
            SizeBytes          = [long] $this.Property($Row, 'SizeBytes', [long] 0)
            SizeRemainingBytes = [long] $this.Property($Row, 'SizeRemainingBytes', [long] 0)
        }
    }

    hidden [string] TypeNameFor([string] $GptType) {
        if ($this.GptTypeName.ContainsKey($GptType)) {
            return [string] $this.GptTypeName[$GptType]
        }

        return 'Basic'
    }

    # DESIGN 9.1: HDT refuses ambiguous targets rather than guessing which disk
    # to wipe. tests/fixtures/disk/ is a CATALOGUE of captured rows rather than a
    # snapshot of one machine - the host disk and the derived Gen2 VM disk are
    # both number 0 - so a fake that silently picked one would be lying about
    # which disk a step just cleared.
    hidden [object] FindDisk([int] $DiskNumber) {
        $match = @($this.Disk | Where-Object { $_.Number -eq $DiskNumber })

        if ($match.Count -eq 0) {
            throw [System.ArgumentOutOfRangeException]::new(
                'DiskNumber', $DiskNumber, "No disk numbered $DiskNumber was seeded on this fake.")
        }
        if ($match.Count -gt 1) {
            throw [System.InvalidOperationException]::new(
                "Disk number $DiskNumber is ambiguous: $($match.Count) seeded disks carry it.")
        }

        return $match[0]
    }

    hidden [object] FindPartition([int] $DiskNumber, [int] $PartitionNumber) {
        $match = @($this.Partition |
                Where-Object { $_.DiskNumber -eq $DiskNumber -and $_.PartitionNumber -eq $PartitionNumber })

        if ($match.Count -eq 0) {
            throw [System.ArgumentOutOfRangeException]::new(
                'PartitionNumber', $PartitionNumber,
                "No partition $PartitionNumber on disk $DiskNumber was seeded on this fake.")
        }

        return $match[0]
    }

    # -- seeding (never recorded: seeding is not an operation the code under
    #    test performed) ---------------------------------------------------

    [void] SeedDisk([object] $Row) {
        [void] $this.Disk.Add($this.NewDiskRow($Row))
    }

    [void] SeedPartition([object] $Row) {
        [void] $this.Partition.Add($this.NewPartitionRow($Row))
    }

    [void] SeedVolume([object] $Row) {
        [void] $this.Volume.Add($this.NewVolumeRow($Row))
    }

    [void] SeedFailure([string] $Operation, [string] $Message) {
        $this.Failure[$Operation] = $Message
    }

    # Checked AFTER the method records, because the attempt is evidence about
    # what the code under test tried. The type matches what the real adapter
    # throws when a Storage cmdlet fails, which is the error-parity rule in
    # tests/helpers/README.md section 5.
    hidden [void] AssertNoFailure([string] $Operation) {
        if ($this.Failure.ContainsKey($Operation)) {
            throw [System.InvalidOperationException]::new([string] $this.Failure[$Operation])
        }
    }

    # -- IDiskService, the read-only three ---------------------------------
    #
    # They record too: query order is evidence about what the code under test
    # tried, and 04-02's disk selection is judged on what it looked at.

    [object[]] GetDisk() {
        $this.Record('GetDisk', @())
        return [object[]] @($this.Disk)
    }

    [object[]] GetPartition() {
        $this.Record('GetPartition', @())
        return [object[]] @($this.Partition)
    }

    [object[]] GetVolume() {
        $this.Record('GetVolume', @())
        return [object[]] @($this.Volume)
    }

    # -- IDiskService, the six that change something -----------------------

    [void] ClearDisk([int] $DiskNumber) {
        $this.Record('ClearDisk', @($DiskNumber))
        $this.AssertNoFailure('ClearDisk')
        $target = $this.FindDisk($DiskNumber)

        # PARITY WITH THE REAL CMDLET, FOUND BY RUNNING IT (04-04). Clear-Disk
        # on a RAW disk reports "The disk has not been initialized." - there is
        # nothing to clear. A brand-new VHDX is RAW, and so is the disk of a
        # machine that has never been deployed, which is the normal case for
        # bare metal. A fake that shrugged at this let DiskPartition pass every
        # unit test while being unable to partition a factory-fresh disk.
        if ($target.PartitionStyle -eq 'RAW') {
            throw [System.InvalidOperationException]::new(
                "Disk $DiskNumber has not been initialized: there is nothing to clear on a RAW disk.")
        }

        $letter = @($this.Partition |
                Where-Object { $_.DiskNumber -eq $DiskNumber -and -not [string]::IsNullOrEmpty($_.DriveLetter) } |
                ForEach-Object { $_.DriveLetter })

        $this.Partition = [System.Collections.ArrayList]::new(
            [object[]] @($this.Partition | Where-Object { $_.DiskNumber -ne $DiskNumber }))
        $this.Volume = [System.Collections.ArrayList]::new(
            [object[]] @($this.Volume | Where-Object { $letter -notcontains $_.DriveLetter }))

        # Clear-Disk -RemoveData -RemoveOEM leaves the disk RAW.
        $target.PartitionStyle = 'RAW'
    }

    [void] InitializeDisk([int] $DiskNumber, [string] $PartitionStyle) {
        $this.Record('InitializeDisk', @($DiskNumber, $PartitionStyle))
        $this.AssertNoFailure('InitializeDisk')
        $target = $this.FindDisk($DiskNumber)

        if ($target.PartitionStyle -ne 'RAW') {
            throw [System.InvalidOperationException]::new(
                "Disk $DiskNumber has already been initialized as $($target.PartitionStyle).")
        }

        $target.PartitionStyle = $PartitionStyle

        # SPIKES.md S6, MODELLED RATHER THAN DOCUMENTED. Initialize-Disk with GPT
        # silently creates a 16 MB Microsoft Reserved partition of its own. HDT
        # never creates one; PSD's PSDPartition.ps1 does, which is how the spike
        # ended up with a duplicate 16 MB partition. Because the fake creates it
        # too, a step that "helpfully" creates an MSR produces a duplicate the
        # tests can see, and the first partition an author creates on a GPT disk
        # is number 2 rather than 1.
        if ($PartitionStyle -eq 'GPT') {
            $this.SeedPartition([pscustomobject] @{
                    DiskNumber      = $DiskNumber
                    PartitionNumber = 1
                    # CAPTURED FROM A REAL Initialize-Disk (04-04), not rounded:
                    # 16759808 bytes at offset 17408, which together are exactly
                    # the 16777216 the layouts carry as ReservedSizeByte.
                    SizeBytes       = [long] 16759808
                    OffsetBytes     = [long] 17408
                    Type            = 'Reserved'
                    GptType         = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
                    IsHidden        = $true
                })
        }
    }

    [object] NewPartition([int] $DiskNumber, [long] $SizeByte, [bool] $UseMaximumSize, [string] $GptType, [bool] $IsActive) {
        $this.Record('NewPartition', @($DiskNumber, $SizeByte, $UseMaximumSize, $GptType, $IsActive))
        $this.AssertNoFailure('NewPartition')
        $target = $this.FindDisk($DiskNumber)

        # New-Partition fails on a disk that was never initialised. A fake that
        # allowed it would let a step that forgot InitializeDisk pass here and
        # fail on metal.
        if ($target.PartitionStyle -eq 'RAW') {
            throw [System.InvalidOperationException]::new(
                "Disk $DiskNumber is RAW: initialise it before creating a partition on it.")
        }

        $existing = @($this.Partition | Where-Object { $_.DiskNumber -eq $DiskNumber })

        $number = 1
        $offset = [long] 1048576
        foreach ($row in $existing) {
            if ($row.PartitionNumber -ge $number) {
                $number = $row.PartitionNumber + 1
            }
            if (($row.OffsetBytes + $row.SizeBytes) -gt $offset) {
                $offset = [long] ($row.OffsetBytes + $row.SizeBytes)
            }
        }

        $size = $SizeByte
        if ($UseMaximumSize) {
            $size = [long] ($target.SizeBytes - $offset)
        }

        $typeName = $this.TypeNameFor($GptType)
        $created = $this.NewPartitionRow([pscustomobject] @{
                DiskNumber      = $DiskNumber
                PartitionNumber = $number
                SizeBytes       = $size
                OffsetBytes     = $offset
                Type            = $typeName
                GptType         = $GptType
                IsActive        = $IsActive
                IsHidden        = ($typeName -ne 'Basic')
            })

        [void] $this.Partition.Add($created)

        return $created
    }

    [void] SetPartitionDriveLetter([int] $DiskNumber, [int] $PartitionNumber, [string] $DriveLetter) {
        $this.Record('SetPartitionDriveLetter', @($DiskNumber, $PartitionNumber, $DriveLetter))
        $this.AssertNoFailure('SetPartitionDriveLetter')
        $target = $this.FindPartition($DiskNumber, $PartitionNumber)

        $previous = [string] $target.DriveLetter
        $target.DriveLetter = $DriveLetter

        # An empty letter means "remove the access path", and a volume with no
        # access path is not one GetVolume reports.
        if ([string]::IsNullOrEmpty($DriveLetter)) {
            $this.Volume = [System.Collections.ArrayList]::new(
                [object[]] @($this.Volume | Where-Object { $_.DriveLetter -ne $previous }))
            return
        }

        foreach ($item in @($this.Volume | Where-Object { $_.DriveLetter -eq $previous })) {
            $item.DriveLetter = $DriveLetter
        }
    }

    [void] SetPartitionType([int] $DiskNumber, [int] $PartitionNumber, [string] $GptType) {
        $this.Record('SetPartitionType', @($DiskNumber, $PartitionNumber, $GptType))
        $this.AssertNoFailure('SetPartitionType')
        $target = $this.FindPartition($DiskNumber, $PartitionNumber)

        $typeName = $this.TypeNameFor($GptType)
        $target.GptType = $GptType
        $target.Type = $typeName
        $target.IsHidden = ($typeName -ne 'Basic')
    }

    [void] FormatVolume([string] $DriveLetter, [string] $FileSystem, [string] $Label) {
        $this.Record('FormatVolume', @($DriveLetter, $FileSystem, $Label))
        $this.AssertNoFailure('FormatVolume')

        $target = @($this.Partition | Where-Object { $_.DriveLetter -eq $DriveLetter })
        if ($target.Count -eq 0) {
            throw [System.ArgumentException]::new(
                "No partition holds drive letter '$DriveLetter' on this fake.", 'DriveLetter')
        }

        $existing = @($this.Volume | Where-Object { $_.DriveLetter -eq $DriveLetter })
        if ($existing.Count -gt 0) {
            foreach ($item in $existing) {
                $item.FileSystem = $FileSystem
                $item.FileSystemLabel = $Label
                $item.SizeBytes = [long] $target[0].SizeBytes
                $item.SizeRemainingBytes = [long] $target[0].SizeBytes
            }
            return
        }

        $this.SeedVolume([pscustomobject] @{
                DriveLetter        = $DriveLetter
                FileSystem         = $FileSystem
                FileSystemLabel    = $Label
                SizeBytes          = [long] $target[0].SizeBytes
                SizeRemainingBytes = [long] $target[0].SizeBytes
            })
    }
}

function New-HDTFakeDiskService {
    <#
        .SYNOPSIS
            Creates an in-memory IDiskService that records every operation and
            never touches a physical disk.

        .DESCRIPTION
            The hand-written double behind every disk test (DESIGN 12.2.1:
            engine logic receives injected services so it can run with no
            machine attached; DESIGN 12.2.3: fake, don't mock). It is what makes
            04-02's DiskPartition step provable on a developer machine whose
            only disk is the one it booted from.

            Nine methods. GetDisk, GetPartition and GetVolume are three FLAT
            listings - no filters, no joins - so the joining is done by the pure
            logic that can be tested, not by an adapter that cannot.

            TWO BEHAVIOURS ARE MODELLED RATHER THAN DOCUMENTED, both from
            SPIKES.md S6:

            - InitializeDisk with GPT creates a 16 MB Reserved partition of its
              own, because Initialize-Disk does. HDT must never create a second
              one; PSD's PSDPartition.ps1 does, which is how the spike ended up
              with a duplicate. A consequence a test must expect: the first
              partition an author creates on a GPT disk is number 2.
            - NewPartition refuses a disk that is still RAW, as New-Partition
              does, so a step that forgot InitializeDisk cannot pass here and
              fail on metal.

            A disk number that was never seeded throws
            ArgumentOutOfRangeException; a disk number carried by two seeded
            rows throws InvalidOperationException naming the ambiguity, because
            DESIGN 9.1's whole point is that HDT refuses ambiguous targets
            rather than guessing which disk to wipe.

            Every call appends to $Operations - Sequence (1-based), Operation,
            Arguments - including the read-only three, and including a call that
            went on to throw. Seeding is deliberately not recorded, which is why
            the seeding methods are named Seed*.

        .PARAMETER Disk
            Seed disk rows: Number, FriendlyName, SerialNumber, SizeBytes,
            BusType, PartitionStyle, IsBoot, IsSystem, IsReadOnly, IsOffline,
            OperationalStatus. Anything omitted takes its documented default,
            and PartitionStyle defaults to RAW.

        .PARAMETER Partition
            Seed partition rows: DiskNumber, PartitionNumber, DriveLetter,
            SizeBytes, OffsetBytes, Type, GptType, IsActive, IsHidden, IsBoot,
            IsSystem.

        .PARAMETER Volume
            Seed volume rows: DriveLetter, FileSystem, FileSystemLabel,
            SizeBytes, SizeRemainingBytes.

        .PARAMETER FixturePath
            A directory of captured *.json files, or one such file. THE BASE
            NAME'S SUFFIX CHOOSES THE LISTING: *-disk.json seeds disks,
            *-partition.json partitions and *-volume.json volumes. See
            tests/fixtures/README.md for the capture and sanitisation rules.

        .PARAMETER Failure
            Methods that fail. Keys are method names, values are the message the
            System.InvalidOperationException carries - the type the real adapter
            throws when a Storage cmdlet fails. Nothing else can make this fake
            fail on a well-formed sequence of calls, and a step's failure path
            is only provable if the service it depends on can be told to fail.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeDiskService. Never write the class name as a type literal in
            a test: it binds to whichever dynamic assembly loaded first and
            breaks across a module reload. Use this factory.

        .EXAMPLE
            $disk = New-HDTFakeDiskService -FixturePath ./tests/fixtures/disk/gen2-vm-raw-disk.json
            $disk.ClearDisk(0)
            $disk.InitializeDisk(0, 'GPT')
            $disk.GetOperationName()

            The start of the UEFI layout of DESIGN 9.1, with no disk attached.

        .EXAMPLE
            $disk = New-HDTFakeDiskService -FixturePath ./tests/fixtures/disk
            @($disk.GetDisk() | Where-Object { $_.IsBoot })

            The row 04-02's selection rule must refuse unconditionally: this
            machine's own boot disk.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [object[]] $Disk,

        [Parameter()]
        [object[]] $Partition,

        [Parameter()]
        [object[]] $Volume,

        [Parameter()]
        [string] $FixturePath,

        [Parameter()]
        [hashtable] $Failure,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    # One file -> one listing, chosen by the base name's suffix. Both the
    # directory form and the single-file form go through this, so they can never
    # drift apart in how they load.
    $loadFixtureFile = {
        param($Fake, $File)

        $text = Get-Content -LiteralPath $File.FullName -Raw

        # Never -AsHashtable: it is PowerShell 6+ only and banned outright.
        #
        # ASSIGNED FIRST, WRAPPED SECOND, AND THAT ORDER IS LOAD-BEARING. Under
        # Windows PowerShell 5.1 ConvertFrom-Json writes a top-level JSON array
        # to the pipeline WITHOUT enumerating it, so @(ConvertFrom-Json ...)
        # yields ONE element - the whole array - and every row after the first is
        # silently lost. Through a variable it is the array itself on both
        # engines. Observed: four captured partitions arriving as one nonsense
        # row under 5.1 while pwsh 7 was green.
        $content = ConvertFrom-Json -InputObject $text

        $name = $File.BaseName
        if ($name -like '*-disk') {
            foreach ($row in @($content)) { $Fake.SeedDisk($row) }
        } elseif ($name -like '*-partition') {
            foreach ($row in @($content)) { $Fake.SeedPartition($row) }
        } elseif ($name -like '*-volume') {
            foreach ($row in @($content)) { $Fake.SeedVolume($row) }
        } else {
            throw ("Disk fixture '{0}' does not say which listing it seeds. Name it *-disk.json, *-partition.json or *-volume.json." -f $File.FullName)
        }
    }

    $fake = [HDTFakeDiskService]::new()
    $fake.Journal = $Journal

    if ($PSBoundParameters.ContainsKey('FixturePath')) {
        if (Test-Path -LiteralPath $FixturePath -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $FixturePath -Filter '*.json' -File)) {
                & $loadFixtureFile $fake $file
            }
        } elseif (Test-Path -LiteralPath $FixturePath -PathType Leaf) {
            & $loadFixtureFile $fake (Get-Item -LiteralPath $FixturePath)
        } else {
            throw "FixturePath '$FixturePath' does not exist."
        }
    }

    if ($PSBoundParameters.ContainsKey('Disk')) {
        foreach ($row in @($Disk)) { $fake.SeedDisk($row) }
    }

    if ($PSBoundParameters.ContainsKey('Partition')) {
        foreach ($row in @($Partition)) { $fake.SeedPartition($row) }
    }

    if ($PSBoundParameters.ContainsKey('Volume')) {
        foreach ($row in @($Volume)) { $fake.SeedVolume($row) }
    }

    if ($PSBoundParameters.ContainsKey('Failure')) {
        foreach ($operation in @($Failure.Keys)) {
            $fake.SeedFailure([string] $operation, [string] $Failure[$operation])
        }
    }

    return $fake
}

class HDTFakeImageService {

    # Normalised image path -> object[] of image rows.
    [hashtable] $Image

    # Method name -> the message that method throws. A step's failure path is
    # only provable if the service it depends on can be told to fail.
    [hashtable] $Failure

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    HDTFakeImageService() {
        $this.Image = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Failure = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'ImageService'
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
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

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- key handling ------------------------------------------------------

    # The same normalisation New-HDTFakeScriptInvoker uses, so one key serves
    # both: a sequence writes 'Z:\OperatingSystems\Win11\sources\install.wim'
    # and a test that seeded the forward-slash form still matches.
    hidden [string] Normalize([string] $Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw [System.ArgumentException]::new('ImagePath must not be empty.', 'ImagePath')
        }

        return $Path.Replace('\', '/')
    }

    # Checked AFTER the method records, because the attempt is evidence about
    # what the code under test tried. The type matches what the real adapter
    # throws when a native tool exits non-zero.
    hidden [void] AssertNoFailure([string] $Operation) {
        if ($this.Failure.ContainsKey($Operation)) {
            throw [System.InvalidOperationException]::new([string] $this.Failure[$Operation])
        }
    }

    # -- seeding (never recorded) ------------------------------------------

    # Reads a property off a seeded row, whether it arrived as a pscustomobject
    # (a fixture, deserialised) or as a hashtable (a test, typed by hand), and
    # falls back to the documented default when it is absent or null. Engine
    # code runs under Set-StrictMode -Version Latest, where reading a property
    # that is not there throws rather than returning nothing.
    hidden [object] Property([object] $Row, [string] $Name, [object] $Default) {
        if ($null -eq $Row) {
            return $Default
        }

        if ($Row -is [System.Collections.IDictionary]) {
            if (-not $Row.Contains($Name)) {
                return $Default
            }
            if ($null -eq $Row[$Name]) {
                return $Default
            }
            return $Row[$Name]
        }

        $member = $Row.PSObject.Properties[$Name]
        if ($null -eq $member) {
            return $Default
        }
        if ($null -eq $member.Value) {
            return $Default
        }

        return $member.Value
    }

    [void] SeedImage([string] $ImagePath, [object[]] $Row) {
        $normalized = @()
        foreach ($item in @($Row)) {
            $normalized += [pscustomobject] @{
                Index        = [int] $this.Property($item, 'Index', 0)
                Name         = [string] $this.Property($item, 'Name', '')
                Description  = [string] $this.Property($item, 'Description', '')
                Edition      = [string] $this.Property($item, 'Edition', '')
                SizeBytes    = [long] $this.Property($item, 'SizeBytes', [long] 0)
                Architecture = [string] $this.Property($item, 'Architecture', '')
                Version      = [string] $this.Property($item, 'Version', '')
            }
        }

        $this.Image[$this.Normalize($ImagePath)] = [object[]] $normalized
    }

    [void] SeedFailure([string] $Operation, [string] $Message) {
        $this.Failure[$Operation] = $Message
    }

    # -- IImageService -----------------------------------------------------

    [object[]] GetImageInfo([string] $ImagePath) {
        $this.Record('GetImageInfo', @($ImagePath))
        $this.AssertNoFailure('GetImageInfo')

        # A path that was never seeded is a WIM that is not there, and the real
        # adapter throws exactly this for it. A fake that returned an empty list
        # would make a typo'd image path look like an image with no indices.
        $key = $this.Normalize($ImagePath)
        if (-not $this.Image.ContainsKey($key)) {
            throw [System.IO.FileNotFoundException]::new(
                "Could not find image '$ImagePath': it was never seeded on this fake.", $ImagePath)
        }

        return [object[]] @($this.Image[$key])
    }

    [void] ApplyImage([string] $ImagePath, [int] $Index, [string] $ApplyPath) {
        $this.Record('ApplyImage', @($ImagePath, $Index, $ApplyPath))
        $this.AssertNoFailure('ApplyImage')
    }

    [void] InstallBootFile([string] $OsRoot, [string] $SystemVolume, [string] $Firmware) {
        $this.Record('InstallBootFile', @($OsRoot, $SystemVolume, $Firmware))
        $this.AssertNoFailure('InstallBootFile')
    }

    [void] SetRecoveryImage([string] $OsRoot, [string] $RecoveryPath) {
        $this.Record('SetRecoveryImage', @($OsRoot, $RecoveryPath))
        $this.AssertNoFailure('SetRecoveryImage')
    }

    [void] SetBootOrderFirst() {
        $this.Record('SetBootOrderFirst', @())
        $this.AssertNoFailure('SetBootOrderFirst')
    }
}

function New-HDTFakeImageService {
    <#
        .SYNOPSIS
            Creates an IImageService that returns seeded image information,
            applies nothing and runs no native tool.

        .DESCRIPTION
            The hand-written double behind every imaging test (DESIGN 9.2;
            DESIGN 12.2.1: engine logic receives injected services; DESIGN
            12.2.3: fake, don't mock). It is what makes ApplyImage,
            ConfigureBoot and their failure paths provable in seconds, against
            no media and with nothing written to a disk.

            Five methods:

              GetImageInfo(imagePath) -> Index, Name, Description, Edition,
                                         SizeBytes, Architecture, Version
              ApplyImage(imagePath, index, applyPath)
              InstallBootFile(osRoot, systemVolume, firmware)
              SetRecoveryImage(osRoot, recoveryPath)
              SetBootOrderFirst()

            SetBootOrderFirst is SPIKES.md S6's fourth finding as an API: after
            apply, a machine that still has the boot media first in the firmware
            order simply reboots into WinPE.

            An image path that was never seeded throws
            System.IO.FileNotFoundException naming it, as the real adapter does
            for a WIM that is not on disk (the error-parity rule in
            tests/helpers/README.md section 5).

            Image paths are matched case-insensitively with backslashes
            normalised to forward slashes, exactly as New-HDTFakeScriptInvoker
            normalises script paths, so one key serves both.

            Every call appends a record to $Operations - before it can throw -
            so the ordered ceremony a step performed can be asserted whole.
            Seeding is deliberately not recorded.

        .PARAMETER Image
            Seed image information. Keys are image paths, values are the rows
            GetImageInfo returns for that path.

        .PARAMETER FixturePath
            A directory of captured *.json files. Each file seeds under its own
            base name, so tests/fixtures/image/ws2025-std-install.json becomes
            the key 'ws2025-std-install'. Seed a real WIM path with -Image when
            a test needs the path an administrator would type.

        .PARAMETER Failure
            Methods that fail. Keys are method names, values are the message the
            System.InvalidOperationException carries - the type the real adapter
            throws when a native tool exits non-zero.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeImageService. Never write the class name as a type literal in
            a test: it binds to whichever dynamic assembly loaded first and
            breaks across a module reload. Use this factory.

        .EXAMPLE
            $row = ConvertFrom-Json ([System.IO.File]::ReadAllText('./tests/fixtures/image/win11-ltsc-2024-install.json'))
            $image = New-HDTFakeImageService -Image @{ 'Z:\OperatingSystems\Win11\sources\install.wim' = @($row) }
            $image.GetImageInfo('Z:\OperatingSystems\Win11\sources\install.wim')[0].Name

            Real captured Get-WindowsImage output, with no media mounted.

        .EXAMPLE
            $image = New-HDTFakeImageService -Failure @{ ApplyImage = 'Error: 0x80070002' }

            The apply that fails, so a step's failure path is provable.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [hashtable] $Image,

        [Parameter()]
        [string] $FixturePath,

        [Parameter()]
        [hashtable] $Failure,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeImageService]::new()
    $fake.Journal = $Journal

    if ($PSBoundParameters.ContainsKey('FixturePath')) {
        if (-not (Test-Path -LiteralPath $FixturePath -PathType Container)) {
            throw "FixturePath '$FixturePath' does not exist or is not a directory."
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $FixturePath -Filter '*.json' -File)) {
            # Assigned first, wrapped second: under Windows PowerShell 5.1
            # ConvertFrom-Json writes a top-level array WITHOUT enumerating it,
            # so @(ConvertFrom-Json ...) would be one element - the whole array.
            $content = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $file.FullName -Raw)
            $fake.SeedImage($file.BaseName, [object[]] @($content))
        }
    }

    if ($PSBoundParameters.ContainsKey('Image')) {
        foreach ($path in @($Image.Keys)) {
            $fake.SeedImage([string] $path, [object[]] @($Image[$path]))
        }
    }

    if ($PSBoundParameters.ContainsKey('Failure')) {
        foreach ($operation in @($Failure.Keys)) {
            $fake.SeedFailure([string] $operation, [string] $Failure[$operation])
        }
    }

    return $fake
}

class HDTFakeClock {

    # The current fake instant. Always Kind = Utc: a clock whose answers depend
    # on the time zone of the machine running the suite is the one thing a fake
    # exists to prevent.
    [datetime] $UtcNow

    # How far GetUtcNow advances the clock after answering. 0 freezes it.
    [int] $TickMillisecond

    # Every millisecond Sleep was asked for, so a backoff test can assert the
    # total wait without waiting.
    [long] $TotalSleepMillisecond

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    HDTFakeClock() {
        $this.UtcNow = [datetime]::SpecifyKind([datetime]::new(1, 1, 1), 'Utc')
        $this.TickMillisecond = 0
        $this.TotalSleepMillisecond = 0
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'Clock'
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
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

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- seeding (never recorded) ------------------------------------------

    [void] SetUtcNow([datetime] $Value) {
        # Unspecified is taken as already UTC; anything else is converted. The
        # literal every test reaches for - [datetime]'2026-08-13T00:00:00Z' -
        # parses to Kind = Local, so storing it verbatim would shift the instant
        # by the developer's offset.
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) {
            $this.UtcNow = [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
        } else {
            $this.UtcNow = $Value.ToUniversalTime()
        }
    }

    [void] Advance([int] $Millisecond) {
        $this.UtcNow = $this.UtcNow.AddMilliseconds($Millisecond)
    }

    # -- IClock ------------------------------------------------------------

    [datetime] GetUtcNow() {
        $this.Record('GetUtcNow', @())
        $answer = $this.UtcNow
        $this.Advance($this.TickMillisecond)
        return $answer
    }

    [void] Sleep([int] $Millisecond) {
        $this.Record('Sleep', @($Millisecond))
        $this.TotalSleepMillisecond = $this.TotalSleepMillisecond + $Millisecond
        $this.Advance($Millisecond)
    }
}

function New-HDTFakeClock {
    <#
        .SYNOPSIS
            Creates an IClock that answers from a seeded instant and never waits.

        .DESCRIPTION
            The hand-written double behind every test that reads the time or
            waits (DESIGN 12.2.1: engine logic receives injected services;
            DESIGN 12.2.3: fake, don't mock).

            It implements the two IClock methods - GetUtcNow and Sleep. Sleep is
            on the interface so retry backoff is provable without a test that
            actually waits: this fake advances its own clock by the requested
            number of milliseconds and returns immediately, and the engine never
            learns the difference.

            -UtcNow IS NORMALISED TO UTC BEFORE IT IS STORED, and that is not
            optional. [datetime]'2026-08-13T00:00:00Z' - the literal a test
            reaches for - parses to Kind = Local on both engines, so a fake that
            stored it verbatim would answer with a non-UTC kind AND an instant
            shifted by the developer's time zone. Kind = Unspecified is taken as
            already UTC; any other kind goes through ToUniversalTime.

            GetUtcNow returns the current fake instant and then advances it by
            -TickMillisecond, which defaults to 0, so a clock is frozen unless a
            test asks for movement. Advance is seeding and is not recorded;
            GetUtcNow and Sleep are, like every other fake's operations.

        .PARAMETER UtcNow
            The instant the clock starts at.

        .PARAMETER TickMillisecond
            How far the clock moves after each GetUtcNow. Defaults to 0.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeClock. Never write the class name as a type literal in a
            test: it binds to whichever dynamic assembly loaded first and breaks
            across a module reload. Use this factory.

        .EXAMPLE
            $clock = New-HDTFakeClock -UtcNow ([datetime]'2026-08-13T00:00:00Z')
            $clock.GetUtcNow()

            A frozen clock, identical on a machine in any time zone.

        .EXAMPLE
            $clock = New-HDTFakeClock -UtcNow ([datetime]'2026-08-13T00:00:00Z')
            $clock.Sleep(30000)
            $clock.TotalSleepMillisecond

            A retry backoff proven in microseconds rather than in half a minute.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [datetime] $UtcNow,

        [Parameter()]
        [int] $TickMillisecond = 0,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeClock]::new()
    $fake.Journal = $Journal
    $fake.TickMillisecond = $TickMillisecond
    $fake.SetUtcNow($UtcNow)

    return $fake
}

class HDTFakeContentProvider {

    # The root every relative path is resolved against - a workspace root, a UNC
    # share, or the root of a piece of standalone media.
    [string] $Root

    # Normalised relative path -> the absolute path ResolveContent answers with,
    # and the set TestContent answers from. Seeded content is content that is
    # THERE; anything else resolves to a path under the root and is absent.
    [hashtable] $Content

    # Method name -> the message that method throws. A provider that cannot fail
    # cannot prove a step's failure path.
    [hashtable] $Failure

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    # Whether Connect has been called. Local and Smb both track it - Smb to map
    # once when Connect is called twice, this fake so a test can see the same.
    [bool] $IsConnected

    HDTFakeContentProvider() {
        $this.Root = 'Z:\Deploy'
        $this.Content = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Failure = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'ContentProvider'
        $this.IsConnected = $false
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
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

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- path handling -----------------------------------------------------

    # One key for both separators, so a test that seeded the forward-slash form
    # still matches the backslash a sequence writes.
    hidden [string] Key([string] $Path) {
        return $Path.Replace('\', '/')
    }

    # THE RESOLUTION RULES, WRITTEN THE SAME WAY IN ALL THREE IMPLEMENTATIONS.
    # Segments are collapsed here rather than by [IO.Path]::GetFullPath, which
    # consults the current directory for a volume-relative root and silently
    # clamps '..' at the root of a UNC share instead of reporting the escape.
    hidden [string] NormalizeRelative([string] $Path) {
        $segment = [System.Collections.ArrayList]::new()

        foreach ($part in ($Path -split '[\\/]+')) {
            if (($part -eq '') -or ($part -eq '.')) { continue }

            if ($part -eq '..') {
                if ($segment.Count -eq 0) {
                    throw [System.ArgumentException]::new(
                        ("HDTConfigurationError: the content path '{0}' escapes the content root '{1}'. A step asking for content outside the workspace is a defect, not a path to follow." -f $Path, $this.Root))
                }
                $segment.RemoveAt($segment.Count - 1)
                continue
            }

            [void] $segment.Add($part)
        }

        return ($segment -join '\')
    }

    hidden [void] AssertUsablePath([string] $Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw [System.ArgumentException]::new(
                ("HDTConfigurationError: a content path must not be empty. The provider was asked to resolve nothing against the content root '{0}'." -f $this.Root))
        }
    }

    hidden [string] Combine([string] $RelativePath) {
        $tail = $this.NormalizeRelative($RelativePath)
        if ($tail.Length -eq 0) { return $this.Root }

        return ($this.Root.TrimEnd('\', '/') + '\' + $tail)
    }

    # Checked AFTER the method records, because the attempt is evidence about
    # what the code under test tried. The type matches what a real provider
    # throws when the transport underneath it fails.
    hidden [void] AssertNoFailure([string] $Operation) {
        if ($this.Failure.ContainsKey($Operation)) {
            throw [System.InvalidOperationException]::new([string] $this.Failure[$Operation])
        }
    }

    # -- seeding (never recorded) ------------------------------------------

    [void] SeedContent([string] $RelativePath, [string] $ResolvedPath) {
        $this.Content[$this.Key($RelativePath)] = $ResolvedPath
    }

    [void] SeedFailure([string] $Operation, [string] $Message) {
        $this.Failure[$Operation] = $Message
    }

    # -- IContentProvider --------------------------------------------------

    [string] ResolveContent([string] $RelativePath) {
        $this.Record('ResolveContent', @($RelativePath))
        $this.AssertNoFailure('ResolveContent')
        $this.AssertUsablePath($RelativePath)

        # DESIGN 9.3: media too large to bring into the share is registered where
        # it stands, and a provider must not re-root it.
        if ([System.IO.Path]::IsPathRooted($RelativePath)) {
            return $RelativePath
        }

        $combined = $this.Combine($RelativePath)

        $key = $this.Key($RelativePath)
        if ($this.Content.ContainsKey($key)) {
            return [string] $this.Content[$key]
        }

        return $combined
    }

    [bool] TestContent([string] $RelativePath) {
        $this.Record('TestContent', @($RelativePath))
        $this.AssertNoFailure('TestContent')
        $this.AssertUsablePath($RelativePath)

        if (-not [System.IO.Path]::IsPathRooted($RelativePath)) {
            [void] $this.Combine($RelativePath)
        }

        return $this.Content.ContainsKey($this.Key($RelativePath))
    }

    [string] CopyContent([string] $RelativePath, [string] $Destination) {
        $this.Record('CopyContent', @($RelativePath, $Destination))
        $this.AssertNoFailure('CopyContent')
        $this.AssertUsablePath($RelativePath)

        if (-not [System.IO.Path]::IsPathRooted($RelativePath)) {
            [void] $this.Combine($RelativePath)
        }

        if (-not $this.Content.ContainsKey($this.Key($RelativePath))) {
            throw [System.IO.FileNotFoundException]::new(
                ("Could not find content '{0}' under '{1}': it was never seeded on this fake." -f $RelativePath, $this.Root), $RelativePath)
        }

        # Nothing is written anywhere: the destination is reported, not created.
        return $Destination
    }

    [string] Connect() {
        $this.Record('Connect', @())
        $this.AssertNoFailure('Connect')
        $this.IsConnected = $true

        return $this.Root
    }

    # No failure seam, deliberately: Disconnect runs in a finally on every
    # implementation and a teardown that throws is a teardown that does not
    # finish.
    [void] Disconnect() {
        $this.Record('Disconnect', @())
        $this.IsConnected = $false
    }
}

function New-HDTFakeContentProvider {
    <#
        .SYNOPSIS
            Creates an IContentProvider that resolves seeded content and reaches
            no share, no media and no disk.

        .DESCRIPTION
            The hand-written double behind DESIGN 6's provider interface
            (DESIGN 12.2.1: engine logic receives injected services; DESIGN
            12.2.3: fake, don't mock).

            Five methods:

              ResolveContent(relativePath) -> an absolute path a step can use
              TestContent(relativePath)    -> [bool]
              CopyContent(relativePath, destination) -> the destination
              Connect()                    -> the root that is now reachable
              Disconnect()

            The resolution rules are the ones every implementation shares: a
            relative path is combined with Root, a ROOTED path is returned
            unchanged (DESIGN 9.3 - media registered where it stands), a '..'
            that escapes Root is refused, and an empty path is refused. Both
            refusals are System.ArgumentException carrying HDTConfigurationError
            in the sentence, because a ScriptMethod - which is what every real
            adapter is - cannot carry an ErrorRecord's error id to its caller.

            ResolveContent does not check existence. TestContent is that
            question, and it answers from what was seeded.

        .PARAMETER Root
            The content root. Defaults to Z:\Deploy.

        .PARAMETER Content
            Seed content that is present. Keys are relative paths, values are the
            absolute path ResolveContent answers with - which is how a test
            stages media registered outside the share.

        .PARAMETER Failure
            Methods that fail. Keys are method names, values are the message the
            System.InvalidOperationException carries.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeContentProvider. Never write the class name as a type literal
            in a test: it binds to whichever dynamic assembly loaded first and
            breaks across a module reload. Use this factory.

        .EXAMPLE
            $content = New-HDTFakeContentProvider -Root 'Z:\Deploy'
            $content.ResolveContent('OperatingSystems\Win11-LTSC-2024\sources\install.wim')

        .EXAMPLE
            $content = New-HDTFakeContentProvider -Failure @{ Connect = 'the network is not up' }

            The connect that fails, so a launcher's failure path is provable.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Root = 'Z:\Deploy',

        [Parameter()]
        [hashtable] $Content,

        [Parameter()]
        [hashtable] $Failure,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeContentProvider]::new()
    $fake.Journal = $Journal
    $fake.Root = $Root

    if ($PSBoundParameters.ContainsKey('Content')) {
        foreach ($key in @($Content.Keys)) {
            $fake.SeedContent([string] $key, [string] $Content[$key])
        }
    }

    if ($PSBoundParameters.ContainsKey('Failure')) {
        foreach ($operation in @($Failure.Keys)) {
            $fake.SeedFailure([string] $operation, [string] $Failure[$operation])
        }
    }

    return $fake
}

class HDTFakeSmbService {

    # Lower-case server name -> the rows GetConnection answers with once a
    # mapping to that server exists.
    [hashtable] $Active

    # Lower-case server name -> what a mapping to that server WILL become. This
    # is how the guest case is staged: seed a row whose UserName is Guest, and
    # the provider must refuse the connection it just made.
    [hashtable] $Seeded

    # EnableInsecureGuestLogons, RequireSecuritySignature.
    [pscustomobject] $ClientConfiguration

    # Method name -> the message that method throws.
    [hashtable] $Failure

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    HDTFakeSmbService() {
        $this.Active = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Seeded = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Failure = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'SmbService'
        $this.ClientConfiguration = [pscustomobject] @{
            EnableInsecureGuestLogons = $false
            RequireSecuritySignature  = $false
        }
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
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

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- path handling -----------------------------------------------------

    hidden [string] ServerOf([string] $RemotePath) {
        $part = @($RemotePath.TrimStart('\', '/') -split '[\\/]+' | Where-Object { $_ -ne '' })
        if ($part.Count -eq 0) { return '' }

        return $part[0]
    }

    hidden [string] ShareOf([string] $RemotePath) {
        $part = @($RemotePath.TrimStart('\', '/') -split '[\\/]+' | Where-Object { $_ -ne '' })
        if ($part.Count -lt 2) { return '' }

        return $part[1]
    }

    hidden [void] AssertNoFailure([string] $Operation) {
        if ($this.Failure.ContainsKey($Operation)) {
            throw [System.InvalidOperationException]::new([string] $this.Failure[$Operation])
        }
    }

    # -- seeding (never recorded) ------------------------------------------

    [void] SeedConnection([object] $Row) {
        $server = [string] $Row.ServerName

        if (-not $this.Seeded.ContainsKey($server)) {
            $this.Seeded[$server] = [System.Collections.ArrayList]::new()
        }

        [void] $this.Seeded[$server].Add($Row)
    }

    [void] SeedClientConfiguration([bool] $EnableInsecureGuestLogons, [bool] $RequireSecuritySignature) {
        $this.ClientConfiguration = [pscustomobject] @{
            EnableInsecureGuestLogons = $EnableInsecureGuestLogons
            RequireSecuritySignature  = $RequireSecuritySignature
        }
    }

    [void] SeedFailure([string] $Operation, [string] $Message) {
        $this.Failure[$Operation] = $Message
    }

    # -- ISmbService -------------------------------------------------------

    # THE PASSWORD IS REDACTED IN THE RECORDING, exactly as
    # ILsaService.SetSecret redacts its value: $Operations is printed verbatim
    # in a Pester failure message, and the deployment password does not belong
    # in one.
    # The third argument is the password. It is called $Secret because a class
    # method cannot carry a SuppressMessageAttribute, and PSScriptAnalyzer's
    # PSAvoidUsingUsernameAndPasswordParams fires on the pair of names - the real
    # adapter suppresses the same two rules with a justification instead.
    [void] NewMapping([string] $RemotePath, [string] $UserName, [string] $Secret) {
        $this.Record('NewMapping', @($RemotePath, $UserName, '<redacted>'))
        $this.AssertNoFailure('NewMapping')

        $server = $this.ServerOf($RemotePath)

        if ($this.Seeded.ContainsKey($server)) {
            $this.Active[$server] = [object[]] @($this.Seeded[$server])
            return
        }

        # SEEDING IS AUTHORITATIVE. Once a test has said what a mapping becomes,
        # a mapping to a server it did not name becomes nothing - which is how
        # "the mapping did not take" is staged for the provider.
        if ($this.Seeded.Count -gt 0) {
            $this.Active[$server] = [object[]] @()
            return
        }

        # What a mapping produces on a modern Windows server when nothing said
        # otherwise: the identity that was asked for, SMB 3.1.1, encrypted.
        $this.Active[$server] = [object[]] @([pscustomobject] @{
                ServerName = $server
                ShareName  = $this.ShareOf($RemotePath)
                UserName   = $UserName
                Dialect    = '3.1.1'
                Encrypted  = $true
                Signed     = $true
            })
    }

    [void] RemoveMapping([string] $RemotePath) {
        $this.Record('RemoveMapping', @($RemotePath))
        $this.AssertNoFailure('RemoveMapping')

        $this.Active.Remove($this.ServerOf($RemotePath))
    }

    [object[]] GetConnection([string] $ServerName) {
        $this.Record('GetConnection', @($ServerName))
        $this.AssertNoFailure('GetConnection')

        if (-not $this.Active.ContainsKey($ServerName)) {
            return [object[]] @()
        }

        return [object[]] @($this.Active[$ServerName])
    }

    [object] GetClientConfiguration() {
        $this.Record('GetClientConfiguration', @())
        $this.AssertNoFailure('GetClientConfiguration')

        return $this.ClientConfiguration
    }
}

function New-HDTFakeSmbService {
    <#
        .SYNOPSIS
            Creates an ISmbService that maps nothing and reaches no share.

        .DESCRIPTION
            The hand-written double behind New-HDTSmbContentProvider's decisions
            (DESIGN 6.3, DESIGN 12.2.1, DESIGN 12.2.3). It is what makes "the
            engine refuses guest fallback" provable on a machine with no server,
            no domain account and no second machine to authenticate to.

            Four methods:

              NewMapping(remotePath, userName, password)
              RemoveMapping(remotePath)
              GetConnection(serverName) -> ServerName, ShareName, UserName,
                                           Dialect, Encrypted, Signed
              GetClientConfiguration()  -> EnableInsecureGuestLogons,
                                           RequireSecuritySignature

            A MAPPING BECOMES A CONNECTION, which is the whole point: the
            provider maps and then reads the established identity back, and this
            fake is what that read-back answers. -Connection seeds what the
            mapping will become; with nothing seeded a mapping produces the
            identity it was asked for over SMB 3.1.1, encrypted, which is what a
            modern Windows server does.

            THE PASSWORD IS RECORDED AS '<redacted>' - see
            tests/helpers/README.md section 4.

        .PARAMETER Connection
            Rows a mapping to their ServerName will produce. Each carries
            ServerName, ShareName, UserName, Dialect, Encrypted and Signed.

        .PARAMETER ClientConfiguration
            EnableInsecureGuestLogons and RequireSecuritySignature. Both default
            to $false.

        .PARAMETER Failure
            Methods that fail. Keys are method names, values are the message the
            System.InvalidOperationException carries - the type the real adapter
            throws when an SmbShare cmdlet fails.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeSmbService. Never write the class name as a type literal in a
            test: it binds to whichever dynamic assembly loaded first and breaks
            across a module reload. Use this factory.

        .EXAMPLE
            $smb = New-HDTFakeSmbService -Connection @(
                [pscustomobject] @{ ServerName = 'hdtserver'; ShareName = 'HdtShare'
                                    UserName = 'hdtserver\Guest'; Dialect = '3.1.1'
                                    Encrypted = $false; Signed = $true })

            The guest connection DESIGN 6.3 says HDT must refuse.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [object[]] $Connection,

        [Parameter()]
        [hashtable] $ClientConfiguration,

        [Parameter()]
        [hashtable] $Failure,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeSmbService]::new()
    $fake.Journal = $Journal

    if ($PSBoundParameters.ContainsKey('Connection')) {
        foreach ($row in @($Connection)) {
            $fake.SeedConnection($row)
        }
    }

    if ($PSBoundParameters.ContainsKey('ClientConfiguration')) {
        $guest = $false
        $signature = $false
        if ($ClientConfiguration.ContainsKey('EnableInsecureGuestLogons')) { $guest = [bool] $ClientConfiguration['EnableInsecureGuestLogons'] }
        if ($ClientConfiguration.ContainsKey('RequireSecuritySignature')) { $signature = [bool] $ClientConfiguration['RequireSecuritySignature'] }

        $fake.SeedClientConfiguration($guest, $signature)
    }

    if ($PSBoundParameters.ContainsKey('Failure')) {
        foreach ($operation in @($Failure.Keys)) {
            $fake.SeedFailure([string] $operation, [string] $Failure[$operation])
        }
    }

    return $fake
}

class HDTFakeWdsService {

    # The images the server holds. A LIST, NOT A RECORDING - see the factory's
    # help: "one image, not two" cannot be asserted against a double that only
    # remembers which calls were made.
    [System.Collections.ArrayList] $Image

    # Method name -> the message that method throws.
    [hashtable] $Failure

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null when the test did not ask for
    # one. Sequence, Service, Operation, Arguments.
    [System.Collections.ArrayList] $Journal

    # Names this fake in a journal entry, so neither the journal nor a test needs
    # a class type literal.
    [string] $ServiceName

    HDTFakeWdsService() {
        $this.Image = [System.Collections.ArrayList]::new()
        $this.Failure = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'WdsService'
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
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

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    hidden [void] AssertNoFailure([string] $Operation) {
        if ($this.Failure.ContainsKey($Operation)) {
            throw [System.InvalidOperationException]::new([string] $this.Failure[$Operation])
        }
    }

    # -- seeding (never recorded) ------------------------------------------

    [void] SeedImage([object] $Row) {
        [void] $this.Image.Add([pscustomobject] @{
                ImageName    = [string] $Row.ImageName
                Architecture = [string] $Row.Architecture
                FileName     = [string] $Row.FileName
                Version      = [string] $Row.Version
            })
    }

    [void] SeedFailure([string] $Operation, [string] $Message) {
        $this.Failure[$Operation] = $Message
    }

    # -- IWdsService -------------------------------------------------------

    [object[]] GetBootImage([string] $Architecture) {
        $this.Record('GetBootImage', @($Architecture))
        $this.AssertNoFailure('GetBootImage')

        $wanted = $Architecture

        return [object[]] @($this.Image | Where-Object {
                [string] $_.Architecture -eq $wanted
            })
    }

    [void] ImportBootImage([string] $Path, [string] $ImageName, [string] $Architecture) {
        $this.Record('ImportBootImage', @($Path, $ImageName, $Architecture))
        $this.AssertNoFailure('ImportBootImage')

        # NO DE-DUPLICATION HERE, DELIBERATELY. Import-WdsBootImage accumulates,
        # and a fake that quietly replaced would let a command that never called
        # RemoveBootImage pass the one test ROADMAP M4 names.
        [void] $this.Image.Add([pscustomobject] @{
                ImageName    = $ImageName
                Architecture = $Architecture
                FileName     = [System.IO.Path]::GetFileName($Path)

                # EMPTY, AND HONESTLY SO: the real Import-WdsBootImage reads the
                # version out of the WIM's own metadata, and this fake has no WIM
                # to read. A test that needs a version seeds one.
                Version      = ''
            })
    }

    [void] RemoveBootImage([string] $ImageName, [string] $Architecture) {
        $this.Record('RemoveBootImage', @($ImageName, $Architecture))
        $this.AssertNoFailure('RemoveBootImage')

        $wantedName = $ImageName
        $wantedArchitecture = $Architecture

        $match = @($this.Image | Where-Object {
                [string] $_.ImageName -eq $wantedName -and [string] $_.Architecture -eq $wantedArchitecture
            })

        # Remove-WdsBootImage refuses a name that is not there. A fake that
        # shrugged would let a caller that removed the wrong thing pass.
        if ($match.Count -eq 0) {
            throw [System.InvalidOperationException]::new(
                ("There is no boot image named '{0}' for architecture '{1}' on this server." -f $ImageName, $Architecture))
        }

        foreach ($row in $match) {
            $this.Image.Remove($row)
        }
    }
}

function New-HDTFakeWdsService {
    <#
        .SYNOPSIS
            Creates an IWdsService that holds boot images in memory and reaches
            no server.

        .DESCRIPTION
            The hand-written double behind Import-HDTBootImageToWds
            (DESIGN 6.1, DESIGN 12.2.1, DESIGN 12.2.3), and THE ONLY WAY ANYTHING
            ABOUT WDS IS PROVABLE ON THIS MACHINE.

            There is no WDS on this host - it is Windows 11 Pro, and WDS is a
            Windows Server role - and standing one up is refused by PROJECT.md's
            lab safety rules, because CM01 already runs a PXE responder on
            'Default Switch' and a second one would either break the user's SCCM
            lab or answer our test VMs and silently invalidate the test. So the
            real New-HDTWdsService gets no contract row, and this is where
            replace-in-place is asserted.

            Three methods:

              GetBootImage(architecture)  -> object[] { ImageName, Architecture,
                                             FileName, Version }
              ImportBootImage(path, imageName, architecture)
              RemoveBootImage(imageName, architecture)

            IT IS A STORE, NOT A RECORDER. ImportBootImage adds a row that
            GetBootImage then answers with, and it does NOT de-duplicate - so
            "importing the same boot image twice leaves ONE image" is a real
            assertion about the command rather than about this file. A fake that
            replaced silently would report green for a command that never removed
            anything.

            RemoveBootImage THROWS for a name it does not hold, matching
            Remove-WdsBootImage, and it matches the name case-insensitively as
            WDS does.

            An imported image's Version is EMPTY: the real cmdlet reads it out of
            the WIM's own metadata and this fake has no WIM to read. A test that
            needs a previous version seeds one.

        .PARAMETER Image
            Boot images the server already holds. Each carries ImageName,
            Architecture, FileName and Version.

        .PARAMETER Failure
            Methods that fail. Keys are method names, values are the message the
            System.InvalidOperationException carries.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeWdsService. Never write the class name as a type literal in a
            test: it binds to whichever dynamic assembly loaded first and breaks
            across a module reload. Use this factory.

        .EXAMPLE
            $wds = New-HDTFakeWdsService -Image @(
                [pscustomobject] @{ ImageName = 'HDTPE_x64'; Architecture = 'x64'
                                    FileName = 'HDTPE_x64.wim'; Version = '10.0.26100.1' })

            The server that already has the image, which is the case
            Import-HDTBootImageToWds has to replace rather than duplicate.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [object[]] $Image,

        [Parameter()]
        [hashtable] $Failure,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeWdsService]::new()
    $fake.Journal = $Journal

    if ($PSBoundParameters.ContainsKey('Image')) {
        foreach ($row in @($Image)) {
            $fake.SeedImage($row)
        }
    }

    if ($PSBoundParameters.ContainsKey('Failure')) {
        foreach ($operation in @($Failure.Keys)) {
            $fake.SeedFailure([string] $operation, [string] $Failure[$operation])
        }
    }

    return $fake
}

class HDTFakeBootImageService {

    # The injected IFileSystem the mount is modelled in. It is a fake talking to
    # a fake, and deliberately so: Update-HDTBootImage WRITES INTO the mount, and
    # a double that recorded MountImage and nothing else could not tell a builder
    # that wrote before mounting from one that wrote after.
    [object] $FileSystem

    # Normalised mount path -> the image path mounted there. A set of one, in
    # practice, but DISM allows several and the integration suite re-mounts the
    # image it just built to read startnet.cmd back out of it.
    [hashtable] $Mounted

    # Normalised mount path -> ArrayList of { Name, State } for the cabs
    # AddPackage was given, so a test can assert "all nine went in" with no DISM.
    [hashtable] $Applied

    # Package rows seeded before anything was applied: Name -> State.
    [hashtable] $SeededPackage

    # Normalised image path -> object[] of { Index, Name, SizeBytes }.
    [hashtable] $Image

    # What AddDriver reports back. The manifest records it (DESIGN 5.1).
    [object[]] $Driver

    # Method name -> the message that method throws, as
    # System.InvalidOperationException - the type the real adapter throws when a
    # DISM cmdlet or oscdimg fails.
    [hashtable] $Failure

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    # The shared cross-service journal, or $null.
    [System.Collections.ArrayList] $Journal

    [string] $ServiceName

    HDTFakeBootImageService() {
        $this.Mounted = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Applied = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.SeededPackage = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Image = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Failure = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Driver = [object[]] @()
        $this.Operations = [System.Collections.ArrayList]::new()
        $this.ServiceName = 'BootImageService'
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
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

    [string[]] GetOperationName() {
        return [string[]] @($this.Operations | ForEach-Object { $_.Operation })
    }

    # -- path handling -----------------------------------------------------

    hidden [string] Normalize([string] $Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw [System.ArgumentException]::new('Path must not be empty.', 'Path')
        }

        return $Path.Replace('/', '\').TrimEnd('\')
    }

    # Checked AFTER the method records, because the attempt is evidence about
    # what the code under test tried.
    hidden [void] AssertNoFailure([string] $Operation) {
        if ($this.Failure.ContainsKey($Operation)) {
            throw [System.InvalidOperationException]::new([string] $this.Failure[$Operation])
        }
    }

    # DISM refuses a -Path that is not a mount, and so does this: a builder that
    # packaged before it mounted would otherwise pass here and fail on metal
    # fifteen minutes in.
    hidden [void] AssertMounted([string] $MountPath) {
        $key = $this.Normalize($MountPath)
        if (-not $this.Mounted.ContainsKey($key)) {
            throw [System.InvalidOperationException]::new(
                "There is no image mounted at '$MountPath'.")
        }
    }

    # -- seeding (never recorded) ------------------------------------------

    hidden [object] Property([object] $Row, [string] $Name, [object] $Default) {
        if ($null -eq $Row) { return $Default }

        if ($Row -is [System.Collections.IDictionary]) {
            if (-not $Row.Contains($Name)) { return $Default }
            if ($null -eq $Row[$Name]) { return $Default }
            return $Row[$Name]
        }

        $member = $Row.PSObject.Properties[$Name]
        if ($null -eq $member) { return $Default }
        if ($null -eq $member.Value) { return $Default }

        return $member.Value
    }

    [void] SeedImage([string] $ImagePath, [object[]] $Row) {
        $normalized = @()
        foreach ($item in @($Row)) {
            $normalized += [pscustomobject] @{
                Index     = [int] $this.Property($item, 'Index', 0)
                Name      = [string] $this.Property($item, 'Name', '')
                SizeBytes = [long] $this.Property($item, 'SizeBytes', [long] 0)
            }
        }

        $this.Image[$this.Normalize($ImagePath)] = [object[]] $normalized
    }

    [void] SeedPackage([string] $Name, [string] $State) {
        $this.SeededPackage[$Name] = $State
    }

    [void] SeedDriver([object[]] $Row) {
        $this.Driver = [object[]] @($Row)
    }

    [void] SeedFailure([string] $Operation, [string] $Message) {
        $this.Failure[$Operation] = $Message
    }

    # -- IBootImageService -------------------------------------------------

    [void] MountImage([string] $ImagePath, [int] $Index, [string] $MountPath) {
        $this.Record('MountImage', @($ImagePath, $Index, $MountPath))
        $this.AssertNoFailure('MountImage')

        $key = $this.Normalize($MountPath)
        if ($this.Mounted.ContainsKey($key)) {
            throw [System.InvalidOperationException]::new(
                "An image is already mounted at '$MountPath'.")
        }

        $this.Mounted[$key] = $ImagePath
        $this.Applied[$key] = [System.Collections.ArrayList]::new()

        # THE MOUNT, MODELLED. Seeded rather than written, because seeding is
        # not an operation the code under test performed and would otherwise show
        # up in the shared journal as a CreateDirectory nobody made.
        $this.FileSystem.SeedDirectory([System.IO.Path]::Combine($key, 'Windows\System32'))
    }

    [void] DismountImage([string] $MountPath, [bool] $Save) {
        $this.Record('DismountImage', @($MountPath, $Save))
        $this.AssertNoFailure('DismountImage')
        $this.AssertMounted($MountPath)

        $key = $this.Normalize($MountPath)
        [void] $this.Mounted.Remove($key)

        if (-not $Save) {
            # A DISCARD TAKES THE TREE WITH IT, as Dismount-WindowsImage -Discard
            # does. This is what catches a builder that wrote into the mount
            # after discarding it.
            $this.FileSystem.RemoveItem($key, $true)
        }
    }

    [void] AddPackage([string] $MountPath, [string] $PackagePath) {
        $this.Record('AddPackage', @($MountPath, $PackagePath))
        $this.AssertNoFailure('AddPackage')
        $this.AssertMounted($MountPath)

        $name = [System.IO.Path]::GetFileNameWithoutExtension($PackagePath)
        [void] $this.Applied[$this.Normalize($MountPath)].Add([pscustomobject] @{
                Name  = [string] $name
                State = 'Installed'
            })
    }

    [object[]] AddDriver([string] $MountPath, [string] $DriverPath, [bool] $Recurse) {
        $this.Record('AddDriver', @($MountPath, $DriverPath, $Recurse))
        $this.AssertNoFailure('AddDriver')
        $this.AssertMounted($MountPath)

        return [object[]] @($this.Driver)
    }

    [object[]] GetPackage([string] $MountPath) {
        $this.Record('GetPackage', @($MountPath))
        $this.AssertNoFailure('GetPackage')
        $this.AssertMounted($MountPath)

        $row = [System.Collections.ArrayList]::new()

        foreach ($name in @($this.SeededPackage.Keys)) {
            [void] $row.Add([pscustomobject] @{
                    Name  = [string] $name
                    State = [string] $this.SeededPackage[$name]
                })
        }

        foreach ($item in @($this.Applied[$this.Normalize($MountPath)])) {
            [void] $row.Add($item)
        }

        return [object[]] @($row)
    }

    [object[]] GetImageInfo([string] $ImagePath) {
        $this.Record('GetImageInfo', @($ImagePath))
        $this.AssertNoFailure('GetImageInfo')

        $key = $this.Normalize($ImagePath)
        if (-not $this.Image.ContainsKey($key)) {
            throw [System.IO.FileNotFoundException]::new(
                "Could not find image '$ImagePath': it was never seeded on this fake.", $ImagePath)
        }

        return [object[]] @($this.Image[$key])
    }

    [void] ExportImage([string] $SourcePath, [int] $Index, [string] $DestinationPath) {
        $this.Record('ExportImage', @($SourcePath, $Index, $DestinationPath))
        $this.AssertNoFailure('ExportImage')

        # THE EXPORT PRODUCES A FILE, because DESIGN 6.1.1's mechanism is that
        # the exported WIM is then COPIED into the media tree - one file, two
        # homes, same bytes. A fake whose export wrote nothing would make that
        # copy, and therefore the equivalence hash, unprovable.
        $this.FileSystem.SeedFile($this.Normalize($DestinationPath),
            ("HDTFakeExportedImage|{0}|{1}" -f $this.Normalize($SourcePath), $Index))
    }

    [void] SetScratchSpace([string] $MountPath, [int] $Megabyte) {
        $this.Record('SetScratchSpace', @($MountPath, $Megabyte))
        $this.AssertNoFailure('SetScratchSpace')
        $this.AssertMounted($MountPath)
    }

    [void] NewIso([string] $MediaRoot, [string] $IsoPath, [string[]] $Argument) {
        $this.Record('NewIso', @($MediaRoot, $IsoPath, $Argument))
        $this.AssertNoFailure('NewIso')

        $this.FileSystem.SeedFile($this.Normalize($IsoPath),
            ("HDTFakeIso|{0}|{1}" -f $this.Normalize($MediaRoot), (@($Argument) -join ' ')))
    }
}

function New-HDTFakeBootImageService {
    <#
        .SYNOPSIS
            Creates an IBootImageService that models a mount, applies nothing to
            a real image and runs no oscdimg.

        .DESCRIPTION
            The hand-written double behind every boot image test (DESIGN 5.1;
            DESIGN 12.2.1: engine logic receives injected services; DESIGN
            12.2.3: fake, don't mock). It is what makes Update-HDTBootImage's
            seventeen steps provable in seconds, on a machine with no ADK, no
            elevation and nothing mounted.

            Nine methods:

              MountImage(imagePath, index, mountPath)
              DismountImage(mountPath, save)
              AddPackage(mountPath, packagePath)
              AddDriver(mountPath, driverPath, recurse) -> the drivers added
              GetPackage(mountPath)                     -> { Name, State }
              GetImageInfo(imagePath)                   -> { Index, Name, SizeBytes }
              ExportImage(sourcePath, index, destinationPath)
              SetScratchSpace(mountPath, megabyte)
              NewIso(mediaRoot, isoPath, argument)

            IT MODELS THE MOUNT, AND THAT IS WHY IT EXISTS. Update-HDTBootImage
            writes startnet.cmd and the engine INTO the mounted image, so
            MountImage seeds <MountPath>\Windows\System32 into the injected
            IFileSystem and DismountImage with Save $false takes the whole tree
            away again. A builder that wrote after discarding is then caught by a
            test rather than by a boot image with no launcher in it. Every other
            fake here only answers questions; this one holds the small piece of
            state the code under test writes into.

            Seeding into the filesystem is deliberately done through the fake's
            Seed* methods rather than through CreateDirectory or WriteAllText, so
            nothing this service does by itself appears in the shared journal as
            an operation the builder performed.

            AddPackage, AddDriver, SetScratchSpace and DismountImage REFUSE A
            PATH THAT IS NOT MOUNTED, as DISM does. A builder that packaged
            before it mounted cannot pass here and fail on metal.

        .PARAMETER FileSystem
            The IFileSystem the mount is modelled in. Defaults to a fresh
            New-HDTFakeFileSystem, which a test can read back through the
            returned object's FileSystem property.

        .PARAMETER Image
            Seed GetImageInfo. Keys are image paths, values are rows of Index,
            Name and SizeBytes.

        .PARAMETER Package
            Packages already in the image before the build starts. Keys are
            component names, values are states.

        .PARAMETER Driver
            What AddDriver reports back - the rows the manifest records.

        .PARAMETER Failure
            Methods that fail. Keys are method names, values are the message the
            System.InvalidOperationException carries - the type the real adapter
            throws when a DISM cmdlet or oscdimg fails.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            HDTFakeBootImageService. Never write the class name as a type literal
            in a test: it binds to whichever dynamic assembly loaded first and
            breaks across a module reload. Use this factory.

        .EXAMPLE
            $fs = New-HDTFakeFileSystem
            $boot = New-HDTFakeBootImageService -FileSystem $fs
            $boot.MountImage('C:\scratch\HDTPE_x64.wim', 1, 'C:\scratch\mount')
            $fs.ReadAllText('C:\scratch\mount\Windows\System32\startnet.cmd')

            Read back exactly what the builder wrote into the image.

        .EXAMPLE
            $boot = New-HDTFakeBootImageService -Failure @{ AddPackage = 'Error: 0x800f081e' }

            The package that fails, so the builder's discard-and-dismount path is
            provable.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [hashtable] $Image,

        [Parameter()]
        [hashtable] $Package,

        [Parameter()]
        [object[]] $Driver,

        [Parameter()]
        [hashtable] $Failure,

        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeBootImageService]::new()
    $fake.Journal = $Journal

    $fake.FileSystem = $FileSystem
    if ($null -eq $fake.FileSystem) {
        $fake.FileSystem = New-HDTFakeFileSystem
    }

    if ($PSBoundParameters.ContainsKey('Image')) {
        foreach ($path in @($Image.Keys)) {
            $fake.SeedImage([string] $path, [object[]] @($Image[$path]))
        }
    }

    if ($PSBoundParameters.ContainsKey('Package')) {
        foreach ($name in @($Package.Keys)) {
            $fake.SeedPackage([string] $name, [string] $Package[$name])
        }
    }

    if ($PSBoundParameters.ContainsKey('Driver')) {
        $fake.SeedDriver([object[]] @($Driver))
    }

    if ($PSBoundParameters.ContainsKey('Failure')) {
        foreach ($operation in @($Failure.Keys)) {
            $fake.SeedFailure([string] $operation, [string] $Failure[$operation])
        }
    }

    return $fake
}

function New-HDTFakeWizardHost {
    <#
        .SYNOPSIS
            Creates an IWizardHost that shows nothing and answers what it was
            told to answer.

        .DESCRIPTION
            The hand-written double behind every wizard test (DESIGN 12.2.3:
            fake, don't mock). It is what lets Show-HDTWizard be asserted on a
            developer machine with no display and no WinPE - the window itself
            lives in New-HDTWizardHost, which is a branch-free adapter and is
            therefore not unit tested.

            It implements the one IWizardHost method, Show(xaml, title, field),
            and records the XAML, title and fields it was handed so a test can
            assert what reached the window without rendering one.

            THE FIELDS ARE RECORDED, NOT APPLIED. Working out what belongs in
            each box is Get-HDTWizardField's job and is tested there; what this
            has to prove is that the list reached the host intact.

            -Action IS RETURNED VERBATIM, INCLUDING EMPTY. An empty action is
            the shape a real window produces when it is closed with the X rather
            than answered, and Show-HDTWizard is required to read that as
            Cancel. A fake that quietly substituted 'Cancel' here would hide the
            very branch that keeps a dismissed wizard from meaning consent to
            partition a disk.

            IT ALSO REPLAYS A TECHNICIAN. ShowShell is the multi-page shell,
            where the window opens once and the page inside it is swapped, so a
            fake that only recorded what it was handed could not exercise the
            navigation at all. -Click is the sequence of buttons a technician
            presses; each one goes through THE SAME navigator scriptblock the
            real host calls, and Visited records where each click landed. That
            is what lets a whole Next/Next/Back/Next walk be asserted as an
            ordered list with no display attached.

        .PARAMETER Action
            What the technician "chose". 'Next', 'Cancel', or empty for a window
            that was dismissed without answering.

        .PARAMETER Click
            For ShowShell: the buttons the technician presses, in order. 'Next'
            and 'Back' go through the navigator; 'Cancel' and 'CommandPrompt'
            end the walk with that answer. Running out of clicks before the last
            page falls back to -Action, which is how "they closed the window on
            page two" is expressed.

        .PARAMETER Journal
            The shared cross-service operation journal.

        .OUTPUTS
            A PSCustomObject with Show and ShowShell methods, an Operations
            list, and the LastXaml, LastTitle, LastField, LastState and Visited
            it recorded.

        .EXAMPLE
            Show-HDTWizard -XamlPath $p -Title 'HDT' -WizardHost (New-HDTFakeWizardHost -Action 'Next')

        .EXAMPLE
            $host = New-HDTFakeWizardHost -Action 'Next' -Click @('Next', 'Next', 'Back', 'Next', 'Next')
            Show-HDTWizardShell -ShellXamlPath $p -Page $page -WizardHost $host
            $host.Visited   # every page, in the order it was reached
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string] $Action = 'Cancel',

        [Parameter()]
        [AllowNull()]
        [string[]] $Click,

        [Parameter()]
        [AllowNull()]
        [hashtable] $Value,

        [Parameter()]
        [AllowNull()]
        [object] $Journal
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # @($null) IS AN ARRAY OF ONE NULL, NOT AN EMPTY ARRAY. Left alone, a fake
    # built with no -Click replays one press of the empty string, and the
    # navigator's ValidateSet refuses it - so every test that never meant to
    # click anything fails inside the fake. Filtered here rather than in the
    # method, so there is one place the list is a list.
    $press = @(@($Click) | Where-Object { -not [string]::IsNullOrEmpty($_) })

    $bag = $Value
    if ($null -eq $bag) { $bag = @{} }

    $service = [pscustomobject] @{
        Action         = $Action
        Click          = $press
        Value          = $bag
        Operations     = (New-Object -TypeName System.Collections.ArrayList)
        Journal        = $Journal
        LastXaml       = ''
        LastShellXaml  = ''
        LastThemeXaml  = ''
        LastTitle      = ''
        LastField      = @()
        LastPane       = @()
        LastState      = $null
        LastCommandPrompt = $null
        Visited        = (New-Object -TypeName System.Collections.ArrayList)
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation)

        [void] $this.Operations.Add($Operation)
        if ($null -ne $this.Journal) { [void] $this.Journal.Add($Operation) }
    }

    $service | Add-Member -MemberType ScriptMethod -Name Show -Value {
        param([string] $Xaml, [string] $Title, [object[]] $Field, [object[]] $Pane)

        $this.LastXaml = $Xaml
        $this.LastTitle = $Title
        $this.LastField = @($Field)
        $this.LastPane = @($Pane)
        $this.Record(('Show({0})' -f $Title))

        return $this.Action
    }

    # THE SHELL, WALKED. The real host opens ONE window and swaps the page
    # inside it; this opens nothing and swaps nothing, but it takes the same
    # arguments and calls the SAME navigator, so what is asserted here is the
    # navigation the real host will perform rather than a paraphrase of it.
    $service | Add-Member -MemberType ScriptMethod -Name ShowShell -Value {
        param(
            [string] $ShellXaml,
            [string] $ThemeXaml,
            [string] $Title,
            [object] $State,
            [object[]] $Field,
            [object[]] $Pane,
            [scriptblock] $Navigator,
            [scriptblock] $CommandPrompt)

        $this.LastShellXaml = $ShellXaml
        $this.LastThemeXaml = $ThemeXaml
        $this.LastTitle = $Title
        $this.LastState = $State
        $this.LastField = @($Field)
        $this.LastPane = @($Pane)
        $this.LastCommandPrompt = $CommandPrompt
        $this.Record(('ShowShell({0})' -f $Title))

        $current = $State
        [void] $this.Visited.Add([string] $current.Page.Id)

        foreach ($press in @($this.Click)) {

            # Cancel and Open CMD never reach the navigator - they are not
            # navigation, they are the technician leaving.
            if ($press -eq 'Cancel' -or $press -eq 'CommandPrompt') {
                $this.Record(('press {0}' -f $press))
                return $press
            }

            # F8 IS NOT LEAVING EITHER, and that is the point of replaying it.
            # MDT's F8 puts a prompt on top of the wizard; the technician closes
            # it and is still on the same page. So the loop does not return, the
            # navigator is not called, and the page does not change.
            if ($press -eq 'F8') {
                $this.Record('press F8')
                if ($null -ne $CommandPrompt) { & $CommandPrompt }
                continue
            }

            # THE COLLECTED VALUES GO WITH EVERY MOVE. The real host reads them
            # off the page it is leaving; this fake has no controls, so a test
            # seeds them with -Value. The summary page is built from them, so a
            # fake that passed nothing could never exercise it.
            $current = & $Navigator $current.Index $press $this.Value

            # THE LATEST STATE, NOT THE FIRST. LastState used to be written once
            # on entry, so a test could only ever assert what the wizard opened
            # with - and anything a later page carries, the summary rows above
            # all, was invisible to every assertion.
            $this.LastState = $current

            if ($current.Done) {
                $this.Record('press Next -> Done')
                return 'Next'
            }

            $this.Record(('press {0} -> {1}' -f $press, [string] $current.Page.Id))
            [void] $this.Visited.Add([string] $current.Page.Id)
        }

        # RAN OUT OF CLICKS. The technician is still standing in front of the
        # window; -Action is what they did next, including nothing at all.
        return $this.Action
    }

    return $service
}

function New-HDTFakeProgressHost {
    <#
        .SYNOPSIS
            Creates an IProgressHost that draws nothing and records what it was
            asked to draw.

        .DESCRIPTION
            The hand-written double behind the progress window (DESIGN 12.2.3:
            fake, don't mock). New-HDTProgressHost is the real one and is a
            branch-free WPF adapter, so it is not unit tested; this is what lets
            Start-HDTProgressDisplay's DECISIONS - suppress, draw, or fall back
            to the console - be asserted with no display attached.

            -FailOpen IS THE ONE THAT MATTERS. DESIGN 11.1 requires the console
            fallback to be exercised by a test "because the fallback is exactly
            the path nobody exercises until the night it matters", and a boot
            image built without WinPE-NetFx has no PresentationFramework at all:
            Add-Type throws where a window should have opened. This is that
            machine, on a developer's desktop.

        .PARAMETER FailOpen
            Throw from Open, the way a machine with no WPF does.

        .PARAMETER Journal
            The shared cross-service operation journal.

        .OUTPUTS
            A PSCustomObject with Open, Update and Close methods, an Operations
            list, LastXaml and LastProgress.

        .EXAMPLE
            Start-HDTProgressDisplay -XamlPath $p -DisplayHost (New-HDTFakeProgressHost -FailOpen)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory test double; it changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [switch] $FailOpen,

        [Parameter()]
        [AllowNull()]
        [object] $Journal
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        FailOpen     = [bool] $FailOpen
        Operations   = (New-Object -TypeName System.Collections.ArrayList)
        Journal      = $Journal
        LastXaml     = ''
        LastCommandPromptPath = ''
        LastProgress = $null
        IsOpen       = $false
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation)

        [void] $this.Operations.Add($Operation)
        if ($null -ne $this.Journal) { [void] $this.Journal.Add($Operation) }
    }

    $service | Add-Member -MemberType ScriptMethod -Name Open -Value {
        param([string] $Xaml, [string] $CommandPromptPath)

        $this.LastCommandPromptPath = $CommandPromptPath

        if ($this.FailOpen) {
            # WHAT A MACHINE WITH NO WPF ACTUALLY DOES. Add-Type throws this
            # shape when PresentationFramework is not there to load.
            throw [System.IO.FileNotFoundException]::new(
                "Could not load file or assembly 'PresentationFramework'.")
        }

        $this.LastXaml = $Xaml
        $this.IsOpen = $true
        $this.Record('Open')
    }

    $service | Add-Member -MemberType ScriptMethod -Name Update -Value {
        param([object] $Progress)

        $this.LastProgress = $Progress
        $this.Record('Update')
    }

    $service | Add-Member -MemberType ScriptMethod -Name Close -Value {
        $this.IsOpen = $false
        $this.Record('Close')
    }

    return $service
}

Export-ModuleMember -Function @(
    'New-HDTFakeProgressHost',
    'New-HDTFakeBootImageService',
    'New-HDTFakeWizardHost',
    'New-HDTFakeCimProvider',
    'New-HDTFakeClock',
    'New-HDTFakeContentProvider',
    'New-HDTFakeDiskService',
    'New-HDTFakeFeatureService',
    'New-HDTFakeEnvironmentProvider',
    'New-HDTFakeFileSystem',
    'New-HDTFakeImageService',
    'New-HDTFakeLsaService',
    'New-HDTFakePowerService',
    'New-HDTFakeProcessService',
    'New-HDTFakeRandomNumberGenerator',
    'New-HDTFakeRegistryService',
    'New-HDTFakeScreen',
    'New-HDTFakeScriptInvoker',
    'New-HDTFakeSmbService',
    'New-HDTFakeWdsService'
)
