<#
    The command reference is a document an administrator reads instead of the
    source, and nothing was keeping it honest. It was written by hand, its own
    meta tag asked to be regenerated and nothing regenerated it, and by the time
    anybody looked it was 32 commands behind the module - the entire driver
    store and every selection profile command, absent from the page that claims
    to list every command there is. It also still carried help text from before
    the help was rewritten, and a version number two releases old.

    So this asserts the page against the SET, not against a command somebody
    remembered to add: every name in FunctionsToExport is grouped in
    docs/command-categories.psd1 and anchored on docs/command-reference.html.
    Command 272 fails this the day it is exported, which is the point.
#>

BeforeDiscovery {
    $script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:HDTManifestPath = [IO.Path]::Combine($script:HDTRepositoryRoot, 'src', 'Hephaestus', 'Hephaestus.psd1')
    $script:HDTCategoryPath = [IO.Path]::Combine($script:HDTRepositoryRoot, 'docs', 'command-categories.psd1')
    $script:HDTReferencePath = [IO.Path]::Combine($script:HDTRepositoryRoot, 'docs', 'command-reference.html')
}

Describe 'Command reference' {

    BeforeAll {
        $script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:HDTManifestPath = [IO.Path]::Combine($script:HDTRepositoryRoot, 'src', 'Hephaestus', 'Hephaestus.psd1')
        $script:HDTCategoryPath = [IO.Path]::Combine($script:HDTRepositoryRoot, 'docs', 'command-categories.psd1')
        $script:HDTReferencePath = [IO.Path]::Combine($script:HDTRepositoryRoot, 'docs', 'command-reference.html')
        $script:HDTTemplatePath = [IO.Path]::Combine($script:HDTRepositoryRoot, 'tools', 'CommandReference.template.html')
        $script:HDTGeneratorPath = [IO.Path]::Combine($script:HDTRepositoryRoot, 'tools', 'New-HDTCommandReference.ps1')

        $script:HDTManifest = Import-PowerShellDataFile -Path $script:HDTManifestPath
        $script:HDTExported = @($script:HDTManifest.FunctionsToExport)

        $script:HDTCategory = @((Import-PowerShellDataFile -Path $script:HDTCategoryPath).Category)
        $script:HDTGrouped = @($script:HDTCategory | ForEach-Object { $_.Command })

        $script:HDTHtml = [IO.File]::ReadAllText($script:HDTReferencePath)
        $script:HDTAnchored = @([regex]::Matches($script:HDTHtml, '<article class="fn" id="([^"]+)"') |
                ForEach-Object { $_.Groups[1].Value })
    }

    Context 'the grouping data file' {

        It 'groups every exported command' {
            $missing = @($script:HDTExported | Where-Object { $script:HDTGrouped -notcontains $_ })
            $missing | Should -BeNullOrEmpty -Because ('every command in FunctionsToExport needs a group in docs/command-categories.psd1; these have none: {0}' -f ($missing -join ', '))
        }

        It 'groups nothing the module does not export' {
            $extra = @($script:HDTGrouped | Where-Object { $script:HDTExported -notcontains $_ })
            $extra | Should -BeNullOrEmpty -Because ('docs/command-categories.psd1 lists commands the module does not export: {0}' -f ($extra -join ', '))
        }

        It 'lists each command exactly once' {
            $twice = @($script:HDTGrouped | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
            $twice | Should -BeNullOrEmpty -Because ('a command in two groups is printed twice on the page: {0}' -f ($twice -join ', '))
        }

        It 'gives every group an id, a title and a blurb' {
            foreach ($group in $script:HDTCategory) {
                $group.Id | Should -Match '^[a-z0-9-]+$' -Because 'the id is the anchor the rail links to'
                $group.Title | Should -Not -BeNullOrEmpty
                $group.Blurb | Should -Not -BeNullOrEmpty -Because 'the blurb is what tells a reader whether the group is the one they want'
                @($group.Command).Count | Should -BeGreaterThan 0 -Because ('the group {0} would render as an empty heading' -f $group.Id)
            }
        }
    }

    Context 'the generated page' {

        It 'has an entry for every exported command' {
            $missing = @($script:HDTExported | Where-Object { $script:HDTAnchored -notcontains $_ })
            $missing | Should -BeNullOrEmpty -Because ('docs/command-reference.html is stale - run tools/New-HDTCommandReference.ps1. Missing: {0}' -f ($missing -join ', '))
        }

        It 'has an entry for nothing else' {
            $extra = @($script:HDTAnchored | Where-Object { $script:HDTExported -notcontains $_ })
            $extra | Should -BeNullOrEmpty -Because ('the page documents commands the module no longer exports: {0}' -f ($extra -join ', '))
        }

        It 'counts the commands it actually lists' {
            $stated = [regex]::Match($script:HDTHtml, '<div class="n">(\d+)</div><div class="l">exported commands</div>').Groups[1].Value
            [int] $stated | Should -Be $script:HDTExported.Count
        }

        It 'names the module version the manifest declares' {
            $script:HDTHtml | Should -BeLike ('*Hephaestus {0} *' -f $script:HDTManifest.ModuleVersion) -Because 'the page states a version, and a wrong one is worse than none'
        }

        It 'carries one rail link per group, with that group''s count' {
            foreach ($group in $script:HDTCategory) {
                $pattern = '<li><a href="#{0}"><span class="nav-t">[^<]*</span><span class="nav-n">{1}</span></a></li>' -f
                    [regex]::Escape($group.Id), @($group.Command).Count
                $script:HDTHtml | Should -Match $pattern -Because ('the rail must agree with the page about how many commands {0} holds' -f $group.Id)
            }
        }
    }

    Context 'the generator' {

        It 'is there, with its template' {
            Test-Path -LiteralPath $script:HDTGeneratorPath | Should -BeTrue
            Test-Path -LiteralPath $script:HDTTemplatePath | Should -BeTrue
        }

        It 'owns every token the template leaves for it' {
            $template = [IO.File]::ReadAllText($script:HDTTemplatePath)
            $generator = [IO.File]::ReadAllText($script:HDTGeneratorPath)
            foreach ($token in @([regex]::Matches($template, '<!--HDT:[A-Z]+-->') | ForEach-Object { $_.Value } | Sort-Object -Unique)) {
                $generator | Should -BeLike ('*{0}*' -f $token) -Because ('the template asks for {0} and nothing fills it in' -f $token)
            }
        }

        It 'leaves no token unfilled in the page it wrote' {
            $script:HDTHtml | Should -Not -Match '<!--HDT:[A-Z]+-->' -Because 'an unreplaced token is a hole in the published page'
        }
    }
}
