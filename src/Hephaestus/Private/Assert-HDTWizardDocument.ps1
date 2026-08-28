function Assert-HDTWizardDocument {
    <#
        .SYNOPSIS
            Validates Scripts\UI\wizard.yaml - the pages the technician wizard
            asks, and in what order.

        .DESCRIPTION
            The technician wizard's page list, as YAML: one entry per screen,
            each declaring an id and the markup under Scripts\UI it draws, in
            the order they are asked, and each carrying at most a Skip variable
            deciding whether it appears at all. MDT held the same list in
            DeployWiz_Definition_ENU.xml as <Pane id= reference= /> entries,
            and that is the shape this follows, with the condition narrowed to
            one variable.

            A SHARE WITH NO wizard.yaml HAS NO WIZARD, and that is the property
            the whole design hangs off. Every image built before this existed
            deploys with nobody present, exactly as it did; a site turns the
            wizard on by authoring pages, not by remembering to turn it off.
            So the document being ABSENT is never an error - only a document
            that is present and wrong.

            IT IS AUTHORED CONTENT ON A SHARE, AND IS VALIDATED LIKE ONE. The
            reference names markup relative to Scripts\UI: never rooted, never
            climbing out with '..', and always .xaml. A definition file that
            could name C:\Windows\... or a .ps1 would be a file on a share that
            reads - or runs - whatever it likes on every machine that deploys.

            A RULE OR A SPLITTER THIS ENGINE DOES NOT IMPLEMENT IS REFUSED,
            not ignored. A control that silently never validates looks, on a
            bench, like a wizard that accepts anything - and the value on the
            other side of it is a machine's identity.

            EVERY VARIABLE IT SETS IS HDT-PREFIXED, because everything the
            resolution engine carries is (DESIGN 3), and a definition on a share
            must not be able to set anything else.

        .PARAMETER Document
            The parsed document.

        .PARAMETER Path
            Where it came from, named in every message.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            None. It throws on the first problem.

        .EXAMPLE
            Assert-HDTWizardDocument -Document $document -Path 'C:\Share\Scripts\UI\wizard.yaml'
    #>
    # $Path IS used - by the $fail closure below, which names it in every
    # message. The analyzer does not follow a parameter into a closure.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Used inside the $fail closure, which PSReviewUnusedParameter does not follow.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Document,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # KEPT IN STEP WITH schemas/wizard.schema.json BY A CONTRACT TEST, which
    # compares the schema's own "required" array with this list.
    $requiredRootKey = @('schemaVersion', 'pages')
    $knownRootKey = @('schemaVersion', 'title', 'pages')

    $knownPageKey = @('id', 'title', 'heading', 'subheading', 'reference', 'skip', 'validate', 'summary', 'collect')
    $knownCollectKey = @('control', 'variable', 'property', 'isSecret', 'optional', 'select', 'split', 'splitVariable', 'splitDefaultFrom')

    $knownProperty = @('Text', 'SelectedValue', 'Password', 'IsChecked')

    # HOW MANY VALUES ONE CONTROL ANSWERS WITH, and 'many' is the whole reason
    # the Applications page could not collect anything. Every declaration above
    # reads ONE property off ONE control; a column of tick boxes is none of
    # those, and the page shipped uncollected rather than have its answer
    # silently dropped. 'many' reads the rows themselves - Id and IsSelected -
    # and joins the ticked ids the way Invoke-HDTInstallApplicationsStep splits
    # them apart again.
    $knownSelect = @('one', 'many')

    # THE VALIDATE BLOCK'S OWN KEYS, checked like every other block's. They were
    # not, so a page could declare validate with a misspelled key and get a
    # control that silently never validates - which is the exact thing the
    # header says this file refuses to allow.
    #
    # 'confirm' NAMES A SECOND CONTROL TO COMPARE AGAINST, and only the
    # AdminPassword rule reads it: a password box shows dots, so the only way
    # to know what was typed is to type it twice.
    $knownValidateKey = @('control', 'rule', 'confirm')
    $knownRule = @('ComputerName', 'AdminPassword', 'TaskSequence')
    $knownSplit = @('AccountName')

    $fail = {
        param([string] $Message)

        throw (New-HDTErrorRecord -Path $Path -Category InvalidData -Message $Message)
    }

    if ($null -eq $Document) {
        & $fail 'the wizard definition is empty. It declares schemaVersion and pages.'
    }

    if (-not ($Document -is [System.Collections.IDictionary])) {
        & $fail 'the wizard definition is not a mapping. It declares schemaVersion and pages.'
    }

    foreach ($key in $requiredRootKey) {
        if (-not $Document.Contains($key)) {
            & $fail ("{0} is missing. A wizard definition declares {1}." -f $key, ($requiredRootKey -join ', '))
        }
    }

    foreach ($key in @($Document.Keys)) {
        if ($knownRootKey -notcontains $key) {
            & $fail ("'{0}' is not a key a wizard definition carries. The keys are {1}." -f $key, ($knownRootKey -join ', '))
        }
    }

    # THE SAME GATE EVERY OTHER DOCUMENT USES, so a version this engine cannot
    # read is refused the same way and with the same advice.
    $supportedSchemaVersion = 1
    $schemaVersion = $Document['schemaVersion']

    if (-not (($schemaVersion -is [int]) -or ($schemaVersion -is [long]))) {
        & $fail ("schemaVersion must be an integer, but it is '{0}'." -f $schemaVersion)
    }

    $supported = $false
    try {
        $supported = Test-HDTSchemaVersion -SchemaVersion ([int] $schemaVersion) -Supported $supportedSchemaVersion
    } catch {
        & $fail ("schemaVersion {0} is not a valid schema version. It must be 1 or greater." -f $schemaVersion)
    }

    if (-not $supported) {
        & $fail ("schemaVersion {0} is newer than this engine understands (schemaVersion {1}). Upgrade the engine rather than the wizard definition." -f
            $schemaVersion, $supportedSchemaVersion)
    }

    $pages = $Document['pages']
    if ($null -eq $pages) { $pages = @() }

    if ($pages -is [System.Collections.IDictionary] -or -not ($pages -is [System.Collections.IEnumerable]) -or $pages -is [string]) {
        & $fail 'pages is not a list. It is one entry per screen, in the order they are asked.'
    }

    $seenId = @()
    $summaryPage = @()

    foreach ($page in @($pages)) {

        if (-not ($page -is [System.Collections.IDictionary])) {
            & $fail 'a page is not a mapping. Each one declares at least id and reference.'
        }

        foreach ($key in @('id', 'reference')) {
            if (-not $page.Contains($key) -or [string]::IsNullOrWhiteSpace([string] $page[$key])) {
                & $fail ("a page is missing {0}. Each page declares id and reference - MDT's <Pane id= reference= />." -f $key)
            }
        }

        $id = [string] $page['id']

        foreach ($key in @($page.Keys)) {
            if ($knownPageKey -notcontains $key) {
                & $fail ("'{0}' is not a key the page '{1}' can carry. The keys are {2}." -f $key, $id, ($knownPageKey -join ', '))
            }
        }

        if ($id -notmatch '^[A-Za-z0-9_-]{1,64}$') {
            & $fail ("the page id '{0}' is not a name. Letters, digits, hyphen and underscore, up to 64." -f $id)
        }

        # THE ID IS WHAT A SKIP VARIABLE AND A SUMMARY ROW ARE KEYED ON.
        if ($seenId -contains $id) {
            & $fail ("the page id '{0}' is declared twice. Each page is named once." -f $id)
        }
        $seenId += $id

        $reference = [string] $page['reference']

        # SEE THE HEADER: this is authored content on a share.
        if ($reference -match '\.\.' -or $reference -match '^[A-Za-z]:' -or $reference.StartsWith('\') -or $reference.StartsWith('/')) {
            & $fail ("the page '{0}' references '{1}', which is not inside Scripts\UI. A reference is relative, never rooted, and never climbs out with '..'." -f
                $id, $reference)
        }

        if ($reference -notmatch '\.xaml$') {
            & $fail ("the page '{0}' references '{1}', which is not markup. A page is a .xaml file." -f $id, $reference)
        }

        if ($page.Contains('skip') -and -not [string]::IsNullOrWhiteSpace([string] $page['skip'])) {
            $skip = [string] $page['skip']

            if ($skip -notmatch '^HDT[A-Za-z0-9]{1,61}$') {
                & $fail ("the page '{0}' is skipped by '{1}', which is not an HDT variable. Everything the engine resolves is HDT-prefixed." -f $id, $skip)
            }
        }

        # -- what it validates ------------------------------------------------

        if ($page.Contains('validate') -and $null -ne $page['validate']) {
            $validate = $page['validate']

            if (-not ($validate -is [System.Collections.IDictionary])) {
                & $fail ("the page '{0}' declares validate, which is not a mapping. It names a control and a rule." -f $id)
            }

            foreach ($key in @('control', 'rule')) {
                if (-not $validate.Contains($key) -or [string]::IsNullOrWhiteSpace([string] $validate[$key])) {
                    & $fail ("the page '{0}' declares validate with no {1}." -f $id, $key)
                }
            }

            foreach ($key in @($validate.Keys)) {
                if ($knownValidateKey -notcontains [string] $key) {
                    & $fail ("the page '{0}' declares validate with '{1}', which is not something validate carries. It carries {2}." -f
                        $id, [string] $key, ($knownValidateKey -join ', '))
                }
            }

            if ($knownRule -notcontains [string] $validate['rule']) {
                & $fail ("the page '{0}' declares the validation rule '{1}', which this engine does not implement. The rules are {2}." -f
                    $id, [string] $validate['rule'], ($knownRule -join ', '))
            }

            # A CONFIRM CONTROL IS ONLY MEANINGFUL TO A RULE THAT COMPARES TWO.
            # Declared beside a rule that reads one control, it would be a
            # second box the technician fills in and nothing ever looks at.
            if ($validate.Contains('confirm') -and [string] $validate['rule'] -ne 'AdminPassword') {
                & $fail ("the page '{0}' declares a confirm control beside the '{1}' rule, which judges one control. Only AdminPassword compares two." -f
                    $id, [string] $validate['rule'])
            }
        }

        # -- whether it is the summary ----------------------------------------

        if ($page.Contains('summary') -and $null -ne $page['summary']) {
            $summary = $page['summary']

            if (-not ($summary -is [System.Collections.IDictionary])) {
                & $fail ("the page '{0}' declares summary, which is not a mapping." -f $id)
            }

            # THE SNIPPET IS THE ONE THAT MUST BE NAMED, because it is the whole
            # page. Summary.xaml once carried a table above the snippet and this
            # demanded rowControl instead; the table went, the demand did not,
            # and the shipped wizard.yaml went on declaring
            # rowControl: HDTSummaryList against markup that had no such
            # control. New-HDTWizardHost's FindName guard swallowed the miss -
            # rightly, so a share half a release behind still opens - so the
            # declaration did nothing and said nothing, which is how a defect
            # elsewhere read as a page missing its data.
            #
            # rowControl IS STILL PERMITTED, JUST NOT REQUIRED. A share is never
            # written over (DESIGN 11.2), so every wizard.yaml seeded before now
            # carries it; refusing the key would refuse those shares outright,
            # and Import-HDTWizardDocument still carries it through to a page
            # that wants to bind a table again.
            if (-not $summary.Contains('snippetControl') -or [string]::IsNullOrWhiteSpace([string] $summary['snippetControl'])) {
                & $fail ("the page '{0}' declares summary with no snippetControl to fill." -f $id)
            }

            $summaryPage += $id
        }

        # -- what it collects --------------------------------------------------

        if ($page.Contains('collect') -and $null -ne $page['collect']) {

            foreach ($collect in @($page['collect'])) {

                if (-not ($collect -is [System.Collections.IDictionary])) {
                    & $fail ("the page '{0}' declares a collect entry that is not a mapping." -f $id)
                }

                foreach ($key in @($collect.Keys)) {
                    if ($knownCollectKey -notcontains $key) {
                        & $fail ("'{0}' is not a key a collect entry on page '{1}' can carry. The keys are {2}." -f
                            $key, $id, ($knownCollectKey -join ', '))
                    }
                }

                foreach ($key in @('control', 'variable')) {
                    if (-not $collect.Contains($key) -or [string]::IsNullOrWhiteSpace([string] $collect[$key])) {
                        & $fail ("a collect entry on page '{0}' is missing {1}." -f $id, $key)
                    }
                }

                if ([string] $collect['variable'] -notmatch '^HDT[A-Za-z0-9]{1,61}$') {
                    & $fail ("the page '{0}' collects into '{1}', which is not an HDT variable. Everything the engine resolves is HDT-prefixed (DESIGN 3)." -f
                        $id, [string] $collect['variable'])
                }

                if ($collect.Contains('property') -and $knownProperty -notcontains [string] $collect['property']) {
                    & $fail ("the page '{0}' reads '{1}' from a control, which the host cannot read. The properties are {2}." -f
                        $id, [string] $collect['property'], ($knownProperty -join ', '))
                }

                if ($collect.Contains('select') -and $knownSelect -notcontains [string] $collect['select']) {
                    & $fail ("the page '{0}' selects '{1}', which this engine does not implement. The values are {2}." -f
                        $id, [string] $collect['select'], ($knownSelect -join ', '))
                }

                if ($collect.Contains('split') -and -not [string]::IsNullOrWhiteSpace([string] $collect['split'])) {

                    if ($knownSplit -notcontains [string] $collect['split']) {
                        & $fail ("the page '{0}' declares the splitter '{1}', which this engine does not implement. The splitters are {2}." -f
                            $id, [string] $collect['split'], ($knownSplit -join ', '))
                    }

                    if (-not $collect.Contains('splitVariable') -or [string]::IsNullOrWhiteSpace([string] $collect['splitVariable'])) {
                        & $fail ("the page '{0}' splits a value and declares no splitVariable to put the other half in." -f $id)
                    }
                }
            }
        }
    }

    # ONE FILE TO HAND OVER, so one page that hands it over.
    if (@($summaryPage).Count -gt 1) {
        & $fail ("more than one page declares summary: {0}. There is one rules.yaml to hand a technician." -f ($summaryPage -join ', '))
    }
}
