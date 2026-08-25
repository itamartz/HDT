# Authoring a selection profile: New, Set, Remove and the save that writes them.
#
# THEY SPLICE, THEY DO NOT RE-SERIALISE. Parsing a document and writing it back
# loses every comment in it, and Control\selection-profiles.yaml is a file an
# administrator explains their fleet in - "the HP pack is the G11 one, the G10
# needs the old driver". Each of these returns LINES; Save- is the only thing
# that touches the share.
#
# THE EMPTY DOCUMENT IS A CASE, NOT AN ERROR. New-HDTWorkspace writes no
# selection-profiles.yaml, because a share with no profile is a share that uses
# the built-ins - so the first profile anybody authors has to be able to create
# the file it goes in.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:documentPath = 'C:\HDTLab\Share\Control\selection-profiles.yaml'

    # A document with a comment in it, which is the thing a re-serialising editor
    # would silently throw away.
    $script:existing = [string[]] @(
        '# The profiles this share deploys from.'
        'schemaVersion: 1'
        'profiles:'
        '  # Both vendor packs, because the floor is mixed.'
        '  - id: boot-critical'
        '    name: Boot critical - Dell and HP'
        '    include:'
        '      - Drivers\WinPE\Dell WinPE 11 x64'
        '      - Drivers\WinPE\HP WinPE 11 x64'
        '  - id: dell-full'
        '    name: Dell full model packs'
        '    include:'
        '      - Drivers\Dell'
    )

    # The lines, parsed, so a test asserts about the DOCUMENT rather than about
    # the exact spelling of the block that produced it.
    function Get-HDTTestProfileDocument {
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]] $Line)

        $module = Get-Module -Name Hephaestus
        return & $module {
            param($Text, $Path)
            ConvertFrom-HDTYaml -Yaml $Text -Path $Path
        } ($Line -join "`r`n") $script:documentPath
    }
}

Describe 'New-HDTSelectionProfile' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'New-HDTSelectionProfile' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    # THE FIRST PROFILE ON A SHARE HAS NO FILE TO GO IN. Refusing here would mean
    # an administrator has to hand-write a document before the console can write
    # one, which is the opposite of what the console is for.
    It 'writes a whole document when there is none yet' {
        $line = New-HDTSelectionProfile -Line ([string[]] @()) -Id 'hp-winpe' `
            -Name 'HP WinPE 11 x64' -Include 'Drivers\WinPE\HP WinPE 11 x64'

        $document = Get-HDTTestProfileDocument -Line $line

        $document['schemaVersion'] | Should -Be 1
        @($document['profiles']).Count | Should -Be 1
        [string] @($document['profiles'])[0]['id'] | Should -BeExactly 'hp-winpe'
    }

    It 'appends to a document that already has profiles' {
        $line = New-HDTSelectionProfile -Line $script:existing -Id 'hp-winpe' `
            -Name 'HP WinPE 11 x64' -Include 'Drivers\WinPE\HP WinPE 11 x64'

        $document = Get-HDTTestProfileDocument -Line $line

        @($document['profiles'] | ForEach-Object { [string] $_['id'] }) |
            Should -Be @('boot-critical', 'dell-full', 'hp-winpe')
    }

    It 'leaves every comment in the document it appended to' {
        $line = New-HDTSelectionProfile -Line $script:existing -Id 'hp-winpe' `
            -Name 'HP WinPE 11 x64' -Include 'Drivers\WinPE\HP WinPE 11 x64'

        $line | Should -Contain '# The profiles this share deploys from.'
        $line | Should -Contain '  # Both vendor packs, because the floor is mixed.'
    }

    It 'carries both vendor packs onto one new profile, in the order given' {
        $line = New-HDTSelectionProfile -Line ([string[]] @()) -Id 'both' -Name 'Both' `
            -Include 'Drivers\WinPE\Dell WinPE 11 x64', 'Drivers\WinPE\HP WinPE 11 x64'

        $document = Get-HDTTestProfileDocument -Line $line

        @(@($document['profiles'])[0]['include'] | ForEach-Object { [string] $_ }) |
            Should -Be @('Drivers\WinPE\Dell WinPE 11 x64', 'Drivers\WinPE\HP WinPE 11 x64')
    }

    It 'accepts a profile that includes nothing yet' {
        $line = New-HDTSelectionProfile -Line ([string[]] @()) -Id 'empty' -Name 'Not filled in yet'

        $document = Get-HDTTestProfileDocument -Line $line

        @($document['profiles'])[0]['include'] | Should -BeNullOrEmpty
    }

    It 'refuses an id the document already declares' {
        $record = $null
        try {
            New-HDTSelectionProfile -Line $script:existing -Id 'boot-critical' -Name 'Again' | Out-Null
        } catch { $record = $_ }

        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'refuses an id a built-in owns' {
        $record = $null
        try {
            New-HDTSelectionProfile -Line ([string[]] @()) -Id 'everything' -Name 'Mine' | Out-Null
        } catch { $record = $_ }

        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    # A PROFILE NAMES FOLDERS THAT EXIST. The console's tree offers only folders
    # the share actually has, so a profile written through the window cannot name
    # one that does not - and a command that let somebody type one anyway would
    # be the weaker door, and would put a boot image on a bench with a vendor's
    # drivers silently absent.
    It 'refuses a folder that is not on the share when it is given one' {
        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Drivers\WinPE\Dell WinPE 11 x64\e.inf' = '[Version]'
        }

        $record = $null
        try {
            New-HDTSelectionProfile -Line ([string[]] @()) -Id 'stale' -Name 'Stale' `
                -Include 'Drivers\WinPE\HP WinPE 10 x64' `
                -Root 'C:\HDTLab\Share' -FileSystem $fs | Out-Null
        } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        [string] $record.Exception.Message | Should -BeLike '*not a folder on this share*'
    }

    It 'accepts a folder that IS on the share' {
        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Drivers\WinPE\Dell WinPE 11 x64\e.inf' = '[Version]'
        }

        { New-HDTSelectionProfile -Line ([string[]] @()) -Id 'dell' -Name 'Dell' `
                -Include 'Drivers\WinPE\Dell WinPE 11 x64' `
                -Root 'C:\HDTLab\Share' -FileSystem $fs } | Should -Not -Throw
    }

    # WITHOUT -Root THERE IS NOTHING TO CHECK AGAINST, and that is a real case:
    # a profile is legitimately authored on a workstation against a UNC path
    # nobody has mounted. The missing folder is then reported by the Drivers tab
    # and by the build's warning instead.
    It 'checks nothing when no share was named' {
        { New-HDTSelectionProfile -Line ([string[]] @()) -Id 'offline' -Name 'Offline' `
                -Include 'Drivers\WinPE\HP WinPE 10 x64' } | Should -Not -Throw
    }

    # THE TRAVERSAL IS REFUSED AT THE POINT IT IS TYPED, not only at load. A
    # console that writes the document and then reports it unreadable has left a
    # broken file on the share.
    It 'refuses an include that climbs out of the share' {
        $record = $null
        try {
            New-HDTSelectionProfile -Line ([string[]] @()) -Id 'escape' -Name 'Escape' `
                -Include 'Drivers\..\..\Windows\System32' | Out-Null
        } catch { $record = $_ }

        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }
}

Describe 'Set-HDTSelectionProfile' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Set-HDTSelectionProfile' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'replaces the include list of the profile it names' {
        $line = Set-HDTSelectionProfile -Line $script:existing -Id 'boot-critical' `
            -Include 'Drivers\WinPE\HP WinPE 11 x64'

        $document = Get-HDTTestProfileDocument -Line $line
        $entry = @($document['profiles'] | Where-Object { [string] $_['id'] -eq 'boot-critical' })[0]

        @($entry['include'] | ForEach-Object { [string] $_ }) |
            Should -Be @('Drivers\WinPE\HP WinPE 11 x64')
    }

    It 'renames a profile without touching what it includes' {
        $line = Set-HDTSelectionProfile -Line $script:existing -Id 'boot-critical' -Name 'WinPE - both vendors'

        $document = Get-HDTTestProfileDocument -Line $line
        $entry = @($document['profiles'] | Where-Object { [string] $_['id'] -eq 'boot-critical' })[0]

        [string] $entry['name'] | Should -BeExactly 'WinPE - both vendors'
        @($entry['include']).Count | Should -Be 2
    }

    It 'leaves the profiles either side of it alone' {
        $line = Set-HDTSelectionProfile -Line $script:existing -Id 'boot-critical' -Name 'Renamed'

        $document = Get-HDTTestProfileDocument -Line $line
        $other = @($document['profiles'] | Where-Object { [string] $_['id'] -eq 'dell-full' })[0]

        [string] $other['name'] | Should -BeExactly 'Dell full model packs'
        $line | Should -Contain '# The profiles this share deploys from.'
    }

    It 'empties a profile when handed an empty include list' {
        $line = Set-HDTSelectionProfile -Line $script:existing -Id 'boot-critical' -Include ([string[]] @())

        $document = Get-HDTTestProfileDocument -Line $line
        $entry = @($document['profiles'] | Where-Object { [string] $_['id'] -eq 'boot-critical' })[0]

        $entry['include'] | Should -BeNullOrEmpty
    }

    It 'refuses an id the document does not declare' {
        $record = $null
        try { Set-HDTSelectionProfile -Line $script:existing -Id 'no-such' -Name 'x' | Out-Null }
        catch { $record = $_ }

        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    # A BUILT-IN HAS NO LINES TO EDIT. Answering "it is not in the document"
    # would be true and useless; this says which thing it actually is.
    It 'refuses a built-in, and says that is what it is' {
        $record = $null
        try { Set-HDTSelectionProfile -Line $script:existing -Id 'all-drivers' -Name 'x' | Out-Null }
        catch { $record = $_ }

        [string] $record.Exception.Message | Should -BeLike '*built-in*'
    }
}

Describe 'Remove-HDTSelectionProfile' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Remove-HDTSelectionProfile' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'takes the profile out and leaves the other one' {
        $line = Remove-HDTSelectionProfile -Line $script:existing -Id 'boot-critical' -Confirm:$false

        $document = Get-HDTTestProfileDocument -Line $line

        @($document['profiles'] | ForEach-Object { [string] $_['id'] }) | Should -Be @('dell-full')
    }

    It 'takes the whole block, not just the id line' {
        $line = Remove-HDTSelectionProfile -Line $script:existing -Id 'boot-critical' -Confirm:$false

        $line | Should -Not -Contain '      - Drivers\WinPE\Dell WinPE 11 x64'
        $line | Should -Not -Contain '    name: Boot critical - Dell and HP'
    }

    # AN EMPTY profiles: PARSES AS A NULL AND THE VALIDATOR REFUSES THE HUSK, so
    # removing the last profile has to leave a list, not a bare key.
    It 'leaves a readable document after the last profile goes' {
        $line = Remove-HDTSelectionProfile -Line $script:existing -Id 'boot-critical' -Confirm:$false
        $line = Remove-HDTSelectionProfile -Line $line -Id 'dell-full' -Confirm:$false

        $module = Get-Module -Name Hephaestus
        { & $module {
                param($Text, $Path)
                Assert-HDTSelectionProfileDocument -Document (ConvertFrom-HDTYaml -Yaml $Text -Path $Path) -Path $Path
            } ($line -join "`r`n") $script:documentPath } | Should -Not -Throw
    }

    It 'refuses an id the document does not declare' {
        $record = $null
        try { Remove-HDTSelectionProfile -Line $script:existing -Id 'no-such' -Confirm:$false | Out-Null }
        catch { $record = $_ }

        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'supports ShouldProcess, because it destroys authored configuration' {
        (Get-Command -Name 'Remove-HDTSelectionProfile').Parameters.ContainsKey('WhatIf') |
            Should -BeTrue
    }

    It 'changes nothing under -WhatIf' {
        $line = Remove-HDTSelectionProfile -Line $script:existing -Id 'boot-critical' -WhatIf

        $line | Should -Be $script:existing
    }
}

Describe 'Save-HDTSelectionProfileDocument' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Save-HDTSelectionProfileDocument' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'writes the lines it was handed' {
        $fs = New-HDTFakeFileSystem
        $line = New-HDTSelectionProfile -Line ([string[]] @()) -Id 'hp-winpe' -Name 'HP WinPE 11 x64' `
            -Include 'Drivers\WinPE\HP WinPE 11 x64'

        $result = Save-HDTSelectionProfileDocument -Path $script:documentPath -Line $line -FileSystem $fs

        $result.Saved | Should -BeTrue
        $fs.ReadAllText($script:documentPath) | Should -BeLike '*hp-winpe*'
    }

    # NOTHING UNREADABLE REACHES THE SHARE. The check parses an in-memory copy at
    # the real path, so the message names the file the administrator is editing.
    It 'refuses to write a document the engine could not read back' {
        $fs = New-HDTFakeFileSystem
        $broken = [string[]] @('schemaVersion: 1', 'profiles:', '  - id: no-name')

        $record = $null
        try { Save-HDTSelectionProfileDocument -Path $script:documentPath -Line $broken -FileSystem $fs | Out-Null }
        catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $fs.TestPath($script:documentPath) | Should -BeFalse
    }
}
