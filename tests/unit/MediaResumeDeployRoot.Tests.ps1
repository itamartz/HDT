# THE LETTER MOVES ACROSS THE REBOOT, AND ONLY THE MARKER DOES NOT.
#
# ROADMAP M7 carry-over 2 says it in those words: media keeps the image's own
# value and resolves it again through Resolve-HDTDeployRoot from the content
# marker. Half of that was built - Invoke-HDTTaskSequence carries a corrected
# deploy root into the staged bootstrap.json only when it starts '\\', so a
# local root is deliberately NOT written across - and the other half never was.
# Nothing in the full-OS leg re-resolved it.
#
# WATCHED ON A REAL MACHINE, 2026-09-03. The first offline media disc deployed
# Windows from a read-only ISO with no network, rebooted, and then:
#
#   this leg could not be started: C:\HDT\TaskSequences\PNP-TEST\sequence.yaml:
#   the sequence file does not exist.
#
# C:\HDT is the agent tree, not the workspace. Start-HDTResume defaults
# $workspaceRoot to its own -WorkspaceRoot and only overwrites it once the
# provider has CONNECTED; the connect was handed '\Share', which is
# volume-relative and names no volume, so it failed and the default stood.
#
# THE SMB DIRECTION MATTERS JUST AS MUCH. A share is the same string in both
# legs, and the state document's HDTDeployRoot is what the WinPE leg actually
# reached - a bootstrap rule may have chosen it, a technician may have typed it.
# A change made for a disc that stopped honouring that would send every resumed
# SMB deployment back to the address the image was built with.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:resumePath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload/Start-HDTResume.ps1'

    $script:token = $null
    $script:parseError = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:resumePath, [ref] $script:token, [ref] $script:parseError)

    $script:text = [System.IO.File]::ReadAllText($script:resumePath)
}

Describe 'Start-HDTResume and a deploy root that is a disc' {

    It 'parses' {
        $script:parseError | Should -BeNullOrEmpty
    }

    It 'resolves a Local deploy root again instead of using it verbatim' {
        # The command exists precisely for this and the WinPE leg already calls
        # it; the full-OS leg has to as well, or a volume-relative root reaches
        # the provider as a path that names no volume.
        $script:text | Should -Match 'Resolve-HDTDeployRoot' -Because 'a local deploy root names no volume until it is resolved against the marker, and the letter it had in WinPE has moved'
    }

    It 'enumerates the volumes to resolve against' {
        # Resolve-HDTDeployRoot deliberately does not enumerate - the caller
        # hands it candidates. So the caller has to have some.
        $script:text | Should -Match 'GetDrives'
    }

    It 'only re-resolves when the provider is Local' {
        # A UNC needs no volume and must not be probed: Resolve-HDTDeployRoot's
        # own rule 1. The guard has to name the provider.
        $call = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true) |
                Where-Object { [string] $_.GetCommandName() -eq 'Resolve-HDTDeployRoot' })

        $call.Count | Should -BeGreaterThan 0

        # Walk up to the enclosing if-statement and prove the condition is about
        # the provider rather than about anything else.
        foreach ($node in $call) {
            $parent = $node.Parent
            $guarded = $false

            while ($null -ne $parent) {
                if ($parent -is [System.Management.Automation.Language.IfStatementAst] -and
                    [string] $parent.Clauses[0].Item1.Extent.Text -match 'Local') {

                    $guarded = $true
                    break
                }

                $parent = $parent.Parent
            }

            $guarded | Should -BeTrue -Because 'a UNC deploy root needs no volume and probing one costs a timeout per candidate'
        }
    }

    It 'still lets the state document name the share for an SMB resume' {
        # THE DIRECTION A DISC FIX COULD QUIETLY BREAK. The WinPE leg records
        # the share it actually reached, and this leg has to keep using it.
        $script:text | Should -Match "HDTDeployRoot"
    }
}
