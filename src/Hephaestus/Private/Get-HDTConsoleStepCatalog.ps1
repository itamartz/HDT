function Get-HDTConsoleStepCatalog {
    <#
        .SYNOPSIS
            Builds the Add button's drop-down: every step type this engine can
            run, by category, under its display name rather than its type name.

        .DESCRIPTION
            ADD IS A MENU, AND THE MENU IS A DECISION MADE HERE. It hangs off
            the Add button by category - General, Disks, Images - and an
            administrator picks 'Apply Operating System' rather than typing a
            type name. Every item of it is asserted in
            tests/unit/ConsoleStepCatalog.Tests.ps1; the window hangs the items
            off a button and formats none of them. The categories and the
            wording are chosen so that muscle memory from MDT's Workbench
            transfers.

            THE LIST IS Get-HDTStepType'S, NOT A LITERAL. That cmdlet is the
            engine's registry and it discovers third-party step types dropped
            into Modules\. A hard-coded menu would offer the ten that shipped
            and quietly omit the one somebody installed this morning - a
            failure that is hard to notice precisely because the menu still
            looks complete.

            THE YAML IS THE ENGINE'S TOO, AND THAT IS THE POINT OF THIS COMMAND.
            The console is a wrapper around the HDT command line, so a menu item
            can only exist where a command exists to carry it out. Each item's
            Block comes from that type's own Get-HDT<Type>StepTemplate; a type
            the engine cannot author reports CanAdd false and is LEFT OUT, even
            though it is a real type that runs. An earlier version wrote a
            two-line block here for anything in the registry, which made this
            window the only thing in HDT that could create a step and meant it
            was guessing the file format on the engine's behalf.

            THE CATALOG ONLY ADDS THE NAME AND THE SHELF. A type the catalog has
            never heard of is still offered, under Custom, named by its own
            type: being absent from a curated list is not a reason to be
            unbuildable, as long as the engine can build it. That is also why
            the categories are filtered to what is actually registered rather
            than drawn from the catalog - an engine with no imaging steps should
            not show an empty Images submenu.

            'NEW GROUP' COMES FIRST AND IS NOT A STEP TYPE. It has no Invoke
            command and never appears in the registry, so its YAML comes from
            Get-HDTGroupTemplate rather than from a type. It is added through
            Add-HDTStep's -Block route, which is the same paste path the
            Copy button uses. Its Kind says Group so the window can tell the two
            apart without inspecting the command string.

        .PARAMETER StepType
            A pre-built Get-HDTStepType registry. Defaults to the engine's.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per category, each with:

              Category  the submenu's name
              Item      its entries, each with Text, Type, Kind, Source and the
                        Add-HDTStep call that would create it

        .EXAMPLE
            Get-HDTConsoleStepCatalog | ForEach-Object { $_.Category }

        .EXAMPLE
            (Get-HDTConsoleStepCatalog).Item | Format-Table Text, Type, Source
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $StepType
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $registry = $StepType

    if ($null -eq $registry) {
        $registry = @(Get-HDTStepType)
    }

    # The name each type is offered under, and the shelf it sits on. The names
    # are MDT's where MDT has one for the same job, because an administrator
    # arriving from Workbench is looking for the words they already use.
    $known = @{
        'CommandLine'   = @{ Text = 'Run Command Line'; Category = 'General'; Order = 1 }
        'PowerShell'    = @{ Text = 'Run PowerShell Script'; Category = 'General'; Order = 2 }
        'SetVariable'   = @{ Text = 'Set Task Sequence Variable'; Category = 'General'; Order = 3 }
        'Validate'      = @{ Text = 'Validate'; Category = 'General'; Order = 4 }
        'Restart'       = @{ Text = 'Restart Computer'; Category = 'General'; Order = 5 }
        'NoOp'          = @{ Text = 'Do Nothing'; Category = 'General'; Order = 6 }
        'InstallApplications' = @{ Text = 'Install Applications'; Category = 'General'; Order = 7 }

        # MDT PUTS Tattoo IN State Restore AND CALLS IT Tattoo, so this does
        # too: an MDT administrator looking for it will look for that word.
        'Tattoo'        = @{ Text = 'Tattoo'; Category = 'General'; Order = 8 }
        # TWO ENTRIES FOR ONE TYPE, AS MDT'S OWN SEQUENCE HAS. Its Standard
        # Client task sequence carries "Format and Partition Disk (BIOS)" and
        # "(UEFI)", each conditioned on the firmware, because the two disks are
        # laid out differently and one sequence has to deploy to both kinds of
        # machine. Offering one and leaving the author to add the condition is
        # how a sequence comes to lay a GPT disk out on a BIOS machine.
        #
        # Variant is what the template is called with; a type without one is
        # offered once, exactly as before.
        'DiskPartition' = @{
            Text = 'Format and Partition Disk'; Category = 'Disks'; Order = 1
            Variant = @(
                @{ Suffix = ' (UEFI)'; Argument = @{ Firmware = 'UEFI' } }
                @{ Suffix = ' (BIOS)'; Argument = @{ Firmware = 'BIOS' } }
            )
        }
        'ApplyImage'    = @{ Text = 'Apply Operating System'; Category = 'Images'; Order = 1 }
        'ApplyUnattend' = @{ Text = 'Apply Windows Settings'; Category = 'Images'; Order = 2 }

        # MDT CALLS IT 'Inject Drivers' AND SO DOES THIS. An MDT administrator
        # looking for the step they already know must find it under the name
        # they know it by, not under 'ApplyDrivers', which is the type - the
        # thing they will never type.
        #
        # BETWEEN Apply Windows Settings AND Configure Boot, which is MDT's own
        # order and the only one that works: injection is offline into the
        # volume the image was just applied to, so it must come after the apply
        # and before the machine boots off it.
        'ApplyDrivers'  = @{ Text = 'Inject Drivers'; Category = 'Images'; Order = 3 }
        'ConfigureBoot' = @{ Text = 'Configure Boot'; Category = 'Images'; Order = 4 }
        'EnableBitLocker' = @{ Text = 'Enable BitLocker'; Category = 'Disks'; Order = 2 }
        'InstallRoles'  = @{ Text = 'Install Roles and Features'; Category = 'Roles'; Order = 1 }

        # ON THE IMAGES SHELF, AFTER Apply Windows Settings, because that is
        # where it belongs in a sequence: it acts on the volume the image was
        # just applied to, and it has to be there before the Restart below it.
        'InstallCertificate' = @{ Text = 'Install Certificates'; Category = 'Images'; Order = 5 }

        # THE REFERENCE-IMAGE PAIR, ON THE Images SHELF AND LAST, WHICH IS WHERE
        # THEY COME IN A SEQUENCE. MDT keeps its capture under Sysprep and
        # Capture in the State Restore group and names the two steps for what
        # they do rather than for their types; an administrator arriving from
        # Workbench is looking for those words.
        #
        # THEY ARE OFFERED SEPARATELY BECAUSE THEY ARE SEPARATED BY A REBOOT.
        # Sysprep runs in the full OS, the machine restarts into WinPE, and only
        # then can the volume be read - so a single 'Sysprep and Capture' menu
        # item would author one step for something that is three (DESIGN 9.3).
        'Sysprep'       = @{ Text = 'Sysprep'; Category = 'Images'; Order = 6 }
        'CaptureImage'  = @{ Text = 'Capture Image'; Category = 'Images'; Order = 7 }

        # THE THIRD OF THE CAPTURE SEQUENCE, AND THE ONE MDT SPELLS OUT TWICE.
        # Client.xml carries 'Apply Windows PE' and 'Apply Windows PE (BCD)'
        # either side of Execute Sysprep, because a reference build cannot reach
        # WinPE to capture itself without them. It is offered once here and its
        # action property says which half - the console would otherwise need
        # three menu items for one step type.
        'BootToWinPE'   = @{ Text = 'Boot into WinPE'; Category = 'Images'; Order = 8 }
    }

    # Workbench's order, and Custom last because it is whatever this particular
    # installation added.
    # Roles sits after Images and before Custom: a server sequence is mostly that
    # one menu, and Workbench gives it a folder of its own for the same reason.
    $shelf = @('General', 'Disks', 'Images', 'Roles', 'Custom')

    $entry = New-Object -TypeName System.Collections.ArrayList

    foreach ($type in $registry) {
        $name = [string] $type.Type

        # A TYPE THE ENGINE CANNOT AUTHOR IS NOT ON THE MENU. It still runs -
        # a sequence naming it executes exactly as before - but nothing here
        # knows what to write for a new one, and inventing it is what this
        # command was changed to stop doing.
        $template = Get-HDTConsoleStepTemplateCommand -StepType $type

        if ($null -eq $template) { continue }

        $text = $name
        $category = 'Custom'
        $order = 0

        # ONE VARIANT BY DEFAULT, WHICH IS THE TYPE ITSELF. A type that needs
        # more than one menu item says so in the table above; everything else
        # goes round this loop once and is unchanged by the existence of the
        # mechanism.
        $variant = @(@{ Suffix = ''; Argument = @{} })

        if ($known.ContainsKey($name)) {
            $text = [string] $known[$name].Text
            $category = [string] $known[$name].Category
            $order = [int] $known[$name].Order

            if ($known[$name].ContainsKey('Variant')) { $variant = @($known[$name].Variant) }
        }

        $offset = 0

        foreach ($current in $variant) {
            $offset++

            $label = '{0}{1}' -f $text, [string] $current.Suffix
            $argument = @{}
            foreach ($key in @($current.Argument.Keys)) { $argument[$key] = $current.Argument[$key] }

            # The display name goes to the template as -Name, so the label an
            # administrator picked and the name written into the file are the
            # same string. The type keeps its own default for anything not in
            # the table above, which is the vendor's wording rather than ours.
            $block = [string[]] @(& $template -Name $label @argument)

            [void] $entry.Add([pscustomobject] @{
                    Text     = $label
                    Type     = $name
                    Kind     = 'Step'
                    Source   = [string] $type.Source

                    Category = $category

                    # Variants keep their declared order among themselves rather
                    # than sorting alphabetically, so (UEFI) stays above (BIOS):
                    # the list is read top to bottom by somebody choosing, and
                    # the common answer belongs first.
                    Order    = ($order * 100) + $offset

                    Command  = ("Add-HDTStep -Line `$line -After '<the selected step>' -Name '{0}' -Type {1}" -f $label, $name)

                    # The lines the menu item actually splices in, straight from
                    # the step type. Every item carries one, group and step
                    # alike, so the handler behind the menu calls Add-HDTStep
                    # -Block and never has to choose a parameter set.
                    Block    = $block
                })
        }
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    # A group is a block of YAML rather than a registered type, so it is added
    # the way a paste is - and it opens the menu, where Workbench puts it.
    [void] $result.Add([pscustomobject] @{
            Category = 'New'
            Item     = [pscustomobject[]] @(
                [pscustomobject] @{
                    Text    = 'New Group'
                    Type    = ''
                    Kind    = 'Group'
                    Source  = 'Hephaestus'
                    Command = "Add-HDTStep -Line `$line -After '<the selected step>' -Block (Get-HDTGroupTemplate)"

                    # Straight from the engine - this window does not get to
                    # decide what a group looks like on disk any more than it
                    # decides what a step looks like. It is a group and nothing
                    # else: an empty group is a document the engine reads, so
                    # there is no placeholder step to delete afterwards.
                    Block   = [string[]] @(Get-HDTGroupTemplate)
                }
            )
        })

    foreach ($name in $shelf) {
        $item = @($entry | Where-Object { $_.Category -eq $name } |
                Sort-Object -Property Order, Text |
                ForEach-Object {
                    [pscustomobject] @{
                        Text    = $_.Text
                        Type    = $_.Type
                        Kind    = $_.Kind
                        Source  = $_.Source
                        Command = $_.Command
                        Block   = $_.Block
                    }
                })

        # An engine with no imaging steps must not show an empty Images
        # submenu - a shelf with nothing on it reads as a broken menu.
        if (@($item).Count -eq 0) { continue }

        [void] $result.Add([pscustomobject] @{
                Category = $name
                Item     = [pscustomobject[]] @($item)
            })
    }

    return [pscustomobject[]] @($result)
}
