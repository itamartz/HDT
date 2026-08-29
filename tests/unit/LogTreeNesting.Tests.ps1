# A LOG TREE NEVER CONTAINS A FOLDER OF ITS OWN NAME, WHATEVER COPIED IT.
#
# Measured on the share and on a deployed machine after a real run:
#
#   PC-5784-6600-26-run-20260829-052141\
#     PC-5784-6600-26-run-20260829-052141\
#       PC-5784-6600-26-run-20260829-052141\
#
# three levels deep, each carrying its own Gather\ and Steps\. The cause was one
# call site handing a copy a destination that sat inside its own source, so the
# walk found the folder it had just created and copied it into itself - once per
# leg, which is why the depth matched the number of legs.
#
# THIS FILE IS WRITTEN AGAINST THE SET, NOT AGAINST THAT ONE CALL SITE. Four
# different commands copy a log tree, and a fix proved only where the defect was
# first seen leaves the next one free to reintroduce it. Every one of them is
# driven here and the same assertion is made of the result: no directory the
# copy created repeats a name it already sits underneath.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # PSAvoidUsingComputerNameHardcoded is an Error and fires on a literal bound
    # to -ComputerName, even in a test.
    $script:machine = 'PC-0001'

    # The run folder shape a real machine carries: the computer name, then the
    # run id Start-HDTDeployment.ps1 mints as run-<yyyyMMdd-HHmmss>.
    $script:runId = 'run-20260829-052141'
    $script:runFolder = 'PC-0001-run-20260829-052141'

    # Every directory the fake holds beneath $Root whose path repeats a segment.
    # Directories only: a FILE named after a folder above it is a legitimate
    # thing (Steps\Steps.log), a DIRECTORY of that name is the defect.
    #
    # THE WHOLE PATH IS SPLIT, NOT THE PART BELOW $Root. The first version of
    # this helper stripped the destination prefix first and passed against the
    # very tree that provoked the report - because the repeated name was the
    # destination folder itself, and stripping it threw away one of the two
    # halves of the comparison.
    $script:selfNested = {
        param([object] $FileSystem, [string] $Root)

        $prefix = $Root.TrimEnd('\', '/') + '\'
        $found = New-Object -TypeName System.Collections.ArrayList

        foreach ($path in @($FileSystem.Directory.Keys)) {
            if (-not ([string] $path).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $segment = @(([string] $path) -split '\\' | Where-Object { $_ })
            $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

            foreach ($item in $segment) {
                if (-not $seen.Add([string] $item)) {
                    [void] $found.Add([string] $path)
                    break
                }
            }
        }

        return , ([string[]] $found)
    }

    # -- the log tree every scenario starts from ------------------------------
    #
    # The live log at the top and a per-run folder beside it, which is what
    # C:\HDT\Logs holds by the time the full-OS leg finishes: Set-HDTLogPath
    # mirrored the RAM disk onto the volume, and the restart path then copied
    # that volume's log root into a run folder underneath it.
    $script:seedLogTree = {
        param([string] $Root)

        $fs = New-HDTFakeFileSystem
        $fs.SeedFile(('{0}\HDT.log' -f $Root), 'master')
        $fs.SeedFile(('{0}\HDT.jsonl' -f $Root), "{`"seq`":1}`n")
        $fs.SeedFile(('{0}\status.json' -f $Root), '{"status":"Running"}')
        $fs.SeedFile(('{0}\Steps\001-Validate.log' -f $Root), 'validate')
        $fs.SeedFile(('{0}\Gather\facts.json' -f $Root), '{"schemaVersion":1}')
        $fs.SeedFile(('{0}\PC-0001-run-20260829-052141\HDT.log' -f $Root), 'master')
        $fs.SeedFile(('{0}\PC-0001-run-20260829-052141\Steps\001-Validate.log' -f $Root), 'validate')
        $fs.SeedFile(('{0}\PC-0001-run-20260829-052141\Gather\facts.json' -f $Root), '{"schemaVersion":1}')

        return $fs
    }

    $script:newClock = {
        return (New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 29, 5, 21, 41, [System.DateTimeKind]::Utc)))
    }

}

# THE SET IS BUILT AT DISCOVERY, NOT IN BeforeAll. Pester expands -ForEach while
# it is finding tests, and BeforeAll has not run by then - a set declared there
# is an empty one, and the file reports zero tests and a green run. The
# scriptblocks in it are only INVOKED inside an It, which is after BeforeAll, so
# the helpers they call are in place by the time they run.
BeforeDiscovery {

    # -- the set: one entry per command that copies a log tree ----------------

    $script:copySite = @(
        @{
            # The share copy-back on phase end and on failure, which is where
            # the nesting was first seen.
            Site        = 'Copy-HDTLog to the share'
            Destination = '\\share\Logs'
            Run         = {
                $fs = & $script:seedLogTree 'X:\HDT\Logs'
                $context = New-HDTLogContext -RunId $script:runId -Phase WinPE -LogPath 'X:\HDT\Logs' `
                    -FileSystem $fs -Clock (& $script:newClock)

                Copy-HDTLog -Context $context -Destination '\\share\Logs' -ComputerName $script:machine | Out-Null

                return $fs
            }
        }
        @{
            # THE ONE THAT DID IT. Invoke-HDTTaskSequence copies the log onto
            # the volume that survives the reboot, and Set-HDTLogPath has
            # already moved the context THERE - so the destination sits inside
            # its own source.
            Site        = 'Copy-HDTLog onto the volume it is already logging to'
            Destination = 'W:\HDT\Logs'
            Run         = {
                $fs = & $script:seedLogTree 'W:\HDT\Logs'
                $context = New-HDTLogContext -RunId $script:runId -Phase WinPE -LogPath 'W:\HDT\Logs' `
                    -FileSystem $fs -Clock (& $script:newClock)

                Copy-HDTLog -Context $context -Destination 'W:\HDT\Logs' -ComputerName $script:machine | Out-Null

                return $fs
            }
        }
        @{
            # The RAM disk to the target volume, once a volume exists.
            Site        = 'Set-HDTLogPath mirroring off the RAM disk'
            Destination = 'W:\HDT\Logs'
            Run         = {
                $fs = & $script:seedLogTree 'X:\HDT\Logs'
                $context = New-HDTLogContext -RunId $script:runId -Phase WinPE -LogPath 'X:\HDT\Logs' `
                    -FileSystem $fs -Clock (& $script:newClock)

                [void] (Set-HDTLogPath -Context $context -TargetVolume 'W:')

                return $fs
            }
        }
        @{
            # End of state restore: the logs are kept before C:\HDT goes.
            Site        = 'Remove-HDTResumeAgent keeping the logs'
            Destination = 'C:\Windows\Logs\HDT'
            Run         = {
                $fs = & $script:seedLogTree 'C:\HDT\Logs'
                $fs.SeedFile('C:\HDT\Start-HDTResume.ps1', '# the agent')
                $fs.SeedFile('C:\HDT\Remove-HDTAgentTree.ps1', '# the deleter')
                $fs.SeedFile('C:\HDT\bootstrap.json', '{"credential":{"protected":"AAAA"}}')
                $fs.SeedFile('C:\HDT\state.json', '{"status":"Succeeded"}')

                [void] (Remove-HDTResumeAgent -Path 'C:\HDT' -LogDestination 'C:\Windows\Logs\HDT' `
                        -FileSystem $fs -Process (New-HDTFakeProcessService) -ProcessId 1234 -Confirm:$false)

                return $fs
            }
        }
    )
}

Describe 'every command that copies a log tree' {

    # THE ASSERTION HAS TEETH, PROVED BEFORE IT IS TRUSTED. Its first version
    # stripped the destination prefix before splitting, so the repeated name -
    # which was the destination folder itself - was thrown away with the prefix
    # and the helper passed against the exact tree that provoked the report.
    # A green suite made of a blind assertion is worse than no suite.
    It 'finds a folder planted inside a folder of its own name' {
        $planted = New-HDTFakeFileSystem
        $planted.SeedFile('\\share\Logs\PC-0001-run-20260829-052141\PC-0001-run-20260829-052141\HDT.log', 'master')

        $nested = & $script:selfNested $planted '\\share\Logs'

        $nested | Should -Not -BeNullOrEmpty
    }

    # The site is named in -Because rather than in the test name: a Pester test
    # name treats angle brackets as a template placeholder, and this repository
    # has already lost a gate run to one.
    It 'leaves no folder inside a folder of its own name' -ForEach $script:copySite {

        $fileSystem = & $Run

        $nested = & $script:selfNested $fileSystem $Destination

        $nested | Should -BeNullOrEmpty -Because ("'{0}' copied a folder into a folder of the same name" -f $Site)
    }

    It 'still delivers the log tree it was asked to copy' -ForEach $script:copySite {

        $fileSystem = & $Run

        $arrived = @($fileSystem.Directory.Keys) | Where-Object {
            ([string] $_).StartsWith($Destination, [System.StringComparison]::OrdinalIgnoreCase)
        }

        $arrived | Should -Not -BeNullOrEmpty -Because ("'{0}' wrote nothing under '{1}'" -f $Site, $Destination)
    }
}
