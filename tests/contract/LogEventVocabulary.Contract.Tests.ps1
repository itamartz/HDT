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

    It 'has thirteen names in the engine' {
        $script:accepted.Count | Should -Be 13
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
