function Get-HDTConsoleRuleHelp {
    <#
        .SYNOPSIS
            What the ? on the Rules and Bootstrap tabs shows - the expressions a
            rule may use, and every variable, grouped by who sets it.

        .DESCRIPTION
            A RULES FILE IS WRITTEN IN A VOCABULARY NOBODY HOLDS IN THEIR HEAD:
            forty variable names and #Left(...)# expressions. The window that
            edits rules.yaml offered none of it, so the only way to find out
            what may be written was to read DESIGN.md - on another machine,
            because this window is usually open over a share.

            THE LIST IS DERIVED, NEVER TYPED. Get-HDTVariableMap already carries
            every variable, its MDT name, where it comes from and what it means.
            A second list in a XAML file would go stale the first time a variable
            was added, and going stale silently is the whole failure mode of
            documentation kept inside a product.

            THREE GROUPS, BECAUSE THAT IS THE QUESTION BEING ASKED. Somebody
            writing a rule wants to know which names they may SET, which the
            machine will REPORT so they can match on them, and which the engine
            fills in so they should not. The map's Origin is per-source -
            Win32_BIOS.SerialNumber, authored, engine - which is the right grain
            for a document and the wrong one for a panel with a scrollbar.

            AN EXAMPLE, NOT A SIGNATURE. 'Left(text, count)' tells somebody
            nothing they could not guess. The line that shortens a 35-character
            serial to something Windows Setup will accept is the reason they
            opened the panel, so each function is shown as a line that can be
            pasted into the rule, beside what that line produces.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Section - each with
            Kind, Title, Note and Row.

        .EXAMPLE
            (Get-HDTConsoleRuleHelp).Section | Select-Object Kind, Title
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # -- the expressions ------------------------------------------------------
    #
    # THE RESULT IS COMPUTED, NOT WRITTEN DOWN. Expand-HDTRuleExpression is what
    # the engine will run, so a panel that renders its actual answer cannot
    # promise something the engine does not do. A worked example that has drifted
    # from the code is worse than none.
    $sample = 'PC-5784-6600-2634-7495'

    $expression = @(
        [pscustomobject] @{ Name = 'Left'; Example = ('#Left({0}, 15)#' -f $sample)
            Summary = 'The first n characters. What shortens a name to the fifteen Windows Setup will accept.'
        }
        [pscustomobject] @{ Name = 'Right'; Example = '#Right(5784-6600-2634-7495, 8)#'
            Summary = 'The last n characters - the end of a serial number is the half that varies.'
        }
        [pscustomobject] @{ Name = 'Mid'; Example = '#Mid(5784-6600-2634, 6, 4)#'
            Summary = 'n characters from a position, counting from one as VBScript does.'
        }
        [pscustomobject] @{ Name = 'UCase'; Example = '#UCase(lt-0042)#'; Summary = 'Upper case.' }
        [pscustomobject] @{ Name = 'LCase'; Example = '#LCase(LT-0042)#'; Summary = 'Lower case.' }
        [pscustomobject] @{ Name = 'Trim'; Example = '#Trim( LT-0042 )#'
            Summary = 'Removes leading and trailing spaces, for a fact that arrived with some on it.'
        }
    )

    foreach ($row in $expression) {
        $row | Add-Member -MemberType NoteProperty -Name 'Result' `
            -Value ([string] (Expand-HDTRuleExpression -Value ([string] $row.Example)))
    }

    # -- the variables --------------------------------------------------------
    #
    # WHAT AN ADMINISTRATOR WRITES, versus what the machine says about itself,
    # versus what the engine owns. Origins that name a WMI class, the
    # environment or the registry are all one answer to a reader: this arrives,
    # you do not set it.
    $authoredOrigin = @('authored', 'bootstrap')
    $engineOrigin = @('engine', 'step', 'rule')

    $authored = New-Object -TypeName System.Collections.ArrayList
    $gathered = New-Object -TypeName System.Collections.ArrayList
    $engine = New-Object -TypeName System.Collections.ArrayList

    foreach ($variable in @(Get-HDTVariableMap)) {
        $row = [pscustomobject] @{
            Name        = [string] $variable.HDTName
            MdtName     = [string] $variable.MdtName
            Origin      = [string] $variable.Origin
            Description = [string] $variable.Description
        }

        if ($authoredOrigin -contains [string] $variable.Origin) {
            [void] $authored.Add($row)
            continue
        }

        if ($engineOrigin -contains [string] $variable.Origin) {
            [void] $engine.Add($row)
            continue
        }

        # EVERYTHING ELSE IS GATHERED, and that is deliberate rather than a
        # fallthrough: a new fact read from a new WMI class must appear in this
        # panel the day it is added, without anybody remembering to list it.
        [void] $gathered.Add($row)
    }

    $section = @(
        [pscustomobject] @{
            Kind  = 'Expression'
            Title = 'Expressions'
            Note  = "MDT's #Left(...)#, evaluated after %Var%. For anything these cannot do, point the rule at a script with setFrom."
            Row   = @($expression)
        }
        [pscustomobject] @{
            Kind  = 'Authored'
            Title = 'You set these'
            Note  = 'Written in a rule, or in bootstrap.yaml when the machine needs them before the share is reachable.'
            Row   = @($authored | Sort-Object -Property Name)
        }
        [pscustomobject] @{
            Kind  = 'Gathered'
            Title = 'The machine reports these'
            Note  = 'Read from the hardware before any rule runs. Match on them with when:; setting one has no effect.'
            Row   = @($gathered | Sort-Object -Property Name)
        }
        [pscustomobject] @{
            Kind  = 'Engine'
            Title = 'The engine sets these'
            Note  = 'Filled in while the deployment runs. Read them in a step or a condition; do not write them.'
            Row   = @($engine | Sort-Object -Property Name)
        }
    )

    # -- and the same thing flat, for the panel to bind to ---------------------
    #
    # ONE TEMPLATE, NOT A TemplateSelector. The panel shows three shapes -
    # a heading, an expression, a variable - and a window that switches
    # templates on a type is a window whose markup has to know what a variable
    # is. Flattened here, the markup binds three columns and a bold flag and
    # never reasons about any of it.
    $line = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in $section) {
        # Insert IS WHAT A DOUBLE-CLICK PUTS IN THE EDITOR. A heading is not a
        # thing anybody can use, so it offers nothing rather than its own title.
        [void] $line.Add([pscustomobject] @{
                IsHeader = $true
                Left     = [string] $current.Title
                Middle   = ''
                Right    = [string] $current.Note
                Insert   = ''
            })

        foreach ($row in @($current.Row)) {
            if ([string] $current.Kind -eq 'Expression') {
                [void] $line.Add([pscustomobject] @{
                        IsHeader = $false
                        Left     = [string] $row.Example
                        Middle   = [string] $row.Result
                        Right    = [string] $row.Summary
                        Insert   = [string] $row.Example
                    })

                continue
            }

            # THE BARE NAME, NOT %Name%. A variable is written both ways in a
            # rules file - as a key under set:, and as %HDTSerialNumber% inside
            # a value - and the name is the half that is the same in both.
            [void] $line.Add([pscustomobject] @{
                    IsHeader = $false
                    Left     = [string] $row.Name
                    Middle   = [string] $row.MdtName
                    Right    = [string] $row.Description
                    Insert   = [string] $row.Name
                })
        }
    }

    return [pscustomobject] @{ Section = $section; Line = @($line) }
}
