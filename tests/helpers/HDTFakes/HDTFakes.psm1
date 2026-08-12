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

    HDTFakeFileSystem() {
        $this.File = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Directory = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Operations = [System.Collections.ArrayList]::new()
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })
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

            It implements the eight IFileSystem methods - TestPath, ReadAllText,
            WriteAllText, CreateDirectory, RemoveItem, CopyItem, GetChildItem,
            GetLength - and throws the same exception types a real adapter throws,
            so tests assert on the type rather than on a message.

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
        [string[]] $Directory
    )

    $fake = [HDTFakeFileSystem]::new()

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

    HDTFakeCimProvider() {
        $this.Instance = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Operations = [System.Collections.ArrayList]::new()
    }

    # -- recording ---------------------------------------------------------

    hidden [void] Record([string] $Operation, [object[]] $Argument) {
        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })
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
            Win32_BIOS. See tests/fixtures/README.md for the capture and
            sanitisation rules.

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
        [string] $FixturePath
    )

    $fake = [HDTFakeCimProvider]::new()

    if ($PSBoundParameters.ContainsKey('FixturePath')) {
        if (-not (Test-Path -LiteralPath $FixturePath -PathType Container)) {
            throw "FixturePath '$FixturePath' does not exist or is not a directory."
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $FixturePath -Filter '*.json' -File)) {
            $text = Get-Content -LiteralPath $file.FullName -Raw

            # Never -AsHashtable: it is PowerShell 6+ only and banned outright.
            $content = ConvertFrom-Json -InputObject $text

            $fake.AddInstance('root/cimv2', $file.BaseName, [object[]] @($content))
        }
    }

    if ($PSBoundParameters.ContainsKey('Instance')) {
        foreach ($key in @($Instance.Keys)) {
            $fake.AddInstance($Namespace, [string] $key, [object[]] @($Instance[$key]))
        }
    }

    return $fake
}

Export-ModuleMember -Function @('New-HDTFakeCimProvider', 'New-HDTFakeFileSystem')
