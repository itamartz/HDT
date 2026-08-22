# WHAT CONTROL A PROPERTIES ROW GETS, AND WHY IT IS DECIDED HERE.
#
# The generic Properties sheet drew every row as a text box, so a step whose
# settings are a closed set - EnableBitLocker's four - asked an administrator to
# spell 'usedSpaceOnly' and 'XtsAes256' from memory, and a step whose setting is
# yes-or-no asked them to type the word True. MDT's dialogs are tick boxes and
# drop-downs for exactly these; a box that accepts anything and refuses it at the
# machine is the failure mode this console exists to remove.
#
# THE ROW DECIDES, NOT THE WINDOW. Same rule as Editable and ReadOnly: the row
# carries Kind, the template swaps controls on a DataTrigger, and what an
# administrator sees can be asserted without a screen (CLAUDE.md rule 1 - the
# host stays branch-free and honestly exempt).
#
# KIND IS A STRING RATHER THAN THREE BOOLEANS because a DataTrigger compares a
# value. XamlReader parses markup and nothing else - there is no code-behind to
# host a converter - which is the same reason ReadOnly exists beside Editable.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:workspaceYaml = @'
schemaVersion: 1
id: HDT-LAB-SMB
name: HDT deployment share
deployRoot: \host\HDTShare
'@

    function New-HDTFieldKindSequence {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a projection from an in-memory fake; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true, Position = 0)]
            [ValidateNotNullOrEmpty()]
            [string] $Yaml
        )

        $workspace = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem (New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml'                        = $script:workspaceYaml
                'C:\ws\TaskSequences\KIND\sequence.yaml'      = $Yaml
            })

        return @($workspace.TaskSequence)[0]
    }

    function Get-HDTFieldKindRow {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true, Position = 0)]
            [ValidateNotNullOrEmpty()]
            [string] $Yaml,

            [Parameter(Mandatory = $true, Position = 1)]
            [ValidateNotNullOrEmpty()]
            [string] $Label
        )

        $editor = Get-HDTConsoleSequenceEditor -Sequence (New-HDTFieldKindSequence $Yaml)
        $step = @($editor.Node | Where-Object { $_.Kind -eq 'Step' })[0]

        return @($step.Field | Where-Object { $_.Label -eq $Label })[0]
    }

    $script:bitLockerYaml = @'
schemaVersion: 1
id: KIND
name: Kind
steps:
  - name: Enable BitLocker
    type: EnableBitLocker
    drive: '%HDTOSVolume%'
    scope: usedSpaceOnly
    method: XtsAes256
    protector: tpm
    escrow: ad
    recoveryPassword: true
    wait: false
'@

    $script:bootYaml = @'
schemaVersion: 1
id: KIND
name: Kind
steps:
  - name: Configure Boot
    type: ConfigureBoot
    firmware: UEFI
'@
}

Describe 'New-HDTConsoleField' {

    Context 'the kind of control a row asks for' {

        It 'is a text box unless the row says otherwise' {
            $field = InModuleScope Hephaestus {
                New-HDTConsoleField -Label 'Command' -Value 'setup.exe' -Property 'command'
            }

            $field.Kind | Should -BeExactly 'Text'
        }

        It 'is a list when the row was given one' {
            $field = InModuleScope Hephaestus {
                New-HDTConsoleField -Label 'Scope' -Value 'full' -Property 'scope' -Choice @('usedSpaceOnly', 'full')
            }

            $field.Kind | Should -BeExactly 'Choice'
        }

        It 'is a tick box when the row was told the value is yes-or-no' {
            $field = InModuleScope Hephaestus {
                New-HDTConsoleField -Label 'Wait' -Value 'false' -Property 'wait' -Check
            }

            $field.Kind | Should -BeExactly 'Check'
        }

        It 'keeps HasChoice, because the browser pane still swaps on it' {
            $field = InModuleScope Hephaestus {
                New-HDTConsoleField -Label 'Scope' -Value 'full' -Property 'scope' -Choice @('usedSpaceOnly', 'full')
            }

            $field.HasChoice | Should -BeTrue
        }
    }
}

Describe 'the control a step property gets on the Properties sheet' {

    Context 'a setting the step will only accept from a closed set' {

        It 'offers BitLocker its four scopes rather than asking for the spelling' {
            $row = Get-HDTFieldKindRow $script:bitLockerYaml 'Encrypt'

            $row.Kind | Should -BeExactly 'Choice'
            $row.Choice | Should -Be @('usedSpaceOnly', 'full')
        }

        It 'offers the encryption methods the step implements' {
            $row = Get-HDTFieldKindRow $script:bitLockerYaml 'Method'

            $row.Choice | Should -Be @('Aes128', 'Aes256', 'XtsAes128', 'XtsAes256')
        }

        It 'offers the protectors the step implements' {
            $row = Get-HDTFieldKindRow $script:bitLockerYaml 'Protector'

            $row.Choice | Should -Be @('tpm', 'tpmPin', 'tpmStartupKey')
        }

        It 'offers the escrow targets the step implements' {
            $row = Get-HDTFieldKindRow $script:bitLockerYaml 'Back the key up to'

            $row.Choice | Should -Be @('ad', 'entra', 'none')
        }

        It 'offers ConfigureBoot its three firmware answers, auto among them' {
            # auto is the DEFAULT and the one worth picking on purpose: it reads
            # the machine rather than trusting what the sequence assumed.
            $row = Get-HDTFieldKindRow $script:bootYaml 'Firmware'

            $row.Kind | Should -BeExactly 'Choice'
            $row.Choice | Should -Be @('auto', 'UEFI', 'BIOS')
        }

        It 'leaves a free-text setting alone' {
            $row = Get-HDTFieldKindRow $script:bitLockerYaml 'Drive'

            $row.Kind | Should -BeExactly 'Text'
        }
    }

    Context 'a setting that is yes or no' {

        It 'is a tick box, not a box that wants the word typed' {
            $row = Get-HDTFieldKindRow $script:bitLockerYaml 'Recovery password'

            $row.Kind | Should -BeExactly 'Check'
        }

        It 'still carries the value as the file spells it, because the splice writes that' {
            $row = Get-HDTFieldKindRow $script:bitLockerYaml 'Wait for encryption'

            $row.Value | Should -BeExactly 'false'
        }

        It 'is still editable - a tick box writes the same key a box would' {
            $row = Get-HDTFieldKindRow $script:bitLockerYaml 'Wait for encryption'

            $row.Property | Should -BeExactly 'wait'
            $row.Editable | Should -BeTrue
        }
    }
}

Describe 'a list whose document value is not on it' {

    # WATCHED IN THE PROBE, AND IT IS THE WORST KIND OF WRONG. A sequence that
    # resolves its scope from a variable drew an EMPTY drop-down: the setting
    # looked unset when the file plainly sets it, and opening the list to see
    # what was there would have replaced the variable with a literal and left
    # nothing to say it had ever been one.
    #
    # THE IMAGE TAB ALREADY SETTLED THIS. An image the document names but the
    # share no longer holds "still appears, marked, rather than being silently
    # swapped for whatever sorts first". A step property is the same bargain.

    BeforeAll {
        $script:variableYaml = @'
schemaVersion: 1
id: KIND
name: Kind
steps:
  - name: Enable BitLocker
    type: EnableBitLocker
    scope: '%HDTBitLockerScope%'
    method: Aes999
'@
    }

    It 'shows what the file says, by offering it' {
        $row = Get-HDTFieldKindRow $script:variableYaml 'Encrypt'

        $row.Choice | Should -Contain '%HDTBitLockerScope%'
        $row.Value | Should -BeExactly '%HDTBitLockerScope%'
    }

    It 'puts it first, because it is the one in force' {
        $row = Get-HDTFieldKindRow $script:variableYaml 'Encrypt'

        @($row.Choice)[0] | Should -BeExactly '%HDTBitLockerScope%'
    }

    It 'still offers the ones the step accepts, so it can be corrected' {
        $row = Get-HDTFieldKindRow $script:variableYaml 'Encrypt'

        $row.Choice | Should -Contain 'usedSpaceOnly'
        $row.Choice | Should -Contain 'full'
    }

    It 'does the same for a value that is simply wrong, rather than hiding it' {
        # Aes999 is not an encryption method and the step will refuse it. A box
        # that showed nothing would make a sequence that cannot run look fine.
        $row = Get-HDTFieldKindRow $script:variableYaml 'Method'

        @($row.Choice)[0] | Should -BeExactly 'Aes999'
    }

    It 'leaves a list alone when the document is already on it' {
        $row = Get-HDTFieldKindRow $script:bitLockerYaml 'Encrypt'

        $row.Choice | Should -Be @('usedSpaceOnly', 'full')
    }
}

Describe 'what a tick box splices' {

    Context 'a row WPF has written True into' {

        It 'writes the lower case the file and every template use' {
            # WPF converts a bool to a string as "True". The document says
            # "true", every Get-HDT*StepTemplate writes "true", and DESIGN 12
            # asks the console not to reformat a file it edits - a diff turning
            # "wipe: true" into "wipe: True" is a reformat with no edit in it.
            $row = InModuleScope Hephaestus {
                New-HDTConsoleField -Label 'Wait' -Value 'True' -Property 'wait' -Check
            }
            $row.Original = 'false'

            $change = @(Get-HDTConsoleStepChange -Field @($row) -Name 'Enable BitLocker')

            $change.Count | Should -Be 1
            $change[0].Value | Should -BeExactly 'true'
        }

        It 'says so in the cmdlet it shows, because that string is meant to be pasted' {
            $row = InModuleScope Hephaestus {
                New-HDTConsoleField -Label 'Wait' -Value 'False' -Property 'wait' -Check
            }
            $row.Original = 'true'

            $change = @(Get-HDTConsoleStepChange -Field @($row) -Name 'Enable BitLocker')

            $change[0].Command | Should -Match "-Value 'false'"
        }

        It 'leaves a text row exactly as typed, capitals and all' {
            $row = InModuleScope Hephaestus {
                New-HDTConsoleField -Label 'Drive' -Value 'C:' -Property 'drive'
            }
            $row.Original = 'D:'

            $change = @(Get-HDTConsoleStepChange -Field @($row) -Name 'Enable BitLocker')

            $change[0].Value | Should -BeExactly 'C:'
        }
    }
}
