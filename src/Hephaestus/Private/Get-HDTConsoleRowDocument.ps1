function Get-HDTConsoleRowDocument {
    <#
        .SYNOPSIS
            Which document a details-pane edit writes, with which pair of
            commands, and whether the tree has to be rebuilt afterwards.

        .DESCRIPTION
            WHICH DOCUMENT A ROW EDITS IS THE ROW'S KIND, and the pair of
            commands follows from it. A task sequence and an imported operating
            system have the same flat header and two DIFFERENT VALIDATORS, so the
            wrong pair writes a file the other one then refuses to read -
            Save-HDTWorkspaceDocument checks the lines against workspace.yaml's
            keys and refuses a sequence for declaring 'description'. Naming the
            setter and the saver together is what stops a handler pairing them by
            hand and getting it wrong.

            A SHARE POINTS AT ITS workspace.yaml UNDER ANOTHER NAME, and this is
            the reason this command exists rather than a lookup table. A
            workspace projection carries the root it was opened from as well as
            the document, so it has WorkspacePath and NO Path at all. Reading a
            row's .Path first and correcting it for a Share afterwards looks
            equivalent and is not: under Set-StrictMode reading a property that
            is not there is a terminating error, on the dispatcher, which takes
            the window down. It survived in the handler only because a click
            arrives with no strict mode on the stack, and surfaced when a probe
            that sets one drove the same control.

            AN APPLICATION WRITES ITSELF. Set-HDTApplication takes a share and an
            id rather than lines, and saves - there is no
            Save-HDTApplicationDocument to pair it with, because splicing
            app.yaml is what Set-HDTApplicationLine already does inside it. So an
            application row carries no saver and no document path, and a caller
            that treated all four kinds alike would hand it neither of the two
            parameters it does take.

            THE REBUILD IS THE EXPENSIVE HALF - it re-reads every open share and
            revalidates every sequence in it, about a third of a second against
            one lab share and growing with the number open. The tree row reads
            'id - name', so it is stale only when the NAME changed; a description
            is not on it, and re-reading the share to discover that would be
            paying the cost to learn nothing.

            THE KEY IS 'name' AND THE PARAMETER IS -Name. The document spells its
            keys camelCase and the commands spell their parameters PascalCase, so
            the echoed line capitalises the first letter and nothing else -
            'timeoutMinutes' is -TimeoutMinutes, not -Timeoutminutes.

            IT READS NO FILE AND WRITES NONE. This is the decision; the caller
            does the read, the set, the save and the rollback.

        .PARAMETER Row
            The selected tree row. Kind is read always; Subject.WorkspacePath for
            a Share, Subject.Path for the other documents, and HeaderRoot with
            Name for an application.

        .PARAMETER Property
            The document key being edited.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Supported      whether this pane edits this kind of row
              Kind           the row's kind, as given
              IsApplication  the one that writes itself
              DocumentPath   the document to read and save, '' for an application
              Setter         the command that sets the property
              Saver          the command that writes it, '' for an application
              WorkspaceRoot  the share, for an application
              Id             the application id
              Parameter      the setter's parameter name for this key
              NeedsRebuild   whether the tree row is now stale
              CommandFormat  the line to echo, with {0} for the value

        .EXAMPLE
            Get-HDTConsoleRowDocument -Row $tree.SelectedItem -Property 'name'

        .EXAMPLE
            $edit = Get-HDTConsoleRowDocument -Row $selected -Property $row.Property
            if (-not $edit.Supported) { return }
            $command.Text = $edit.CommandFormat -f $typed
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Row,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [string] $Property
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $kind = [string] $Row.Kind

    $answer = [pscustomobject] @{
        Supported     = $false
        Kind          = $kind
        IsApplication = $false
        DocumentPath  = ''
        Setter        = ''
        Saver         = ''
        WorkspaceRoot = ''
        Id            = ''
        Parameter     = ''
        NeedsRebuild  = $false
        CommandFormat = ''
    }

    if (@('TaskSequence', 'OperatingSystem', 'Share', 'Application') -notcontains $kind) { return $answer }

    $answer.Supported = $true

    # THE TREE ROW READS 'id - name'. See the rebuild note above.
    $answer.NeedsRebuild = ($Property -eq 'name')

    # camelCase key, PascalCase parameter.
    if ($Property.Length -gt 0) {
        $answer.Parameter = $Property.Substring(0, 1).ToUpperInvariant() + $Property.Substring(1)
    }

    if ($kind -eq 'Application') {
        $answer.IsApplication = $true
        $answer.Setter = 'Set-HDTApplication'
        $answer.WorkspaceRoot = [string] $Row.HeaderRoot
        $answer.Id = [string] $Row.Name

        # The application echo is composed by the caller: what to pass and what
        # to call it is Get-HDTConsoleApplicationEdit's decision, because the
        # exit codes are int[] and the dependencies string[].
        return $answer
    }

    if ($kind -eq 'Share') {
        $answer.Setter = 'Set-HDTWorkspaceProperty'
        $answer.Saver = 'Save-HDTWorkspaceDocument'

        # ONE BRANCH, NOT AN ASSIGNMENT THEN A CORRECTION - the projection has
        # no Path at all. See the StrictMode note above.
        $answer.DocumentPath = [string] $Row.Subject.WorkspacePath
    } else {
        if ($kind -eq 'OperatingSystem') {
            $answer.Setter = 'Set-HDTOperatingSystemProperty'
            $answer.Saver = 'Save-HDTOperatingSystemDocument'
        } else {
            $answer.Setter = 'Set-HDTTaskSequenceProperty'
            $answer.Saver = 'Save-HDTSequenceDocument'
        }

        $answer.DocumentPath = [string] $Row.Subject.Path
    }

    $answer.CommandFormat = "{0} -Line `$line -{1} '{{0}}'" -f $answer.Setter, $answer.Parameter

    return $answer
}
