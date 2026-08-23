function Get-HDTConsoleTheme {
    <#
        .SYNOPSIS
            The colours the console window paints itself with.

        .DESCRIPTION
            ONE PALETTE, AND THE CONSOLE IS LIGHT. HDTConsole.xaml names every
            colour through a DynamicResource key and declares the light values
            inline, so the file renders on its own; the host replaces those
            resources with what this command returns.

            LIGHT, BECAUSE THE CONSOLE IS A DESKTOP APPLICATION that sits beside
            Explorer, the Deployment Workbench it replaces, and an
            administrator's other windows, and it is used in an office rather
            than in front of a server rack.

            THERE WAS A DARK PALETTE AND IT IS GONE. It was never asked for; it
            doubled every colour decision, and the contract that both palettes
            carried the same keys existed only to catch the failure it created -
            a key present in one and missing from the other renders as an
            unstyled control, black on black, and only in the theme nobody had
            open when the change was made. One palette cannot drift from itself.

            THE WinPE WIZARD KEEPS ITS OWN DARK LOOK, and this command has
            nothing to do with it: HDTTheme.xaml is a separate file staged into
            the boot image. That screen is looked at in a dark room, on a bench,
            on a machine with nothing else on it.

            THE ACCENT BLUE IS #FF0E639C. It is HDT's, it carries white text at
            the required contrast, and it does not move.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Collections.Specialized.OrderedDictionary - resource key to
            colour, as #AARRGGBB.

        .EXAMPLE
            Get-HDTConsoleTheme
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'


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

        # NOT THE ERROR RED, AND IT USED TO BE. Both were #FFA31515, and on
        # every dialog that has them the two lines sit one above the other: the
        # refusal, and the command it would have run. Painted alike, a
        # technician cannot tell a complaint from a preview, and the complaints
        # get read as decoration.
        #
        # The console window has no error line at all, which is why red reads
        # correctly THERE and this went unnoticed until somebody asked why the
        # New Deployment Share window had red text on it.
        #
        # Deep blue rather than another warm tone: the dark theme separates the
        # two with a string colour on a dark ground, and the light theme's
        # equivalent has to stay clear of both the error red and the banner blue
        # (#FF0E639C), which is lighter than this.
        HDTCommandTextBrush = '#FF0A3069'
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
