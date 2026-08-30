function Get-HDTCaptureImageStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new CaptureImage step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            runIn: WinPE IS WRITTEN OUT AND IS LOAD-BEARING. A capture reads the
            volume it is capturing, and a volume with Windows running on it is a
            volume being written while it is read. The whole point of
            sysprepping and restarting first is that this step runs from the
            boot media instead (DESIGN 9.3).

            image: IS THE ONE VALUE, AND IT DEFAULTS TO THE SEQUENCE'S OWN ID.
            %HDTTaskSequenceID% means a share that builds three reference images
            gets three differently named WIMs without anybody typing a name, and
            a second run of the same sequence overwrites its own output rather
            than somebody else's. It is a single-quoted scalar because the value
            carries per cent signs, and a double-quoted one would read a
            backslash as an escape - the trap StepTemplate.Contract.Tests.ps1
            exists for.

            compress: max IS WRITTEN OUT because it is the decision worth seeing.
            A reference image is written once and then stored, copied and read
            for years, so the slow compression is the right default - but it is
            also the one that turns a ten-minute capture into twenty, and an
            author who is turning a lab build round quickly should be able to see
            the setting rather than discover it.

            name: AND description: ARE NOT. The step names the image after the
            file when nothing says otherwise, which is what an administrator
            would have typed anyway; writing them empty would make two more
            boxes to delete.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTCaptureImageStepTemplate

            The YAML lines for a new CaptureImage step, named after its type.

        .EXAMPLE
            $line = Get-HDTCaptureImageStepTemplate -Name 'Capture the reference image'
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
        [string] $Name = 'Capture Image'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: CaptureImage'
        '  runIn: WinPE'
        "  image: '%HDTTaskSequenceID%.wim'"
        '  compress: max'
    )
}
