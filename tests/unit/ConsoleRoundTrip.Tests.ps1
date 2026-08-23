# A load and a save must give the file back unchanged, on every sample we ship.
#
# THIS IS ROADMAP M8'S NAMED "TESTS FIRST" ITEM, and DESIGN 11's constraint
# behind it: "a UI that reformats the file breaks git review". Every other test
# in this console checks one edit in isolation - this one checks the thing an
# administrator actually does, which is open a document, look at it, and close
# it, and it checks it against the real files rather than a fixture written to
# pass.
#
# THE BENCHMARK IS BYTES, NOT MEANING. It is not enough that the result parses
# to the same document: the comments, the blank lines, the key order and the
# indentation are the file, and losing them is the failure this whole splice
# design exists to prevent. The lab's DEMO-M4 is 107 lines of which 51 are a
# header recording SPIKES findings; a round trip through ConvertFrom-HDTYaml
# would hand back a correct sequence and none of that.
#
# IT RUNS OVER EVERY SAMPLE IN THE REPOSITORY, discovered rather than listed, so
# a sequence added to samples/ is covered the day it is added and nobody has to
# remember to add it here.
#
# AND OVER AN EDIT THAT SHOULD CHANGE ONE LINE. A cycle that changed nothing
# would pass on a Save that wrote the file it read; the second half of this
# proves the splice touches exactly the line it was asked to and nothing else.

# THE SAMPLES ARE FOUND AT FILE SCOPE, NOT IN BeforeAll, and that is not a
# style choice. Pester evaluates -ForEach during DISCOVERY, before any BeforeAll
# has run, so a list built in BeforeAll is empty when the cases are expanded -
# the file then reports one passing test and covers nothing. It looked green the
# first time it was run for exactly that reason.
# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# The wrapper opens at the very top, above the tables below, because -ForEach
# is read while Pester is DISCOVERING and $script: inside InModuleScope means
# the module's scope: a table built outside the wrapper and read inside it
# discovers as empty, and the file reports no tests at all rather than failing.
#
# InModuleScope also has to resolve the module while discovery is running, so
# the import is at file scope. The body keeps its own indentation: a here-string
# terminator has to stay at column 0.
$script:hdtRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:hdtRepoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

$script:root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$script:sample = @(
    Get-ChildItem -Path (Join-Path -Path $script:root -ChildPath 'samples') `
        -Filter 'sequence.yaml' -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { @{ Name = $_.Directory.Name; Path = $_.FullName } }
)

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'a load and save cycle on every sample' {

    It 'has samples to cover in the first place' {
        # WITHOUT SAMPLES THE WHOLE FILE IS VACUOUS: -ForEach over an empty list
        # expands to no tests and a green run, which is how a suite that covers
        # nothing looks exactly like one that covers everything.
        #
        # The scan is repeated here rather than reading the discovery-time list,
        # because the two phases do not share a scope - and a guard that read a
        # variable which is empty in this phase would fail while the cases it
        # was guarding ran perfectly well, which is what happened when it did.
        $found = @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath 'samples') `
                -Filter 'sequence.yaml' -Recurse -ErrorAction SilentlyContinue)

        @($found).Count | Should -BeGreaterOrEqual 4
    }

    It 'gives <Name> back byte for byte' -ForEach $script:sample {
        $original = [System.IO.File]::ReadAllText($Path)
        $line = [string[]] @($original -split "`r?`n")

        # The editor's own cycle: split on load, join on save. Save writes
        # through an IFileSystem, so the fake is what receives it and the sample
        # on disk is never touched.
        $script:captured = $null
        $script:capturedPath = $null

        $fake = New-HDTFakeFileSystem -File @{ $Path = $original }
        $fake | Add-Member -MemberType ScriptMethod -Name WriteAllText -Force -Value {
            param([string] $Path, [string] $Text)

            $script:capturedPath = $Path
            $script:captured = $Text
        }

        [void] (Save-HDTSequenceDocument -Path $Path -Line $line -FileSystem $fake -Confirm:$false)

        # It wrote, and it wrote to the file it was opened on - both of this
        # lab's shares hold a DEMO-M4, so "it saved" is only half an answer.
        $script:capturedPath | Should -BeExactly $Path

        $script:captured | Should -BeExactly $original -Because ("{0} came back different from how it went in" -f $Name)
    }

    It 'leaves <Name> readable by the engine after the cycle' -ForEach $script:sample {
        $original = [System.IO.File]::ReadAllText($Path)
        $line = [string[]] @($original -split "`r?`n")

        $state = Get-HDTConsoleEditorState -Line $line -Path $Path

        $state.Status | Should -BeExactly 'Ok' -Because ([string] $state.Message)
    }
}

Describe 'an edit that should change exactly one line' {

    It 'changes only the line it was asked to, in <Name>' -ForEach $script:sample {
        $original = [System.IO.File]::ReadAllText($Path)
        $line = [string[]] @($original -split "`r?`n")

        $state = Get-HDTConsoleEditorState -Line $line -Path $Path
        $step = @($state.Node | Where-Object { $_.Kind -eq 'Step' })

        if (@($step).Count -eq 0) { Set-ItResult -Skipped -Because 'this sample holds no steps'; return }

        $subject = $step[0].Name

        $edited = @(Set-HDTStepFlag -Line $line -Name $subject -Flag Disabled -Value $true)

        # One line added, and it is the one that was added.
        @($edited).Count | Should -Be (@($line).Count + 1)

        $difference = @(Compare-Object -ReferenceObject $line -DifferenceObject $edited |
                Where-Object { $_.SideIndicator -eq '=>' })

        @($difference).Count | Should -Be 1
        $difference[0].InputObject.Trim() | Should -BeExactly 'disabled: true'
    }
}

Describe 'a new group added to a real sample' {

    # THE TWO COMMANDS COMPOSED, ON A FILE THAT SHIPS. Every other test in this
    # area brings its own fixture, and the last two defects here were both "each
    # suite passed on its own document and nothing put the pair together": the
    # menu wrote YAML the engine would not read back. So this presses the New
    # Group button on every sample in the repository and then makes the engine
    # read the result - Add-HDTStep with the template the menu carries, then
    # Import-HDTSequenceDocument, then the tree.

    It 'adds a group to <Name> that the engine still reads' -ForEach $script:sample {
        $original = [System.IO.File]::ReadAllText($Path)
        $line = [string[]] @($original -split "`r?`n")

        $fake = New-HDTFakeFileSystem -File @{ $Path = $original }
        $before = Import-HDTSequenceDocument -Path $Path -FileSystem $fake

        $edited = @(Add-HDTStep -Line $line -After $before.Step[0].Name `
                -Block (Get-HDTGroupTemplate -Name 'Round Trip Group') -Confirm:$false)

        $after = Import-HDTSequenceDocument -Path $Path `
            -FileSystem (New-HDTFakeFileSystem -File @{ $Path = ($edited -join [System.Environment]::NewLine) })

        # A GROUP IS NOT A STEP. Adding one adds no work to the deployment, so
        # every step and every index is exactly what it was.
        @($after.Step | ForEach-Object { $_.Index }) | Should -Be @($before.Step | ForEach-Object { $_.Index })
        @($after.Step | ForEach-Object { $_.Name }) | Should -Be @($before.Step | ForEach-Object { $_.Name })

        @($after.Group | ForEach-Object { $_.Path[-1] }) | Should -Contain 'Round Trip Group'
    }

    It 'adds a group to <Name> that the tree still draws' -ForEach $script:sample {
        $original = [System.IO.File]::ReadAllText($Path)
        $line = [string[]] @($original -split "`r?`n")

        $fake = New-HDTFakeFileSystem -File @{ $Path = $original }
        $before = Import-HDTSequenceDocument -Path $Path -FileSystem $fake

        $edited = @(Add-HDTStep -Line $line -After $before.Step[0].Name `
                -Block (Get-HDTGroupTemplate -Name 'Round Trip Group') -Confirm:$false)

        $state = Get-HDTConsoleEditorState -Line $edited -Path $Path

        $state.Status | Should -BeExactly 'Ok' -Because ([string] $state.Message)

        $row = @($state.Node | Where-Object { $_.Kind -eq 'StepGroup' -and $_.Name -eq 'Round Trip Group' })

        @($row).Count | Should -Be 1
        @($row)[0].Children.Count | Should -Be 0
    }
}


}
