# What the boot image build hands DISM once a driver can be turned off.
#
# THE TICK BOX HAS TO CHANGE WHAT DISM RECEIVES OR IT IS DECORATION.
# Add-WindowsDriver on a folder with -Recurse takes everything in it and there
# is no "except that one" - so a folder holding a disabled driver cannot go in
# as a folder.
#
# AND EVERY OTHER FOLDER STILL GOES IN WHOLE. A vendor pack of forty drivers
# with nothing disabled is ONE call; the same pack with one turned off is
# thirty-nine. Injecting individually always would cost forty calls on every
# share to serve a case most shares never have.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\S'
    $script:store = 'C:\S\Drivers'

    function New-HDTTestDriverRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([string] $Path, [bool] $Enabled = $true)

        return [pscustomobject] @{
            Path = $Path
            FullPath = (Join-Path -Path $script:store -ChildPath $Path)
            Enabled = $Enabled
            InfName = [System.IO.Path]::GetFileName($Path)
        }
    }

    $script:decide = {
        param([string[]] $Folder, [object[]] $Driver)

        $module = Get-Module -Name Hephaestus
        return @(& $module {
                param($F, $D, $R)
                Get-HDTBootImageDriverInjection -Folder $F -Driver $D -Root $R
            } $Folder $Driver $script:root)
    }

    $script:decidePerDriver = {
        param([string[]] $Folder, [object[]] $Driver)

        $module = Get-Module -Name Hephaestus
        return @(& $module {
                param($F, $D, $R)
                Get-HDTBootImageDriverInjection -Folder $F -Driver $D -Root $R -PerDriver
            } $Folder $Driver $script:root)
    }
}

Describe 'Get-HDTBootImageDriverInjection' {

    Context 'nothing disabled' {

        # ONE CALL PER FOLDER, exactly as before any of this existed.
        It 'injects each folder whole' {
            $call = & $script:decide @('C:\S\Drivers\WinPE\Dell', 'C:\S\Drivers\WinPE\HP') @(
                (New-HDTTestDriverRow 'WinPE\Dell\net\a.inf')
                (New-HDTTestDriverRow 'WinPE\Dell\storage\b.inf')
                (New-HDTTestDriverRow 'WinPE\HP\c.inf')
            )

            @($call).Count | Should -Be 2
            @($call | ForEach-Object { $_.Path }) | Should -Be @('C:\S\Drivers\WinPE\Dell', 'C:\S\Drivers\WinPE\HP')
            @($call | Where-Object { -not $_.Recurse }) | Should -BeNullOrEmpty
        }

        # A SHARE WITH NO CATALOG AT ALL is every share before this feature, and
        # the build must behave the way it always did.
        It 'injects each folder whole when there is no catalog' {
            $call = & $script:decide @('C:\S\Drivers\WinPE\Dell') @()

            @($call).Count | Should -Be 1
            $call[0].Recurse | Should -BeTrue
        }

        # A FOLDER WITH NOTHING IN IT IS STILL A FOLDER CALL - a build whose
        # operation list changed shape because a folder happened to be empty
        # would be a build nobody could assert about.
        It 'still calls once for a folder holding no drivers' {
            $call = & $script:decide @('C:\S\Drivers\Empty') @(
                (New-HDTTestDriverRow 'WinPE\Dell\a.inf')
            )

            @($call).Count | Should -Be 1
            $call[0].Path | Should -BeExactly 'C:\S\Drivers\Empty'
            $call[0].Recurse | Should -BeTrue
        }
    }

    Context 'one driver disabled' {

        BeforeAll {
            $script:mixed = & $script:decide @('C:\S\Drivers\WinPE\Dell') @(
                (New-HDTTestDriverRow 'WinPE\Dell\net\a.inf')
                (New-HDTTestDriverRow 'WinPE\Dell\net\bad.inf' $false)
                (New-HDTTestDriverRow 'WinPE\Dell\storage\b.inf')
            )
        }

        # THE WHOLE POINT.
        It 'injects the folder one .inf at a time' {
            @($script:mixed).Count | Should -Be 2
            @($script:mixed | Where-Object { $_.Recurse }) | Should -BeNullOrEmpty
        }

        It 'leaves the disabled driver out' {
            @($script:mixed | ForEach-Object { $_.Path }) |
                Should -Not -Contain 'C:\S\Drivers\WinPE\Dell\net\bad.inf'
        }

        It 'keeps the enabled ones' {
            @($script:mixed | ForEach-Object { $_.Path }) | Should -Be @(
                'C:\S\Drivers\WinPE\Dell\net\a.inf'
                'C:\S\Drivers\WinPE\Dell\storage\b.inf'
            )
        }
    }

    # THE REASON THIS IS DECIDED PER FOLDER. One pack with a problem must not
    # cost the other pack forty calls.
    It 'only splits the folder that has something disabled' {
        $call = & $script:decide @('C:\S\Drivers\WinPE\Dell', 'C:\S\Drivers\WinPE\HP') @(
            (New-HDTTestDriverRow 'WinPE\Dell\a.inf')
            (New-HDTTestDriverRow 'WinPE\Dell\bad.inf' $false)
            (New-HDTTestDriverRow 'WinPE\HP\c.inf')
            (New-HDTTestDriverRow 'WinPE\HP\d.inf')
        )

        @($call | Where-Object { $_.Recurse } | ForEach-Object { $_.Path }) |
            Should -Be @('C:\S\Drivers\WinPE\HP')
        @($call | Where-Object { -not $_.Recurse } | ForEach-Object { $_.Path }) |
            Should -Be @('C:\S\Drivers\WinPE\Dell\a.inf')
    }

    # A DRIVER IN A DIFFERENT FOLDER IS NOT IN THIS ONE, and a prefix match that
    # ignored the separator would make 'WinPE\Dell2' part of 'WinPE\Dell'.
    It 'does not count a folder whose name merely starts the same' {
        $call = & $script:decide @('C:\S\Drivers\WinPE\Dell') @(
            (New-HDTTestDriverRow 'WinPE\Dell\a.inf')
            (New-HDTTestDriverRow 'WinPE\Dell2\bad.inf' $false)
        )

        @($call).Count | Should -Be 1
        $call[0].Recurse | Should -BeTrue
    }

    # EVERY DRIVER IN A FOLDER DISABLED means nothing to inject from it - and
    # NOT a folder call, which would inject all of them.
    It 'injects nothing from a folder that is entirely disabled' {
        $call = & $script:decide @('C:\S\Drivers\WinPE\Dell') @(
            (New-HDTTestDriverRow 'WinPE\Dell\a.inf' $false)
            (New-HDTTestDriverRow 'WinPE\Dell\b.inf' $false)
        )

        @($call) | Should -BeNullOrEmpty
    }

    # ONE CALL PER DRIVER, SO THE BUILD CAN COUNT THEM.
    #
    # A folder injected with -Recurse is a SINGLE Add-WindowsDriver that DISM
    # works through for a minute with no callback, so step 10 parked at
    # "Injecting the boot drivers" and said nothing else for the whole of it.
    # There is nothing to report against unless the calls ARE the drivers.
    #
    # IT IS A SWITCH AND NOT THE NEW DEFAULT. A folder is one call and this is
    # seventy; the cost is real, so the build asks for it deliberately and every
    # other caller keeps the cheap shape.
    Context 'one call per driver' {

        It 'splits a folder nothing has disabled' {
            $call = & $script:decidePerDriver @('C:\S\Drivers\WinPE\Dell') @(
                (New-HDTTestDriverRow 'WinPE\Dell\net\a.inf')
                (New-HDTTestDriverRow 'WinPE\Dell\storage\b.inf')
            )

            @($call).Count | Should -Be 2
            @($call | Where-Object { $_.Recurse }) | Should -BeNullOrEmpty
        }

        It 'names each .inf, because that is what the window shows' {
            $call = & $script:decidePerDriver @('C:\S\Drivers\WinPE\Dell') @(
                (New-HDTTestDriverRow 'WinPE\Dell\net\a.inf')
                (New-HDTTestDriverRow 'WinPE\Dell\storage\b.inf')
            )

            @($call | ForEach-Object { $_.Name }) | Should -Be @('a.inf', 'b.inf')
        }

        It 'still leaves a disabled driver out' {
            $call = & $script:decidePerDriver @('C:\S\Drivers\WinPE\Dell') @(
                (New-HDTTestDriverRow 'WinPE\Dell\a.inf')
                (New-HDTTestDriverRow 'WinPE\Dell\bad.inf' $false)
            )

            @($call).Count | Should -Be 1
            @($call)[0].Path | Should -BeLike '*a.inf'
        }

        It 'falls back to the folder when there is no catalog to split by' {
            # A STORE THIS CANNOT READ IS NOT A STORE WITH NO DRIVERS.
            # Get-HDTDriver failing must not turn into a boot image with nothing
            # injected, so the folder still goes in whole - one call and no
            # progress, which is the honest outcome rather than a silent empty
            # build.
            $call = & $script:decidePerDriver @('C:\S\Drivers\WinPE\Dell') @()

            @($call).Count | Should -Be 1
            @($call)[0].Recurse | Should -BeTrue
        }
    }
}
