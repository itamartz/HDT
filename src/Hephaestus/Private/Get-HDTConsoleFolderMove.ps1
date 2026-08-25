function Get-HDTConsoleFolderMove {
    <#
        .SYNOPSIS
            What moving a row into a folder takes: which commands, against which
            document, and what folder it is in now.

        .DESCRIPTION
            MOVING IS A ONE-KEY EDIT TO THE DOCUMENT, NOT A FILE OPERATION. A
            task sequence stays at TaskSequences\<id> because its id is the path
            the engine resolves it from, and every rule and boot image that names
            it would break if a folder moved it on disk. The folder is a property
            of the document; the window draws the tree from it. Nothing here
            touches the filesystem - it returns the plan and the caller runs it.

            THE SETTER AND THE SAVER HAVE TO BE A PAIR, which is the decision
            this exists for. Each saver validates the lines against its own
            document's keys, so Save-HDTSequenceDocument REFUSES an operating
            system document that Set-HDTOperatingSystemProperty has just written
            correctly. The failure lands after the edit and reads as a broken
            setter, which it is not. Naming both together is what stops a future
            handler pairing them by hand and getting it wrong.

            AN APPLICATION WRITES ITSELF, and is the exception that makes this a
            decision rather than a table lookup. Set-HDTApplication takes a share
            root and an id rather than lines, and saves - so there is nothing to
            read first and no saver to pair. A caller treating all three
            categories alike would hand it a document path it has no parameter
            for.

            A ROW THAT HAS NEVER BEEN IN A FOLDER CARRIES NO Folder PROPERTY at
            all, which is not the same as carrying an empty one - and reading a
            property that is not there throws under StrictMode, inside a click
            handler, where the only symptom is a menu item that does nothing.

            THE ECHO IS A FORMAT, NOT A LINE, because the folder is not known
            until somebody has typed it. The caller fills it in with -f, which is
            the same shape the boot image view already uses.

        .PARAMETER Row
            The selected tree row. Name, HeaderRoot and Subject.Path are read;
            Folder is read when it is there.

        .PARAMETER Category
            Which category the row belongs to, as Get-HDTConsoleFolderAction
            reports it. Anything this window does not move answers 'None'.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Kind           'Document', 'Application' or 'None'
              Current        the folder it is in now, '' for none
              Setter         the command that sets the folder
              Saver          the command that writes it, '' for an application
              DocumentPath   the document to edit, '' for an application
              WorkspaceRoot  the share, for an application
              Id             the application id
              CommandFormat  the line to echo, with {0} for the folder

        .EXAMPLE
            Get-HDTConsoleFolderMove -Row $tree.SelectedItem -Category 'TaskSequence'

        .EXAMPLE
            $move = Get-HDTConsoleFolderMove -Row $chosen -Category $action.Category
            $command.Text = $move.CommandFormat -f $typed
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Row,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [string] $Category
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # NOT $Row.Folder DIRECTLY. See the StrictMode note above.
    $current = ''
    if ($null -ne $Row.PSObject.Properties['Folder']) { $current = [string] $Row.Folder }

    $answer = [pscustomobject] @{
        Kind          = 'None'
        Current       = $current
        Setter        = ''
        Saver         = ''
        DocumentPath  = ''
        WorkspaceRoot = ''
        Id            = ''
        CommandFormat = ''
    }

    if ($Category -eq 'Application') {
        $answer.Kind = 'Application'
        $answer.Setter = 'Set-HDTApplication'
        $answer.WorkspaceRoot = [string] $Row.HeaderRoot
        $answer.Id = [string] $Row.Name
        $answer.CommandFormat = "Set-HDTApplication -WorkspaceRoot '{0}' -Id '{1}' -Folder '{{0}}'" -f
            $answer.WorkspaceRoot, $answer.Id

        return $answer
    }

    if ($Category -eq 'OperatingSystem') {
        $answer.Setter = 'Set-HDTOperatingSystemProperty'
        $answer.Saver = 'Save-HDTOperatingSystemDocument'
    } elseif ($Category -eq 'TaskSequence') {
        $answer.Setter = 'Set-HDTTaskSequenceProperty'
        $answer.Saver = 'Save-HDTSequenceDocument'
    } else {
        # A category this window does not move. Answering with a setter would be
        # guessing at which document it is.
        return $answer
    }

    $answer.Kind = 'Document'
    $answer.DocumentPath = [string] $Row.Subject.Path
    $answer.CommandFormat = "{0} -Line `$line -Folder '{{0}}'" -f $answer.Setter

    return $answer
}
