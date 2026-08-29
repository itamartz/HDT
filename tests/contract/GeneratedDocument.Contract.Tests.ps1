<#
    A VERSION BUMP MAKES DOCUMENTS STALE, AND ONLY ONE HALF OF THAT PAIR WAS
    AUTOMATED.

    ./build.ps1 version writes a new ModuleVersion into Hephaestus.psd1.
    docs/command-reference.html embeds that number, and
    tests/contract/CommandReference.Contract.Tests.ps1 asserts the two agree. So
    every bump turned that one test red until somebody remembered to run
    tools/New-HDTCommandReference.ps1 by hand. It happened on 0.8.0 -> 0.9.0 and
    it stalled the release.

    THIS ASSERTS THE SET, NOT THE FILE. Nothing here names
    docs/command-reference.html. The generated documents are DISCOVERED - every
    tracked file outside tools\ that declares, in its own text, which script in
    tools\ generates it - and the ones a bump makes stale are the ones whose
    generator substitutes ModuleVersion. A second generated document added
    tomorrow joins the set the moment it declares its generator, and fails these
    tests until build.ps1's version task regenerates it too.
#>

BeforeAll {
    $script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    $script:HDTManifestPath = [IO.Path]::Combine($script:HDTRepositoryRoot, 'src', 'Hephaestus', 'Hephaestus.psd1')
    $script:HDTVersion = [string] (Import-PowerShellDataFile -Path $script:HDTManifestPath).ModuleVersion

    $script:HDTToFullPath = {
        param([string] $Relative)

        [IO.Path]::Combine($script:HDTRepositoryRoot, ($Relative -replace '/', '\'))
    }

    # WHAT IS TRACKED, ASKED OF GIT. out\ holds a whole staged copy of the
    # module and would be walked as though it were source; .gitignore already
    # knows the difference and git is the only thing that reads it.
    $script:HDTTracked = @()
    $script:HDTTrackedError = ''
    try {
        $script:HDTTracked = @(& git -C $script:HDTRepositoryRoot ls-files 2>$null |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } catch {
        $script:HDTTrackedError = $_.Exception.Message
    }

    # A DOCUMENT SAYS WHO GENERATES IT. docs/command-reference.html carries a
    # meta generator tag naming tools/New-HDTCommandReference.ps1 and the word
    # generated, and that sentence is the only thing that makes it discoverable
    # as an artefact rather than as a page somebody wrote. Anything under tools\
    # is a generator's own input - the template carries the same line, because
    # the line is copied through into the page - so tools\ is not searched.
    $script:HDTGeneratedDocument = @()

    foreach ($relative in $script:HDTTracked) {
        if ($relative -like 'tools/*') { continue }
        if ($relative -match '\.(png|jpg|jpeg|gif|ico|wim|iso|zip|exe|dll|pdf|ttf|otf)$') { continue }

        # POWERSHELL SOURCE IS NOT A GENERATED DOCUMENT. build.ps1 names the
        # generator in the list it regenerates from, on a line that begins
        # 'Generator =' - which matches every tell a document uses to declare
        # one, and made the build script look like its own artefact. Code that
        # mentions a generator is code; the artefacts are documents.
        if ($relative -match '\.(ps1|psm1|psd1)$') { continue }

        $full = & $script:HDTToFullPath $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }

        $text = [IO.File]::ReadAllText($full)

        foreach ($line in ($text -split "`n")) {
            if ($line -notmatch 'generat') { continue }

            $matched = [regex]::Match($line, 'tools[\\/](?<name>[A-Za-z0-9_.-]+\.ps1)')
            if (-not $matched.Success) { continue }

            $script:HDTGeneratedDocument += [pscustomobject] @{
                Path      = $relative
                Generator = 'tools/' + $matched.Groups['name'].Value
                Text      = $text
            }

            break
        }
    }

    # AND OF THOSE, THE ONES A BUMP MAKES STALE: the ones whose generator reads
    # ModuleVersion and writes it into what it produces. Read off the generator
    # rather than guessed from the document, so a page that happens to contain
    # three dot-separated numbers is not mistaken for a version stamp.
    $script:HDTVersionStamped = @($script:HDTGeneratedDocument | Where-Object {
            $generator = & $script:HDTToFullPath $_.Generator

            (Test-Path -LiteralPath $generator -PathType Leaf) -and
            ([IO.File]::ReadAllText($generator) -match 'ModuleVersion')
        })

    # WHAT build.ps1 SAYS IT REGENERATES. Lifted out of the script by parsing it
    # and dot-sourcing the one function, because running build.ps1 to ask it a
    # question would run a build.
    $script:HDTBuildPath = [IO.Path]::Combine($script:HDTRepositoryRoot, 'build.ps1')

    $token = $null
    $parseError = $null
    $buildAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:HDTBuildPath, [ref] $token, [ref] $parseError)

    $script:HDTDeclared = @()
    $declaringFunction = @($buildAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-HDTGeneratedDocument'
            }, $true))

    if ($declaringFunction.Count -eq 1) {
        . ([scriptblock]::Create($declaringFunction[0].Extent.Text))
        $script:HDTDeclared = @(Get-HDTGeneratedDocument)
    }
}

Describe 'Generated documents' {

    Context 'the set itself' {

        It 'was enumerated from the tracked tree' {
            $script:HDTTracked.Count | Should -BeGreaterThan 0 -Because ('git ls-files returned nothing, so every assertion below would pass by looking at no files at all. {0}' -f $script:HDTTrackedError)
        }

        It 'holds at least one document that a version bump makes stale' {
            # NOT A COUNT ANYBODY HAS TO MAINTAIN - a floor. Zero here means the
            # discovery above stopped working, and a suite that found nothing to
            # check is not a suite that checked.
            $script:HDTVersionStamped.Count | Should -BeGreaterThan 0 -Because 'no tracked document was found that declares a generator in tools\ which substitutes ModuleVersion, so nothing below was actually asserted'
        }
    }

    Context 'what each one carries' {

        It 'states the version the manifest declares, in every document that states one' {
            $stale = @($script:HDTVersionStamped |
                    Where-Object { $_.Text -notlike ('*{0}*' -f $script:HDTVersion) } |
                    ForEach-Object { $_.Path })

            $stale | Should -BeNullOrEmpty -Because ('these documents were generated from a version the manifest no longer declares ({0}) - ./build.ps1 -Task version is what rewrites them: {1}' -f $script:HDTVersion, ($stale -join ', '))
        }
    }

    Context 'what the version task regenerates' {

        It 'declares a document list at all' {
            $script:HDTDeclared.Count | Should -BeGreaterThan 0 -Because 'build.ps1 needs a Get-HDTGeneratedDocument naming what a bump makes stale, or nothing regenerates it'
        }

        It 'regenerates every document a bump makes stale' {
            $declaredPath = @($script:HDTDeclared | ForEach-Object { $_.Path })

            $left = @($script:HDTVersionStamped |
                    Where-Object { $declaredPath -notcontains $_.Path } |
                    ForEach-Object { $_.Path })

            $left | Should -BeNullOrEmpty -Because ('a bump rewrites the manifest and leaves these stating the old version, which is exactly the defect the command reference had - list them in Get-HDTGeneratedDocument in build.ps1: {0}' -f ($left -join ', '))
        }

        It 'names, for each one, the generator the document itself names' {
            foreach ($stamped in $script:HDTVersionStamped) {
                $declared = @($script:HDTDeclared | Where-Object { $_.Path -eq $stamped.Path })

                if ($declared.Count -eq 1) {
                    $declared[0].Generator | Should -Be $stamped.Generator -Because ('{0} says it is generated by {1}, and the build would run something else' -f $stamped.Path, $stamped.Generator)
                }
            }
        }

        It 'declares nothing that is not a generated document' {
            $known = @($script:HDTGeneratedDocument | ForEach-Object { $_.Path })
            $extra = @($script:HDTDeclared | Where-Object { $known -notcontains $_.Path } | ForEach-Object { $_.Path })

            $extra | Should -BeNullOrEmpty -Because ('build.ps1 would regenerate a file that does not declare a generator in tools\, so nothing proves the two agree about what writes it: {0}' -f ($extra -join ', '))
        }

        It 'points at a generator and a document that both exist' {
            foreach ($declared in $script:HDTDeclared) {
                Test-Path -LiteralPath (& $script:HDTToFullPath $declared.Generator) -PathType Leaf |
                    Should -BeTrue -Because ('build.ps1 would run {0}, which is not there' -f $declared.Generator)

                Test-Path -LiteralPath (& $script:HDTToFullPath $declared.Path) -PathType Leaf |
                    Should -BeTrue -Because ('build.ps1 names {0} as a generated document, and there is no such file' -f $declared.Path)
            }
        }
    }
}
