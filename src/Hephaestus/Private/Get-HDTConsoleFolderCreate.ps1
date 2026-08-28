function Get-HDTConsoleFolderCreate {
    <#
        .SYNOPSIS
            Making a folder from the tree: what to ask for, where the folder
            lands, and the command that puts it there.

        .DESCRIPTION
            THE PARENT IS THE ROW IT WAS ASKED FOR ON, which is what makes ONE
            menu item serve both "a folder at the top" and "a folder inside this
            one". Right-click the category and the new folder is top level;
            right-click a folder and it goes inside that one. Nothing else on the
            screen distinguishes the two presses - the row under the pointer is
            the whole difference - so the parent has to be carried into the path
            rather than assumed.

            THE PROMPT SAYS WHICH OF THE TWO IS ABOUT TO HAPPEN, because the
            dialog is the last point at which anybody can tell. A prompt that
            reads the same either way turns nesting into something discovered
            afterwards, in a tree that then has to be edited to undo it.

            A FOLDER ORGANISES THE WINDOW AND NOTHING ELSE. Nothing moves on
            disk, and a deployment does not know folders exist - a folder is a
            key in workspace.yaml, not a directory. The hint says so, in the
            space its neighbours use, because an administrator who met MDT's
            folders as real directories under the share has every reason to
            assume the opposite.

            WHITESPACE IS NOT A PARENT. The dialog trims what is typed, but a
            parent read off a row can still be blank, and 'Clients\ ' is not a
            folder anybody asked for.

            IT WRITES NOTHING. The caller reads workspace.yaml, splices and
            saves.

        .PARAMETER Root
            The share the folder is being made in.

        .PARAMETER Parent
            The folder it goes inside, or '' for the top of the category.

        .PARAMETER Name
            The name that was typed. May be empty while the prompt is being
            composed, before anybody has typed anything.

        .PARAMETER Category
            The category the folder belongs to, for the echoed command.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Folder        the full folder path, parent included
              Prompt        the sentence to put in the dialog
              DocumentPath  the workspace.yaml to splice
              Command       the Add-HDTWorkspaceFolder line to echo

        .EXAMPLE
            Get-HDTConsoleFolderCreate -Root 'C:\HDTLab\Share' -Parent 'Clients' -Name 'Bare metal'

        .EXAMPLE
            $make = Get-HDTConsoleFolderCreate -Root $where -Parent $action.Parent -Name $typed
            $command.Text = $make.Command
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Parent = '',

        [Parameter(Position = 2)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Name = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $Category = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $hasParent = -not [string]::IsNullOrWhiteSpace($Parent)

    # THE PROMPT SAYS WHICH OF THE TWO IS ABOUT TO HAPPEN.
    $inside = ''
    if ($hasParent) { $inside = ' inside ''{0}''' -f $Parent }

    $prompt = 'A name for the folder{0}. It organises this window and nothing else: nothing moves on disk, and a deployment does not know folders exist.' -f $inside

    # THE PARENT IS THE ROW IT WAS ASKED FOR ON.
    $folder = $Name
    if ($hasParent) { $folder = '{0}\{1}' -f $Parent, $Name }

    return [pscustomobject] @{
        Folder       = $folder
        Prompt       = $prompt
        DocumentPath = [System.IO.Path]::Combine($Root, 'workspace.yaml')
        Command      = "Add-HDTWorkspaceFolder -Line `$line -Category {0} -Folder '{1}'" -f $Category, $folder
    }
}
