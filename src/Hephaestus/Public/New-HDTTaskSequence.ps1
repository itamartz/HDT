function New-HDTTaskSequence {
    <#
        .SYNOPSIS
            Creates a task sequence in a workspace from a template.

        .DESCRIPTION
            Takes an id, a name and a template, and copies that template into
            TaskSequences\<Id>\sequence.yaml, which is where this engine looks
            for a sequence. (The same three answers MDT's New Task Sequence
            wizard asks for, written to a document instead of a Control folder.)

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
            Which template to create it from. Defaults to the client one.

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

        # WHAT THE WIZARD ASKED FOR - the image, the full name, the
        # organisation, the administrator password. They land in the document's
        # own variables block, which is what every step already substitutes
        # from, rather than in a second file that would have to agree with it.
        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Variable,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # [IO.Path]::Combine, NOT Join-Path, ON A CALLER'S PATH. Join-Path resolves
    # the drive qualifier against the real PSDrives and throws "Cannot find
    # drive" for one this process has not got - which is every share under a
    # fake file system, and a mapped drive WinPE has not connected yet.
    #
    # New-HDTWorkspace has carried this note since it was written; this command
    # never got the same treatment, so it could only ever be tested against a
    # path on a drive that happened to exist. A test that built a share on Z:
    # found it - the seeding worked and the sequence could not be created
    # beside it.
    $folder = [System.IO.Path]::Combine($Workspace, 'TaskSequences', $Id)
    $path = [System.IO.Path]::Combine($folder, 'sequence.yaml')

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

    # THE WIZARD'S SETTINGS, SPLICED INTO THE VARIABLES BLOCK. A key the
    # template already carries is REPLACED rather than appended: a document with
    # the same key twice is one the reader takes the last of, and an author
    # reading the first is then wrong about their own file.
    if ($null -ne $Variable -and @($Variable.Keys).Count -gt 0) {
        $spliced = New-Object -TypeName System.Collections.ArrayList
        $pending = New-Object -TypeName System.Collections.ArrayList
        foreach ($key in @($Variable.Keys)) { [void] $pending.Add([string] $key) }

        $inVariables = $false
        $indent = '  '

        for ($index = 0; $index -lt @($written).Count; $index++) {
            $line = [string] $written[$index]

            if ($line -match '^variables:\s*$') {
                $inVariables = $true
                [void] $spliced.Add($line)
                continue
            }

            # BACK OUT TO COLUMN ZERO AND THE BLOCK IS OVER - the next top-level
            # key of the document has started, and anything still pending goes
            # in before it.
            if ($inVariables -and $line -match '^\S') {
                foreach ($key in @($pending)) {
                    [void] $spliced.Add(('{0}{1}: {2}' -f $indent, $key,
                            (Get-HDTConsoleScalarText -Value ([string] $Variable[$key]))))
                }

                $pending.Clear()
                $inVariables = $false
            }

            if ($inVariables -and $line -match '^(\s+)([A-Za-z_][A-Za-z0-9_]*):') {
                $indent = [string] $Matches[1]
                $key = [string] $Matches[2]

                if ($Variable.Contains($key)) {
                    [void] $spliced.Add(('{0}{1}: {2}' -f $indent, $key,
                            (Get-HDTConsoleScalarText -Value ([string] $Variable[$key]))))

                    [void] $pending.Remove($key)
                    continue
                }
            }

            [void] $spliced.Add($line)
        }

        # A DOCUMENT THAT ENDED INSIDE THE BLOCK, or one with no variables block
        # at all: whatever is left is written where it can still be read.
        if (@($pending).Count -gt 0) {
            if (-not $inVariables) { [void] $spliced.Add('variables:') }

            foreach ($key in @($pending)) {
                [void] $spliced.Add(('{0}{1}: {2}' -f '  ', $key,
                        (Get-HDTConsoleScalarText -Value ([string] $Variable[$key]))))
            }
        }

        $written = $spliced
    }

    $FileSystem.WriteAllText($path, (@($written) -join [System.Environment]::NewLine))

    # AND THE ANSWER FILE THE SEQUENCE NAMES. The template's Apply Windows
    # Settings step says 'template: unattend.xml'; without this, every sequence
    # created from it referenced a file nobody supplied and failed at the
    # machine. MDT copies its Unattend_x64.xml into the new sequence's folder
    # for the same reason.
    #
    # IT NEVER OVERWRITES ONE THAT IS THERE. Somebody's answer file is not this
    # command's to replace, and an existing sequence is refused above - so the
    # only way here is a folder holding an unattend and no sequence.
    # $answerSource is the MODULE's own path and always exists, so Join-Path is
    # safe there; $answerPath is the caller's, and is not.
    $answerSource = Join-Path -Path $TemplatePath -ChildPath 'unattend.xml'
    $answerPath = [System.IO.Path]::Combine($folder, 'unattend.xml')

    $moduleFileSystem = New-HDTFileSystem

    if ($moduleFileSystem.TestPath($answerSource) -and -not $FileSystem.TestPath($answerPath)) {
        $FileSystem.WriteAllText($answerPath, [string] $moduleFileSystem.ReadAllText($answerSource))
    }

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
