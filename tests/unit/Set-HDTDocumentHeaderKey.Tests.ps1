# Set-HDTDocumentHeaderKey is the flat-header splice behind
# Set-HDTTaskSequenceProperty, Set-HDTOperatingSystemProperty and now
# Set-HDTMedia. It is private, so every assertion runs inside InModuleScope.
#
# Its two shared surfaces are what this file holds in place: the -Key ValidateSet
# - a key not in it cannot be spliced at all - and -Block, the pattern whose line
# ENDS the header. sequence.yaml and os.yaml both open with scalars and then a
# block; media.yaml has no block at all, and saying so is the difference between
# splicing the whole document and stopping partway down it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:mediaOrder = @('schemaVersion', 'id', 'name', 'description', 'selectionProfile', 'output', 'enabled')
}

Describe 'Set-HDTDocumentHeaderKey' {

    Context 'the keys it will splice' {

        It 'accepts <_>, because a document declares it and something has to edit it' -ForEach @(
            'name'
            'version'
            'description'
            'folder'
            'selectionProfile'
            'output'
            'enabled'
        ) {
            InModuleScope Hephaestus -Parameters @{ Key = $_ } {
                param($Key)

                $line = [string[]] @('schemaVersion: 1', 'id: M1', ('{0}: before' -f $Key))

                { Set-HDTDocumentHeaderKey -Line $line -Key $Key -Value 'after' } | Should -Not -Throw
            }
        }

        It 'refuses a key no document declares, rather than writing one nothing reads' {
            InModuleScope Hephaestus {
                $line = [string[]] @('schemaVersion: 1', 'id: M1')

                { Set-HDTDocumentHeaderKey -Line $line -Key 'mediaPath' -Value 'D:\somewhere' } |
                    Should -Throw
            }
        }
    }

    Context 'a document with no block at all' {

        It 'splices a key that sits below a line the default -Block would have stopped at' {
            # THE PARAMETER IS BEING PASSED FOR THIS CASE AND NO OTHER. With the
            # sequence/os default of 'steps|variables', the scan breaks at the
            # 'steps:' line, never finds 'enabled' below it, and INSERTS a second
            # one higher up - so the document ends with two. '(?!)' never
            # matches, which is how "this document has no nested block" is said.
            InModuleScope Hephaestus -Parameters @{ Order = $script:mediaOrder } {
                param($Order)

                $line = [string[]] @('schemaVersion: 1', 'id: M1', 'steps: 4 of them', 'enabled: true')

                $result = @(Set-HDTDocumentHeaderKey -Line $line -Key 'enabled' -Value 'false' `
                        -Order $Order -Block '(?!)')

                @($result | Where-Object { $_ -match '^enabled\s*:' }).Count |
                    Should -Be 1 -Because 'the key was replaced where it was, not duplicated above the block'

                $result[3] | Should -BeExactly 'enabled: false'
                $result[2] | Should -BeExactly 'steps: 4 of them'
            }
        }

        It 'shows the default -Block getting it wrong on the same document, which is why it is passed' {
            InModuleScope Hephaestus -Parameters @{ Order = $script:mediaOrder } {
                param($Order)

                $line = [string[]] @('schemaVersion: 1', 'id: M1', 'steps: 4 of them', 'enabled: true')

                $result = @(Set-HDTDocumentHeaderKey -Line $line -Key 'enabled' -Value 'false' -Order $Order)

                @($result | Where-Object { $_ -match '^enabled\s*:' }).Count |
                    Should -Be 2 -Because 'the scan stopped at steps: and inserted rather than replaced'
            }
        }
    }

    Context 'what it leaves alone' {

        It 'leaves every line it was not asked about byte-identical' {
            InModuleScope Hephaestus -Parameters @{ Order = $script:mediaOrder } {
                param($Order)

                $line = [string[]] @(
                    '# HDT standalone media definition.',
                    '# Update-HDTMediaContent builds the ISO this names.',
                    '',
                    'schemaVersion: 1',
                    'id: M1',
                    '# the name is what the console shows',
                    'name: Media one',
                    'selectionProfile: everything',
                    'output: Media\M1\HDT_M1.iso',
                    'enabled: true'
                )

                $result = @(Set-HDTDocumentHeaderKey -Line $line -Key 'name' -Value 'Media renamed' `
                        -Order $Order -Block '(?!)')

                @($result).Count | Should -Be @($line).Count

                for ($i = 0; $i -lt @($line).Count; $i++) {
                    if ($i -eq 6) { continue }
                    $result[$i] | Should -BeExactly $line[$i] -Because "line $i was not asked about"
                }

                $result[6] | Should -BeExactly 'name: Media renamed'
            }
        }
    }

    Context 'a value that spans lines, whichever line ending it carries' {

        # THE COLLAPSE REGEX USED TO BE WRITTEN WITH A REAL LINE BREAK PASTED
        # INTO THE PATTERN, in place of \n. That parses - a single-quoted
        # string needs no escape to contain one - but it makes the pattern's
        # MEANING depend on the end-of-line bytes THIS SOURCE FILE happens to
        # be saved with. git's CRLF normalisation can rewrite those bytes on a
        # fresh checkout, so a working tree edited in place (LF preserved)
        # passed every local run while a CI checkout (CRLF) silently stopped
        # collapsing the value at all - reproduced directly from the CI run's
        # own log on 2026-09-04, not re-derived. \r?\n as two ASCII characters
        # is unaffected by any checkout's line-ending choice, which is the
        # whole point of these three cases.

        It 'collapses a value that arrived with <Label>' -ForEach @(
            @{ Label = 'CRLF'; Newline = "`r`n" }
            @{ Label = 'LF only'; Newline = "`n" }
        ) {
            InModuleScope Hephaestus -Parameters @{ Newline = $Newline } {
                param($Newline)

                $line = [string[]] @('schemaVersion: 1', 'id: M1', 'name: Demo')
                $value = 'One line.{0}And another.' -f $Newline

                $result = @(Set-HDTDocumentHeaderKey -Line $line -Key 'name' -Value $value)

                @($result | Where-Object { $_ -like 'name:*' }).Count | Should -Be 1 -Because 'a collapsed value is one line, never a splice that put the next key inside it'
                $result | Should -Contain 'name: One line. And another.'
                @($result).Count | Should -Be @($line).Count -Because 'the collapse must not have added a line'
            }
        }
    }
}
