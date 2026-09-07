function Get-HDTWorkspaceSeed {
    <#
        .SYNOPSIS
            Which template folders a new deployment share is seeded from, and
            where each one lands on it.

        .DESCRIPTION
            THE ONE PLACE THAT SAYS WHICH TREES ARE COPIED, and it exists for
            CLAUDE.md rule 8. Every seeded tree is a whole DIRECTORY copied whole:
            the templates are the product and the share is a copy of them, so a
            file added to one of these folders reaches every share created
            afterwards without a line being written anywhere. A copy loop naming
            files one by one is a second source of truth, and the two disagree the
            first time somebody adds a page.

            IT IS A TABLE RATHER THAN TWO BLOCKS OF CODE because a test can walk a
            table. tests/unit/WorkspaceLauncherTemplate.Tests.ps1 asserts that
            every file of every folder named here lands on a share this module
            creates - so a third row added tomorrow is proven the day it lands,
            against the SET rather than against the row somebody just added.

            THE ROWS, AND WHY EACH IS WHERE IT IS:

              Wizard   -> Scripts\UI
                  The technician wizard. DESIGN 11.2 puts the pages on the share
                  precisely so an administrator can change one without touching
                  the toolkit, and MDT's New Deployment Share populates Scripts\
                  with the LiteTouch panes for the same reason.

              Launcher -> Scripts
                  How a Refresh is STARTED. MDT's equivalent is
                  \\server\Share$\Scripts\LiteTouch.vbs, sitting in the Scripts
                  root rather than a subfolder, and an administrator arriving from
                  Workbench is looking in that folder. HDT's is the same pair of
                  files in the same place: a .cmd that can be double-clicked and
                  the .ps1 it runs.

            AN EXISTING FILE IS NEVER WRITTEN OVER, and that is the caller's rule
            rather than this table's - but it is the reason this table matters.
            New-HDTWorkspace deliberately leaves a share's own copies alone
            (DESIGN 11.2), so a folder added here does NOT reach a share created
            yesterday. Adding a row means saying so and splicing the shares that
            matter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Template  - the folder under src\Hephaestus\Templates\
              Kind      - the Get-HDTWorkspacePath -Kind it lands under
              ChildPath - a folder beneath that Kind, or '' for the Kind itself

        .EXAMPLE
            Get-HDTWorkspaceSeed

            The two rows New-HDTWorkspace copies for every new share.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return @(
        [pscustomobject] @{ Template = 'Wizard'; Kind = 'Scripts'; ChildPath = 'UI' }
        [pscustomobject] @{ Template = 'Launcher'; Kind = 'Scripts'; ChildPath = '' }
    )
}
