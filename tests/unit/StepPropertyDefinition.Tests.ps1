# WHAT A STEP TYPE CAN BE ASKED, as a table rather than as whatever the
# document happens to mention.
#
# THE DEFECT THIS CLOSES, and it is the same one sixteen times over. The
# Properties sheet built one row per key ALREADY IN THE FILE, and a step's
# template writes only the keys it cannot start without. So every other setting
# the engine reads had no row, could not be typed into, and could only be
# reached by opening the YAML in another editor:
#
#   ConfigureBoot   recovery, setBootOrder - both documented switches, both
#                   defaulting to true, neither turn-off-able
#   EnableBitLocker pin, startupKey - while the protector list OFFERED tpmPin
#                   and tpmStartupKey, which need them
#   NoOp            all five of its keys; the sheet was empty
#   Tattoo          both of its keys; the sheet was empty
#   Restart         message - the sentence a technician reads before the reboot
#   InstallRoles    source - the SxS payload path, the .NET 3.5 case
#   ApplyUnattend   target - named in the engine's own refusal message
#   InstallCert     bootstrap
#
# Validate never had the problem, because Get-HDTValidateCheckDefinition already
# did exactly this for that one type: offer every check whether or not the
# document declares it. This is that idea for the rest.
#
# A KEY THE DOCUMENT HAS STILL WINS. The table supplies the row and the DEFAULT;
# the file supplies the value whenever it has one.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    function Get-HDTDefinitionKey {
        param([string] $Type)

        # -Parameters, not a positional: InModuleScope's second position is the
        # parameter HASHTABLE, so passing the type there fails to bind rather
        # than reaching the scriptblock.
        return @(InModuleScope Hephaestus -Parameters @{ T = $Type } {
                    Get-HDTStepPropertyDefinition -Type $T
                } | ForEach-Object { [string] $_.Key })
    }
}

Describe 'Get-HDTStepPropertyDefinition' {

    Context 'the shape every row has' {

        It 'answers a type it knows with rows carrying a key, a label and a kind' {
            $row = @(InModuleScope Hephaestus { Get-HDTStepPropertyDefinition -Type 'Restart' })[0]

            $row.Key | Should -Not -BeNullOrEmpty
            $row.Label | Should -Not -BeNullOrEmpty
            $row.Kind | Should -BeIn @('Text', 'Check', 'Choice', 'Table')
        }

        It 'answers a type it has never heard of with nothing, rather than throwing' {
            # A third-party step type out of Modules\ (CLAUDE.md rule 3) has no
            # table here and must still open: its rows come from the document,
            # the way every row used to.
            $rows = @(InModuleScope Hephaestus { Get-HDTStepPropertyDefinition -Type 'AcmeWidget' })

            $rows.Count | Should -Be 0
        }
    }

    Context 'the settings that had no row at all' {

        It 'offers ConfigureBoot the two switches its own header calls load-bearing' {
            Get-HDTDefinitionKey 'ConfigureBoot' | Should -Contain 'recovery'
            Get-HDTDefinitionKey 'ConfigureBoot' | Should -Contain 'setBootOrder'
        }

        It 'offers BitLocker the keys its protector list makes mandatory' {
            # Picking tpmPin without a pin is a step that fails at the machine.
            # The list offered the protector; nothing offered the pin.
            Get-HDTDefinitionKey 'EnableBitLocker' | Should -Contain 'pin'
            Get-HDTDefinitionKey 'EnableBitLocker' | Should -Contain 'startupKey'
        }

        It 'offers NoOp every key it reads, having offered none' {
            $key = Get-HDTDefinitionKey 'NoOp'

            foreach ($one in @('message', 'exitCode', 'fail', 'failAttempt', 'requestReboot')) {
                $key | Should -Contain $one
            }
        }

        It 'offers Tattoo the registry path it stamps into' {
            Get-HDTDefinitionKey 'Tattoo' | Should -Contain 'path'
        }

        It 'offers Restart the sentence shown before the machine goes down' {
            Get-HDTDefinitionKey 'Restart' | Should -Contain 'message'
        }

        It 'offers Install Roles the payload source for a removed feature' {
            Get-HDTDefinitionKey 'InstallRoles' | Should -Contain 'source'
        }

        It 'offers Apply Windows Settings the target its own refusal names' {
            Get-HDTDefinitionKey 'ApplyUnattend' | Should -Contain 'target'
        }

        It 'offers Install Certificates the bootstrap document it reads' {
            Get-HDTDefinitionKey 'InstallCertificate' | Should -Contain 'bootstrap'
        }
    }

    Context 'the kind each row asks for' {

        It 'makes a documented switch a tick box' {
            $row = @(InModuleScope Hephaestus { Get-HDTStepPropertyDefinition -Type 'ConfigureBoot' } |
                    Where-Object { $_.Key -eq 'setBootOrder' })[0]

            $row.Kind | Should -BeExactly 'Check'
            $row.Default | Should -BeExactly 'true'
        }

        It 'takes a closed set from the one table the engine refuses by' {
            # Get-HDTStepPropertyChoice is what Invoke-HDTEnableBitLockerStep
            # reads its own refusals from. Two lists would drift into a
            # drop-down offering a value the step rejects.
            $row = @(InModuleScope Hephaestus { Get-HDTStepPropertyDefinition -Type 'EnableBitLocker' } |
                    Where-Object { $_.Key -eq 'scope' })[0]

            $row.Kind | Should -BeExactly 'Choice'
            $row.Choice | Should -Be @('usedSpaceOnly', 'full')
        }

        It 'leaves a path a text box' {
            $row = @(InModuleScope Hephaestus { Get-HDTStepPropertyDefinition -Type 'Tattoo' } |
                    Where-Object { $_.Key -eq 'path' })[0]

            $row.Kind | Should -BeExactly 'Text'
        }
    }

    Context 'the defaults it carries' {

        It 'shows what the engine will do, not an empty box' {
            $row = @(InModuleScope Hephaestus { Get-HDTStepPropertyDefinition -Type 'Tattoo' } |
                    Where-Object { $_.Key -eq 'path' })[0]

            $row.Default | Should -BeExactly 'HKLM:\SOFTWARE\Hephaestus\Deployment'
        }

        It 'agrees with the step about the restart message' {
            $row = @(InModuleScope Hephaestus { Get-HDTStepPropertyDefinition -Type 'Restart' } |
                    Where-Object { $_.Key -eq 'message' })[0]

            $row.Default | Should -BeExactly 'a restart was requested'
        }
    }
}

Describe 'the Properties sheet, once the table drives it' {

    BeforeAll {
        $script:workspaceYaml = @'
schemaVersion: 1
id: HDT-LAB
name: HDT share
deployRoot: \\host\HDTShare
'@

        function Get-HDTSheetRow {
            param([string] $Yaml, [string] $StepName)

            $workspace = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem (New-HDTFakeFileSystem -File @{
                    'C:\ws\workspace.yaml'                     = $script:workspaceYaml
                    'C:\ws\TaskSequences\T\sequence.yaml'      = $Yaml
                })

            $editor = Get-HDTConsoleSequenceEditor -Sequence (@($workspace.TaskSequence)[0])
            $step = @($editor.Node | Where-Object { $_.Kind -eq 'Step' -and $_.Name -eq $StepName })[0]

            return @($step.Field)
        }

        $script:bootYaml = @'
schemaVersion: 1
id: T
name: T
steps:
  - name: Configure Boot
    type: ConfigureBoot
    firmware: UEFI
'@

        $script:noopYaml = @'
schemaVersion: 1
id: T
name: T
steps:
  - name: Do Nothing
    type: NoOp
'@
    }

    It 'gives a step a row for a key its document never mentions' {
        $row = @(Get-HDTSheetRow $script:bootYaml 'Configure Boot' | Where-Object { $_.Property -eq 'setBootOrder' })

        $row | Should -Not -BeNullOrEmpty
        $row[0].Editable | Should -BeTrue
    }

    It 'fills that row with what the engine would have done' {
        $row = @(Get-HDTSheetRow $script:bootYaml 'Configure Boot' | Where-Object { $_.Property -eq 'setBootOrder' })[0]

        $row.Value | Should -BeExactly 'true'
        $row.Kind | Should -BeExactly 'Check'
    }

    It 'lets the document win wherever it says something' {
        # The here-string above ends without a newline, so the extra key needs
        # one in front of it or it lands on the end of the firmware line.
        $written = $script:bootYaml + "`n    setBootOrder: false"
        $row = @(Get-HDTSheetRow $written 'Configure Boot' | Where-Object { $_.Property -eq 'setBootOrder' })[0]

        $row.Value | Should -BeExactly 'false'
    }

    It 'gives the empty sheet its five rows back' {
        # A NoOp step showed nothing at all: its template writes name and type,
        # and every behaviour it has lives in a key the template omits.
        $row = @(Get-HDTSheetRow $script:noopYaml 'Do Nothing' | Where-Object { $_.Editable })

        $row.Count | Should -BeGreaterOrEqual 5
    }

    It 'writes nothing for a row nobody touched' {
        # The whole risk of showing defaults: a sheet that banked them would add
        # every key to every step the first time anything was edited, and turn a
        # one-line diff into a twelve-line one (DESIGN 12).
        $row = @(Get-HDTSheetRow $script:bootYaml 'Configure Boot')

        $change = @(Get-HDTConsoleStepChange -Field $row -Name 'Configure Boot')

        $change.Count | Should -Be 0
    }

    It 'writes the one row somebody did touch, and only that one' {
        $row = @(Get-HDTSheetRow $script:bootYaml 'Configure Boot')
        @($row | Where-Object { $_.Property -eq 'recovery' })[0].Value = 'false'

        $change = @(Get-HDTConsoleStepChange -Field $row -Name 'Configure Boot')

        $change.Count | Should -Be 1
        $change[0].Property | Should -BeExactly 'recovery'
        $change[0].Value | Should -BeExactly 'false'
    }

    It 'makes a flat list a line somebody can type, not a dead row' {
        # Install Roles ships 'features: []' and the sheet drew
        # '0 entries - a table, not a value', read-only. So the ONE key the step
        # refuses to run without was the one key the console could not set, and
        # the step could not be made runnable from the UI at all.
        #
        # A COMMA LINE, which is what Get-HDTConsoleValidateCheck already does
        # for requireVariable and what the Command page does for its exit codes.
        $yaml = @'
schemaVersion: 1
id: T
name: T
steps:
  - name: Install Roles and Features
    type: InstallRoles
    features: [Web-Server, Web-Mgmt-Console]
'@

        $row = @(Get-HDTSheetRow $yaml 'Install Roles and Features' |
                Where-Object { $_.Property -eq 'features' })[0]

        $row.Value | Should -BeExactly 'Web-Server, Web-Mgmt-Console'
        $row.Editable | Should -BeTrue
    }

    It 'offers the empty list as an empty box rather than as 0 entries' {
        $yaml = @'
schemaVersion: 1
id: T
name: T
steps:
  - name: Install Roles and Features
    type: InstallRoles
    features: []
'@

        $row = @(Get-HDTSheetRow $yaml 'Install Roles and Features' |
                Where-Object { $_.Property -eq 'features' })[0]

        $row.Value | Should -BeExactly ''
        $row.Editable | Should -BeTrue
    }

    It 'says the change is a list, so the splice writes a sequence and not a string' {
        # Set-HDTStepProperty would quote it - features: 'Web-Server, DNS' - and
        # the step would look for one feature with a comma in its name.
        $yaml = @'
schemaVersion: 1
id: T
name: T
steps:
  - name: Install Roles and Features
    type: InstallRoles
    features: []
'@

        $row = @(Get-HDTSheetRow $yaml 'Install Roles and Features')
        @($row | Where-Object { $_.Property -eq 'features' })[0].Value = 'Web-Server, DNS'

        $change = @(Get-HDTConsoleStepChange -Field $row -Name 'Install Roles and Features')

        $change.Count | Should -Be 1
        $change[0].IsList | Should -BeTrue
        $change[0].Item | Should -Be @('Web-Server', 'DNS')
        $change[0].Command | Should -Match 'Set-HDTStepPropertyList'
    }

    It 'leaves a mapping alone, because a comma line cannot hold one' {
        # Tattoo's 'values' is name -> value. Flattening that to a line would
        # lose which half was which.
        $yaml = @'
schemaVersion: 1
id: T
name: T
steps:
  - name: Tattoo
    type: Tattoo
'@

        $row = @(Get-HDTSheetRow $yaml 'Tattoo' | Where-Object { $_.Label -eq 'Extra values' })[0]

        $row.Editable | Should -BeFalse
    }

    It 'still shows a key the table has never heard of, for a third-party type' {
        $odd = @'
schemaVersion: 1
id: T
name: T
steps:
  - name: Do Nothing
    type: NoOp
    acmeSetting: 7
'@

        $row = @(Get-HDTSheetRow $odd 'Do Nothing' | Where-Object { $_.Property -eq 'acmeSetting' })

        $row | Should -Not -BeNullOrEmpty
        $row[0].Value | Should -BeExactly '7'
    }
}
