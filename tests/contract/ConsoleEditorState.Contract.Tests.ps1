# EVERY CALLER OF Get-HDTConsoleEditorState GETS THE FIELDS IT READS - and the
# set of callers is READ OUT OF THE SOURCE, not written down here.
#
# CLAUDE.md rule 8: a thing is not added until every surface that must know
# about it does, and the proof is a test written against the SET rather than
# against the one just added. The surface here is every call site of this one
# command, and there are two traps in it.
#
# THE FIRST IS A FIELD THAT STOPS BEING RETURNED. The window is branch-free by
# design: every string on it is one assignment out of this object, so a renamed
# or dropped field is a blank control and no error anywhere - StrictMode is on
# in the command, not in the WPF handler that reads its output.
#
# THE SECOND IS -NoTree, AND IT IS THE ONE THIS FILE WAS ADDED FOR. The switch
# lets a caller skip Get-HDTConsoleStepNode - 164ms of a 365ms click, spent
# building rows the selection path discards. A FUTURE CALLER THAT PASSES IT AND
# THEN BINDS Node OR Root WOULD GET AN EMPTY TREE, silently: an editor that
# opens with no steps in it, which looks like a parse failure and is not one.
# Naming today's two callers would prove nothing about tomorrow's.

Describe 'Get-HDTConsoleEditorState and the callers that read it' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') `
            -Force -ErrorAction Stop

        $script:sourceRoot = Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus'

        # EVERY CALL SITE: the file, the variable the result was assigned to,
        # whether that call asked for the tree to be skipped, and every field
        # read off that variable anywhere in the file.
        $script:callSite = New-Object -TypeName System.Collections.ArrayList

        # THE BUNDLE IS A COPY OF THESE FILES, not a second source. Counting it
        # would double every finding and make a failure name a generated file
        # nobody edits.
        $script:sourceFile = @(Get-ChildItem -LiteralPath $script:sourceRoot -Recurse -Filter '*.ps1' -File |
                Where-Object { $_.Name -ne 'Hephaestus.bundle.ps1' })

        foreach ($file in $script:sourceFile) {
            $body = [System.IO.File]::ReadAllText($file.FullName)
            if ($body -notmatch 'Get-HDTConsoleEditorState') { continue }

            $text = [string[]] @($body -split "`r?`n")

            for ($i = 0; $i -lt $text.Count; $i++) {

                # AN ASSIGNMENT FROM THE COMMAND, which is the only shape that
                # can go on to read a field off the result. A mention in a
                # comment or in comment-based help is not a call, and the help
                # in this module quotes the command several times.
                if ($text[$i] -notmatch '^\s*\$([A-Za-z_][A-Za-z0-9_]*)\s*=[^#]*Get-HDTConsoleEditorState') { continue }

                $variable = [string] $Matches[1]

                # THE WHOLE CALL, however many lines it was written across - a
                # backtick continuation, or a splatted hashtable opened on the
                # first line and closed several below. Reading only the first
                # line would miss `NoTree = $true` inside a splat, which is
                # exactly the form the editor's own refresh uses.
                #
                # AND THE COMMENTS COME OFF FIRST. The rebuild site carries the
                # line 'NO -NoTree HERE' explaining why it does not pass the
                # switch, and reading that as the switch itself flagged the one
                # caller that must never have it. A brace in a comment would
                # skew the balance count below for the same reason.
                $bare = { param([string] $Text) return ($Text -replace '#.*$', '') }

                $call = [string] (& $bare $text[$i])
                $j = $i

                while ($j + 1 -lt $text.Count -and (
                        $call.TrimEnd().EndsWith('`') -or
                        ([regex]::Matches($call, '\{').Count -gt [regex]::Matches($call, '\}').Count))) {

                    $j++
                    $call = '{0} {1}' -f $call, (& $bare $text[$j])
                }

                $read = [string[]] @(
                    [regex]::Matches($body, ('\$' + [regex]::Escape($variable) + '\.([A-Za-z_][A-Za-z0-9_]*)')) |
                        ForEach-Object { [string] $_.Groups[1].Value } |
                        Sort-Object -Unique)

                [void] $script:callSite.Add([pscustomobject] @{
                        File     = [string] $file.FullName
                        Variable = $variable
                        NoTree   = [bool] ($call -match '(-NoTree\b)|(\bNoTree\s*=\s*\$true)')
                        Read     = $read
                    })
            }
        }

        $script:line = [string[]] @(
            'schemaVersion: 1'
            'id: DEMO'
            'name: Demo'
            'variables:'
            '  HDTOSImage: Win11-LTSC-2024'
            'steps:'
            '  - name: Validate'
            '    type: Validate'
            '    minRamMB: 4096'
        )

        $script:path = 'C:\ws\TaskSequences\DEMO\sequence.yaml'

        # THE TWO SHAPES THE COMMAND CAN RETURN, both with a row selected so
        # nothing is absent merely because nothing was clicked.
        $script:whole = InModuleScope -ModuleName 'Hephaestus' -Parameters @{
            Body = $script:line; Where = $script:path } {

            param($Body, $Where)

            Get-HDTConsoleEditorState -Line $Body -Path $Where -SelectedName 'Validate'
        }

        $script:skipped = InModuleScope -ModuleName 'Hephaestus' -Parameters @{
            Body = $script:line; Where = $script:path } {

            param($Body, $Where)

            Get-HDTConsoleEditorState -Line $Body -Path $Where -SelectedName 'Validate' -NoTree
        }

        # NOT FIELDS THE COMMAND PROMISES. PSObject is reflection on any object;
        # Count and Length are what PowerShell puts on a collection.
        $script:notAField = [string[]] @('PSObject', 'PSTypeNames', 'Count', 'Length')
    }

    It 'finds the call sites it is driven by' {
        # If this fails everything below is passing by finding nothing to check.
        @($script:callSite).Count | Should -BeGreaterThan 1
    }

    It 'returns every field any caller reads off it' {
        $offered = [string[]] @($script:whole.PSObject.Properties.Name)

        foreach ($site in @($script:callSite)) {
            foreach ($field in @($site.Read | Where-Object { $_ -notin $script:notAField })) {

                $offered | Should -Contain $field -Because (
                    '{0} reads ${1}.{2}' -f [System.IO.Path]::GetFileName($site.File), $site.Variable, $field)
            }
        }
    }

    # THE ONE THAT STOPS A FUTURE CALLER SILENTLY GETTING AN EMPTY TREE.
    #
    # IF THIS FAILS AND THE CALL SITE LOOKS INNOCENT, check whether two call
    # sites in that file share a variable name. The reads are found by scanning
    # the file for '$name.Field', so two results both called $state cannot be
    # told apart and one's Root read is attributed to both. That is a real
    # ambiguity, not a false alarm - a reader of the source cannot tell them
    # apart either - and the fix is to name them differently, which is why
    # New-HDTConsoleEditorView calls its rebuilt one $treeState.
    It 'never skips the tree for a caller that binds Node or Root' {
        foreach ($site in @($script:callSite | Where-Object { $_.NoTree })) {
            foreach ($bound in @('Node', 'Root')) {

                @($site.Read) | Should -Not -Contain $bound -Because (
                    '{0} passes -NoTree, so ${1}.{2} would always be empty' -f
                    [System.IO.Path]::GetFileName($site.File), $site.Variable, $bound)
            }
        }
    }

    It 'hands a caller that skips the tree every other field it reads' {
        $offered = [string[]] @($script:skipped.PSObject.Properties.Name)

        foreach ($site in @($script:callSite | Where-Object { $_.NoTree })) {
            foreach ($field in @($site.Read | Where-Object { $_ -notin $script:notAField })) {

                $offered | Should -Contain $field -Because (
                    '{0} reads ${1}.{2}' -f [System.IO.Path]::GetFileName($site.File), $site.Variable, $field)
            }
        }
    }

    # AND THE TWO SHAPES STAY THE SAME SHAPE. A caller that switches -NoTree on
    # or off must not have to check for a different set of properties - which is
    # the same bargain Get-HDTConsoleStepNode makes with a sequence that will
    # not parse.
    It 'returns the same set of fields either way' {
        [string[]] @($script:skipped.PSObject.Properties.Name | Sort-Object) |
            Should -Be ([string[]] @($script:whole.PSObject.Properties.Name | Sort-Object))
    }
}
