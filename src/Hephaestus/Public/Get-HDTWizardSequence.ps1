function Get-HDTWizardSequence {
    <#
        .SYNOPSIS
            The task sequences this share actually carries, as rows the wizard's
            picker can show.

        .DESCRIPTION
            W3 OF .planning/WPF-FIRST.md, AND THE END OF A HAND-WRITTEN LIST.
            Scripts\UI\TaskSequence.xaml carried one <ListBoxItem> per sequence,
            typed by whoever added the sequence, and admitted as much in its own
            comment. A lab share holding eight sequences offered one - not as a
            failure anybody could see, but as a list that was quietly wrong, and
            the technician's only clue was that their sequence "was not there".

            THE LIST IS THE FOLDER. TaskSequences\<Id>\sequence.yaml is what the
            engine runs, so it is what the picker offers - the same rule the
            console's catalog uses, for the same reason: a folder counts when
            the document is in it, never because it is a directory. A lab share
            keeps a readme and a stray unattend.xml beside the sequence folders,
            and a picker that offered 'unattend.xml' would fail a deployment
            after the technician had answered every question.

            SORTED BY ID, because the order a file system hands folders back is
            not an order anybody can scan, and a list that rearranges itself
            between boots is one a technician stops trusting.

            A DOCUMENT THAT WILL NOT PARSE IS LEFT OUT AND SAID OUT LOUD. Both
            halves matter. Offering it means a deployment that dies at its first
            step; dropping it in silence means "why is mine not in the list?"
            has no answer anywhere. So it is excluded and named in Problem,
            which the payload logs.

            NOTHING IS PRESELECTED UNLESS A RULE CHOSE IT, AND A REAL
            DEPLOYMENT IS WHY. This used to open on the first row, because a
            list has to highlight something - and the wizard host records
            whatever it puts in a box as a SEED, which the harvest then drops if
            it comes back unchanged (Test-HDTWizardAnswerChanged). So a
            technician who went through the wizard and chose the sequence the
            picker was already sitting on answered nothing at all:
            HDTTaskSequenceID never entered the value bag, the summary said
            "(not set)", and the machine failed before its first step with
            "nothing in the rules resolved HDTTaskSequenceID for this machine".

            THE SEED MECHANISM WAS RIGHT AND WHAT IT WAS SEEDING WAS NOT. A
            value a RULE supplied has provenance worth protecting; a row this
            command highlighted because a ListBox looks odd with nothing lit has
            none. So the picker opens on the rule's choice or on nothing, which
            is also what MDT's Task Sequence pane does - it preselects nothing
            and will not move on until the technician has chosen.

            AN ID THE SHARE DOES NOT CARRY IS A PROBLEM RATHER THAN A SILENT
            FIRST ROW. A rule naming a sequence that is not on this share is a
            mistake somebody has to be told about, and selecting something else
            quietly would deploy the wrong build to a machine that is already
            open.

            IT RETURNS A FIELD, because that is how the wizard fills a control:
            Show-HDTWizardShell applies fields by name after each page loads,
            and New-HDTWizardHost writes Item to ItemsSource and Text to the
            property the field names. wizard.yaml's TaskSequence page collects
            HDTTaskSequenceList's SelectedValue into HDTTaskSequenceID, so those
            two names are what this fills in.

        .PARAMETER WorkspaceRoot
            The connected share's root.

        .PARAMETER FileSystem
            An IFileSystem. The share is already connected by the time the
            wizard runs, so this reads it as ordinary paths.
            Defaults to the real one.

        .PARAMETER Variable
            The resolved variables, read for HDTTaskSequenceID and nothing else.

        .PARAMETER Control
            The control the field names. Defaults to HDTTaskSequenceList, which
            is what the shipped page calls it; a site that renamed it in its own
            page does not have to fork this command.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Choice (Id, Name,
            Description, Text), Selected, Problem and Field. The Field carries
            Seed, true only when a rule chose the row - an empty picker is the
            wizard opening on nothing, which is not a value to remember.

        .EXAMPLE
            $root = 'C:\HDTLab\Share'
            $fs = New-HDTFileSystem
            $title = 'Task Sequence'
            $field = @()
            $fact = Get-HDTMachineFact -CimProvider (New-HDTCimProvider) `
                -RegistryService (New-HDTRegistryService) -EnvironmentProvider (New-HDTEnvironmentProvider)
            $resolved = Resolve-HDTVariable -Fact $fact
            $ask = Get-HDTWizardPage -Page @() -Variable $resolved.Variable
            Get-HDTWizardSequence -WorkspaceRoot 'Z:\Deploy'

        .EXAMPLE
            $sequence = Get-HDTWizardSequence -WorkspaceRoot $root -FileSystem $fs -Variable $resolved.Variable
            Show-HDTWizardShell -Page $ask.Page -Field (@($field) + @($sequence.Field)) -Title $title

            What the payload does: the picker is one more field, applied by name
            like every other.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Variable,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Control = 'HDTTaskSequenceList'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $choice = New-Object -TypeName System.Collections.ArrayList
    $problem = New-Object -TypeName System.Collections.ArrayList

    $sequenceRoot = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind TaskSequences

    if (-not $FileSystem.TestPath($sequenceRoot)) {
        # NOT AN EXCEPTION. A share being set up has no TaskSequences\ yet, and
        # a wizard that refused to open would leave the technician with nothing
        # to read the reason on.
        [void] $problem.Add(("there is no TaskSequences folder at '{0}', so this share offers nothing to deploy." -f $sequenceRoot))
    } else {
        foreach ($folder in @($FileSystem.GetChildItem($sequenceRoot))) {

            $documentPath = [System.IO.Path]::Combine([string] $folder, 'sequence.yaml')
            if (-not $FileSystem.TestPath($documentPath)) { continue }

            $folderName = [System.IO.Path]::GetFileName([string] $folder)

            # PARSED, NOT VALIDATED. A picker needs three fields off the top of
            # the document; whether every step in it is legal is the engine's
            # question, answered when the sequence runs and answered with a
            # message about the step. Refusing to LIST a sequence over a step
            # type would hide it from the one person who could fix it.
            $document = $null
            try {
                $document = ConvertFrom-HDTYaml -Yaml ([string] $FileSystem.ReadAllText($documentPath)) -Path $documentPath
            } catch {
                [void] $problem.Add(("'{0}' is not offered: its sequence.yaml could not be read - {1}" -f
                        $folderName, [string] $_.Exception.Message))
                continue
            }

            if ($null -eq $document -or $document -isnot [System.Collections.IDictionary]) {
                [void] $problem.Add(("'{0}' is not offered: its sequence.yaml is empty or is not a document." -f $folderName))
                continue
            }

            # THE FOLDER IS THE ID, AND THE DOCUMENT'S id FIELD IS NOT CONSULTED
            # FOR IT. HDTTaskSequenceID names a FOLDER - the engine builds
            # TaskSequences\<Id>\sequence.yaml from it - so anything else on this
            # row would be a picker offering an id nothing can be looked up by.
            #
            # A REAL SHARE PROVED IT COSTS NOTHING TO GET WRONG. The lab's '001'
            # sequence declares `id: 001`, and YAML reads that as the NUMBER 1:
            # a picker trusting the document would offer '1' and the deployment
            # would look for TaskSequences\1\sequence.yaml, which is not there.
            # The same is true of any id a parser can read as a number, a date
            # or a boolean - and quoting it is a fix nobody will remember.
            $id = $folderName
            $name = $id
            if ($document.Contains('name') -and -not [string]::IsNullOrWhiteSpace([string] $document['name'])) {
                $name = [string] $document['name']
            }

            $description = ''
            if ($document.Contains('description')) { $description = [string] $document['description'] }

            [void] $choice.Add([pscustomobject] @{
                    Id          = $id
                    Name        = $name
                    Description = $description

                    # THE ID AND THE NAME ON ONE ROW. The id is what the
                    # deployment records and what a rule names; the name is what
                    # a technician recognises. A row carrying one of them makes
                    # somebody guess at the other.
                    Text        = ('{0}  -  {1}' -f $id, $name)
                })
        }
    }

    $ordered = [object[]] @($choice | Sort-Object -Property Id)

    # -- what is already chosen ---------------------------------------------

    $wanted = ''
    if ($null -ne $Variable -and $Variable.Contains('HDTTaskSequenceID')) {
        $wanted = [string] $Variable['HDTTaskSequenceID']
    }

    # EMPTY MEANS NOBODY HAS CHOSEN YET, AND THAT IS A STATE THE WIZARD MUST BE
    # ABLE TO BE IN. See the header: opening on $ordered[0] made "the technician
    # picked the first sequence" and "the technician answered nothing" the same
    # thing to the harvest, and a real machine failed before its first step
    # because of it. The page gates its own Next button on this being filled in
    # (wizard.yaml's TaskSequence validate rule), which is MDT's shape: choose
    # one, or you do not leave this screen.
    $selected = ''

    if (-not [string]::IsNullOrWhiteSpace($wanted)) {
        $match = @($ordered | Where-Object { $_.Id -eq $wanted })

        if (@($match).Count -gt 0) {
            $selected = [string] $match[0].Id
        } else {
            [void] $problem.Add(("HDTTaskSequenceID resolved to '{0}', which is not on this share. Nothing is preselected and the technician has to choose." -f
                    $wanted))
        }
    }

    return [pscustomobject] @{
        Choice   = $ordered
        Selected = $selected
        Problem  = [string[]] @($problem)

        Field    = [pscustomobject] @{
            Name     = $Control
            Property = 'SelectedValue'
            Text     = $selected
            Item     = $ordered

            # A SEED ONLY WHEN A RULE CHOSE THE ROW. $selected is empty unless
            # HDTTaskSequenceID resolved to something this share carries, so
            # this is true exactly when there is provenance worth protecting -
            # and false when the picker is opening on nothing, which is the
            # state that made "the technician picked a sequence" and "the
            # technician answered nothing" the same thing to the harvest.
            Seed     = (-not [string]::IsNullOrWhiteSpace($selected))
        }
    }
}
