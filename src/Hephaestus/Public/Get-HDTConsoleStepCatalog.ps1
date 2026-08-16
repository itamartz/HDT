function Get-HDTConsoleStepCatalog {
    <#
        .SYNOPSIS
            Builds the Add button's drop-down: every step type this engine can
            run, by category, under the names an MDT administrator knows.

        .DESCRIPTION
            ADD IS A MENU, WHICH IS WORKBENCH'S SHAPE. MDT and ConfigMgr both
            hang a drop-down off Add - General, Disks, Images - and an
            administrator picks 'Apply Operating System' rather than typing a
            type name. This console is meant to be close enough that muscle
            memory transfers, so the menu is a decision, it is made here, and
            every item of it is asserted in
            tests/unit/ConsoleStepCatalog.Tests.ps1. The window hangs the items
            off a button and formats none of them.

            THE LIST IS Get-HDTStepType'S, NOT A LITERAL. That cmdlet is the
            engine's registry and it discovers third-party step types dropped
            into Modules\. A hard-coded menu would offer the ten
            that shipped and quietly omit the one somebody installed this
            morning - a failure that is hard to notice precisely because the
            menu still looks complete.

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
            Add-HDTConsoleStep's -Block route, which is the same paste path the
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
                        Add-HDTConsoleStep call that would create it

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
        'DiskPartition' = @{ Text = 'Format and Partition Disk'; Category = 'Disks'; Order = 1 }
        'ApplyImage'    = @{ Text = 'Apply Operating System'; Category = 'Images'; Order = 1 }
        'ApplyUnattend' = @{ Text = 'Apply Windows Settings'; Category = 'Images'; Order = 2 }
        'ConfigureBoot' = @{ Text = 'Configure Boot'; Category = 'Images'; Order = 3 }
    }

    # Workbench's order, and Custom last because it is whatever this particular
    # installation added.
    $shelf = @('General', 'Disks', 'Images', 'Custom')

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

        if ($known.ContainsKey($name)) {
            $text = [string] $known[$name].Text
            $category = [string] $known[$name].Category
            $order = [int] $known[$name].Order
        }

        # The display name goes to the template as -Name, so the label an
        # administrator picked and the name written into the file are the same
        # string. The type keeps its own default for anything not in the table
        # above, which is the vendor's wording rather than ours.
        $block = [string[]] @(& $template -Name $text)

        [void] $entry.Add([pscustomobject] @{
                Text     = $text
                Type     = $name
                Kind     = 'Step'
                Source   = [string] $type.Source
                Category = $category
                Order    = $order
                Command  = ("Add-HDTConsoleStep -Line `$line -After '<the selected step>' -Name '{0}' -Type {1}" -f $text, $name)

                # The lines the menu item actually splices in, straight from the
                # step type. Every item carries one, group and step alike, so the
                # handler behind the menu calls Add-HDTConsoleStep -Block and
                # never has to choose a parameter set.
                Block    = $block
            })
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
                    Command = "Add-HDTConsoleStep -Line `$line -After '<the selected step>' -Block (Get-HDTGroupTemplate)"

                    # Straight from the engine, including the placeholder step
                    # it comes with - this window does not get to decide what a
                    # group looks like on disk any more than it decides what a
                    # step looks like. Get-HDTGroupTemplate carries the reason
                    # the placeholder is there.
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
