# THE MODULE LOADS FROM ONE FILE WHEN IT CAN, and from 363 when it cannot.
#
# Importing Hephaestus costs 2.6 seconds on this machine, of which 2.46 is the
# dot-sourcing loop itself - PowerShell parses 2.6 MB of script, comment-based
# help included, once per import. The same code concatenated into one file
# parses in 1.37 seconds: the difference is per-file overhead, paid 363 times.
#
# THAT MATTERS BECAUSE OF -Detach. Start-HDTConsole -Detach starts a fresh
# powershell.exe, which imports the module cold before it can draw anything, so
# every millisecond here is a millisecond somebody watches nothing happen.
#
# A STALE BUNDLE MUST BE IMPOSSIBLE TO RUN. A generated file that is older than
# the sources it was generated from would run yesterday's code while today's is
# on disk - the worst failure this repository could ship, because nothing looks
# wrong. So the loader compares timestamps and falls back to the files, and
# these tests are what keep that comparison honest.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:moduleRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus'
    $script:loader = Get-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psm1') -Raw

    Import-Module -Name (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'the loader' {

    It 'prefers a bundle when there is one' {
        $script:loader | Should -BeLike '*Hephaestus.bundle.ps1*'
    }

    It 'compares the bundle against the newest source before trusting it' {
        # THE ONE LINE THAT MAKES IT SAFE. Without it a bundle from before an
        # edit runs the code from before the edit.
        $script:loader | Should -BeLike '*LastWriteTimeUtc*'
    }

    It 'still exports the public commands by file name, bundle or not' {
        # The export list is the Public folder, which is true either way - a
        # bundle that changed what is exported would be a second contract.
        (Get-Module -Name 'Hephaestus').ExportedFunctions.Count | Should -BeGreaterThan 100
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

        $text.IndexOf('Get-HDTBundleOne') | Should -BeLessThan $text.IndexOf('Get-HDTBundleTwo')
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
