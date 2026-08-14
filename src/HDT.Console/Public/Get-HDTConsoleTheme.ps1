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
            HDTBorderBrush      = '#FF3C3C3C'
            HDTLabelBrush       = '#FF9CDCFE'
            HDTCommandBrush     = '#FF1B1B1B'
            HDTCommandTextBrush = '#FFCE9178'
            HDTFooterBrush      = '#FF252526'
            HDTButtonBrush      = '#FF0E639C'
            HDTButtonTextBrush  = '#FFFFFFFF'
        }
    }

    return [ordered] @{
        HDTWindowBrush      = '#FFF3F3F3'
        HDTBannerBrush      = '#FF0E639C'
        HDTBannerTextBrush  = '#FFFFFFFF'
        HDTBannerLabelBrush = '#FFD6E9F5'
        HDTPanelBrush       = '#FFFFFFFF'
        HDTPanelTextBrush   = '#FF1B1B1B'
        HDTBorderBrush      = '#FFC8C8C8'
        HDTLabelBrush       = '#FF0E639C'
        HDTCommandBrush     = '#FFF7F7F7'
        HDTCommandTextBrush = '#FFA31515'
        HDTFooterBrush      = '#FFE8E8E8'
        HDTButtonBrush      = '#FF0E639C'
        HDTButtonTextBrush  = '#FFFFFFFF'
    }
}
