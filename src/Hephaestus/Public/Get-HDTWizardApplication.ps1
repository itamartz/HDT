function Get-HDTWizardApplication {
    <#
        .SYNOPSIS
            The applications this share actually publishes, as rows the wizard's
            Applications page can tick.

        .DESCRIPTION
            THE END OF A HAND-WRITTEN LIST, for the second time. W3 did it for
            the task sequence picker; Scripts\UI\Applications.xaml was the last
            page still carrying its rows in markup - three CheckBoxes somebody
            typed - and it admitted as much in its own comment. A share holding
            eleven applications offered three, and the technician's only clue
            was that theirs "was not there".

            THE LIST IS THE CATALOG, read through Get-HDTApplication so this
            command repeats none of the parsing, validation or projection that
            already exists. What it adds is the two things a PICKER needs and a
            catalog reader must not do: it survives one bad document, and it
            says which one.

            ONE APPLICATION AT A TIME, AND THAT IS THE WHOLE REASON THE FOLDER
            WALK IS HERE. Get-HDTApplication with no -Id reads the catalog and
            throws on the first document it cannot accept - correct for a step
            that is about to install from it, and fatal for a page: one
            half-edited app.yaml would take the whole page down and the wizard
            with it. Reading each folder in its own try leaves the other ten
            offered.

            THE ID IS THE CATALOG'S, NEVER THE FOLDER NAME. Both are supposed to
            be the same thing - Assert-HDTApplicationDocument says "the id is
            the folder name under Applications\" and validates it as one - but
            nothing checks that they AGREE, and the id the technician's tick
            turns into is matched by Resolve-HDTApplicationOrder against the
            projected catalog. So this offers exactly what that will match. It
            is the opposite choice from Get-HDTWizardSequence, and for the same
            reason: offer the value the engine will look up, which there is the
            folder and here is the document.

            HDTMandatoryApplications IS NOT ON THIS PAGE. MDT does not list it
            and neither does this: the step installs that list whatever the
            technician picked, so a tick beside one would be a control that
            changes nothing - and one they could clear, which is worse than
            useless. The page carries a hint saying so instead.

            AN ID NO ROW CAN CARRY IS NAMED. A rule selecting an application
            this share has never held is a mistake somebody has to be told
            about; there is no row to draw its tick on, and dropping it in
            silence makes "why did that not install?" unanswerable.

            IT RETURNS A FIELD, like every other page-filling command:
            Show-HDTWizardShell applies fields by name after each page loads and
            New-HDTWizardHost writes Item to ItemsSource. The rows carry
            IsSelected and Id, which is the convention wizard.yaml's
            `select: many` collection reads them back by.

        .PARAMETER WorkspaceRoot
            The connected share's root.

        .PARAMETER FileSystem
            An IFileSystem. The share is already connected by the time this page
            is reached, so it reads ordinary paths. Defaults to the real one.

        .PARAMETER Variable
            The resolved variables, read for HDTApplications and nothing else.

        .PARAMETER Control
            The control the field names. Defaults to HDTApplicationList, which is
            what the shipped page calls it; a site that renamed it in its own
            page does not have to fork this command.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Choice (Id, Name,
            Publisher, Version, Text, IsSelected), Problem and Field.

        .EXAMPLE
            Get-HDTWizardApplication -WorkspaceRoot 'Z:\Deploy'

            Every application on the share, none ticked.

        .EXAMPLE
            $root = 'Z:\Deploy'
            $rule = Import-HDTRuleDocument -Path (Join-Path $root 'rules.yaml')
            $resolved = Resolve-HDTVariable -Rule $rule.Rule -Fact (Get-HDTMachineFact)
            $application = Get-HDTWizardApplication -WorkspaceRoot $root -Variable $resolved.Variable
            @($application.Choice | Where-Object { $_.IsSelected } | ForEach-Object { $_.Id })

            What a rules.yaml already selected, shown ticked before the
            technician is asked to confirm it.

        .EXAMPLE
            $root = 'Z:\Deploy'
            $application = Get-HDTWizardApplication -WorkspaceRoot $root
            $provider = New-HDTLocalContentProvider -Root $root
            $ask = Import-HDTWizardDocument -Provider $provider
            Show-HDTWizardShell -Page $ask.Page -Field @($application.Field)

            What the payload does: the list is one more field, applied by name
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
        [string] $Control = 'HDTApplicationList'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $choice = New-Object -TypeName System.Collections.ArrayList
    $problem = New-Object -TypeName System.Collections.ArrayList

    $applicationRoot = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Applications

    # A SHARE WITH NO Applications\ IS NOT A BROKEN SHARE. DESIGN 2.1 makes them
    # optional, and a workspace that lays down an image and no software is a
    # normal workspace - so this is silent rather than a Problem. The page is
    # skipped when there is nothing to offer, which is what Get-HDTWizardPage
    # already does with an empty list.
    if ($FileSystem.TestPath($applicationRoot)) {

        foreach ($folder in @($FileSystem.GetChildItem($applicationRoot))) {

            $folderName = [System.IO.Path]::GetFileName([string] $folder)

            $documentPath = [System.IO.Path]::Combine([string] $folder, 'app.yaml')
            if (-not $FileSystem.TestPath($documentPath)) { continue }

            # ONE FOLDER, ONE TRY. See the header: the catalog reader throws on
            # the first bad document, which would cost the page every
            # application after it.
            $application = $null
            try {
                $application = Get-HDTApplication -WorkspaceRoot $WorkspaceRoot -Id $folderName -FileSystem $FileSystem
            } catch {
                [void] $problem.Add(("'{0}' is not offered: its app.yaml could not be read - {1}" -f
                        $folderName, [string] $_.Exception.Message))
                continue
            }

            if ($null -eq $application) {
                [void] $problem.Add(("'{0}' is not offered: its app.yaml is empty or is not a document." -f $folderName))
                continue
            }

            $name = [string] $application.Name
            if ([string]::IsNullOrWhiteSpace($name)) { $name = [string] $application.Id }

            # THE NAME AND THE VERSION, BECAUSE A TECHNICIAN CHOOSING BETWEEN
            # TWO BUILDS OF ONE PRODUCT NEEDS BOTH. Nothing when there is no
            # version: a site agent reads 'Site agent', not 'Site agent ' with a
            # gap where a number was expected to be.
            #
            # AND NOTHING WHEN THE NAME ALREADY ENDS WITH IT, which the lab
            # share found rather than a fixture. Import-HDTApplication builds a
            # name out of the publisher, the product and the version, so a real
            # catalog holds 'Acrobat Acrobat Reader DC 2600121771' with version
            # '2600121771' beside it - and appending gave a row that said the
            # build number twice.
            $text = $name
            $version = [string] $application.Version

            if (-not [string]::IsNullOrWhiteSpace($version)) {
                if (-not $name.TrimEnd().EndsWith($version.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
                    $text = ('{0} {1}' -f $name, $version)
                }
            }

            [void] $choice.Add([pscustomobject] @{
                    Id         = [string] $application.Id
                    Name       = $name
                    Publisher  = [string] $application.Publisher
                    Version    = $version
                    Text       = $text

                    # SETTABLE, AND THE BINDING WRITES TO IT. The page's
                    # CheckBox is bound TwoWay to this note property, so what
                    # the technician ticks is on the row the harvest reads back
                    # - no visual-tree walk, and nothing that needs a screen.
                    IsSelected = $false
                })
        }
    }

    $ordered = [object[]] @($choice | Sort-Object -Property Id)

    # -- what is already ticked ---------------------------------------------
    #
    # SPLIT THE WAY THE STEP SPLITS. Invoke-HDTInstallApplicationsStep accepts
    # [,;\r\n]; a picker that took the comma alone would leave a semicolon list
    # entirely unticked, and the technician would either tick it all again or -
    # worse - trust the empty page.

    $wanted = @()
    if ($null -ne $Variable -and $Variable.Contains('HDTApplications')) {
        $wanted = @(@(([string] $Variable['HDTApplications']) -split '[,;\r\n]') |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    foreach ($id in @($wanted)) {

        $match = @($ordered | Where-Object { $_.Id -eq $id })

        if (@($match).Count -eq 0) {
            [void] $problem.Add(("HDTApplications selects '{0}', which this share does not publish, so the page has no row to tick for it." -f $id))
            continue
        }

        $match[0].IsSelected = $true
    }

    return [pscustomobject] @{
        Choice  = $ordered
        Problem = [string[]] @($problem)

        Field   = [pscustomobject] @{
            Name = $Control

            # NO Property AND NO Text. Every other field writes one value to one
            # property; this one only ever carries rows, and the ticks travel on
            # the rows themselves.
            Item = $ordered
        }
    }
}
