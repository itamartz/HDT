function Get-HDTApplyUpdatesStepTemplate {
    <#
        .SYNOPSIS
            The YAML an ApplyUpdates step starts life as.

        .DESCRIPTION
            THE RELEASE LINE IS THE ONE THAT TEACHES THE STEP, and it is the
            reason the default carries a variable rather than a literal. Which
            updates apply depends on which operating system was just laid down,
            and %HDTOSRelease% is what a rule or the wizard sets - so a template
            naming 'Win11-24H2' would produce a step that quietly applies client
            updates to every server the share ever deploys.

            AN EMPTY release IS "EVERYTHING IMPORTED", which is a legitimate
            setting for a share that deploys one operating system, and the
            comment says so rather than leaving an administrator to guess what
            blank means.

            IT RUNS IN WinPE, AFTER THE IMAGE. Injection is offline into the
            applied volume, so a template that defaulted to FullOS would produce
            a step that cannot work and a technician who cannot see why - the
            same trap Get-HDTApplyDriversStepTemplate documents.

            AN EMPTY updates IS THE SAME STATEMENT, and the key ships anyway.
            A share a month old has two cumulative updates for one release, and
            `release` cannot choose between them - it selects everything filed
            under one. The other lever, `enabled` on the update document, is
            SHARE-WIDE: turning one off takes it out of every sequence, which is
            not what "this sequence applies that one" means. `updates` is the
            per-sequence lever, and it is here as an empty list rather than left
            out because a key nobody can see is a key nobody knows they have.

            AND IT GOES BEFORE ApplyUnattend, WHICH THE SAMPLE SEQUENCE SHOWS.
            Servicing an image and then applying the answer file is the order
            that leaves the offlineServicing pass with everything to work from;
            the reverse ordering is what cost 0.10.1 a rebuild on drivers.

        .PARAMETER Name
            The step name. Defaults to 'Apply Windows Updates'.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[], one line per line of YAML.

        .EXAMPLE
            Get-HDTApplyUpdatesStepTemplate

        .EXAMPLE
            Get-HDTApplyUpdatesStepTemplate -Name 'Patch the image'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Apply Windows Updates'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: ApplyUpdates'
        '  # Which release''s updates to apply. Empty applies everything imported.'
        '  # A variable, not a literal: the same sequence deploys more than one OS.'
        "  release: '%HDTOSRelease%'"
        '  # Named updates, by id, when the release holds more than this sequence wants.'
        '  # Empty applies every update for the release, which is what most sequences mean.'
        '  updates: []'
        '  # The applied OS volume. Offline servicing, before the machine first boots.'
        "  target: '%HDTOSVolume%'"
        '  runIn: WinPE'
    )
}
