# Which folders a boot image's drivers: key actually names.
#
# THE KEY CHANGED MEANING AND OLD SHARES MUST NOT BREAK. It used to be one
# folder under Drivers\; it is now a selection profile id, which can name two
# vendor packs at once. A share written before profiles existed still says
# 'drivers: winpe-nic' and still means the folder - so the resolver tries the
# profile first and falls back to the folder, and neither answer needs an
# administrator to migrate anything.
#
# A NAME THAT IS NEITHER STILL WARNS AND STILL BUILDS. A boot image build must
# not be blocked by a folder nobody has imported into yet, which is the rule the
# build has had since M4.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\HDTLab\Share'

    $script:profileYaml = @(
        'schemaVersion: 1'
        'profiles:'
        '  - id: boot-critical'
        '    name: Boot critical - Dell and HP'
        '    include:'
        '      - Drivers\WinPE\Dell WinPE 11 x64'
        '      - Drivers\WinPE\HP WinPE 11 x64'
    ) -join "`r`n"

    function New-HDTTestDriverShare {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter()] [switch] $NoDocument)

        $file = @{
            'C:\HDTLab\Share\Drivers\WinPE\Dell WinPE 11 x64\e1d68x64.inf' = '[Version]'
            'C:\HDTLab\Share\Drivers\WinPE\HP WinPE 11 x64\stornvme.inf'   = '[Version]'

            # The old shape: a group that is a folder directly under Drivers\.
            'C:\HDTLab\Share\Drivers\winpe-nic\e1d68x64.inf'               = '[Version]'
        }

        if (-not $NoDocument) {
            $file['C:\HDTLab\Share\Control\selection-profiles.yaml'] = $script:profileYaml
        }

        return New-HDTFakeFileSystem -File $file
    }

    function Invoke-HDTTestResolve {
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Name,
            [Parameter(Mandatory = $true)] [object] $FileSystem
        )

        $module = Get-Module -Name Hephaestus
        return & $module {
            param($Root, $DriverName, $Fs)
            Resolve-HDTBootImageDriverPath -WorkspaceRoot $Root -Name $DriverName -FileSystem $Fs
        } $script:root $Name $FileSystem
    }
}

Describe 'Resolve-HDTBootImageDriverPath' {

    It 'resolves a profile id to every folder it includes' {
        $fs = New-HDTTestDriverShare

        $resolved = Invoke-HDTTestResolve -Name 'boot-critical' -FileSystem $fs

        @($resolved.Path) | Should -Be @(
            'C:\HDTLab\Share\Drivers\WinPE\Dell WinPE 11 x64'
            'C:\HDTLab\Share\Drivers\WinPE\HP WinPE 11 x64'
        )
        $resolved.Kind | Should -BeExactly 'Profile'
    }

    # THE ONE THAT KEEPS EVERY EXISTING SHARE WORKING. 'drivers: winpe-nic' was
    # written against a folder, before a profile was a thing that existed.
    It 'falls back to a folder under Drivers for a share written before profiles' {
        $fs = New-HDTTestDriverShare -NoDocument

        $resolved = Invoke-HDTTestResolve -Name 'winpe-nic' -FileSystem $fs

        @($resolved.Path) | Should -Be @('C:\HDTLab\Share\Drivers\winpe-nic')
        $resolved.Kind | Should -BeExactly 'Folder'
    }

    It 'prefers a profile over a folder of the same name' {
        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Control\selection-profiles.yaml'          = @(
                'schemaVersion: 1'
                'profiles:'
                '  - id: winpe-nic'
                '    name: WinPE network'
                '    include:'
                '      - Drivers\WinPE\HP WinPE 11 x64'
            ) -join "`r`n"
            'C:\HDTLab\Share\Drivers\winpe-nic\old.inf'                = '[Version]'
            'C:\HDTLab\Share\Drivers\WinPE\HP WinPE 11 x64\stor.inf'   = '[Version]'
        }

        $resolved = Invoke-HDTTestResolve -Name 'winpe-nic' -FileSystem $fs

        $resolved.Kind | Should -BeExactly 'Profile'
        @($resolved.Path) | Should -Be @('C:\HDTLab\Share\Drivers\WinPE\HP WinPE 11 x64')
    }

    It 'answers with nothing, and a reason, for a name that is neither' {
        $fs = New-HDTTestDriverShare

        $resolved = Invoke-HDTTestResolve -Name 'no-such-thing' -FileSystem $fs

        @($resolved.Path) | Should -BeNullOrEmpty
        $resolved.Kind | Should -BeExactly 'Missing'
        [string] $resolved.Warning | Should -BeLike '*no-such-thing*'
    }

    # A PROFILE WHOSE FOLDER WAS RENAMED IS THE DANGEROUS CASE: the boot image
    # builds, one vendor's drivers are simply absent, and it is found on a bench.
    It 'drops a folder that is not there but says which one' {
        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Control\selection-profiles.yaml'        = $script:profileYaml
            'C:\HDTLab\Share\Drivers\WinPE\Dell WinPE 11 x64\e.inf' = '[Version]'
        }

        $resolved = Invoke-HDTTestResolve -Name 'boot-critical' -FileSystem $fs

        @($resolved.Path) | Should -Be @('C:\HDTLab\Share\Drivers\WinPE\Dell WinPE 11 x64')
        [string] $resolved.Warning | Should -BeLike '*HP WinPE 11 x64*'
    }

    # A PROFILE THAT INCLUDES NOTHING INJECTS NOTHING, quietly. There is no
    # built-in for this - the picker's empty row is how "no drivers" is said -
    # but a profile somebody is halfway through filling in must not warn.
    It 'answers with nothing at all for a profile that includes nothing' {
        $yaml = @(
            'schemaVersion: 1'
            'profiles:'
            '  - id: empty'
            '    name: Not filled in yet'
            '    include: []'
        ) -join "`r`n"

        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Control\selection-profiles.yaml' = $yaml
            'C:\HDTLab\Share\Drivers\winpe-nic\e.inf'         = '[Version]'
        }

        $resolved = Invoke-HDTTestResolve -Name 'empty' -FileSystem $fs

        @($resolved.Path) | Should -BeNullOrEmpty
        $resolved.Kind | Should -BeExactly 'Profile'
        [string] $resolved.Warning | Should -BeNullOrEmpty
    }

    It 'resolves the All drivers built-in to the whole Drivers folder' {
        $fs = New-HDTTestDriverShare

        $resolved = Invoke-HDTTestResolve -Name 'all-drivers' -FileSystem $fs

        @($resolved.Path) | Should -Be @('C:\HDTLab\Share\Drivers')
    }

    It 'answers with nothing for an empty name, which is what no drivers means' {
        $fs = New-HDTTestDriverShare

        $resolved = Invoke-HDTTestResolve -Name '' -FileSystem $fs

        @($resolved.Path) | Should -BeNullOrEmpty
        $resolved.Kind | Should -BeExactly 'None'
        [string] $resolved.Warning | Should -BeNullOrEmpty
    }

    # A BROKEN DOCUMENT MUST NOT TAKE THE BUILD DOWN WITH IT AT THIS POINT. The
    # build is nine steps in with a WIM mounted; the honest answer is to warn and
    # inject nothing, not to abandon a mounted image.
    It 'warns rather than throwing when the document cannot be read' {
        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDTLab\Share\Control\selection-profiles.yaml' = 'schemaVersion: 1'
            'C:\HDTLab\Share\Drivers\winpe-nic\e1d68x64.inf'  = '[Version]'
        }

        $resolved = Invoke-HDTTestResolve -Name 'winpe-nic' -FileSystem $fs

        @($resolved.Path) | Should -Be @('C:\HDTLab\Share\Drivers\winpe-nic')
        $resolved.Kind | Should -BeExactly 'Folder'
    }
}
