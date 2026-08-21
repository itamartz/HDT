# 'line 214,207 of Hephaestus.bundle.ps1' IS NOT AN ANSWER ANYBODY CAN ACT ON.
#
# The module ships as one 2.8 MB file - that is what goes into a boot image and
# onto every machine HDT deploys - so a stack trace, a breakpoint and a coverage
# report all name the bundle and a line number in it. The source file that line
# came from is the thing a person needs, and it is recoverable, because
# Write-HDTModuleBundle writes the file name above each file it concatenates.
#
# THIS IS THE READER FOR THOSE MARKERS. PowerShell has no #line directive - it
# ignores comments entirely - so nothing does this mapping for us, which is why
# ModuleBuilder ships its own ConvertTo-SourceLineNumber for exactly this.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:moduleRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus'

    Import-Module -Name (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.psd1') -Force -ErrorAction Stop

    # A module root of two known files, bundled, so every line number in the
    # assertions below is one that can be counted by hand.
    $script:scratch = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('hdt-resolve-{0}' -f [guid]::NewGuid())

    $null = New-Item -Path (Join-Path -Path $script:scratch -ChildPath 'Private') -ItemType Directory -Force
    $null = New-Item -Path (Join-Path -Path $script:scratch -ChildPath 'Public') -ItemType Directory -Force

    Set-Content -LiteralPath (Join-Path -Path $script:scratch -ChildPath 'Private/Get-HDTResolveOne.ps1') `
        -Value @(
        'function Get-HDTResolveOne {'
        "    'one'"
        '}'
    ) -Encoding UTF8

    Set-Content -LiteralPath (Join-Path -Path $script:scratch -ChildPath 'Public/Get-HDTResolveTwo.ps1') `
        -Value @(
        'function Get-HDTResolveTwo {'
        "    'two'"
        '}'
    ) -Encoding UTF8

    $script:made = Write-HDTModuleBundle -ModuleRoot $script:scratch
    $script:bundlePath = [string] $script:made.Path
    $script:bundleLine = @(Get-Content -LiteralPath $script:bundlePath)

    # The 1-based line number of a marker, found rather than hard-coded: the
    # generated preamble is free to grow without rewriting this file.
    $script:markerLine = {
        param([string] $Leaf)

        for ($i = 0; $i -lt $script:bundleLine.Count; $i++) {
            if ($script:bundleLine[$i] -like ('*---- source: *{0} ----*' -f $Leaf)) {
                return $i + 1
            }
        }

        return 0
    }
}

AfterAll {
    # A directory this test created, removed by the code that created it.
    if ($null -ne $script:scratch -and (Test-Path -LiteralPath $script:scratch)) {
        Remove-Item -LiteralPath $script:scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'the markers Write-HDTModuleBundle writes' {

    It 'names the source relative to the module root, not the machine that built it' {
        # AN ABSOLUTE PATH HERE IS TWO DEFECTS. It names a folder that does not
        # exist on the machine the bundle runs on - a boot image, a deployed
        # disk - and it makes the artefact differ between build machines that
        # are building identical code.
        $text = Get-Content -LiteralPath $script:bundlePath -Raw

        # \r? because the bundle keeps the CRLF endings its sources had, and a
        # multiline $ in .NET anchors before the \n, not before the \r.
        $text | Should -Match '(?m)^# ---- source: Public.Get-HDTResolveTwo\.ps1 ----\r?$'
        $text | Should -Not -Match [regex]::Escape($script:scratch)
    }

    It 'puts the export list above the sources, so the last one owns every line after it' {
        # IT USED TO BE THE FOOTER, and a footer is a range of lines that belong
        # to no file sitting after the last marker - which is precisely the case
        # the resolver cannot see. Above the first marker it is preamble, and
        # preamble is already unmapped.
        $export = ($script:bundleLine | Select-String -SimpleMatch 'HDTBundleExport' | Select-Object -First 1).LineNumber

        $export | Should -BeLessThan (& $script:markerLine 'Get-HDTResolveOne.ps1')
    }
}

Describe 'Resolve-HDTBundleLine' {

    It 'maps a line in the first file back to that file' {
        $marker = & $script:markerLine 'Get-HDTResolveOne.ps1'

        $found = Resolve-HDTBundleLine -Path $script:bundlePath -Line ($marker + 2)

        $found.Path | Should -Be (Join-Path -Path 'Private' -ChildPath 'Get-HDTResolveOne.ps1')
        $found.Line | Should -Be 2
    }

    It 'maps a line in the last file back to that file' {
        $marker = & $script:markerLine 'Get-HDTResolveTwo.ps1'

        $found = Resolve-HDTBundleLine -Path $script:bundlePath -Line ($marker + 1)

        $found.Path | Should -Be (Join-Path -Path 'Public' -ChildPath 'Get-HDTResolveTwo.ps1')
        $found.Line | Should -Be 1
    }

    It 'reports the line it was asked about, so a list of them stays readable' {
        $marker = & $script:markerLine 'Get-HDTResolveTwo.ps1'

        (Resolve-HDTBundleLine -Path $script:bundlePath -Line ($marker + 3)).BundleLine |
            Should -Be ($marker + 3)
    }

    It 'answers nothing for the generated preamble, which came from no file' {
        Resolve-HDTBundleLine -Path $script:bundlePath -Line 1 | Should -BeNullOrEmpty
    }

    It 'answers nothing for a marker line itself' {
        $marker = & $script:markerLine 'Get-HDTResolveOne.ps1'

        Resolve-HDTBundleLine -Path $script:bundlePath -Line $marker | Should -BeNullOrEmpty
    }

    It 'takes many lines in one call, because a coverage report is thousands of them' {
        $one = & $script:markerLine 'Get-HDTResolveOne.ps1'
        $two = & $script:markerLine 'Get-HDTResolveTwo.ps1'

        $found = @(Resolve-HDTBundleLine -Path $script:bundlePath -Line @(($one + 1), ($two + 1)))

        @($found).Count | Should -Be 2
        @($found | ForEach-Object { $_.Line }) | Should -Be @(1, 1)
    }

    It 'takes them from the pipeline too' {
        $one = & $script:markerLine 'Get-HDTResolveOne.ps1'

        (@(($one + 1), ($one + 2)) | Resolve-HDTBundleLine -Path $script:bundlePath).Count | Should -Be 2
    }

    It 'refuses a line number that is not in the file, rather than inventing a source for it' {
        { Resolve-HDTBundleLine -Path $script:bundlePath -Line ($script:bundleLine.Count + 50) } |
            Should -Throw -ExpectedMessage '*line*'
    }

    It 'refuses a bundle that is not there' {
        { Resolve-HDTBundleLine -Path (Join-Path -Path $script:scratch -ChildPath 'nope.ps1') -Line 1 } |
            Should -Throw
    }

    It 'counts a bare carriage return as a line, because PowerShell does' {
        # TWO FILES IN THIS MODULE CARRY ONE. Set-HDTDocumentHeaderKey has a
        # regex written as a single-quoted string with a real CR and LF inside
        # it; Show-HDTConsole has a stray \r\r\n. PowerShell's tokenizer ends a
        # line on CR, on LF and on CRLF alike, so the line numbers it reports in
        # a stack trace count those - and grep, sed and Get-Content -ReadCount
        # do not. Read the bundle the other way and every mapping past the first
        # such file comes back one short.
        $odd = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('hdt-cr-{0}' -f [guid]::NewGuid())

        $null = New-Item -Path (Join-Path -Path $odd -ChildPath 'Private') -ItemType Directory -Force
        $null = New-Item -Path (Join-Path -Path $odd -ChildPath 'Public') -ItemType Directory -Force

        try {
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $odd -ChildPath 'Private/Get-HDTCrOne.ps1'),
                "function Get-HDTCrOne { 'a`r?b' }`r`n")

            [System.IO.File]::WriteAllText(
                (Join-Path -Path $odd -ChildPath 'Public/Get-HDTCrTwo.ps1'),
                "function Get-HDTCrTwo {`r`n    'two'`r`n}`r`n")

            $bundle = [string] (Write-HDTModuleBundle -ModuleRoot $odd).Path
            $line = @([System.IO.File]::ReadAllLines($bundle))

            $marker = 0
            for ($i = 0; $i -lt $line.Count; $i++) {
                if ($line[$i] -like '*source: Public*Get-HDTCrTwo.ps1*') { $marker = $i + 1 }
            }

            $found = Resolve-HDTBundleLine -Path $bundle -Line ($marker + 2)

            $found.Line | Should -Be 2
            $line[$marker + 1] | Should -BeExactly "    'two'"
        } finally {
            Remove-Item -LiteralPath $odd -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'defaults to the bundle this module was loaded from' {
        # THE CASE IT EXISTS FOR: somebody has a stack trace from the engine and
        # a line number, and no idea which of 377 files it came from.
        $found = Resolve-HDTBundleLine -Line (& {
                $real = @(Get-Content -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath 'Hephaestus.bundle.ps1'))
                for ($i = 0; $i -lt $real.Count; $i++) {
                    if ($real[$i] -like '# ---- source: *') { return $i + 2 }
                }
                return 1
            })

        $found | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path -Path $script:moduleRoot -ChildPath $found.Path) | Should -BeTrue
    }
}
