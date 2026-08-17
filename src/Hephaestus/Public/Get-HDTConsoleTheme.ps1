function Get-HDTConsoleTheme {
    <#
        .SYNOPSIS
            The colours the console window paints itself with.

        .DESCRIPTION
            ONE WINDOW FILE, TWO PALETTES. HDTConsole.xaml names every colour
            through a DynamicResource key and declares the light values inline,
            so the file renders on its own; the host replaces those resources
            with whichever palette this command returned. The alternative - a
            second XAML - is a hundred and seventy lines that have to be kept
            identical by hand, and they never are.

            LIGHT IS THE DEFAULT because the console is a desktop application
            that sits beside Explorer, the Deployment Workbench it replaces, and
            an administrator's other windows, and it is used in an office rather
            than in front of a server rack. The technician wizard in WinPE keeps
            its dark palette: that one is looked at in a dark room, on a bench,
            on a machine with nothing else on the screen.

            BOTH PALETTES CARRY THE SAME KEYS, and a test asserts it. A key
            present in one and missing from the other renders as an unstyled
            control - black on black, or invisible - and only in the theme
            nobody had open when the change was made.

            THE ACCENT BLUE DOES NOT CHANGE. #FF0E639C is HDT's, it carries
            white text at the required contrast on both palettes, and a product
            whose identity colour moves with the theme has no identity colour.

        .PARAMETER Name
            Light or Dark.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Collections.Specialized.OrderedDictionary - resource key to
            colour, as #AARRGGBB.

        .EXAMPLE
            Get-HDTConsoleTheme -Name Light

        .EXAMPLE
            Show-HDTConsole -Path 'C:\HDTLab\Share' -Theme Dark

            How a caller asks for the other one.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('Light', 'Dark')]
        [string] $Name = 'Light'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($Name -eq 'Dark') {
        return [ordered] @{
            HDTWindowBrush      = '#FF1E1E1E'
            HDTBannerBrush      = '#FF0E639C'
            HDTBannerTextBrush  = '#FFFFFFFF'
            HDTBannerLabelBrush = '#FFBEDCF0'
            HDTPanelBrush       = '#FF252526'
            HDTPanelTextBrush   = '#FFE6E6E6'

            # SECONDARY TEXT AND A REFUSAL. Both are named by markup that had
            # nothing behind them: an undefined DynamicResource does not fail,
            # it silently paints the control's default - which is how a hint
            # meant to be quiet came out the same weight as the label above it,
            # and an error message came out black.
            HDTHintTextBrush    = '#FF9A9A9A'
            HDTErrorBrush       = '#FFF48771'
            HDTBorderBrush      = '#FF3C3C3C'
            HDTLabelBrush       = '#FF9CDCFE'
            HDTCommandBrush     = '#FF1B1B1B'
            HDTCommandTextBrush = '#FFCE9178'
            HDTFieldBrush            = '#FF1B1B1B'
            HDTFooterBrush           = '#FF252526'
            HDTButtonBrush           = '#FF0E639C'
            HDTButtonTextBrush       = '#FFFFFFFF'
            HDTButtonHoverBrush      = '#FF1177BB'
            HDTButtonHoverTextBrush  = '#FFFFFFFF'
            HDTButtonPressedBrush    = '#FF0C5484'
        }
    }

    return [ordered] @{
        HDTWindowBrush      = '#FFF3F3F3'
        HDTBannerBrush      = '#FF0E639C'
        HDTBannerTextBrush  = '#FFFFFFFF'
        HDTBannerLabelBrush = '#FFD6E9F5'
        HDTPanelBrush       = '#FFFFFFFF'
        HDTPanelTextBrush   = '#FF1B1B1B'

        # See the dark theme for why these two exist. Grey enough to read as
        # secondary, dark enough to read at 11pt on white.
        HDTHintTextBrush    = '#FF6B6B6B'
        HDTErrorBrush       = '#FFA31515'
        HDTBorderBrush      = '#FFC8C8C8'
        HDTLabelBrush       = '#FF0E639C'
        HDTCommandBrush     = '#FFF7F7F7'
        HDTCommandTextBrush = '#FFA31515'
        # THE READ-ONLY WASH, AND IT HAS TO BE SEEN TO BE ONE. It was #FAFAFA,
        # which against a white panel is a difference nobody can see - so a box
        # that takes a rename and a box that shows a step count looked exactly
        # alike, on this window and in the editor's Properties pane. Grey enough
        # to read as "not this one", light enough that a pane of them is not a
        # grey slab.
        HDTFieldBrush            = '#FFEDEDED'
        HDTFooterBrush           = '#FFE8E8E8'
        HDTButtonBrush           = '#FF0E639C'
        HDTButtonTextBrush       = '#FFFFFFFF'

        # HOVER IS A LIGHT WASH IN THE LIGHT THEME, SO THE LABEL GOES BLACK.
        # White on #FFCCE4F7 is a contrast ratio of about 1.7:1 - a button that
        # empties as the pointer reaches it. The dark theme's hover goes the
        # other way, so its label stays white. A test measures both rather than
        # trusting the pair to be chosen carefully next time.
        HDTButtonHoverBrush      = '#FFCCE4F7'
        HDTButtonHoverTextBrush  = '#FF000000'
        HDTButtonPressedBrush    = '#FFA9CFEC'
    }
}
