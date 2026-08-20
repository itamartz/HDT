# The version the module claims, kept honest by the build.
#
# A MODULE VERSION THAT DOES NOT MOVE IS WORSE THAN NO VERSION AT ALL. A boot
# image records the engine version staged into it and the share records its own;
# comparing them is how a technician finds out that WinPE is running last
# month's engine (Get-HDTModuleVersion says so in as many words). That check
# only works if editing the engine changes the number - and nobody remembers to
# edit a manifest by hand.
#
# WHAT COUNTS AS WHICH BUMP. A file added or removed is a change in what the
# module IS - a new command, a page of markup, a template - so it takes the
# minor. Editing the inside of a file that already shipped takes the patch.
# Neither is semver's promise about breakage, because 0.x makes no such promise;
# they are a build's honest report of what moved.
#
# IT MUST BE IDEMPOTENT, and that is the whole reason the hashes are written
# back into the manifest. A bump computed from "does the tree differ from the
# last commit" bumps again on every run until somebody commits, so `ci` twice in
# a row would take 0.2.0 to 0.4.0. Comparing against a hash the last bump
# recorded makes the second run a no-op, and makes the manifest the record of
# which source tree the version stands for.
#
# THE MANIFEST IS SPLICED, NEVER RE-SERIALISED. Import-PowerShellDataFile plus a
# rewrite drops every comment in the file, and Hephaestus.psd1 is more comment
# than data. Three lines are replaced in place; nothing else in the file may move.

BeforeAll {
    $script:runIndex = 0
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # A module folder small enough to reason about, in the shape the real one
    # has: a manifest, a loader, a Private and a Public file, and one piece of
    # markup - because markup ships too, and editing a window is editing the
    # module.
    function New-HDTTestModule {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes a throwaway module tree under the test''s own temp path; nothing to confirm.')]
        param(
            [string] $Path,
            [string] $Version = '0.2.0',
            [string] $SourceHash = '',
            [string] $LayoutHash = ''
        )

        New-Item -Path (Join-Path -Path $Path -ChildPath 'Private') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path -Path $Path -ChildPath 'Public') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path -Path $Path -ChildPath 'UI') -ItemType Directory -Force | Out-Null

        Set-Content -LiteralPath (Join-Path -Path $Path -ChildPath 'Private\Get-HDTThing.ps1') -Value 'function Get-HDTThing { 1 }'
        Set-Content -LiteralPath (Join-Path -Path $Path -ChildPath 'Public\Get-HDTOther.ps1') -Value 'function Get-HDTOther { 2 }'
        Set-Content -LiteralPath (Join-Path -Path $Path -ChildPath 'UI\HDTThing.xaml') -Value '<Window />'
        Set-Content -LiteralPath (Join-Path -Path $Path -ChildPath 'Hephaestus.psm1') -Value '# loader'

        $manifest = @"
@{
    # A COMMENT THAT MUST SURVIVE.
    ModuleVersion        = '$Version'
    GUID                 = '11111111-2222-3333-4444-555555555555'
    Author               = 'HDT'
    FunctionsToExport    = @('Get-HDTOther')
    PrivateData          = @{
        PSData = @{
            Tags = @('MDT')
        }
        # ANOTHER COMMENT THAT MUST SURVIVE.
        HDT = @{
            SourceHash = '$SourceHash'
            LayoutHash = '$LayoutHash'
        }
    }
}
"@

        Set-Content -LiteralPath (Join-Path -Path $Path -ChildPath 'Hephaestus.psd1') -Value $manifest
    }

    function Get-HDTTestVersion {
        param([string] $Path)

        (Import-PowerShellDataFile -Path (Join-Path -Path $Path -ChildPath 'Hephaestus.psd1')).ModuleVersion
    }
}

Describe 'Update-HDTModuleVersion' {

    BeforeEach {
        # A FOLDER PER TEST, NOT ONE REUSED. TestDrive is not emptied between
        # examples, so a module root reused across them keeps the file the
        # previous example added - and a test that adds a file to prove the
        # minor moves proves nothing when the file is already there.
        $script:runIndex = $script:runIndex + 1
        $script:moduleRoot = Join-Path -Path $TestDrive -ChildPath ('Hephaestus{0}' -f $script:runIndex)
        New-HDTTestModule -Path $script:moduleRoot

        # THE FIRST RUN SEEDS, IT DOES NOT BUMP. A manifest recording no hashes
        # has nothing to compare against, and a build that bumped on that would
        # bump for a tree nobody touched. It records what is there and leaves the
        # number alone; every assertion below starts from that settled state.
        Update-HDTModuleVersion -ModuleRoot $script:moduleRoot | Out-Null
        $script:settled = Get-HDTTestVersion -Path $script:moduleRoot
    }

    Context 'a manifest that records no hashes yet' {

        It 'records them and leaves the version where it was' {
            $fresh = Join-Path -Path $TestDrive -ChildPath 'Fresh'
            New-HDTTestModule -Path $fresh

            $answer = Update-HDTModuleVersion -ModuleRoot $fresh

            $answer.Changed | Should -BeFalse
            $answer.Version | Should -Be '0.2.0'
            (Import-PowerShellDataFile -Path (Join-Path -Path $fresh -ChildPath 'Hephaestus.psd1')).PrivateData.HDT.SourceHash |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'a source tree that has not moved' {

        It 'leaves the version alone' {
            Update-HDTModuleVersion -ModuleRoot $script:moduleRoot | Out-Null

            Get-HDTTestVersion -Path $script:moduleRoot | Should -Be $script:settled
        }

        It 'does not write the manifest at all' {
            $before = Get-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psd1') -Raw

            Update-HDTModuleVersion -ModuleRoot $script:moduleRoot | Out-Null

            Get-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psd1') -Raw |
                Should -Be $before
        }

        It 'says so, rather than saying nothing' {
            $answer = Update-HDTModuleVersion -ModuleRoot $script:moduleRoot

            $answer.Changed | Should -BeFalse
            $answer.Version | Should -Be $script:settled
        }
    }

    Context 'a file that changed inside' {

        It 'takes the patch' {
            Set-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Public\Get-HDTOther.ps1') -Value 'function Get-HDTOther { 3 }'

            $answer = Update-HDTModuleVersion -ModuleRoot $script:moduleRoot

            $answer.Changed | Should -BeTrue
            $answer.Version | Should -Be '0.2.1'
            Get-HDTTestVersion -Path $script:moduleRoot | Should -Be '0.2.1'
        }

        It 'counts markup as the module, because a window is the module too' {
            Set-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'UI\HDTThing.xaml') -Value '<Window Title="x" />'

            (Update-HDTModuleVersion -ModuleRoot $script:moduleRoot).Version | Should -Be '0.2.1'
        }

        It 'settles after one run, so a second build does not bump again' {
            Set-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Public\Get-HDTOther.ps1') -Value 'function Get-HDTOther { 3 }'

            Update-HDTModuleVersion -ModuleRoot $script:moduleRoot | Out-Null
            Update-HDTModuleVersion -ModuleRoot $script:moduleRoot | Out-Null

            Get-HDTTestVersion -Path $script:moduleRoot | Should -Be '0.2.1'
        }
    }

    Context 'a file that was added or removed' {

        It 'takes the minor and resets the patch' {
            Set-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Public\Get-HDTNew.ps1') -Value 'function Get-HDTNew { 4 }'

            $answer = Update-HDTModuleVersion -ModuleRoot $script:moduleRoot

            $answer.Version | Should -Be '0.3.0'
        }

        It 'takes the minor when one is removed as well' {
            Remove-Item -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Private\Get-HDTThing.ps1') -Force

            (Update-HDTModuleVersion -ModuleRoot $script:moduleRoot).Version | Should -Be '0.3.0'
        }

        It 'resets a patch that had already moved' {
            Set-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Public\Get-HDTOther.ps1') -Value 'function Get-HDTOther { 3 }'
            Update-HDTModuleVersion -ModuleRoot $script:moduleRoot | Out-Null

            Set-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Public\Get-HDTNew.ps1') -Value 'function Get-HDTNew { 4 }'

            (Update-HDTModuleVersion -ModuleRoot $script:moduleRoot).Version | Should -Be '0.3.0'
        }
    }

    Context 'what it does not count' {

        # THE DEFECT THIS GUARDS AGAINST SHIPPED, AND CI CAUGHT IT. The first
        # build after the version task landed reported "0.3.0 -> 0.3.1 (file
        # contents changed)" on a clean checkout nobody had edited: the runner's
        # working copy had CRLF where the developer's had LF, so the two
        # fingerprints disagreed. Every CI run would have bumped a version it can
        # never commit, and no two clones would ever have agreed on the number.
        It 'ignores the line endings a checkout chose, so a fresh clone does not bump' {
            $path = Join-Path -Path $script:moduleRoot -ChildPath 'Public\Get-HDTOther.ps1'

            [System.IO.File]::WriteAllText($path, "function Get-HDTOther {`r`n    3`r`n}`r`n")
            Update-HDTModuleVersion -ModuleRoot $script:moduleRoot | Out-Null

            [System.IO.File]::WriteAllText($path, "function Get-HDTOther {`n    3`n}`n")

            (Update-HDTModuleVersion -ModuleRoot $script:moduleRoot).Changed | Should -BeFalse
        }

        It 'still sees a change that is not just the line endings' {
            $path = Join-Path -Path $script:moduleRoot -ChildPath 'Public\Get-HDTOther.ps1'

            [System.IO.File]::WriteAllText($path, "function Get-HDTOther {`r`n    3`r`n}`r`n")
            Update-HDTModuleVersion -ModuleRoot $script:moduleRoot | Out-Null

            [System.IO.File]::WriteAllText($path, "function Get-HDTOther {`n    4`n}`n")

            (Update-HDTModuleVersion -ModuleRoot $script:moduleRoot).Changed | Should -BeTrue
        }

        It 'ignores the generated bundle, which every build rewrites' {
            Set-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.bundle.ps1') -Value '# generated'

            (Update-HDTModuleVersion -ModuleRoot $script:moduleRoot).Changed | Should -BeFalse
        }

        It 'ignores the manifest, which is what it writes to' {
            $path = Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psd1'
            Set-Content -LiteralPath $path -Value ((Get-Content -LiteralPath $path -Raw) + "`r`n# a later comment")

            (Update-HDTModuleVersion -ModuleRoot $script:moduleRoot).Changed | Should -BeFalse
        }
    }

    Context 'the manifest it writes' {

        It 'keeps every comment, because it splices and does not re-serialise' {
            Set-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Public\Get-HDTOther.ps1') -Value 'function Get-HDTOther { 3 }'

            Update-HDTModuleVersion -ModuleRoot $script:moduleRoot | Out-Null

            $text = Get-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psd1') -Raw

            $text | Should -BeLike '*A COMMENT THAT MUST SURVIVE*'
            $text | Should -BeLike '*ANOTHER COMMENT THAT MUST SURVIVE*'
            $text | Should -BeLike '*GUID*'
        }

        It 'still parses as a data file' {
            Set-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Public\Get-HDTOther.ps1') -Value 'function Get-HDTOther { 3 }'

            Update-HDTModuleVersion -ModuleRoot $script:moduleRoot | Out-Null

            { Import-PowerShellDataFile -Path (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psd1') } |
                Should -Not -Throw
        }

        It 'records the tree the version stands for' {
            Set-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Public\Get-HDTOther.ps1') -Value 'function Get-HDTOther { 3 }'

            Update-HDTModuleVersion -ModuleRoot $script:moduleRoot | Out-Null

            $data = Import-PowerShellDataFile -Path (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psd1')

            $data.PrivateData.HDT.SourceHash | Should -Not -BeNullOrEmpty
            $data.PrivateData.HDT.LayoutHash | Should -Not -BeNullOrEmpty
        }

        It 'writes nothing under -WhatIf' {
            Set-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Public\Get-HDTOther.ps1') -Value 'function Get-HDTOther { 3 }'

            Update-HDTModuleVersion -ModuleRoot $script:moduleRoot -WhatIf | Out-Null

            Get-HDTTestVersion -Path $script:moduleRoot | Should -Be $script:settled
        }
    }

    Context 'a manifest it cannot write to' {

        It 'names the two keys it needs rather than the line it failed on' {
            $bare = Join-Path -Path $TestDrive -ChildPath 'Bare'
            New-HDTTestModule -Path $bare
            $path = Join-Path -Path $bare -ChildPath 'Hephaestus.psd1'
            Set-Content -LiteralPath $path -Value ((Get-Content -LiteralPath $path -Raw) -replace 'SourceHash', 'Something')

            { Update-HDTModuleVersion -ModuleRoot $bare } |
                Should -Throw -ExpectedMessage '*SourceHash*'
        }
    }
}

Describe 'The shipped manifest' {

    It 'carries the two keys the build writes back into it' {
        $data = Import-PowerShellDataFile -Path (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\Hephaestus.psd1')

        $data.PrivateData.HDT.Keys | Should -Contain 'SourceHash'
        $data.PrivateData.HDT.Keys | Should -Contain 'LayoutHash'
    }
}

Describe 'The build script' {

    BeforeAll {
        $script:buildText = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'build.ps1') -Raw
    }

    It 'accepts a version task' {
        $script:buildText | Should -BeLike "*'version'*"
    }

    # BEFORE bundle AND build, because the bundle is written from the sources the
    # version now stands for and Invoke-HDTBuild stages into out/<version>/ - a
    # bump after either would leave the artefact folder named for the version
    # before it.
    It 'runs it before the bundle and the staging, so out/ is named for the new version' {
        $script:buildText | Should -Match "canonicalOrder = @\('clean', 'version', 'bundle', 'build'"
    }

    It 'dispatches it, rather than only accepting it' {
        $script:buildText | Should -Match "'version'\s*\{\s*Invoke-HDTVersion"
    }
}
