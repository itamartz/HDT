# Selection profiles - the named sets of share folders a boot image, a driver
# step and standalone media all point at.
#
# THIS IS MDT'S SELECTION PROFILE, KEPT. A driver group was one folder, and one
# folder cannot describe a mixed floor: a share carrying a Dell WinPE pack and an
# HP WinPE pack needs ONE boot image that sees both, and 'drivers: <folder>' has
# no way to say so. MDT answered that with a named set of include paths saved
# once in Control\SelectionProfiles.xml and reused everywhere, and this is the
# same idea in the format the rest of HDT is authored in.
#
# THE INCLUDE PATHS ARE THE SECURITY BOUNDARY, and most of what is asserted here
# is about refusing them. An include becomes a folder under the share that
# Add-WindowsDriver is pointed at with -Recurse; a rooted path or a '..' segment
# in one is a directory traversal that projects whatever it reaches into a boot
# image that gets transferred to every machine that PXE boots.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\HDTLab\Share'
    $script:documentPath = 'C:\HDTLab\Share\Control\selection-profiles.yaml'

    # The share the pictures were drawn from: two vendor WinPE packs, and the
    # full model packs that must NOT follow them into the boot image.
    $script:twoVendorYaml = @(
        'schemaVersion: 1'
        'profiles:'
        '  - id: boot-critical'
        '    name: Boot critical - Dell and HP'
        '    include:'
        '      - Drivers\WinPE\Dell WinPE 11 x64'
        '      - Drivers\WinPE\HP WinPE 11 x64'
        '  - id: dell-winpe'
        '    name: Dell WinPE 11 x64'
        '    include:'
        '      - Drivers\WinPE\Dell WinPE 11 x64'
    ) -join "`r`n"

    function New-HDTTestProfileFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter()] [string] $Yaml = $script:twoVendorYaml)

        return New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Control\selection-profiles.yaml'                  = $Yaml
            'C:\HDTLab\Share\Drivers\WinPE\Dell WinPE 11 x64\e1d68x64.inf'     = '[Version]'
            'C:\HDTLab\Share\Drivers\WinPE\HP WinPE 11 x64\stornvme.inf'       = '[Version]'
            'C:\HDTLab\Share\Drivers\Dell\Latitude 7450\wifi.inf'              = '[Version]'
        }
    }
}

Describe 'Get-HDTSelectionProfile' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTSelectionProfile' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'reads the profiles the document declares' {
        $fs = New-HDTTestProfileFileSystem

        $authored = @(Get-HDTSelectionProfile -Root $script:root -FileSystem $fs |
                Where-Object { -not $_.IsBuiltIn })

        @($authored | ForEach-Object { $_.Id }) | Should -Be @('boot-critical', 'dell-winpe')
    }

    It 'carries both vendor packs on the one profile' {
        $fs = New-HDTTestProfileFileSystem

        $boot = Get-HDTSelectionProfile -Root $script:root -Id 'boot-critical' -FileSystem $fs

        $boot.Include | Should -Be @('Drivers\WinPE\Dell WinPE 11 x64', 'Drivers\WinPE\HP WinPE 11 x64')
        $boot.Name | Should -BeExactly 'Boot critical - Dell and HP'
    }

    # THE BUILT-INS NEED NO DOCUMENT. MDT ships Everything, All Drivers and
    # Nothing, and a share that has never had a profile authored still has to
    # give the boot image's picker something legal to point at.
    It 'answers with the built-ins on a share with no document at all' {
        $fs = New-HDTFakeFileSystem

        $builtIn = @(Get-HDTSelectionProfile -Root $script:root -FileSystem $fs)

        @($builtIn | ForEach-Object { $_.Id }) | Should -Be @('all-drivers', 'everything', 'nothing')
        @($builtIn | Where-Object { -not $_.IsBuiltIn }) | Should -BeNullOrEmpty
    }

    It 'gives Nothing an empty include list rather than no list' {
        $fs = New-HDTFakeFileSystem

        $none = Get-HDTSelectionProfile -Root $script:root -Id 'nothing' -FileSystem $fs

        $none.Include | Should -BeNullOrEmpty
        $none.IsBuiltIn | Should -BeTrue
    }

    It 'sorts every profile by name, built in or not' {
        $fs = New-HDTTestProfileFileSystem

        $name = @(Get-HDTSelectionProfile -Root $script:root -FileSystem $fs | ForEach-Object { $_.Name })

        $name | Should -Be @($name | Sort-Object)
    }

    It 'refuses an id that is in neither the document nor the built-ins' {
        $fs = New-HDTTestProfileFileSystem

        $record = $null
        try { Get-HDTSelectionProfile -Root $script:root -Id 'no-such-profile' -FileSystem $fs }
        catch { $record = $_ }

        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'

        # AND IT SAYS WHAT THE SHARE DOES HAVE. A refusal that only says "no"
        # leaves an administrator guessing at a name they half remember.
        [string] $record.Exception.Message | Should -BeLike '*boot-critical*'
    }
}

Describe 'Assert-HDTSelectionProfileDocument' {

    BeforeAll {
        # The private validator, reached the way the other document tests reach
        # theirs. It is what runs in WinPE; the JSON Schema is the console's gate.
        $script:assert = {
            param([string] $Yaml)

            $module = Get-Module -Name Hephaestus
            & $module {
                param($Text, $Path)
                Assert-HDTSelectionProfileDocument -Document (ConvertFrom-HDTYaml -Yaml $Text -Path $Path) -Path $Path
            } $Yaml $script:documentPath
        }

        # THE RECORD, NOT THE THROW. Reached through a module script block the
        # error id arrives qualified with the function name -
        # 'HDTConfigurationError,Assert-HDTSelectionProfileDocument' - so this
        # matches on the prefix, as every other document validator's tests do.
        $script:assertFails = {
            param([string] $Yaml)

            try {
                & $script:assert $Yaml
                return $null
            } catch {
                return $_
            }
        }
    }

    It 'accepts the two-vendor document' {
        { & $script:assert $script:twoVendorYaml } | Should -Not -Throw
    }

    It 'refuses an include that climbs out of the share' {
        $yaml = @(
            'schemaVersion: 1'
            'profiles:'
            '  - id: escape'
            '    name: Escape'
            '    include:'
            '      - Drivers\..\..\Windows\System32'
        ) -join "`r`n"

        (& $script:assertFails $yaml).FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'refuses an include that is a rooted path' {
        $yaml = @(
            'schemaVersion: 1'
            'profiles:'
            '  - id: rooted'
            '    name: Rooted'
            '    include:'
            '      - C:\Windows\System32\DriverStore'
        ) -join "`r`n"

        (& $script:assertFails $yaml).FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'refuses an include whose first segment is not a workspace folder' {
        $yaml = @(
            'schemaVersion: 1'
            'profiles:'
            '  - id: stray'
            '    name: Stray'
            '    include:'
            '      - Downloads\drivers'
        ) -join "`r`n"

        (& $script:assertFails $yaml).FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    # A RESERVED ID IS REFUSED RATHER THAN SHADOWED. An authored profile called
    # all-drivers either wins or loses against the built-in, and both answers are
    # a share where the name on the boot image tab does not mean what it says.
    It 'refuses an id a built-in already owns' {
        $yaml = @(
            'schemaVersion: 1'
            'profiles:'
            '  - id: all-drivers'
            '    name: Mine'
            '    include:'
            '      - Drivers'
        ) -join "`r`n"

        (& $script:assertFails $yaml).FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'refuses the same id declared twice' {
        $yaml = @(
            'schemaVersion: 1'
            'profiles:'
            '  - id: twice'
            '    name: First'
            '    include:'
            '      - Drivers'
            '  - id: twice'
            '    name: Second'
            '    include:'
            '      - Applications'
        ) -join "`r`n"

        (& $script:assertFails $yaml).FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'refuses a profile with no name' {
        $yaml = @(
            'schemaVersion: 1'
            'profiles:'
            '  - id: nameless'
            '    include:'
            '      - Drivers'
        ) -join "`r`n"

        (& $script:assertFails $yaml).FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'refuses a key the document may not declare' {
        $yaml = @(
            'schemaVersion: 1'
            'profiles: []'
            'selectionProfiles: []'
        ) -join "`r`n"

        (& $script:assertFails $yaml).FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'refuses a schemaVersion this engine does not understand' {
        $yaml = @(
            'schemaVersion: 99'
            'profiles: []'
        ) -join "`r`n"

        (& $script:assertFails $yaml).FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    # AN EMPTY include IS LEGAL AND MEANS NOTHING IS INCLUDED, which is exactly
    # what MDT's Nothing profile is for. A profile being built up over an
    # afternoon must not be a document the engine refuses to load.
    It 'accepts a profile that includes nothing yet' {
        $yaml = @(
            'schemaVersion: 1'
            'profiles:'
            '  - id: empty'
            '    name: Not filled in yet'
            '    include: []'
        ) -join "`r`n"

        { & $script:assert $yaml } | Should -Not -Throw
    }
}

Describe 'Expand-HDTSelectionProfile' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Expand-HDTSelectionProfile' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'resolves both vendor packs to folders on the share, in declared order' {
        $fs = New-HDTTestProfileFileSystem

        $folder = @(Expand-HDTSelectionProfile -Root $script:root -Id 'boot-critical' -FileSystem $fs)

        @($folder | ForEach-Object { $_.FullPath }) | Should -Be @(
            'C:\HDTLab\Share\Drivers\WinPE\Dell WinPE 11 x64'
            'C:\HDTLab\Share\Drivers\WinPE\HP WinPE 11 x64'
        )
    }

    # A RENAMED FOLDER COMES BACK AS MISSING RATHER THAN AS NOTHING. Dropping it
    # silently is how a boot image gets built with one vendor's drivers in it and
    # nobody finds out until an HP laptop cannot see its disk.
    It 'reports an include that is not on the share rather than dropping it' {
        $yaml = @(
            'schemaVersion: 1'
            'profiles:'
            '  - id: stale'
            '    name: Stale'
            '    include:'
            '      - Drivers\WinPE\Dell WinPE 11 x64'
            '      - Drivers\WinPE\HP WinPE 10 x64'
        ) -join "`r`n"

        $fs = New-HDTTestProfileFileSystem -Yaml $yaml

        $folder = @(Expand-HDTSelectionProfile -Root $script:root -Id 'stale' -FileSystem $fs)

        @($folder).Count | Should -Be 2
        $folder[0].Present | Should -BeTrue
        $folder[1].Present | Should -BeFalse
    }

    It 'expands the All drivers built-in to the Drivers folder' {
        $fs = New-HDTTestProfileFileSystem

        $folder = @(Expand-HDTSelectionProfile -Root $script:root -Id 'all-drivers' -FileSystem $fs)

        @($folder).Count | Should -Be 1
        $folder[0].FullPath | Should -BeExactly 'C:\HDTLab\Share\Drivers'
    }

    It 'expands Nothing to nothing at all' {
        $fs = New-HDTTestProfileFileSystem

        @(Expand-HDTSelectionProfile -Root $script:root -Id 'nothing' -FileSystem $fs) |
            Should -BeNullOrEmpty
    }

    It 'keeps the share-relative path beside the resolved one' {
        $fs = New-HDTTestProfileFileSystem

        $folder = @(Expand-HDTSelectionProfile -Root $script:root -Id 'dell-winpe' -FileSystem $fs)

        $folder[0].Path | Should -BeExactly 'Drivers\WinPE\Dell WinPE 11 x64'
    }
}
