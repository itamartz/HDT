<#
    A BADGE NAMES A PACKAGE, AND NOTHING WAS CHECKING IT WAS OURS.

    README.md carries a shields.io badge for the PowerShell Gallery, and the
    package id is written into that URL by hand. shields.io does not fail loudly
    when the id is wrong - a package that does not exist renders as a grey
    "not found", and a package that does exist but is somebody else's renders a
    perfectly healthy version number for software this repository does not
    publish. Either way the page looks fine and the number is a lie.

    The id is not a constant either. The module publishes under the name in
    src/Hephaestus/Hephaestus.psd1, so a rename there silently orphans every
    badge pointing at the old name.

    THIS ASSERTS THE SET, NOT THE BADGE ADDED TODAY. Nothing here names the
    version badge. Every https://img.shields.io/powershellgallery/... image in
    README.md is discovered, and each one has to name the module the manifest
    publishes and link to that module's Gallery page. A downloads badge added
    tomorrow joins the set the moment it is written, and fails these tests if it
    names anything else.
#>

BeforeDiscovery {
    $script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:HDTReadmePath = [IO.Path]::Combine($script:HDTRepositoryRoot, 'README.md')
}

Describe 'PowerShell Gallery badges' {

    BeforeAll {
        $script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:HDTReadmePath = [IO.Path]::Combine($script:HDTRepositoryRoot, 'README.md')
        $script:HDTManifestPath = [IO.Path]::Combine($script:HDTRepositoryRoot, 'src', 'Hephaestus', 'Hephaestus.psd1')

        # The Gallery publishes a module under the manifest's own name, which is
        # the manifest file's base name - the same string Publish-Module reads.
        # Taking it from the file rather than from a literal here is the whole
        # point: rename the manifest and this test moves with it, while a badge
        # left behind fails.
        $script:HDTModuleName = [IO.Path]::GetFileNameWithoutExtension($script:HDTManifestPath)

        $script:HDTReadme = [IO.File]::ReadAllText($script:HDTReadmePath)

        # [![alt](image)](link) - the inline form every badge in this README uses.
        $pattern = '\[!\[(?<Alt>[^\]]*)\]\((?<Image>https://img\.shields\.io/powershellgallery/[^)]+)\)\]\((?<Link>[^)]+)\)'
        $script:HDTGalleryBadge = @(
            [regex]::Matches($script:HDTReadme, $pattern) | ForEach-Object {
                [pscustomobject] @{
                    Alt   = $_.Groups['Alt'].Value
                    Image = $_.Groups['Image'].Value
                    Link  = $_.Groups['Link'].Value
                }
            }
        )
    }

    It 'finds a Gallery badge at all, so the sweep below cannot pass by finding none' {
        # Every assertion after this one iterates the discovered set, and an
        # empty set passes them all. HDT publishes to the Gallery, so the README
        # says so; if this drops to zero the badge was deleted or the inline
        # markdown form changed under the pattern above.
        @($script:HDTGalleryBadge).Count | Should -BeGreaterOrEqual 1 -Because 'README.md should carry at least one shields.io PowerShell Gallery badge'
    }

    It 'names the module the manifest publishes' {
        foreach ($badge in $script:HDTGalleryBadge) {
            # https://img.shields.io/powershellgallery/<metric>/<package id>
            $badge.Image | Should -Match ('^https://img\.shields\.io/powershellgallery/[a-z]+/{0}(\?|$)' -f [regex]::Escape($script:HDTModuleName)) -Because ('the badge image must name the module src/Hephaestus/Hephaestus.psd1 publishes ({0}); a stale id renders somebody else''s package, or a grey "not found", and neither fails a build: {1}' -f $script:HDTModuleName, $badge.Image)
        }
    }

    It 'links to that module''s Gallery page' {
        foreach ($badge in $script:HDTGalleryBadge) {
            $badge.Link | Should -Be ('https://www.powershellgallery.com/packages/{0}' -f $script:HDTModuleName) -Because ('a badge that renders one package and links to another sends a reader to the wrong page: {0}' -f $badge.Link)
        }
    }

    It 'gives every badge alt text' {
        foreach ($badge in $script:HDTGalleryBadge) {
            $badge.Alt | Should -Not -BeNullOrEmpty -Because ('an image with no alt text is nothing at all to a screen reader: {0}' -f $badge.Image)
        }
    }
}
