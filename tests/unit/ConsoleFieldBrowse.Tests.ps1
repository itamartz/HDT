# A PATH IS A THING TO POINT AT, NOT A THING TO REMEMBER.
#
# The details pane has a text box and a drop-down and no browse affordance at
# all, so the Output row on a media item - a filesystem path to an ISO - is
# something a technician is expected to type from memory. This is the row
# builder half of the fix: a field may DECLARE that it browses, and one place
# decides what dialog that declaration opens.
#
# WHY A KIND AND NOT A SWITCH. A bare [switch] $Browse would force the window's
# click handler to know that "a browse on a media output row means a save dialog
# filtered to .iso" - a decision, inside an adapter, where nothing can test it.
# A closed set is also a thing a contract can WALK (CLAUDE.md rule 8): the set
# has one member today, Get-HDTConsoleFieldBrowse answers it, and the day
# somebody adds a second the sweep below fails until the mapper learns it.
#
# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope. The
# import sits at file scope because InModuleScope has to resolve the module
# while Pester is still discovering, before any BeforeAll has run.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

    Describe 'New-HDTConsoleField -Browse' {

        It 'carries the kind on the row, so the template and the handler read it off the row rather than keeping a list of which labels browse' {
            $field = New-HDTConsoleField -Label 'Output' -Value 'C:\ws\Media\HYDRA\HDT_HYDRA.iso' `
                -Property 'output' -Browse 'IsoFile'

            [string] $field.Browse | Should -BeExactly 'IsoFile'
        }

        It 'sets HasBrowse, the boolean a DataTrigger can compare - a trigger cannot ask whether a string is empty' {
            $field = New-HDTConsoleField -Label 'Output' -Value 'C:\ws\a.iso' `
                -Property 'output' -Browse 'IsoFile'

            [bool] $field.HasBrowse | Should -BeTrue
        }

        It 'leaves HasBrowse false on every row that does not ask for one' {
            $plain = New-HDTConsoleField -Label 'Description' -Value 'The bench disc.' -Property 'description'
            $read = New-HDTConsoleField -Label 'Id' -Value 'HYDRA'

            [bool] $plain.HasBrowse | Should -BeFalse
            [string] $plain.Browse | Should -BeExactly ''

            [bool] $read.HasBrowse | Should -BeFalse
            [string] $read.Browse | Should -BeExactly ''
        }

        It 'leaves Kind as Text, because a browse is an adjunct to a box and not a fourth kind of row' {
            $field = New-HDTConsoleField -Label 'Output' -Value 'C:\ws\a.iso' `
                -Property 'output' -Browse 'IsoFile'

            [string] $field.Kind | Should -BeExactly 'Text'
        }

        It 'refuses a browse on a row with no Property - a picker with nowhere to put the answer' {
            # A BUTTON THAT OPENS A FILE PICKER AND THEN HAS NOWHERE TO PUT THE
            # ANSWER looks to a technician like a UI that does nothing. Refused
            # at the row builder, the failure names the line that caused it.
            { New-HDTConsoleField -Label 'Output' -Value 'C:\ws\a.iso' -Browse 'IsoFile' } |
                Should -Throw -ExpectedMessage '*no document key*'
        }

        It 'refuses a browse on a Choice row' {
            { New-HDTConsoleField -Label 'Output' -Value 'a' -Property 'output' `
                    -Browse 'IsoFile' -Choice @('a', 'b') } |
                Should -Throw -ExpectedMessage '*not one of a list*'
        }

        It 'refuses a browse on a Check row' {
            { New-HDTConsoleField -Label 'Output' -Value 'true' -Property 'output' `
                    -Browse 'IsoFile' -Check } |
                Should -Throw -ExpectedMessage '*not one of a list*'
        }

        It 'still builds every row that asks for no browse exactly as it did' {
            # THE REGRESSION GUARD. Two properties were added to a shape eleven
            # other panes read; this is the assertion that none of the others
            # moved.
            $field = New-HDTConsoleField -Label 'Selection profile' -Value 'everything' `
                -Property 'selectionProfile' -Hint 'What goes on the disc.' -Choice @('everything', 'boot-critical')

            [string] $field.Label | Should -BeExactly 'Selection profile'
            [string] $field.Value | Should -BeExactly 'everything'
            [string] $field.Property | Should -BeExactly 'selectionProfile'
            [string] $field.Hint | Should -BeExactly 'What goes on the disc.'
            [bool] $field.HasHint | Should -BeTrue
            [bool] $field.Editable | Should -BeTrue
            [bool] $field.HasChoice | Should -BeTrue
            @($field.Choice) | Should -Be @('everything', 'boot-critical')
            [string] $field.Kind | Should -BeExactly 'Choice'
            [bool] $field.ReadOnly | Should -BeFalse
            [string] $field.Original | Should -BeExactly 'everything'
        }
    }

    Describe 'Get-HDTConsoleFieldBrowse' {

        Context 'IsoFile' {

            BeforeAll {
                $script:iso = Get-HDTConsoleFieldBrowse -Kind 'IsoFile' -Current 'C:\ws\Media\HYDRA\HDT_HYDRA.iso'
            }

            It 'asks for a save dialog, because Update-HDTMediaContent creates the file the box names' {
                # NOT AN OPEN DIALOG. CheckFileExists would refuse the one legal
                # answer - the ISO does not exist until the build writes it. The
                # New Media dialog's own output picker made this decision first,
                # with the reasoning written above it in New-HDTConsoleHost.
                [string] $script:iso.Dialog | Should -BeExactly 'Save'
            }

            It 'filters to .iso and keeps an All files escape hatch' {
                # -Match AND NOT -BeLike. A dialog filter is made of asterisks,
                # and -BeLike's wildcard escape is a BACKTICK - so '*\*.iso*'
                # asks for a literal backslash and fails against a filter that
                # is perfectly correct.
                [string] $script:iso.Filter | Should -Match '\*\.iso'
                [string] $script:iso.Filter | Should -Match '\*\.\*'
            }

            It 'titles it in one line, saying where the ISO is written' {
                [string] $script:iso.Title | Should -Not -BeNullOrEmpty
                [string] $script:iso.Title | Should -BeLike '*ISO*'
                [string] $script:iso.Title | Should -Not -BeLike "*`n*"
            }

            It 'seeds the file name and the folder from the path the row already holds' {
                [string] $script:iso.FileName | Should -BeExactly 'HDT_HYDRA.iso'
                [string] $script:iso.Directory | Should -BeExactly 'C:\ws\Media\HYDRA'
            }

            It 'seeds nothing from a value that is not rooted, rather than guessing a folder' {
                # A SHARE-RELATIVE PATH IS RESOLVED BY THE COMMAND, NOT HERE.
                # media.yaml may hold Media\<id>\<id>.iso, and this function is
                # not allowed to touch the disk to find out what that means.
                $relative = Get-HDTConsoleFieldBrowse -Kind 'IsoFile' -Current 'Media\HYDRA\HDT_HYDRA.iso'

                [string] $relative.FileName | Should -BeExactly ''
                [string] $relative.Directory | Should -BeExactly ''
            }

            It 'seeds nothing at all from an empty value - New-HDTMedia owns that default, not this' {
                $empty = Get-HDTConsoleFieldBrowse -Kind 'IsoFile' -Current ''

                [string] $empty.FileName | Should -BeExactly ''
                [string] $empty.Directory | Should -BeExactly ''
                [string] $empty.Dialog | Should -BeExactly 'Save'
            }
        }

        Context 'the set as a whole' {

            # RULE 8 IN MINIATURE. The kinds are read OFF the parameter rather
            # than written down here, so a kind added to the field builder and
            # not to the mapper fails this without anybody remembering to come
            # back and extend a list.
            It 'answers every kind New-HDTConsoleField will accept' {
                $validate = @((Get-Command -Name New-HDTConsoleField).Parameters['Browse'].Attributes |
                        Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })

                $validate.Count | Should -Be 1 -Because 'the browse kinds are a closed set declared on the parameter, which is what makes this sweep possible'

                $kind = @($validate[0].ValidValues)
                $kind.Count | Should -BeGreaterThan 0

                foreach ($one in $kind) {
                    $answer = Get-HDTConsoleFieldBrowse -Kind $one -Current ''

                    [string] $answer.Dialog | Should -Not -BeNullOrEmpty -Because ("{0} must open something" -f $one)
                    [string] $answer.Title | Should -Not -BeNullOrEmpty -Because ("{0} must say what it is picking" -f $one)
                    [string] $answer.Filter | Should -Not -BeNullOrEmpty -Because ("{0} must say what it accepts" -f $one)
                }
            }

            It 'refuses a kind that is not in the set' {
                # THE MESSAGE IS ASSERTED, NOT JUST THE THROW. A bare
                # Should -Throw here passed before the function existed at all -
                # CommandNotFoundException is an exception too - which is a test
                # that is green about nothing. The set error is the one wanted.
                { Get-HDTConsoleFieldBrowse -Kind 'Folder' -Current '' } |
                    Should -Throw -ExpectedMessage '*does not belong to the set*'
            }
        }
    }
}
