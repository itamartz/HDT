function Get-HDTCleanVolumeStepTemplate {
    <#
        .SYNOPSIS
            The YAML a new CleanVolume step starts life as.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            IT WRITES 'volume: primary' RATHER THAN LEAVING IT OUT, even though
            primary is the default. This is the step that empties an operating
            system volume, and a step whose target is invisible in the document
            is a step nobody reviews the target of - the one line an author
            should see when they open the sequence is which volume this is
            about.

            'primary' IS %HDTOSVolume%, which is the same word the ApplyImage
            step that follows it uses for the same volume. Two steps naming one
            volume two different ways is how they come to disagree.

        .PARAMETER Name
            The step's name. Defaults to 'Clean the OS volume', which says what
            happens to the machine rather than naming the type.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTCleanVolumeStepTemplate

            The YAML lines for a new CleanVolume step.

        .EXAMPLE
            $line = Get-HDTCleanVolumeStepTemplate -Name 'Delete the old installation'
            $line -join [System.Environment]::NewLine

            The same lines under a name of your own. They are lines, not a
            document: Add-HDTStep splices them into a sequence.yaml so the
            comments and the order of everything already in it survive.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Clean the OS volume'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: CleanVolume'
        '  volume: primary'
    )
}
