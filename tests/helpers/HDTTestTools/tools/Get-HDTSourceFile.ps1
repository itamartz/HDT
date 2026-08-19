function Get-HDTSourceFile {
    <#
        .SYNOPSIS
            Enumerates every PowerShell source file in the repository that is subject
            to HDT's own rules.

        .DESCRIPTION
            Returns the full path of every *.ps1 and *.psm1 file that the naming
            contract, the PowerShell 5.1 syntax contract and PSScriptAnalyzer apply
            to. One definition of "our source" keeps build.ps1 and the contract tests
            from drifting apart.

            Included:
              - *.ps1 and *.psm1 anywhere under src/
              - *.ps1 and *.psm1 anywhere under tests/
              - build.ps1 in the repository root

            Excluded:
              - Hephaestus.bundle.ps1 - a generated concatenation of everything
                                    else under src/Hephaestus, so including it
                                    would lint and scan the module twice
              - tests/fixtures/** - fixtures are deliberately malformed
              - out/**            - build output is a copy of src/
              - any .git, bin or obj directory
              - *.psd1            - manifests define no functions and are not parsed
                                    for syntax

            Output is absolute, sorted and duplicate free.

        .PARAMETER RepositoryRoot
            The root of the HDT repository to enumerate.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            Get-HDTSourceFile -RepositoryRoot (Get-Location).Path

            Lists every source file the contract tests and the analyzer cover.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $RepositoryRoot
    )

    if (-not (Test-Path -Path $RepositoryRoot -PathType Container)) {
        throw "RepositoryRoot '$RepositoryRoot' does not exist or is not a directory."
    }

    $rootPath = [System.IO.Path]::GetFullPath((Resolve-Path -Path $RepositoryRoot).ProviderPath)
    $rootPath = $rootPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

    $extension = @('.ps1', '.psm1')
    $excludedDirectory = @('.git', 'bin', 'obj')
    $excludedPrefix = @('out/', 'tests/fixtures/')

    # THE MODULE BUNDLE IS NOT SOURCE. It is every file under src/Hephaestus
    # concatenated - a build artefact Write-HDTModuleBundle generates and
    # .gitignore keeps out - so linting it lints everything twice, and a
    # suppression attribute that was valid in its own file is reported as
    # unmatched once it sits beside 364 other files' diagnostics.
    $excludedName = @('hephaestus.bundle.ps1')

    $candidate = New-Object -TypeName System.Collections.ArrayList

    foreach ($includeRoot in @('src', 'tests')) {
        $searchPath = Join-Path -Path $rootPath -ChildPath $includeRoot
        if (Test-Path -Path $searchPath -PathType Container) {
            $found = @(Get-ChildItem -Path $searchPath -Recurse -File -ErrorAction SilentlyContinue)
            foreach ($item in $found) {
                [void] $candidate.Add($item.FullName)
            }
        }
    }

    $buildScript = Join-Path -Path $rootPath -ChildPath 'build.ps1'
    if (Test-Path -Path $buildScript -PathType Leaf) {
        [void] $candidate.Add([System.IO.Path]::GetFullPath($buildScript))
    }

    $keep = New-Object -TypeName System.Collections.ArrayList

    foreach ($path in $candidate) {
        $fullPath = [System.IO.Path]::GetFullPath($path)

        if ($extension -notcontains [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()) {
            continue
        }

        $relative = $fullPath.Substring($rootPath.Length).TrimStart(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar).Replace('\', '/')

        $segment = @($relative.Split('/'))
        $isExcludedDirectory = $false
        for ($index = 0; $index -lt ($segment.Count - 1); $index++) {
            if ($excludedDirectory -contains $segment[$index]) {
                $isExcludedDirectory = $true
            }
        }
        if ($isExcludedDirectory) {
            continue
        }

        if ($excludedName -contains ([System.IO.Path]::GetFileName($fullPath)).ToLowerInvariant()) {
            continue
        }

        $isExcludedPrefix = $false
        foreach ($prefix in $excludedPrefix) {
            if ($relative.ToLowerInvariant().StartsWith($prefix)) {
                $isExcludedPrefix = $true
            }
        }
        if ($isExcludedPrefix) {
            continue
        }

        if ($keep -notcontains $fullPath) {
            [void] $keep.Add($fullPath)
        }
    }

    return [string[]] @($keep | Sort-Object)
}
