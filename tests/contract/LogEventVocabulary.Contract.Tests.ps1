# DESIGN 4.4.2 calls the JSONL `event` field "a controlled vocabulary", and a
# controlled vocabulary that the design document and the engine disagree about is
# not controlled - it is two lists.
#
# That is not hypothetical: the design listed eleven names while
# Write-HDTLog's ValidateSet accepted thirteen for the whole of phase 03, because
# `reboot.teardown` and `message` were added as the engine was built. The
# vocabulary is a compatibility surface - a report renderer and the console
# filter on it, and so does anyone writing a step type - so the two sides are
# pinned to each other here rather than by anybody remembering.
#
# The design's table is the source read: adding a name to the ValidateSet without
# documenting it fails, and documenting one the engine will not accept fails too.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:designPath = Join-Path -Path $script:repoRoot -ChildPath 'docs/DESIGN.md'
    $script:design = Get-Content -LiteralPath $script:designPath -Raw

    # The table under 4.4.2: rows whose first cell is a backticked event name
    # carrying a dot, which no other table in the document has.
    $script:documented = @([regex]::Matches($script:design, '(?m)^\|\s*`([a-z]+(?:\.[a-z]+)?)`\s*\|') |
            ForEach-Object { $_.Groups[1].Value } |
            Select-Object -Unique)

    $script:accepted = @((Get-Command -Name Write-HDTLog).Parameters['Event'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
            ForEach-Object { $_.ValidValues })
}

Describe 'the DESIGN 4.4.2 event vocabulary' {

    It 'is documented at all' {
        $script:documented.Count | Should -BeGreaterThan 0 -Because 'DESIGN 4.4.2 has to list the vocabulary somewhere this test can read'
    }

    It 'has twenty-four names in the engine' {
        # Fourteen until 2026-08-27, when ApplyDrivers added five driver.* events
        # and the console - which until that day wrote no log at all - added
        # three console.* ones. The number is asserted rather than derived on
        # purpose: it is the tripwire that makes adding a name a deliberate act,
        # documented in DESIGN 4.4.2 in the same change, instead of something
        # that lands in a ValidateSet and is discovered later by a report
        # renderer that does not know the name.
        #
        # THE TWENTY-THIRD IS var.unresolved, ADDED 2026-08-29, AND THE TRIPWIRE
        # DID ITS JOB. var.resolve had three writers in two grammars at two
        # severities, and it also carried three things that are not resolutions:
        # a %Var% nothing supplied, a fact the machine could not determine, and a
        # resolved value the gather declined to overwrite. Those assert the
        # OPPOSITE of a resolution, and ConvertTo-HDTReport - the only consumer
        # in src/ that filters this event, rendering data.name/value/source as a
        # row of the report's Variables table - drew a blank row for every one of
        # them.
        #
        # THE TWENTY-FOURTH IS update.apply, ADDED 2026-09-01 WITH THE
        # WINDOWS UPDATES NODE. It is its own name rather than a step.progress
        # for driver.staged's reason: a pass that applies twenty .msu files
        # produces twenty outcomes worth filtering - applied, already present,
        # prerequisite missing, failed - and one summary line at the end of the
        # step answers none of the questions asked afterwards.
        #
        # ONE NAME WAS ADDED AND NOT THREE. A rule resolution, a SetVariable step
        # and a gathered fact all claim "this variable took this value", so they
        # keep var.resolve, one grammar and data.source as the discriminator -
        # otherwise every consumer asking where a value came from would have to
        # filter three names, and a fourth writer would make it four.
        #
        # THIS IS NOW THE ONLY PLACE THE COUNT IS ASSERTED, and that too was a
        # finding of the same change. tests/unit/Write-HDTLog.Tests.ps1 asserted
        # it as well, against its own hand-kept copy of the name list - one fact,
        # several producers, exactly the shape being fixed - and adding
        # var.unresolved reddened both while only one was updated. Its list had
        # already drifted: it said twenty-two and enumerated fifteen.
        #
        # The number belongs HERE because this is the only file that also reads
        # DESIGN 4.4.2's table, so the count and the document that defines it are
        # checked in one place and cannot disagree.
        $script:accepted.Count | Should -Be 24
    }

    It 'documents every name the engine accepts' {
        $missing = @($script:accepted | Where-Object { $script:documented -notcontains $_ })

        $missing | Should -BeNullOrEmpty -Because ('DESIGN 4.4.2 does not document: {0}' -f ($missing -join ', '))
    }

    It 'accepts every name the design documents' {
        $extra = @($script:documented | Where-Object { $script:accepted -notcontains $_ })

        $extra | Should -BeNullOrEmpty -Because ('Write-HDTLog would reject: {0}' -f ($extra -join ', '))
    }

    It 'documents message, the event a call with no -Event actually writes' {
        # The one most easily forgotten: every custom step's log line under
        # DESIGN 4.4.4 lands under it, because those calls name no event at all.
        # Asserted by WRITING one rather than by reading the parameter's default,
        # which is not visible through Get-Command.
        $script:documented | Should -Contain 'message'

        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force
        $fs = New-HDTFakeFileSystem
        $log = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' -FileSystem $fs `
            -Clock (New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 9, 0, 0, [System.DateTimeKind]::Utc))) -ThreadId 1

        Write-HDTLog -Context $log -Message 'Checking vendor BIOS level'

        (ConvertFrom-Json -InputObject ($fs.ReadAllText($log.JsonlPath).Trim())).event | Should -BeExactly 'message'
    }
}
