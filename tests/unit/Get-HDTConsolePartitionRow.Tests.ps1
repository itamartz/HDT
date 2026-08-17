#requires -Modules Pester

# THE GRID'S VIEW MODEL. Everything the Format and Partition Disk panel draws is
# asserted here, because the panel itself is XAML and nothing in Pester runs it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:path = 'X:\Share\Control\DEMO\sequence.yaml'

    $script:authored = [string[]] @(@'
schemaVersion: 1
id: DEMO-GRID
name: partition grid
steps:
  - group: Preinstall
    steps:
      - name: Format and Partition
        type: DiskPartition
        diskNumber: 0
        wipe: true
        partition:
          # the one the firmware boots from
          - name: System
            type: EFI
            size: 260MB
          - name: Windows
            type: Primary
            size: '60%'
            filesystem: NTFS
            variable: OSDisk
          - name: Data
            type: Primary
            size: remainder
'@ -split "`r?`n")

    $script:pinned = [string[]] @(@($script:authored) | ForEach-Object {
            if ($_ -eq '        wipe: true') { '        wipe: true'; '        style: MBR' } else { $_ }
        })

    $script:named = [string[]] @(@'
schemaVersion: 1
id: DEMO-GRID
name: partition grid
steps:
  - group: Preinstall
    steps:
      - name: Format and Partition
        type: DiskPartition
        diskNumber: 0
        wipe: true
        layout: uefi-standard
'@ -split "`r?`n")
}

Describe 'Get-HDTConsolePartitionRow' {

    Context 'a step that writes its own table' {

        It 'gives the grid one row per partition, in document order' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'

            $view.HasTable | Should -BeTrue
            @($view.Row).Count | Should -Be 3
            @($view.Row | ForEach-Object { $_.Name }) | Should -Be @('System', 'Windows', 'Data')
            @($view.Row | ForEach-Object { $_.Order }) | Should -Be @(1, 2, 3)
        }

        It 'shows the size as it was authored, never as a byte count' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'

            # 60% and remainder resolve against the disk in front of the machine.
            # A grid that printed a number here would be this build host
            # answering for a machine that has not booted.
            @($view.Row | ForEach-Object { $_.Size }) | Should -Be @('260MB', '60%', 'remainder')
        }

        It 'carries the columns MDT has on that dialog' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'
            $windows = @($view.Row | Where-Object { $_.Name -eq 'Windows' })[0]

            $windows.Type | Should -Be 'Primary'
            $windows.FileSystem | Should -Be 'NTFS'
            $windows.Variable | Should -Be 'OSDisk'
        }

        It 'leaves a column empty rather than inventing a default for it' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'
            $data = @($view.Row | Where-Object { $_.Name -eq 'Data' })[0]

            # The engine's default for a Primary is NTFS, but the document does
            # not say so. Showing NTFS here would make the grid disagree with the
            # file it is editing.
            $data.FileSystem | Should -Be ''
            $data.Variable | Should -Be ''
        }

        It 'says the style follows the firmware when the step does not pin one' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'

            $view.Style | Should -Be 'follows the firmware'
        }

        It 'says which style when the step pins one' {
            $view = Get-HDTConsolePartitionRow -Line $script:pinned -Path $script:path -Name 'Format and Partition'

            $view.Style | Should -Be 'MBR'
        }
    }

    Context 'the size, taken apart for the two boxes' {

        It 'splits <Written> into <Amount> and <Unit>' -ForEach @(
            @{ Written = '260MB'; Amount = '260'; Unit = 'MB' }
            @{ Written = "'60%'"; Amount = '60'; Unit = '% of what is left' }
            @{ Written = 'remainder'; Amount = ''; Unit = 'the rest of the disk' }
            @{ Written = '1GB'; Amount = '1'; Unit = 'GB' }
            @{ Written = '536870912'; Amount = '536870912'; Unit = 'bytes' }
        ) {
            $wantedAmount = $Amount
            $wantedUnit = $Unit

            $line = [string[]] @(@($script:authored) | ForEach-Object {
                    if ($_ -eq '            size: 260MB') { '            size: {0}' -f $Written } else { $_ }
                })

            $view = Get-HDTConsolePartitionRow -Line $line -Path $script:path -Name 'Format and Partition'
            $system = @($view.Row | Where-Object { $_.Name -eq 'System' })[0]

            $system.Amount | Should -BeExactly $wantedAmount
            $system.Unit | Should -BeExactly $wantedUnit
        }

        It 'offers a unit whose format composes something the engine reads' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'

            # THE WINDOW JOINS NOTHING. Each unit carries the format, and what
            # it composes has to survive the same refusal the build makes.
            foreach ($unit in @($view.Unit)) {
                $composed = $unit.Format -f '60'

                { ConvertTo-HDTDiskLayout -Style GPT -Partition @(
                        @{ name = 'Probe'; type = 'Primary'; size = $composed }) } |
                    Should -Not -Throw -Because ("'{0}' composed '{1}'" -f $unit.Display, $composed)
            }
        }

        It 'says which unit needs no number' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'

            @($view.Unit | Where-Object { -not $_.NeedsAmount } | ForEach-Object { $_.Display }) |
                Should -Be @('the rest of the disk')
        }
    }

    Context "the top of MDT's page" {

        It 'carries the disk number the step names' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'

            $view.DiskNumber | Should -BeExactly '0'
        }

        It 'offers the disk types, with following the firmware among them' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'

            # NOT A CHOICE BETWEEN GPT AND MBR ONLY. The step resolves the style
            # from the firmware when it pins neither, and that is the setting
            # most sequences should keep - so it is on the list rather than
            # being the absence of a choice.
            @($view.StyleOption) | Should -Be @('follows the firmware', 'GPT', 'MBR')
        }

        It 'says whether the disk is wiped' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'

            $view.Wipe | Should -BeTrue
        }
    }

    Context "the two checkboxes on MDT's Partition Properties" {

        It 'reports a row that says neither as the engine defaults' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'
            $data = @($view.Row | Where-Object { $_.Name -eq 'Data' })[0]

            # Quick unless told otherwise, and bootable only on the first row -
            # so the box for Data is ticked and unticked respectively without
            # the document saying either.
            $data.QuickFormat | Should -BeTrue
            $data.Bootable | Should -BeFalse
        }

        It 'reports the first row as bootable, which is MDT default' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'

            @($view.Row)[0].Bootable | Should -BeTrue
        }

        It 'follows what the row actually says when it says it' {
            $line = [string[]] @(@($script:authored) | ForEach-Object {
                    if ($_ -eq '            size: 260MB') {
                        '            size: 260MB'
                        '            quickFormat: false'
                        '            bootable: false'
                    } else { $_ }
                })

            $view = Get-HDTConsolePartitionRow -Line $line -Path $script:path -Name 'Format and Partition'

            @($view.Row)[0].QuickFormat | Should -BeFalse
            @($view.Row)[0].Bootable | Should -BeFalse
        }
    }

    Context 'the command each button would run' {

        It 'names the row it acts on, so the echo is the invocation' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'
            $windows = @($view.Row | Where-Object { $_.Name -eq 'Windows' })[0]

            $windows.RemoveCommand | Should -BeLike "*Remove-HDTStepPartition*-Partition 'Windows'*"
            $windows.UpCommand | Should -BeLike '*-Direction Up*'
            $windows.DownCommand | Should -BeLike '*-Direction Down*'
        }

        It 'gives New a format that produces a command the module exports' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'
            $written = $view.AddCommandFormat -f 'Recovery', 'Recovery', '990MB'

            $written | Should -BeLike '*Add-HDTStepPartition*'
            $written | Should -BeLike "*-Partition 'Recovery'*"
            $written | Should -BeLike "*-Size '990MB'*"

            Get-Command -Name 'Add-HDTStepPartition' -Module 'Hephaestus' | Should -Not -BeNullOrEmpty
        }
    }

    Context 'a step that names a layout instead' {

        It 'says which layout is in force, and carries no table of its own' {
            $view = Get-HDTConsolePartitionRow -Line $script:named -Path $script:path -Name 'Format and Partition'

            # HasTable governs the buttons, and the buttons edit the DOCUMENT -
            # so it means "there are rows in the file", not "there are rows on
            # screen". The layout's volumes are shown; they are not editable.
            $view.HasTable | Should -BeFalse
            $view.Layout | Should -Be 'uefi-standard'
            $view.Summary | Should -BeLike "*uefi-standard*"
        }

        It "shows the layout's own volumes, because that is the disk being built" {
            # AN EMPTY GRID OVER uefi-standard DESCRIBES NOTHING. The step has no
            # table of its own, but it certainly has volumes - three of them -
            # and a page whose whole job is showing the disk should show them.
            $view = Get-HDTConsolePartitionRow -Line $script:named -Path $script:path -Name 'Format and Partition'

            @($view.Row).Count | Should -Be 3
            @($view.Row | ForEach-Object { $_.Name }) | Should -Be @('System', 'Windows', 'Recovery')
        }

        It 'renders their sizes the way an author would have written them' {
            $view = Get-HDTConsolePartitionRow -Line $script:named -Path $script:path -Name 'Format and Partition'

            # 272629760 bytes is 260MB. Printing the byte count would be
            # technically true and unreadable.
            @($view.Row)[0].Size | Should -BeExactly '260MB'
            @($view.Row)[1].Size | Should -BeExactly 'remainder'
        }

        It 'marks them read-only, because the document does not carry them' {
            $view = Get-HDTConsolePartitionRow -Line $script:named -Path $script:path -Name 'Format and Partition'

            # THE BUTTONS STAY DARK. Editing a row here would have to write a
            # table into the step, which silently converts it from "the standard
            # layout, whatever that becomes" to a frozen copy of today's - a
            # decision to make deliberately, not by clicking Edit.
            $view.HasTable | Should -BeFalse
            foreach ($row in @($view.Row)) { $row.FromLayout | Should -BeTrue }
        }

        It 'is still the tab of a DiskPartition step' {
            $view = Get-HDTConsolePartitionRow -Line $script:named -Path $script:path -Name 'Format and Partition'

            $view.IsDiskStep | Should -BeTrue
        }
    }

    Context 'the panel belongs to one step type' {

        It 'says so for a DiskPartition step' {
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition'

            $view.IsDiskStep | Should -BeTrue
        }

        It 'says no for a step of any other type' {
            $other = [string[]] @(@($script:authored) | ForEach-Object {
                    if ($_ -eq '        type: DiskPartition') { '        type: Command' } else { $_ }
                })

            $view = Get-HDTConsolePartitionRow -Line $other -Path $script:path -Name 'Format and Partition'

            $view.IsDiskStep | Should -BeFalse
        }

        It 'says no when a group is selected rather than a step' {
            # The tree selects groups often, and a group is not a step. The
            # question has to survive not finding one rather than throw.
            $view = Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Preinstall'

            $view.IsDiskStep | Should -BeFalse
            @($view.Row).Count | Should -Be 0
        }
    }

    Context 'it is a query' {

        It 'leaves the document exactly as it found it' {
            $before = @($script:authored)

            [void] (Get-HDTConsolePartitionRow -Line $script:authored -Path $script:path -Name 'Format and Partition')

            @($script:authored) | Should -Be $before
        }
    }
}

Describe 'the variable a layout row publishes' {

    # THE COLUMN WAS EMPTY AND THE VARIABLES WERE BEING PUBLISHED ANYWAY. A
    # built-in layout carries no `variable` key - Invoke-HDTDiskPartitionStep
    # publishes HDTSystemVolume, HDTOSVolume and HDTRecoveryVolume by ROLE - so
    # the grid showed nothing in the one column that answers "which volume does
    # the Install OS step apply to".

    BeforeAll {
        $script:layoutView = Get-HDTConsolePartitionRow -Line $script:named `
            -Path $script:path -Name 'Format and Partition'
    }

    It 'names what the step will publish for <Volume>' -ForEach @(
        @{ Volume = 'System'; Variable = 'HDTSystemVolume' }
        @{ Volume = 'Windows'; Variable = 'HDTOSVolume' }
        @{ Volume = 'Recovery'; Variable = 'HDTRecoveryVolume' }
    ) {
        $wanted = $Variable

        $row = @($script:layoutView.Row | Where-Object { $_.Name -eq $Volume })[0]

        $row.Variable | Should -BeExactly $wanted
    }

    It 'leaves an authored row saying what the document says' {
        # AN AUTHORED TABLE NAMES ITS OWN, and a row that names none publishes
        # none - the roles are not what an authored table is keyed on.
        $view = Get-HDTConsolePartitionRow -Line $script:authored `
            -Path $script:path -Name 'Format and Partition'

        @($view.Row | Where-Object { $_.Name -eq 'Windows' })[0].Variable | Should -BeExactly 'OSDisk'
        @($view.Row | Where-Object { $_.Name -eq 'System' })[0].Variable | Should -BeExactly ''
    }
}
