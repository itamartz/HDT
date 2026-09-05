function Get-HDTConsoleMediaNode {
    <#
        .SYNOPSIS
            The Media category and the rows beneath it, built on its own.

        .DESCRIPTION
            MDT'S Media NODE, under Advanced Configuration, with Update Media
            Content hanging off it. The commands behind it were built in plans
            07-01 and 07-02; a command an administrator can only reach from a
            prompt is half a feature, and this repository has shipped that one
            before - the Windows Updates node had a tree row, a detail pane, an
            import dialog and a host method, and right-clicking any of it did
            nothing.

            IT IS ITS OWN FILE, LIKE Get-HDTConsoleMonitorNode. The share node
            builder is nine hundred lines of seven categories, and the branch
            with the most to say about each row is the one that is hardest to
            read in the middle of it. Nothing here refreshes on a timer the way
            monitoring does - a media build takes minutes and is watched in its
            own window - so this is called once, from the share.

            THE THREE QUESTIONS SOMEBODY OPENS THE BRANCH TO ASK: which
            selection profile, where the ISO goes, and when it was last built.
            Everything else about a media definition is on the document, and the
            row names the file.

            (never built) IS THE HONEST ANSWER AND THE USEFUL ONE. A blank or a
            zero date reads as a display fault; the words say the disc has never
            been made, which is exactly the state in which Update Media Content
            is the action somebody wants. Get-HDTMedia returns $null for
            LastBuildUtc when there is no manifest beside the document.

            A BROKEN DOCUMENT IS A ROW, NOT AN EMPTY BRANCH. A share whose media
            will not read still has eight other branches worth opening, and a
            branch that empties itself over one typo hides every disc that is
            fine. The failure row and the media rows are shown TOGETHER for that
            reason.

            AN EMPTY BRANCH IS A (none) ROW AND NEVER A MISSING ONE. A category
            that vanishes when it holds nothing reads as "this share cannot do
            media", which is false of every share - Media\ is created on demand,
            and a share made before Media\ was part of the layout has not got
            one because New-HDTWorkspace never writes over an existing share.

        .PARAMETER Media
            The media definitions, as Get-HDTConsoleWorkspace read them.

        .PARAMETER MediaFailure
            Why they could not be read, when they could not. Empty otherwise.

        .PARAMETER SelectionProfile
            The selection profiles this share offers, as Get-HDTSelectionProfile
            reported them - the profile OBJECTS, not their ids. This file reads
            the Id off each one itself, in a single place a test can cover,
            rather than at a call site where nothing checks it.

            A PARAMETER RATHER THAN A READ, and deliberately. The share node has
            already read selection-profiles.yaml for its own Selection Profiles
            category, and a second Get-HDTSelectionProfile here would be a second
            answer to the same question - one that can disagree with the first
            the moment the document changes between the two calls, leaving a list
            that offers a profile the category beside it does not.

        .PARAMETER Root
            The deployment share's root.

        .PARAMETER Header
            The banner these rows carry, as Get-HDTConsoleHeader builds them.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - one console node, with
            its media rows already in Children.

        .EXAMPLE
            Get-HDTConsoleMediaNode -Media $workspace.Media -MediaFailure $workspace.MediaFailure -Root $workspace.Root -Header $header
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds display rows in memory; it changes no state.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Media is a mass noun here and the singular name of one object - MDT calls the Deployment Workbench node Media and its action Update Media Content, and DESIGN 6.2 names the commands behind it. The analyzer reads it as the Latin plural of medium.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]] $Media,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $MediaFailure = '',

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Header,

        # DEFAULTED, so a caller that has no profiles to offer still builds a
        # row - $Workspace.SelectionProfileFailure is a real state, and the
        # branch must survive it rather than throwing on the way to a list.
        [Parameter()]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]] $SelectionProfile = @()
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $item = @($Media)

    # THE IDS, ONCE, ABOVE THE LOOP. The document stores the profile's Id -
    # New-HDTMedia and Set-HDTMedia both validate with $_.Id -eq
    # $SelectionProfile - so a list of Names would be a list every entry of
    # which the command refuses.
    $shareProfile = @(@($SelectionProfile) |
            Where-Object { $null -ne $_ } |
            ForEach-Object { [string] $_.Id } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    # [IO.Path]::Combine BY WAY OF Get-HDTWorkspacePath, NEVER Join-Path. The
    # root may be a share nothing has mounted, and Join-Path resolves the drive
    # and throws DriveNotFound - which makes the line untestable against a fake.
    $folder = Get-HDTWorkspacePath -Root $Root -Kind Media

    # WHAT AN ADMINISTRATOR WOULD TYPE TO SEE THE SAME LIST. Every row in this
    # console shows what it runs; the category shows the read, and each item row
    # shows the action that belongs to it.
    $command = "Get-HDTMedia -WorkspaceRoot '{0}'" -f $Root

    # NAMED, as every other category is: the window hangs Update Media Content
    # off this row and has to tell it from the rest without parsing a label
    # somebody may reword. The label carries a count and the name does not.
    #
    # IT CARRIES THE SHARE ROOT AS Subject, the way Selection Profiles does,
    # because the action behind the row needs the root and only the row knows
    # which of several open shares was clicked.
    $category = New-HDTConsoleNode -Depth 2 -Kind 'Category' -Status 'Ok' `
        -Name 'Media' `
        -Text ('Media ({0})' -f $item.Count) `
        -Icon (Get-HDTConsoleIcon -Kind 'Media' -Status 'Ok') `
        -Field @(
        New-HDTConsoleField -Label 'Folder' -Value $folder
        New-HDTConsoleField -Label 'Media' -Value ([string] $item.Count)
        New-HDTConsoleField -Label '' -Value ('Standalone media - MDT''s Media node. Each item is the share projected onto a bootable ISO for a machine that cannot reach the deployment share. Right-click one and choose Update Media Content to build it.')
    ) `
        -Command $command -Header $Header -Subject $Root

    # THE FAILURE ROW COMES FIRST AND DOES NOT REPLACE THE OTHERS. A document
    # with a typo in it gets a row saying so, and every media that DID parse is
    # still listed under it.
    if (-not [string]::IsNullOrEmpty([string] $MediaFailure)) {
        $failureRow = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Error' `
            -Text '(a media document could not be read)' `
            -Field @(
            New-HDTConsoleField -Label 'Error' -Value ([string] $MediaFailure)
            New-HDTConsoleField -Label 'Folder' -Value $folder
        ) `
            -Command $command -Header $Header -Subject $Root

        [void] $category.Children.Add($failureRow)
    }

    foreach ($current in $item) {

        # (never built) RATHER THAN A BLANK OR A ZERO DATE. See the description:
        # it is the state in which the action on this row is the one somebody
        # wants, so it says so in words.
        $lastBuild = '(never built)'

        if ($null -ne $current.LastBuildUtc) {
            $lastBuild = [string]::Format([cultureinfo]::InvariantCulture, '{0:yyyy-MM-dd HH:mm:ss} UTC',
                ([datetime] $current.LastBuildUtc).ToUniversalTime())

            # THE SIZE BESIDE THE TIME, because "did it build the whole disc"
            # is the second half of the same question. A 400 MB ISO where six
            # gigabytes were expected is a build that finished and lied.
            if ([long] $current.IsoSizeBytes -gt 0) {
                $lastBuild = '{0} ({1})' -f $lastBuild,
                (Format-HDTConsoleByteCount -Byte ([long] $current.IsoSizeBytes) -Compact)
            }
        }

        # A DISABLED MEDIA IS STILL A ROW, and it says so on the row rather than
        # being left out: Update-HDTMediaContent REFUSES a disabled item by
        # name, and a branch that hid it would leave an administrator reading a
        # refusal about something they cannot see.
        #
        # THE WORDS ARE true AND false, NOT yes AND no. media.yaml carries a
        # bare YAML boolean, Set-HDTMedia writes $Enabled.ToString() lowercased,
        # and Assert-HDTMediaDocument refuses a quoted one - "quoting it makes
        # it a string, and a string is not a tick box". A row showing a
        # different word than the file does is a row a technician has to
        # translate.
        $enabledText = 'true'
        if (-not [bool] $current.Enabled) { $enabledText = 'false' }

        # THE PROFILE THE DOCUMENT NAMES GOES ON THE LIST, FIRST, when the share
        # no longer offers it. A LIST THAT DOES NOT OFFER WHAT THE FILE SAYS
        # SHOWS NOTHING - an empty combo over a document that plainly sets a
        # profile reads as "no profile set", and opening the list to find out
        # what it really is would replace it with whatever was clicked. This is
        # the same bargain Get-HDTConsoleStepNode makes for a step resolving its
        # scope from a variable: a value the command will refuse is shown, for
        # the reason that a media item that cannot build should not look fine.
        $profileChoice = @($shareProfile)
        $profileText = [string] $current.SelectionProfile

        if (-not [string]::IsNullOrWhiteSpace($profileText) -and -not ($profileChoice -contains $profileText)) {
            $profileChoice = @($profileText) + $profileChoice
        }

        $field = @(
            New-HDTConsoleField -Label 'Id' -Value ([string] $current.Id)

            # NO FALLBACK IN A BOX THAT WRITES - the rule every other editable
            # description on this tree already follows. Always shown, even
            # empty, so adding one is typing into the box rather than finding
            # a command first.
            New-HDTConsoleField -Label 'Description' -Value ([string] $current.Description) -Property 'description'

            # THE PROFILE IS THE WHOLE PROJECTION. DESIGN 13 calls standalone
            # media a content projection of the share, and this names its
            # filter: what the disc holds is exactly what the profile includes.
            #
            # A LIST, NEVER A BOX. Set-HDTMedia refuses an id this share does
            # not have, so a typo is caught - but the failure this guards
            # against is a LEGAL id that is the wrong one, which nothing
            # refuses and which produces a media item whose disc has no content
            # on it. HDTNewMedia.xaml makes exactly this argument for why ITS
            # profile picker is a ComboBox; this pane is the other door to the
            # same key, and it was left a box.
            #
            # AN EMPTY LIST DEGRADES TO A BOX, and that is correct: Kind falls
            # back to 'Text' when Choice is empty, and a box can at least be
            # typed into where a combo holding nothing cannot be used at all.
            New-HDTConsoleField -Label 'Selection profile' -Value $profileText -Property 'selectionProfile' `
                -Choice $profileChoice `
                -Hint 'What goes on the disc. The media holds exactly the folders this profile includes.'

            # THE RESOLVED PATH, NOT THE DECLARED ONE. The document may name a
            # share-relative path - Media\<id>\<id>.iso - and where the file
            # actually lands is the question somebody opens this row to answer.
            New-HDTConsoleField -Label 'Output' -Value ([string] $current.OutputPath) -Property 'output' `
                -Hint 'Where the next build writes its ISO. A path in the document that is not rooted is taken from the share root.'

            New-HDTConsoleField -Label 'Last build' -Value $lastBuild
            # THE WORDS ARE true AND false because that is what media.yaml
            # holds and what Assert-HDTMediaDocument accepts; anything else
            # asks a technician to hold two vocabularies for one key.
            #
            # THE EXPLANATION IS IN -Hint, NOT IN THE VALUE. CLAUDE.md's rule -
            # one or two lines on screen, the reasoning in the code - and a live
            # defect besides: while it lived inside the VALUE, an Apply spliced
            # an English sentence into the key.
            #
            # IT IS A LIST RATHER THAN THE TICK BOX EVERY OTHER YES-OR-NO IN
            # THIS WINDOW IS, BY EXPLICIT INSTRUCTION AND NOT BY OVERSIGHT. The
            # Options tab's Disabled and Continue on error, and a step's wipe,
            # expand, recoveryPassword and wait, are all New-HDTConsoleField
            # -Check. The user asked for a dropdown on this row specifically.
            # A later consistency sweep should leave it alone rather than
            # "fixing" it, and should not change any other row to match.
            New-HDTConsoleField -Label 'Enabled' -Value $enabledText -Property 'enabled' `
                -Choice @('true', 'false') `
                -Hint 'Update Media Content refuses to build this disc while this is false.'
            New-HDTConsoleField -Label 'Document' -Value ([string] $current.DocumentPath)
            New-HDTConsoleField -Label 'To build it' -Value ("Update-HDTMediaContent -WorkspaceRoot '{0}' -Id '{1}'" -f $Root, [string] $current.Id)
        )

        # THE ROW'S OWN COMMAND IS THE ACTION, not the read. Every other row in
        # this tree shows what it runs, and what a media row runs is the build -
        # which is also what the menu item on it does.
        $row = New-HDTConsoleNode -Depth 3 -Kind 'Media' -Status 'Ok' `
            -Name ([string] $current.Id) `
            -Text ([string] $current.Name) `
            -Field $field `
            -Command ("Update-HDTMediaContent -WorkspaceRoot '{0}' -Id '{1}'" -f $Root, [string] $current.Id) `
            -Header $Header -Subject $Root

        [void] $category.Children.Add($row)
    }

    # AN EMPTY CATEGORY READS AS A BROKEN ONE. This says which it is, and says
    # what to type. New-HDTMedia is on the menu too now (07-04-01, right-click
    # the category) - this row is the OTHER door, for somebody reading
    # Get-HDTMedia's own output outside the console rather than pointing at
    # this branch.
    if ($item.Count -eq 0 -and [string]::IsNullOrEmpty([string] $MediaFailure)) {
        $empty = New-HDTConsoleNode -Depth 3 -Kind 'Empty' -Status 'Ok' -Text '(none)' `
            -Field @(
            New-HDTConsoleField -Label 'Folder' -Value $folder
            New-HDTConsoleField -Label '' -Value ('There is no standalone media on this share yet. Add one with New-HDTMedia - it lands as a folder under the folder above with a media.yaml in it, naming a selection profile and where the ISO goes.')
        ) `
            -Command $command -Header $Header -Subject $Root

        [void] $category.Children.Add($empty)
    }

    return $category
}
