# THE MODULE LOADS FROM ONE FILE. Never from the 377 it was built out of.
#
# Importing Hephaestus costs 2.6 seconds on this machine, of which 2.46 is the
# dot-sourcing loop itself - PowerShell parses 2.6 MB of script, comment-based
# help included, once per import. The same code concatenated into one file
# parses in 1.37 seconds: the difference is per-file overhead, paid 377 times.
#
# THAT MATTERS BECAUSE OF -Detach. Start-HDTConsole -Detach starts a fresh
# powershell.exe, which imports the module cold before it can draw anything, so
# every millisecond here is a millisecond somebody watches nothing happen.
#
# THERE IS NO SECOND LOAD PATH ANY MORE. There used to be: the loader fell back
# to the individual files whenever the bundle was missing or older than one of
# them. Two ways to load the same module is two sets of line numbers in a stack
# trace, two coverage shapes, and a difference between what a developer runs and
# what ships. One path, always the bundle.
#
# A STALE BUNDLE MUST STILL BE IMPOSSIBLE TO RUN - a generated file older than
# the sources it came from would run yesterday's code while today's is on disk,
# the worst failure this repository could ship, because nothing looks wrong. So
# the loader still compares timestamps; what it does about a stale one is now
# REBUILD it rather than sidestep it. These tests keep that honest.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:moduleRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus'
    $script:loader = Get-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psm1') -Raw

    Import-Module -Name (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'the loader' {

    It 'loads the bundle' {
        $script:loader | Should -BeLike '*Hephaestus.bundle.ps1*'
    }

    It 'has no second path that dot-sources the sources one by one' {
        # THE FALLBACK IS GONE ON PURPOSE. Anything that walks Private\ and
        # Public\ dot-sourcing as it goes is that fallback growing back.
        $script:loader | Should -Not -Match '(?m)foreach\s*\(\s*\$file\s+in'
    }

    It 'compares the bundle against the newest source before trusting it' {
        # THE ONE LINE THAT MAKES IT SAFE. Without it a bundle from before an
        # edit runs the code from before the edit.
        $script:loader | Should -BeLike '*LastWriteTimeUtc*'
    }

    It 'exports the list the bundle carries' {
        (Get-Module -Name 'Hephaestus').ExportedFunctions.Count | Should -BeGreaterThan 100
    }
}

Describe 'a working tree the build has not been run in' {

    # THE DEVELOPER LOOP, WHICH IS THE WHOLE REASON THIS IS NOT JUST A THROW.
    #
    # 266 test files import src/Hephaestus/Hephaestus.psd1 directly, and the
    # documented way to run one of them is Invoke-Pester on the file. With no
    # fallback, a bundle that is missing or older than the file just edited
    # would mean every one of those runs testing the wrong code - or, if the
    # loader merely refused, a build task standing between every edit and every
    # test. So the loader builds the bundle it needs and then loads that.
    #
    # IT NEEDS TWO FILES TO DO IT: the writer, and the one private helper the
    # writer's error path calls. Both are dot-sourced by name before the bundle
    # exists, which is why this scratch module has to have them.

    BeforeAll {
        $script:tree = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('hdt-tree-{0}' -f [guid]::NewGuid())

        $script:newTree = {
            param([string] $Body)

            if (Test-Path -LiteralPath $script:tree) {
                Remove-Item -LiteralPath $script:tree -Recurse -Force
            }

            $null = New-Item -Path (Join-Path -Path $script:tree -ChildPath 'Private') -ItemType Directory -Force
            $null = New-Item -Path (Join-Path -Path $script:tree -ChildPath 'Public') -ItemType Directory -Force

            foreach ($bootstrap in @('Private/New-HDTErrorRecord.ps1', 'Public/Write-HDTModuleBundle.ps1')) {
                Copy-Item -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath $bootstrap) `
                    -Destination (Join-Path -Path $script:tree -ChildPath $bootstrap) -Force
            }

            Set-Content -LiteralPath (Join-Path -Path $script:tree -ChildPath 'Public/Get-HDTTreeThing.ps1') `
                -Value ("function Get-HDTTreeThing {{ '{0}' }}" -f $Body) -Encoding UTF8

            Copy-Item -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psm1') `
                -Destination (Join-Path -Path $script:tree -ChildPath 'Hephaestus.psm1') -Force

            Set-Content -LiteralPath (Join-Path -Path $script:tree -ChildPath 'Hephaestus.psd1') -Encoding UTF8 -Value @'
@{
    RootModule        = 'Hephaestus.psm1'
    ModuleVersion     = '9.9.9'
    GUID              = 'b41c9d7e-2f5a-4c18-9d31-6ae8f0c25b73'
    Author            = 'HDT'
    FunctionsToExport = @('Get-HDTTreeThing', 'Write-HDTModuleBundle')
}
'@
        }

        $script:importTree = {
            $module = Import-Module -Name (Join-Path -Path $script:tree -ChildPath 'Hephaestus.psd1') -Force -PassThru

            try {
                return (& (Get-Command -Name 'Get-HDTTreeThing' -Module $module.Name))
            } finally {
                $module | Remove-Module -Force -ErrorAction SilentlyContinue
            }
        }
    }

    AfterAll {
        # A directory this test created, removed by the code that created it.
        if ($null -ne $script:tree -and (Test-Path -LiteralPath $script:tree)) {
            Remove-Item -LiteralPath $script:tree -Recurse -Force -ErrorAction SilentlyContinue
        }

        # AND THE REAL MODULE BACK. The scratch one is called Hephaestus too, so
        # importing it displaced the real one and removing it left the session
        # with none - and every Describe after this one calls into it.
        Import-Module -Name (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psd1') -Force -ErrorAction Stop
    }

    It 'builds the bundle on import when there is none, and runs' {
        & $script:newTree 'fresh'

        & $script:importTree | Should -BeExactly 'fresh'
        Test-Path -LiteralPath (Join-Path -Path $script:tree -ChildPath 'Hephaestus.bundle.ps1') | Should -BeTrue
    }

    It 'rebuilds it when a source is newer, rather than running the code from before the edit' {
        & $script:newTree 'before'
        & $script:importTree | Should -BeExactly 'before'

        $edited = Join-Path -Path $script:tree -ChildPath 'Public/Get-HDTTreeThing.ps1'
        Set-Content -LiteralPath $edited -Value "function Get-HDTTreeThing { 'after' }" -Encoding UTF8
        (Get-Item -LiteralPath $edited).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(5)

        & $script:importTree | Should -BeExactly 'after'
    }

    It 'says what to do when the bundle is missing and there are no sources to build one from' {
        # A PACKAGE THAT SHIPPED WITHOUT ITS BUNDLE. There is nothing on disk to
        # recover from, so the message has to name the remedy that works.
        $broken = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('hdt-broken-{0}' -f [guid]::NewGuid())
        $null = New-Item -Path $broken -ItemType Directory -Force

        try {
            Copy-Item -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psm1') `
                -Destination (Join-Path -Path $broken -ChildPath 'Hephaestus.psm1') -Force

            Set-Content -LiteralPath (Join-Path -Path $broken -ChildPath 'Hephaestus.psd1') -Encoding UTF8 -Value @'
@{
    RootModule        = 'Hephaestus.psm1'
    ModuleVersion     = '9.9.9'
    GUID              = 'e77b3a10-9c42-4f8d-8b6e-1d2f5c0a4e99'
    Author            = 'HDT'
    FunctionsToExport = @()
}
'@

            { Import-Module -Name (Join-Path -Path $broken -ChildPath 'Hephaestus.psd1') -Force -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*einstall*'
        } finally {
            Remove-Item -LiteralPath $broken -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Write-HDTModuleBundle' {

    BeforeAll {
        $script:scratch = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('hdt-bundle-{0}' -f [guid]::NewGuid())

        $null = New-Item -Path (Join-Path -Path $script:scratch -ChildPath 'Private') -ItemType Directory -Force
        $null = New-Item -Path (Join-Path -Path $script:scratch -ChildPath 'Public') -ItemType Directory -Force

        Set-Content -LiteralPath (Join-Path -Path $script:scratch -ChildPath 'Private/Get-HDTBundleOne.ps1') `
            -Value "function Get-HDTBundleOne { 'one' }" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path -Path $script:scratch -ChildPath 'Public/Get-HDTBundleTwo.ps1') `
            -Value "function Get-HDTBundleTwo { 'two' }" -Encoding UTF8
    }

    AfterAll {
        # A directory this test created, removed by the code that created it.
        if (Test-Path -LiteralPath $script:scratch) {
            Remove-Item -LiteralPath $script:scratch -Recurse -Force
        }
    }

    It 'writes one file holding every function' {
        $made = Write-HDTModuleBundle -ModuleRoot $script:scratch

        Test-Path -LiteralPath ([string] $made.Path) | Should -BeTrue

        $text = Get-Content -LiteralPath ([string] $made.Path) -Raw
        $text | Should -BeLike '*function Get-HDTBundleOne*'
        $text | Should -BeLike '*function Get-HDTBundleTwo*'
    }

    It 'says what went into it' {
        $made = Write-HDTModuleBundle -ModuleRoot $script:scratch

        [int] $made.FileCount | Should -Be 2
    }

    It 'puts the private ones first, because a public one may call them at load' {
        $made = Write-HDTModuleBundle -ModuleRoot $script:scratch
        $text = Get-Content -LiteralPath ([string] $made.Path) -Raw

        # THE DEFINITIONS, NOT THE NAMES. The export list is written above the
        # sources, so the first mention of a public name is up there.
        $text.IndexOf('function Get-HDTBundleOne') |
            Should -BeLessThan $text.IndexOf('function Get-HDTBundleTwo')
    }

    It 'is newer than everything it was built from' {
        # WHICH IS WHAT THE LOADER CHECKS. A bundle written with an older
        # timestamp than its sources would be ignored on every import - correct,
        # and pointless.
        $made = Write-HDTModuleBundle -ModuleRoot $script:scratch

        $newest = @(Get-ChildItem -Path $script:scratch -Filter '*.ps1' -Recurse |
                Where-Object { $_.Name -ne 'Hephaestus.bundle.ps1' } |
                Sort-Object -Property LastWriteTimeUtc -Descending)[0]

        (Get-Item -LiteralPath ([string] $made.Path)).LastWriteTimeUtc |
            Should -BeGreaterOrEqual $newest.LastWriteTimeUtc
    }

    It 'refuses a folder that is not a module root, rather than writing an empty bundle' {
        $empty = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('hdt-empty-{0}' -f [guid]::NewGuid())
        $null = New-Item -Path $empty -ItemType Directory -Force

        try {
            { Write-HDTModuleBundle -ModuleRoot $empty } | Should -Throw -ExpectedMessage '*no*'
        } finally {
            Remove-Item -LiteralPath $empty -Recurse -Force
        }
    }
}

Describe 'a module that ships as a bundle and nothing else' {

    # WHAT GOES INTO A BOOT IMAGE, AND ONTO A DEPLOYED MACHINE. Update-HDTBootImage
    # stages the engine so WinPE can run it, and Copy-HDTResumeAgent copies that
    # staged tree onto the disk the machine boots from. Staging 391 one-function
    # files to do it is 391 files to read, copy and parse, twice, on every
    # deployment - and the bundle exists precisely to make that one file.
    #
    # THE TRAP IS THE EXPORT LIST. Hephaestus.psm1 ends with
    #
    #     Export-ModuleMember -Function ($publicFile | ForEach-Object { $_.BaseName })
    #
    # so a module with a bundle and no Public\ folder loads every function and
    # then exports NONE of them. It would import without error and answer
    # CommandNotFound for everything - on a machine mid-deployment, with no
    # console to ask.
    #
    # SO THE BUNDLE CARRIES ITS OWN LIST. Write-HDTModuleBundle knows the public
    # names because it just read them; the loader uses that list when there is no
    # Public\ to enumerate. Not Import-PowerShellDataFile on the manifest: that
    # is one more thing to be missing inside WinPE, and this needs none.

    BeforeAll {
        $script:packed = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('hdt-packed-{0}' -f [guid]::NewGuid())

        $null = New-Item -Path (Join-Path -Path $script:packed -ChildPath 'Private') -ItemType Directory -Force
        $null = New-Item -Path (Join-Path -Path $script:packed -ChildPath 'Public') -ItemType Directory -Force

        Set-Content -LiteralPath (Join-Path -Path $script:packed -ChildPath 'Private/Get-HDTPackedHelper.ps1') `
            -Value "function Get-HDTPackedHelper { 'helper' }" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path -Path $script:packed -ChildPath 'Public/Get-HDTPackedThing.ps1') `
            -Value "function Get-HDTPackedThing { Get-HDTPackedHelper }" -Encoding UTF8

        Copy-Item -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psm1') `
            -Destination (Join-Path -Path $script:packed -ChildPath 'Hephaestus.psm1')

        $manifest = @'
@{
    RootModule        = 'Hephaestus.psm1'
    ModuleVersion     = '9.9.9'
    GUID              = 'd0c4f7a2-11aa-4f6e-9f77-3a5b2c1d4e8f'
    Author            = 'HDT'
    FunctionsToExport = @('Get-HDTPackedThing')
}
'@
        Set-Content -LiteralPath (Join-Path -Path $script:packed -ChildPath 'Hephaestus.psd1') -Value $manifest -Encoding UTF8

        [void] (Write-HDTModuleBundle -ModuleRoot $script:packed)

        # AND THEN THE SOURCES GO, which is exactly what the boot image stages.
        Remove-Item -LiteralPath (Join-Path -Path $script:packed -ChildPath 'Private') -Recurse -Force
        Remove-Item -LiteralPath (Join-Path -Path $script:packed -ChildPath 'Public') -Recurse -Force
    }

    AfterAll {
        # A directory this test created, removed by the code that created it.
        if ($null -ne $script:packed -and (Test-Path -LiteralPath $script:packed)) {
            Remove-Item -LiteralPath $script:packed -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'has no Private or Public folder left' {
        Test-Path -LiteralPath (Join-Path -Path $script:packed -ChildPath 'Public') | Should -BeFalse
    }

    It 'still exports its public commands' {
        $module = Import-Module -Name (Join-Path -Path $script:packed -ChildPath 'Hephaestus.psd1') -Force -PassThru

        try {
            @($module.ExportedFunctions.Keys) | Should -Contain 'Get-HDTPackedThing'
        } finally {
            $module | Remove-Module -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exports the public ones and not the private ones' {
        $module = Import-Module -Name (Join-Path -Path $script:packed -ChildPath 'Hephaestus.psd1') -Force -PassThru

        try {
            @($module.ExportedFunctions.Keys) | Should -Not -Contain 'Get-HDTPackedHelper'
        } finally {
            $module | Remove-Module -Force -ErrorAction SilentlyContinue
        }
    }

    It 'runs, and a public command can still call a private one' {
        $module = Import-Module -Name (Join-Path -Path $script:packed -ChildPath 'Hephaestus.psd1') -Force -PassThru

        try {
            & (Get-Command -Name 'Get-HDTPackedThing' -Module $module.Name) | Should -BeExactly 'helper'
        } finally {
            $module | Remove-Module -Force -ErrorAction SilentlyContinue
        }
    }
}
