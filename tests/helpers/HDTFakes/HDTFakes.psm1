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
            Win32_BIOS. Subdirectories are ignored - a second namespace is a
            second directory named by -NamespaceFixturePath, not a nested folder.
            See tests/fixtures/README.md for the capture and sanitisation rules.

        .PARAMETER NamespaceFixturePath
            Additional fixture directories, keyed by the namespace they seed.
            Each directory is loaded exactly as -FixturePath is, but into that
            namespace, so tests/fixtures/cim-microsofttpm/Win32_Tpm.json becomes
            Win32_Tpm in root/cimv2/security/microsofttpm. A missing directory
            throws, naming it.

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
        [hashtable] $NamespaceFixturePath
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

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    HDTFakeRegistryService() {
        $this.Key = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
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

    [void] SetValue([string] $Path, [string] $Name, [object] $Value) {
        $full = $this.Normalize($Path)

        if (-not $this.Key.ContainsKey($full)) {
            $this.Key[$full] = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        }

        $this.Key[$full][$Name] = $Value
    }

    [void] AddKey([string] $Path) {
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
            whether by this factory or by SetValue, is deliberately not recorded.

        .PARAMETER Value
            Seed keys and values. Keys are registry paths, values are hashtables
            of value name to value. An empty hashtable seeds a key that exists
            and holds nothing, which is a different fact from a key that does not
            exist.

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
        [hashtable] $Value
    )

    $fake = [HDTFakeRegistryService]::new()

    if ($PSBoundParameters.ContainsKey('Value')) {
        foreach ($path in @($Value.Keys)) {
            $fake.AddKey([string] $path)

            $entry = $Value[$path]
            foreach ($name in @($entry.Keys)) {
                $fake.SetValue([string] $path, [string] $name, $entry[$name])
            }
        }
    }

    return $fake
}

class HDTFakeEnvironmentProvider {

    # Variable name -> value. Case-insensitive, matching Windows semantics.
    [hashtable] $Variable

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    HDTFakeEnvironmentProvider() {
        $this.Variable = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
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
        [hashtable] $Variable
    )

    $fake = [HDTFakeEnvironmentProvider]::new()

    if ($PSBoundParameters.ContainsKey('Variable')) {
        foreach ($name in @($Variable.Keys)) {
            $fake.SetVariable([string] $name, [string] $Variable[$name])
        }
    }

    return $fake
}

class HDTFakeScriptInvoker {

    # Normalised script path -> the object Invoke returns. A path present with a
    # $null value means "the script ran and emitted nothing".
    [hashtable] $Result

    # One [pscustomobject] per call: Sequence (1-based), Operation, Arguments.
    [System.Collections.ArrayList] $Operations

    HDTFakeScriptInvoker() {
        $this.Result = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
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

    # -- IScriptInvoker ----------------------------------------------------

    [object] Invoke([string] $Path, [System.Collections.IDictionary] $Variable) {
        $this.Record('Invoke', @($Path, $Variable))
        $full = $this.Normalize($Path)

        # A path that was never seeded is a script that does not exist, and the
        # real adapter throws exactly this for it.
        if (-not $this.Result.ContainsKey($full)) {
            throw [System.IO.FileNotFoundException]::new("Could not find script '$Path'.", $Path)
        }

        return $this.Result[$full]
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
        [hashtable] $Result
    )

    $fake = [HDTFakeScriptInvoker]::new()

    if ($PSBoundParameters.ContainsKey('Result')) {
        foreach ($path in @($Result.Keys)) {
            $fake.SetResult([string] $path, $Result[$path])
        }
    }

    return $fake
}

Export-ModuleMember -Function @(
    'New-HDTFakeCimProvider',
    'New-HDTFakeEnvironmentProvider',
    'New-HDTFakeFileSystem',
    'New-HDTFakeRegistryService',
    'New-HDTFakeScriptInvoker'
)
