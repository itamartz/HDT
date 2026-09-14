function Get-HDTConsoleShareNode {
    <#
        .SYNOPSIS
            Builds the rows for one deployment share - the share itself and
            every category beneath it, in the order they are drawn.

        .DESCRIPTION
            One share's subtree, so Get-HDTConsoleTreeNode can hold several of
            them without repeating any of this. The rows start at Depth 1
            because Depth 0 is the Deployment Shares root every share hangs off,
            the way Deployment Workbench roots them.

            THIS FILE IS THE ORDER, NOT THE ROWS. Each category is built by its
            own command - Get-HDTConsoleApplicationNode, ...OperatingSystemNode,
            ...WindowsUpdateNode, ...DriverNode, ...TaskSequenceNode,
            ...SelectionProfileNode, and the boot image, media and monitoring
            builders that were already separate - because what a row of each
            category says has nothing in common with what a row of another says.
            What they do have in common is their place in the share, and that is
            what is here.

            A SHARE THAT WOULD NOT OPEN IS STILL A ROW. With one share, a bad
            path could reasonably throw; with four, throwing means three shares
            an administrator can see nothing of because of a fourth. So a
            failure is a row that says which path failed and why, and the other
            shares are unaffected.

        .PARAMETER Workspace
            A share from Get-HDTConsoleWorkspace, or a failure from
            New-HDTConsoleShareFailure.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] - console nodes in
            display order.

        .EXAMPLE
            Get-HDTConsoleShareNode -Workspace (Get-HDTConsoleWorkspace -Path 'C:\HDTLab\Share')
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Workspace
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $node = New-Object -TypeName System.Collections.ArrayList
    $header = Get-HDTConsoleHeader -Workspace $Workspace

    # -- a share that would not open ---------------------------------------

    if ($Workspace.Status -ne 'Ok') {
        $field = @(
            New-HDTConsoleField -Label 'Path' -Value $Workspace.Root
            New-HDTConsoleField -Label 'Could not be opened' -Value $Workspace.Error
        )

        [void] $node.Add((New-HDTConsoleNode -Depth 1 -Kind 'Share' -Status 'Error' `
                    -Text ('{0} - (could not be opened)' -f $Workspace.Root) `
                    -Field $field `
                    -Command ("Import-HDTWorkspaceDocument -Path '{0}\workspace.yaml'" -f $Workspace.Root) `
                    -Header $header))

        return [pscustomobject[]] @($node)
    }

    # -- the share ---------------------------------------------------------
    #
    # TWO SHAPES, ONE PASS. $node is the flat reading, in display order, and
    # every row is also added to its parent's Children so the window has a tree
    # to expand. Building them separately is how the two would come to disagree.

    # THE THREE THIS ROW SETS, and they arrived here from the Windows PE
    # window's Bootstrap tab: a share's name, where clients reach it and how
    # much it logs are the SHARE's settings, and that tab's subject is the rules
    # file. The id and the schema version are fixed at creation; 'Opened from'
    # is where this console found it.
    #
    # THE CREDENTIAL IS NOT AMONG THEM. Setting it writes two things - a line in
    # workspace.yaml and a protected file beside it - so a box writing one would
    # leave a share declaring an account no secret exists for, which is a build
    # that refuses. Set-HDTShareCredential does both.
    $shareField = @(
        New-HDTConsoleField -Label 'Share' -Value $Workspace.Name -Property 'name'
        New-HDTConsoleField -Label 'Id' -Value $Workspace.Id
        New-HDTConsoleField -Label 'Schema version' -Value $Workspace.SchemaVersion
        New-HDTConsoleField -Label 'Opened from' -Value $Workspace.Root
        # THE TWO PATHS ARE NOT THE SAME PATH, and they sit next to each other:
        # 'Opened from' is the disk this console reached the share on, and this
        # is what a machine in WinPE dials. A local path here is a share that
        # deploys nothing.
        #
        # AND IT SHOULD BE A NAME, NOT AN ADDRESS. deployRoot is baked into the
        # boot image at build time, and this lab's host address is a DHCP lease
        # that moves when the Wi-Fi changes - a name survives what an octet does
        # not. That is a sentence too many for a tooltip, so the hint carries the
        # trap a technician hits and this comment carries the reason.
        New-HDTConsoleField -Label 'Deploy root' -Value $Workspace.DeployRoot -Property 'deployRoot' `
            -Hint ('What a machine in WinPE connects to - not the path above, which is only where this ' +
            'console opened the share. A local path here is a share that deploys nothing.')

        # INFO IS THE ORDINARY SETTING and Debug is not a louder version of it:
        # it logs every variable resolution, which is what makes it the level to
        # turn on for a deployment that is failing and off again afterwards.
        New-HDTConsoleField -Label 'Log level' -Value $Workspace.LogLevel -Property 'logLevel' `
            -Choice (Get-HDTWorkspaceLogLevel) `
            -Hint ('How much every deployment from this share writes. Info is the ordinary setting; ' +
            'Debug logs every variable resolution and is worth turning back afterwards.')

        # READ-ONLY ON PURPOSE, and the hint says so rather than leaving a
        # technician to discover it by clicking. Setting it writes two things -
        # this line and a protected file beside it - so a box that wrote one
        # would leave the share naming an account no secret exists for, which is
        # a build that refuses.
        New-HDTConsoleField -Label 'Credential' -Value (Get-HDTConsoleDisplayText -Text $Workspace.CredentialUser -Fallback '(none - the share is opened as the signed-in user)') `
            -Hint ('Read-only here: setting it writes this line and a protected file beside it. ' +
            'Set-HDTShareCredential writes both.')
        New-HDTConsoleField -Label 'Document' -Value $Workspace.WorkspacePath

        # DESIGN 12's inline validation, on the share's own document. What
        # CustomSettings.ini was: a rules.yaml that will not parse breaks every
        # deployment from this share, so it is reported here rather than under
        # any one category - and the refusal shown is the engine's own, the same
        # one the Windows PE window's Rules tab puts under the box.
        New-HDTConsoleField -Label 'Rules' `
            -Value (Get-HDTConsoleDisplayText -Text $Workspace.Rule.Problem -Fallback ([string] $Workspace.Rule.Summary)) `
            -Hint ('Read-only here: the rules are edited on the Rules tab of the Windows PE window. ' +
            'Add-HDTRule and Save-HDTRuleDocument write them.')
    )

    # RED ONLY EVER MEANS WRONG. A share with no rules.yaml is one nobody has
    # configured - every variable falls to its default - and that is every new
    # share there is; only a document that will not parse marks the row.
    $shareStatus = 'Ok'
    if ([string] $Workspace.Rule.Status -eq 'Error') { $shareStatus = 'Error' }

    $shareNode = New-HDTConsoleNode -Depth 1 -Kind 'Share' -Status $shareStatus `
        -Text ('{0} ({1})' -f $Workspace.Name, $Workspace.Id) `
        -Field $shareField `
        -Command ("Import-HDTWorkspaceDocument -Path '{0}\workspace.yaml'" -f $Workspace.Root) `
        -Header $header -Subject $Workspace

    [void] $node.Add($shareNode)

    # ONE CATEGORY AT A TIME, BUILT WHOLE AND ADDED WHOLE.
    #
    # TWO SHAPES, ONE PASS. $node is the flat reading, in display order, and
    # every row is also in its parent's Children so the window has a tree to
    # expand. Building them separately is how the two would come to disagree, so
    # a category builder returns its rows in display order with the category
    # first and its own Children already wired, and this adds the whole list to
    # one shape and the category to the other.
    $addCategory = {
        param([object[]] $Row)

        foreach ($current in @($Row)) { [void] $node.Add($current) }
        [void] $shareNode.Children.Add($Row[0])
    }

    # -- the boot image ----------------------------------------------------

    $bootFolder = Get-HDTWorkspacePath -Root $Workspace.Root -Kind Boot

    # NAMED, LIKE THE OTHER THREE CATEGORIES, because a window matches on Name
    # and reads Text. And it carries workspace.yaml: the Windows PE window hangs
    # off this row as well as off the image under it, and that window edits the
    # document rather than the share root.
    # THE CATEGORY WEARS WHAT IT HOLDS. Every category here used to fall
    # through to Kind 'Category', which is a closed folder - so five of the seven
    # rows under a share were the same picture stacked on top of each other.
    # Drivers and Selection Profiles already asked for a named glyph; these four
    # now do the same. See Get-HDTConsoleIcon.
    $bootCategory = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' `
        -Name 'BootImage' -Text 'Boot Image' `
        -Icon (Get-HDTConsoleIcon -Kind 'BootImage' -Status 'Ok') `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $bootFolder
        New-HDTConsoleField -Label 'Image name' -Value $Workspace.BootImage.Name
    ) `
        -Command ("Get-HDTWorkspacePath -Root '{0}' -Kind Boot" -f $Workspace.Root) `
        -Header $header -Subject $Workspace.WorkspacePath

    $bootNode = Get-HDTConsoleBootImageNode -BootImage $Workspace.BootImage -Workspace $Workspace -Header $header

    [void] $bootCategory.Children.Add($bootNode)

    & $addCategory @($bootCategory, $bootNode)

    # -- what a share holds --------------------------------------------------
    #
    # THE CATEGORY ORDER IS THE ORDER A SHARE IS BUILT IN, and it is not
    # Workbench's alphabetical-ish one. A share is useless until it has an image
    # that boots and an OS to lay down; applications and updates are what goes on
    # top of that OS; drivers make it work on the hardware in front of you; the
    # task sequence is what finally ties them together, and it is the thing that
    # can only be written once the others exist. Reading top to bottom is reading
    # the order the work happens in.
    #
    # SELECTION PROFILES AND MEDIA COME AFTER THE CONTENT, where MDT puts them:
    # Advanced Configuration, because both are share-wide configuration rather
    # than another thing to build. MONITORING COMES LAST, after all of it, for
    # the same reason - it is the share IN USE.
    #
    # ONE BUILDER EACH, AND THE ORDER IS HERE. What a row of each category says
    # differs entirely - a row of updates is nothing like a row of drivers - and
    # each of those readings is its own file. What they have in common is only
    # this line and their place in it, which is what this list is.

    & $addCategory @(Get-HDTConsoleApplicationNode -Workspace $Workspace -Header $header)
    & $addCategory @(Get-HDTConsoleOperatingSystemNode -Workspace $Workspace -Header $header)
    & $addCategory @(Get-HDTConsoleWindowsUpdateNode -Workspace $Workspace -Header $header)
    & $addCategory @(Get-HDTConsoleDriverNode -Workspace $Workspace -Header $header)
    & $addCategory @(Get-HDTConsoleTaskSequenceNode -Workspace $Workspace -Header $header)
    & $addCategory @(Get-HDTConsoleSelectionProfileNode -Workspace $Workspace -Header $header)

    # -- standalone media ---------------------------------------------------
    #
    # AFTER THE PROFILES AND BEFORE MONITORING, and both halves of that are the
    # decision. A media definition is SHARE-WIDE CONFIGURATION like a profile -
    # MDT puts both under Advanced Configuration, and a media item is a
    # selection profile pointed at a disc - so it belongs beside one rather than
    # among the content categories. Monitoring stays last because it is the
    # share IN USE rather than another thing to build.
    #
    # THE WHOLE SUBTREE IS Get-HDTConsoleMediaNode'S, the way every other
    # category's is: what a row of one category says has nothing in common with
    # what a row of another says, and this file composes them rather than
    # spelling any of them out.
    #
    # AND IT IS HANDED THE PROFILES THIS FILE ALREADY READ, rather than reading
    # them again: the media row draws its selection profile as a LIST of this
    # share's ids, and the list the row offers has to be the same collection the
    # Selection Profiles category above lists. Two reads of one document are two
    # answers waiting to disagree.
    $mediaCategory = Get-HDTConsoleMediaNode -Media $Workspace.Media `
        -MediaFailure $Workspace.MediaFailure -Root $Workspace.Root -Header $header `
        -SelectionProfile $Workspace.SelectionProfile

    & $addCategory @(@($mediaCategory) + @($mediaCategory.Children))

    # -- monitoring --------------------------------------------------------
    #
    # DESIGN 12 lists it among the tree's categories, so an administrator looking
    # for what is running finds it where they find everything else about the
    # share rather than having to know a command exists. It comes LAST because it
    # is the share in use rather than another thing to build.
    #
    # THE WHOLE SUBTREE IS Get-HDTConsoleMonitorNode'S, and that is not tidiness:
    # the console rebuilds this branch on a timer while the window is open
    # (ROADMAP M8, "tailing"), and the tree as first drawn has to be the same
    # shape as the tree as refreshed. One builder, called from both, is the only
    # arrangement in which they cannot drift.

    $monitorCategory = Get-HDTConsoleMonitorNode -Path $Workspace.Root -Header $header `
        -Monitor $Workspace.Monitor

    & $addCategory @(@($monitorCategory) + @($monitorCategory.Children))

    return [pscustomobject[]] @($node)
}
