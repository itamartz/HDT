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

        $this.AddFile($full, $Content)
    }

    [void] AppendAllText([string] $Path, [string] $Content) {
        $this.Record('AppendAllText', @($Path, $Content))
        $full = $this.Normalize($Path)

        if ($this.Directory.ContainsKey($full)) {
            throw [System.UnauthorizedAccessException]::new("Access to the path '$full' is denied: it is a directory.")
        }

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

            It implements the nine IFileSystem methods - TestPath, ReadAllText,
            WriteAllText, AppendAllText, CreateDirectory, RemoveItem, CopyItem,
            GetChildItem, GetLength - and throws the same exception types the real
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
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeFileSystem]::new()
    $fake.Journal = $Journal

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

class HDTFakeProcessService {

    # Normalised command line -> the result Start returns.
    [hashtable] $Result

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
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $fake = [HDTFakeProcessService]::new()
    $fake.Journal = $Journal

    if ($PSBoundParameters.ContainsKey('Result')) {
        foreach ($commandLine in @($Result.Keys)) {
            $fake.SetResult([string] $commandLine, $Result[$commandLine])
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

Export-ModuleMember -Function @(
    'New-HDTFakeCimProvider',
    'New-HDTFakeClock',
    'New-HDTFakeEnvironmentProvider',
    'New-HDTFakeFileSystem',
    'New-HDTFakeLsaService',
    'New-HDTFakePowerService',
    'New-HDTFakeProcessService',
    'New-HDTFakeRandomNumberGenerator',
    'New-HDTFakeRegistryService',
    'New-HDTFakeScriptInvoker'
)
