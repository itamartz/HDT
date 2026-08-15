function Get-HDTConsoleIconColor {
    <#
        .SYNOPSIS
            The colour one row's icon is drawn in.

        .DESCRIPTION
            A COLOURED ICON IS THE ONE THING ON THIS SCREEN THAT IS READ WITHOUT
            BEING READ. The tree is a wall of near-identical rows; colour is what
            lets somebody find the broken one from across a desk, and it is why
            every console that shows machine state has some.

            MEANING BEFORE DECORATION. Red means something is wrong and nothing
            else is allowed to use it - a screen where four things are red is a
            screen where red means nothing. Amber is for absent rather than
            broken, which is a different problem with a different fix. Green
            appears exactly once, on a deployment that is running, because that
            is the only row on this tree that is ALIVE. Everything structural is
            the console's own blue, and a placeholder is grey so it does not
            compete with content.

            THE COLOURS ARE LITERALS RATHER THAN THEME RESOURCES, deliberately.
            Every other colour in these windows is a DynamicResource so
            Get-HDTConsoleTheme can repaint it; these cannot be, because WPF
            resolves a DynamicResource by a key fixed in the markup and a
            per-ROW key would need a value converter - which markup loaded by
            XamlReader has nowhere to come from (there is no code-behind and no
            assembly to point an xmlns at; see New-HDTConsoleField's note on
            IsReadOnly for the same constraint).

            They are therefore chosen to work on BOTH palettes: mid-tone and
            saturated, dark enough to read on the light panel and light enough
            to read on the dark one. They are Windows' own accessible set - the
            reds and greens Fluent uses for exactly this job - rather than
            invented ones.

            EVERY KIND GETS ONE. A row with no colour would fall back to the
            foreground brush and look like a rendering bug rather than a
            deliberate choice, so the table is total and a test walks
            New-HDTConsoleNode's own ValidateSet to prove it.

        .PARAMETER Kind
            What the row is.

        .PARAMETER Status
            How it is.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - an ARGB colour WPF can bind straight to a Foreground.

        .EXAMPLE
            Get-HDTConsoleIconColor -Kind 'MonitorRun' -Status 'Error'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('Root', 'Share', 'Category', 'TaskSequence', 'OperatingSystem', 'BootImage', 'Empty',
            'DriverStore', 'StepGroup', 'Step', 'MonitorRun', 'MonitorCategory')]
        [string] $Kind,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet('Ok', 'Error', 'Missing')]
        [string] $Status
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Wrong beats everything else it could have been.
    if ($Status -eq 'Error') { return '#FFC42B1C' }

    # Absent is not broken: a boot image that has not been built yet is a job to
    # do, not a fault to chase, and giving it red would send somebody looking
    # for a failure that never happened.
    if ($Status -eq 'Missing') { return '#FFB77400' }

    $colour = @{
        Root            = '#FF0E639C'   # the console's own blue - structure
        Share           = '#FF0E639C'
        Category        = '#FF0E639C'
        TaskSequence    = '#FF8764B8'   # violet - the thing an administrator authors
        OperatingSystem = '#FF0F7B8A'   # teal - content brought in from outside
        BootImage       = '#FF0F7B8A'
        DriverStore     = '#FF0F7B8A'
        StepGroup       = '#FF8764B8'   # a group belongs to its sequence
        Step            = '#FF6E7781'   # grey-blue: many of them, and none is news
        MonitorRun      = '#FF107C10'   # green, and the only green here: it is running
        MonitorCategory = '#FF0E639C'   # structure, like every other category
        Empty           = '#FF767676'   # a placeholder must not compete with content
    }

    return [string] $colour[$Kind]
}
