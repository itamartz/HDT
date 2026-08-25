function Import-HDTWizardDocument {
    <#
        .SYNOPSIS
            Reads Scripts\UI\wizard.yaml off the share and returns the pages the
            shell can show.

        .DESCRIPTION
            MDT READS ITS PANE DEFINITION OFF THE SHARE AND SO DOES THIS.
            DeployWiz_Definition_ENU.xml lives in Scripts\ next to the panes it
            names, precisely so a site can change what the wizard asks without
            rebuilding a boot image; wizard.yaml lives in Scripts\UI\ next to
            the pages it names, for the same reason.

            THROUGH THE CONTENT PROVIDER, NEVER THE FILE SYSTEM, and that is
            what means standalone media needs no second code path: media is a
            content projection of the share with the provider swapped, so the
            same wizard is read from a UNC share, a local folder or a USB stick
            without this command knowing which it is on.

            A SHARE WITH NO wizard.yaml HAS NO WIZARD, and returning nothing is
            the answer rather than an error. Every image built before this
            existed deploys with nobody present, exactly as it did; a site turns
            the wizard on by authoring pages. That property is the reason the
            definition is a document on the share and not a catalogue in the
            engine.

            MISSING MARKUP IS A DIFFERENT MATTER AND IS REFUSED. A definition
            that names a page which is not there is a definition that is wrong,
            and the failure belongs here - where the file that is wrong can be
            named - rather than two clicks into a deployment with the console
            hidden behind the window.

            THE SHAPE IT RETURNS IS THE SHAPE Show-HDTWizardShell TAKES. Id,
            Title, Heading, Subheading, XamlPath, Skip, Validate, Collect,
            Summary - so nothing between the share and the screen has to
            translate, and there is no second shape to keep in step.

        .PARAMETER Provider
            An IContentProvider, already connected.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Title, Page and
            Path - or nothing at all when the share declares no wizard.

        .EXAMPLE
            $provider = New-HDTLocalContentProvider -Root 'C:\HDTLab\Share'
            $fact = Get-HDTMachineFact -CimProvider (New-HDTCimProvider) `
                -RegistryService (New-HDTRegistryService) -EnvironmentProvider (New-HDTEnvironmentProvider)
            $resolved = Resolve-HDTVariable -Fact $fact
            $wizard = Import-HDTWizardDocument -Provider $provider
            if ($null -eq $wizard) { }   # no wizard on this share

        .EXAMPLE
            $ask = Get-HDTWizardPage -Page $wizard.Page -Variable $resolved.Variable
            if ($ask.IsWizardNeeded) { Show-HDTWizardShell -Page $ask.Page ... }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Provider
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # ResolveContent ANSWERS WHERE, NOT WHAT. It maps a relative content path
    # onto whatever this provider is pointing at - a UNC share, a local folder,
    # a mounted stick - and the provider's own file system reads the bytes. That
    # split is what makes media and a share the same to this command.
    $definitionPath = [string] $Provider.ResolveContent('Scripts\UI\wizard.yaml')

    # SEE THE HEADER: absent is an answer, not a fault.
    if (-not $Provider.TestContent('Scripts\UI\wizard.yaml')) { return }

    $text = [string] $Provider.FileSystem.ReadAllText($definitionPath)

    $document = ConvertFrom-HDTYaml -Yaml $text -Path $definitionPath
    Assert-HDTWizardDocument -Document $document -Path $definitionPath

    $title = ''
    if ($document.Contains('title')) { $title = [string] $document['title'] }

    $page = @()

    foreach ($declared in @($document['pages'])) {

        $id = [string] $declared['id']
        $reference = [string] $declared['reference']

        # THE REFERENCE IS RELATIVE TO Scripts\UI, which is where the pages sit
        # beside the definition that names them - MDT's Scripts\ layout.
        $relative = 'Scripts\UI\{0}' -f $reference

        if (-not $Provider.TestContent($relative)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $definitionPath -Category ObjectNotFound `
                        -Message ("the wizard page '{0}' references '{1}', and there is nothing there. The pages live beside this file, under Scripts\UI." -f
                            $id, $reference)))
        }

        $readable = { param([string] $Key) if ($declared.Contains($Key)) { return [string] $declared[$Key] } return '' }

        # A PAGE WITH NO TITLE IS NAMED AFTER ITSELF, because a rail row with no
        # text is a step a technician cannot refer to.
        $pageTitle = & $readable 'title'
        if ([string]::IsNullOrWhiteSpace($pageTitle)) { $pageTitle = $id }

        $validate = $null
        if ($declared.Contains('validate') -and $null -ne $declared['validate']) {
            $validate = [pscustomobject] @{
                Control = [string] $declared['validate']['control']
                Rule    = [string] $declared['validate']['rule']
            }
        }

        $summary = $null
        if ($declared.Contains('summary') -and $null -ne $declared['summary']) {
            $snippetControl = ''
            if ($declared['summary'].Contains('snippetControl')) {
                $snippetControl = [string] $declared['summary']['snippetControl']
            }

            $summary = [pscustomobject] @{
                RowControl     = [string] $declared['summary']['rowControl']
                SnippetControl = $snippetControl
            }
        }

        $collect = @()
        if ($declared.Contains('collect') -and $null -ne $declared['collect']) {
            foreach ($entry in @($declared['collect'])) {

                $reader = { param([string] $Key) if ($entry.Contains($Key)) { return [string] $entry[$Key] } return '' }

                $isSecret = $false
                if ($entry.Contains('isSecret')) { $isSecret = [bool] $entry['isSecret'] }

                # WHICH HALF OF A TWO-HALVED PAGE THIS BELONGS TO. See
                # Get-HDTWizardPage's skip check: a workgroup machine skipping
                # Computer Details must not be made to supply a domain.
                $isOptional = $false
                if ($entry.Contains('optional')) { $isOptional = [bool] $entry['optional'] }

                $collect += [pscustomobject] @{
                    Control          = & $reader 'control'
                    Variable         = & $reader 'variable'
                    Property         = & $reader 'property'

                    # HOW MANY VALUES THE CONTROL ANSWERS WITH. 'many' is a
                    # column of ticks - the Applications page - and it is the
                    # one declaration that reads the ROWS rather than a property
                    # on the control. Absent reads as 'one', which is every
                    # page written before this existed.
                    Select           = & $reader 'select'
                    IsSecret         = $isSecret
                    Optional         = $isOptional
                    Split            = & $reader 'split'
                    SplitVariable    = & $reader 'splitVariable'
                    SplitDefaultFrom = & $reader 'splitDefaultFrom'
                }
            }
        }

        $page += [pscustomobject] @{
            Id         = $id
            Title      = $pageTitle
            Heading    = & $readable 'heading'
            Subheading = & $readable 'subheading'
            XamlPath   = [string] $Provider.ResolveContent($relative)
            Skip       = & $readable 'skip'
            Validate   = $validate
            Summary    = $summary
            Collect    = $collect
        }
    }

    return [pscustomobject] @{
        Title = $title
        Page  = $page
        Path  = $definitionPath
    }
}
