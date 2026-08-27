function Get-HDTApplyDriversStepTemplate {
    <#
        .SYNOPSIS
            The YAML an ApplyDrivers step starts life as.

        .DESCRIPTION
            THE GROUP LINE IS THE ONE THAT TEACHES THE STEP. MDT's Total Control
            method is a path with variables in it, and an administrator who has
            never seen it will not guess that '%HDTMake%' resolves per machine -
            so the default carries the pattern rather than a placeholder, and the
            comment beside it says the store is theirs to shape. Nothing in HDT
            requires a Make\Model tree; that is a convention, and a share can use
            any folder names at any depth.

            IT RUNS IN WinPE, AFTER THE IMAGE. Injection is offline into the
            applied volume, so a template that defaulted to FullOS would produce
            a step that cannot work and a technician who cannot see why.

        .PARAMETER Name
            The step name. Defaults to MDT's own wording.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[], one line per line of YAML.

        .EXAMPLE
            Get-HDTApplyDriversStepTemplate

        .EXAMPLE
            Get-HDTApplyDriversStepTemplate -Name 'Inject storage drivers'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Inject Drivers'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: ApplyDrivers'
        '  # A folder under Drivers\, and the variables resolve per machine.'
        '  # Your store, your folder names - this is only the usual shape.'
        #
        # SINGLE QUOTES, AND THAT IS NOT A STYLE CHOICE. A YAML double-quoted
        # scalar takes backslash escapes, so "Win11\%HDTMake%" contains the
        # escape \% - which does not exist, and powershell-yaml refuses the
        # whole document with "found unknown escape character". The step that
        # teaches an administrator the variable path would have handed them a
        # sequence.yaml that will not load. A single-quoted scalar is literal.
        "  group: 'Win11\%HDTMake%\%HDTModel%'"
        '  # all = every driver in the group; matching = only what this PC needs'
        '  mode: all'
        '  runIn: WinPE'
    )
}
