function New-HDTTaskSequence {
    <#
        .SYNOPSIS
            Creates a task sequence in a workspace from a template.

        .DESCRIPTION
            MDT'S New Task Sequence WIZARD, as a command. Its wizard asks for an
            id, a name and a template, then copies that template into the new
            sequence's Control folder; this does the same into
            TaskSequences\<Id>\sequence.yaml, which is where this engine looks.

            IT SPLICES THE TWO LINES IT HAS TO CHANGE and copies the rest
            verbatim. A parse and re-emit would hand back a correct document and
            none of the prose - and half the value of a template is that whoever
            opens the new sequence can read why the steps are in that order.

            IT REFUSES TO WRITE OVER AN EXISTING SEQUENCE. That is the one
            destructive thing this command could do, and there is no reading of
            "new" that means "replace somebody's edited sequence".

            IT DOES NOT VALIDATE THE TEMPLATE HERE. The templates are validated
            by their own suite, on every build; re-checking at creation time
            would put a second opinion in the path of a routine action and
            invite the two to disagree.

        .PARAMETER Workspace
            The deployment share's root.

        .PARAMETER Id
            The sequence's id, which is also its folder name.

        .PARAMETER Name
            What the sequence is called.

        .PARAMETER Template
            Which template to create it from. Defaults to the client one, which
            is what MDT leads with.

        .PARAMETER TemplatePath
            Where templates are read from. Defaults to the ones this module
            ships.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Id, Name, Path and
            StepCount.

        .EXAMPLE
            New-HDTTaskSequence -Workspace C:\HDTLab\Share -Id WIN11 -Name 'Windows 11 bare metal'

        .EXAMPLE
            New-HDTTaskSequence -Workspace C:\HDTLab\Share -Id SRV -Name 'Server 2025' -Template client
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Workspace,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Position = 3)]
        [ValidateNotNullOrEmpty()]
        [string] $Template = 'client',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $TemplatePath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'Templates'),

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $folder = Join-Path -Path (Join-Path -Path $Workspace -ChildPath 'TaskSequences') -ChildPath $Id
    $path = Join-Path -Path $folder -ChildPath 'sequence.yaml'

    if ($FileSystem.TestPath($path)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path -Category ResourceExists `
                    -Message ("this workspace already has a task sequence called '{0}'. Creating over it would discard whatever is in it - remove it first, or choose another id." -f $Id)))
    }

    # THE TEMPLATE IS READ BEFORE ANYTHING IS WRITTEN, so a name that does not
    # exist fails before a folder is created for it.
    #
    # AND IT IS READ THROUGH ITS OWN FILE SYSTEM. -FileSystem is the WORKSPACE's
    # port - the share, which may be a fake, a projection or a UNC path - and a
    # template is module content sitting beside the code. Reading one through
    # the other conflates two different places that only happen to both be
    # files.
    $line = @(Get-HDTSequenceTemplate -Id $Template -Line -Path $TemplatePath `
            -FileSystem (New-HDTFileSystem))

    if (-not $PSCmdlet.ShouldProcess($path, ("Create task sequence '{0}' from the {1} template" -f $Id, $Template))) {
        return [pscustomobject] @{
            Id        = $Id
            Name      = $Name
            Path      = $path
            StepCount = 0
        }
    }

    # THE TWO LINES THAT ARE THIS SEQUENCE'S RATHER THAN THE TEMPLATE'S. Written
    # by splice at the top level, so a step called 'id' or a description
    # mentioning one is untouched: only a key in column zero is the document's
    # own.
    $written = New-Object -TypeName System.Collections.ArrayList
    $seenId = $false
    $seenName = $false

    foreach ($current in $line) {
        if (-not $seenId -and $current -match '^id:\s') {
            [void] $written.Add(('id: {0}' -f (Get-HDTConsoleScalarText -Value $Id)))
            $seenId = $true
            continue
        }

        if (-not $seenName -and $current -match '^name:\s') {
            [void] $written.Add(('name: {0}' -f (Get-HDTConsoleScalarText -Value $Name)))
            $seenName = $true
            continue
        }

        [void] $written.Add([string] $current)
    }

    $FileSystem.WriteAllText($path, (@($written) -join [System.Environment]::NewLine))

    # READ BACK THROUGH THE ENGINE, which is the only honest way to report what
    # was created: a count taken from the lines would be this command's opinion
    # of its own output.
    $document = Import-HDTSequenceDocument -Path $path -FileSystem $FileSystem

    return [pscustomobject] @{
        Id        = [string] $document.Id
        Name      = [string] $document.Name
        Path      = $path
        StepCount = @($document.Step).Count
    }
}
