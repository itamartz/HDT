function Get-HDTConsoleBootImageSetting {
    <#
        .SYNOPSIS
            Everything the WinPE window shows, worked out without a window.

        .DESCRIPTION
            HDTBootImage.xaml is four tabs over one YAML block. This is the
            question those tabs ask, answered once: what is in the General
            boxes, which optional components are ticked and which may not be
            unticked, what content and start commands the document declares, and
            THE CALL EACH CONTROL WOULD RUN.

            IT EXISTS SO THE ADAPTER STAYS AN ADAPTER. New-HDTConsoleHost is
            exempt from TDD as a thin wrapper over WPF, and the price of that
            exemption is that it stays branch-free - "because it is not unit
            tested". Deciding which rows are ticked, which are locked, what a
            size reads as and what a button would invoke is all decision, so it
            is here, where Pester reaches it with no display.

            THE ADK IS A PARAMETER, NOT A READ. Get-HDTAdkComponent needs an
            installed ADK and a registry hive; taking its output means the whole
            Features tab is testable on a machine with neither, and means the
            window can re-ask for a different architecture without this command
            knowing how.

            EVERY ROW CARRIES ITS OWN INVOCATION, which is DESIGN 12's rule:
            "the console may not do anything the cmdlets can't", and it shows
            the invocation so an administrator learns the automation surface by
            clicking. Where the value is typed at click time - a driver group, a
            content pair - the object carries a FORMAT rather than a finished
            string, and the adapter's whole contribution is -f.

            A DOCUMENT THAT WILL NOT PARSE THROWS. The browser's row already
            says so; a window that opened anyway would offer to Save over it.

        .PARAMETER Line
            The workspace.yaml lines, as read from disk. Nothing here writes;
            the editing commands splice these same lines.

        .PARAMETER Path
            The document the lines came from, for the banner. Read by nothing.

        .PARAMETER Component
            What Get-HDTAdkComponent returned for the architecture being shown.
            An empty list is legal and means the Features tab has no rows -
            which is what a build host with no ADK actually offers.

        .PARAMETER HasCertificatePassword
            Whether Control\certificate-password.json exists, as
            Test-HDTBootImageCertificatePassword answers it. INJECTED RATHER
            THAN READ, like the ADK list and the driver groups - and unlike
            them, deliberately a BOOLEAN rather than the value: a view model
            that read the password would hold a private key's password in an
            object a window binds to.

        .PARAMETER DriverGroup
            What Get-HDTDriverGroup returned for this share. An empty list is
            legal and means the only choice is "no drivers" - which is what a
            share with nothing imported yet honestly offers.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Title,
            DocumentPath, General, Component, SelectedSizeText, Driver, Content,
            StartCommand and the Add* formats.

        .EXAMPLE
            $line = Get-Content -LiteralPath 'C:\HDTLab\Share\workspace.yaml'
            Get-HDTConsoleBootImageSetting -Line $line -Path 'C:\HDTLab\Share\workspace.yaml' `
                -Component (Get-HDTAdkComponent -Architecture amd64)

        .EXAMPLE
            (Get-HDTConsoleBootImageSetting -Line $line -Path $path -Component $adk).Component |
                Where-Object { $_.Declared } | Format-Table Name, SizeText

            The whole Features tab, on a console, with no window.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Component = @(),

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $DriverGroup = @(),

        [Parameter()]
        [bool] $HasCertificatePassword = $false,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $TimeZone = @()
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Throws on a document that will not parse. See the header: that is the
    # answer, not something to recover from.
    $workspace = ConvertFrom-HDTWorkspaceLine -Line $Line
    $bootImage = $workspace.BootImage

    # -- the Features tab ----------------------------------------------------
    #
    # DECLARED IS "the document asks for it OR the engine always applies it".
    # Get-HDTAdkComponent's Required marks the six every image gets; they are
    # shown ticked and disabled rather than hidden, because an administrator
    # looking for WinPE-PowerShell in this list has to FIND it and see that it
    # is already there.

    $declaredName = @($bootImage.OptionalComponent | ForEach-Object { [string] $_ })

    $componentRow = New-Object -TypeName System.Collections.ArrayList
    $selectedBytes = [long] 0
    $selectedCount = 0

    foreach ($current in @($Component)) {
        $isRequired = [bool] $current.Required
        $isDeclared = $isRequired -or ($declaredName -contains [string] $current.Name)

        if ($isDeclared) {
            $selectedBytes += [long] $current.SizeBytes
            $selectedCount++
        }

        # WHAT IT NEEDS BESIDE IT, ON THE ROW. WinPE-PowerShell without
        # WinPE-WMI is a build that fails two and a half minutes in; saying so
        # where the tick is costs nothing.
        $requiresText = ''
        if (@($current.Requires).Count -gt 0) {
            $requiresText = 'needs {0}' -f (@($current.Requires) -join ', ')
        }
        if ($isRequired) {
            $requiresText = ('always applied. {0}' -f $requiresText).Trim()
        }

        # WHAT IT DOES, THEN WHAT IT COSTS YOU TO TICK IT, IN ONE COLUMN. The
        # description answers "what is this", the suffix answers "and what else
        # comes with it" - and they are read together, in that order, by
        # somebody deciding. Two columns would put the answer to the second
        # question off the right-hand edge on a narrow window.
        $description = [string] $current.Description
        $detailText = $description

        if (-not [string]::IsNullOrWhiteSpace($requiresText)) {
            if ([string]::IsNullOrWhiteSpace($detailText)) {
                $detailText = $requiresText
            } else {
                $detailText = '{0}  ({1})' -f $description, $requiresText
            }
        }

        [void] $componentRow.Add([pscustomobject] @{
                Name          = [string] $current.Name
                Declared      = $isDeclared
                CanChange     = (-not $isRequired)
                SizeText      = '{0:N1} MB' -f ([double] $current.SizeBytes / 1MB)
                Description   = $description
                DetailText    = $detailText
                RequiresText  = $requiresText
                AddCommand    = "Add-HDTBootImageComponent -Line `$line -Name '{0}'" -f [string] $current.Name
                RemoveCommand = "Remove-HDTBootImageComponent -Line `$line -Name '{0}'" -f [string] $current.Name
            })
    }

    # THE TOTAL, BECAUSE THE COST OF THAT TAB IS THE THING IT HIDES. Every tick
    # is megabytes in a WIM transferred to every machine that PXE boots, and a
    # list gives no sense of that one row at a time.
    $selectedSizeText = '{0} of {1} components selected, {2:N1} MB of cabs before compression.' -f
        $selectedCount, @($Component).Count, ([double] $selectedBytes / 1MB)

    # -- the Customisations tab ----------------------------------------------

    $contentRow = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($bootImage.ExtraContent)) {
        [void] $contentRow.Add([pscustomobject] @{
                Source        = [string] $current.Source
                Destination   = [string] $current.Destination

                # KEYED ON THE DESTINATION, which is what Remove takes: it is
                # what makes a row unique inside the image, and two sources can
                # land in one place.
                RemoveCommand = "Remove-HDTBootImageContent -Line `$line -Destination '{0}'" -f [string] $current.Destination
            })
    }

    $startCommandRow = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($bootImage.StartCommand)) {
        # THE LINE AS THE DOCUMENT HOLDS IT, AND NOTHING ELSE. This view model
        # describes workspace.yaml; startnet.cmd is a different file, generated
        # from it at build time and carrying `call` in front of a batch file so
        # cmd.exe returns. An earlier version also published that generated
        # line here, and the window showed it - which put text on screen that
        # appears in no file this window can save. Get-HDTStartnetScript is
        # where that translation belongs, and it is the only caller of
        # ConvertTo-HDTStartnetCommandLine again.
        [void] $startCommandRow.Add([pscustomobject] @{
                Text          = [string] $current
                RemoveCommand = "Remove-HDTBootImageStartCommand -Line `$line -Command '{0}'" -f [string] $current
            })
    }

    # -- the time zone --------------------------------------------------------
    #
    # A LIST, BECAUSE tzutil TAKES AN ID AND NOBODY KNOWS THE IDS. What an
    # administrator is looking for is "(UTC+02:00) Jerusalem"; what the document
    # has to hold is "Israel Standard Time".
    #
    # "The hardware clock" IS THE FIRST ROW rather than an empty selection - it
    # is what every image built before this did, and a list you can only say it
    # in by clearing the box is a list you cannot say it in.
    #
    # THE DOCUMENT'S OWN ANSWER SURVIVES A MACHINE THAT HAS NEVER HEARD OF IT.
    # Windows adds time zones; a share edited on a patched machine and opened on
    # an older one would otherwise read as "no time zone", and a Save would make
    # that true.

    $zoneChoice = New-Object -TypeName System.Collections.ArrayList

    [void] $zoneChoice.Add([pscustomobject] @{
            Id      = ''
            Display = '(leave WinPE on the hardware clock)'
        })

    foreach ($current in @($TimeZone)) {
        [void] $zoneChoice.Add([pscustomobject] @{
                Id      = [string] $current.Id
                Display = [string] $current.Display
            })
    }

    $declaredZone = [string] $bootImage.TimeZone

    if (-not [string]::IsNullOrWhiteSpace($declaredZone) -and
        @($zoneChoice | Where-Object { $_.Id -eq $declaredZone }).Count -eq 0) {

        [void] $zoneChoice.Add([pscustomobject] @{
                Id      = $declaredZone
                Display = '{0}  (this machine does not know it)' -f $declaredZone
            })
    }

    $timeZoneRow = [pscustomobject] @{
        Id                 = $declaredZone
        Choice             = [pscustomobject[]] @($zoneChoice)

        Hint               = 'WinPE has no time zone setting in its answer file, so it runs on the hardware clock - UTC in practice, which puts its log timestamps hours from the machine it just built. Named here, startnet.cmd runs tzutil, and the deployed machine''s unattend inherits the same answer.'

        ApplyCommandFormat = 'Set-HDTBootImageTimeZone -Line $line -Name ''{0}'''
        ClearCommand       = 'Set-HDTBootImageTimeZone -Line $line -Clear'
    }

    # -- the Certificates tab -------------------------------------------------
    #
    # TWO LISTS BECAUSE THEY ARE TWO DIFFERENT THINGS, and the Store column is
    # what says so on the screen: a certificate authority is trusted (Root) and
    # a machine certificate is presented (My). An administrator looking at a
    # page with two file boxes on it has to be told why it is not one.

    $certificateRow = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($bootImage.RootCertificate)) {
        [void] $certificateRow.Add([pscustomobject] @{
                Path          = [string] $current
                Store         = 'Root'
                RemoveCommand = ("Remove-HDTBootImageCertificate -Line `$line -Path '{0}'" -f [string] $current)
            })
    }

    # THE COUNT, BECAUSE THE BOX SHOWS ONE ROW AT A TIME. A PKI is a chain - a
    # root and the subordinate that actually issued the certificate - and an
    # image trusting only the root still cannot validate what the issuing CA
    # signed. A drop-down that has to be opened to find out how many are in it
    # is a drop-down nobody opens.
    $certificateSummaryText = 'This image trusts no certificate authorities of its own, which is the ordinary case.'

    if (@($certificateRow).Count -eq 1) {
        $certificateSummaryText = '1 certificate authority trusted.'
    } elseif (@($certificateRow).Count -gt 1) {
        $certificateSummaryText = '{0} certificate authorities trusted - a chain is normally a root and the subordinate that issued from it.' -f
        @($certificateRow).Count
    }

    # THE WARNING IS COMPUTED HERE, NOT DRAWN IN THE MARKUP, because it is a
    # fact about this document: a .pfx named with no password stored is a build
    # Update-HDTBootImage refuses, and the refusal comes minutes after the press
    # if the window did not say so first.
    $clientPath = [string] $bootImage.ClientCertificate
    $certificateWarning = ''

    if (-not [string]::IsNullOrWhiteSpace($clientPath) -and -not $HasCertificatePassword) {
        $certificateWarning = 'This certificate has no password stored, and a .pfx will not import without one. Update Boot Image refuses the build until Set password has been used.'
    }

    $clientCertificate = [pscustomobject] @{
        Path                  = $clientPath
        HasPassword           = $HasCertificatePassword
        Warning               = $certificateWarning

        ApplyCommandFormat    = 'Set-HDTBootImageClientCertificate -Line $line -Path ''{0}'''
        ClearCommand          = 'Set-HDTBootImageClientCertificate -Line $line -Clear'

        # THE SHARE, AND NOT THE PASSWORD. What the window echoes is the command
        # an administrator could have typed, and this is the one command in the
        # console whose second argument must never appear in that box.
        # THE PROMPT IS Get-Credential's, and a contract test is what decided
        # that: no file in this module may name the console-reading cmdlet, at
        # all, because the engine runs where nobody is at the keyboard and a
        # prompt there is a deployment that hangs until somebody notices.
        #
        # THE RULE IS FILE-BLIND AND SO IS ITS SCAN. This view model never runs
        # in WinPE and the test does not care - and it also matched the COMMENT
        # that first explained the exception, which is why this one does not
        # spell the name either.
        PasswordCommandFormat = 'Set-HDTBootImageCertificatePassword -WorkspaceRoot ''{0}'' -Password (Get-Credential -UserName certificate -Message ''The .pfx password'').Password'
    }

    # -- the General tab, and the calls Save runs ----------------------------

    $general = [pscustomobject] @{
        Name                  = [string] $bootImage.Name
        Architecture          = [string] $bootImage.Architecture
        Language              = [string] $bootImage.Language

        # AS TEXT, because the combo matches on its Tag and SelectedValuePath
        # compares strings. An int here selects nothing, and the box comes up
        # blank on a document that set it.
        ScratchSpaceMB        = [string] $bootImage.ScratchSpaceMB
        Unattend              = [string] $bootImage.Unattend
        Background            = [string] $bootImage.Background

        # A REAL BOOLEAN, because the control is a CheckBox and IsChecked takes
        # one - every other value here is a string because the controls that
        # show them are text boxes and combo boxes.
        PromptForKey          = [bool] $bootImage.PromptForKey

        Command               = "Set-HDTWorkspaceProperty -Line `$line -BootImageName '{0}' -Architecture '{1}' -Language '{2}' -ScratchSpaceMB {3}" -f
        [string] $bootImage.Name, [string] $bootImage.Architecture,
        [string] $bootImage.Language, [string] $bootImage.ScratchSpaceMB

        UnattendCommandFormat = 'Set-HDTBootImageUnattend -Line $line -Path ''{0}'''
        UnattendClearCommand  = 'Set-HDTBootImageUnattend -Line $line -Clear'

        # THE FILE, NOT THE NAME OF IT. The box beside this takes a path to an
        # answer file that has to already exist, and a share that has never had
        # one has nothing to browse to - which left the ordinary case as "go and
        # write a windowsPE document from Microsoft's schema, by hand".
        UnattendTemplateCommandFormat = 'New-HDTBootImageUnattend -Workspace ''{0}'''

        BackgroundCommandFormat = 'Set-HDTBootImageBackground -Line $line -Path ''{0}'''
        BackgroundClearCommand  = 'Set-HDTBootImageBackground -Line $line -Clear'
    }

    # -- the Drivers tab -----------------------------------------------------
    #
    # A LIST, NOT A BOX YOU TYPE INTO. A group is a folder under Drivers\ on the
    # share, so the set of legal answers is knowable - and a typed one that is
    # wrong produces a boot image with no drivers in it, warned about at build
    # time and discovered on a bench.
    #
    # THE EMPTY ANSWER IS AN ENTRY IN THE LIST. "No drivers" is a real choice,
    # not the absence of one, and a list whose only way to say it was to clear a
    # selection would be a list you cannot say it in.
    $driverChoice = New-Object -TypeName System.Collections.ArrayList

    [void] $driverChoice.Add([pscustomobject] @{
            Name    = ''
            Display = '(none - WinPE uses the drivers Microsoft ships)'
        })

    foreach ($current in @($DriverGroup)) {
        [void] $driverChoice.Add([pscustomobject] @{
                Name    = [string] $current.Name
                Display = [string] $current.Name
            })
    }

    # THE DOCUMENT'S OWN ANSWER, EVEN WHEN THE FOLDER IS GONE. A share whose
    # driver group was renamed still has to show what the document says, or the
    # window silently reads as "no drivers" and a Save makes that true.
    $declaredGroup = [string] $bootImage.Drivers

    if (-not [string]::IsNullOrWhiteSpace($declaredGroup) -and
        @($driverChoice | Where-Object { $_.Name -eq $declaredGroup }).Count -eq 0) {

        [void] $driverChoice.Add([pscustomobject] @{
                Name    = $declaredGroup
                Display = '{0}  (not on the share)' -f $declaredGroup
            })
    }

    $driver = [pscustomobject] @{
        Group              = $declaredGroup
        Choice             = [pscustomobject[]] @($driverChoice)
        ApplyCommandFormat = 'Set-HDTBootImageDriver -Line $line -Name ''{0}'''
        ClearCommand       = 'Set-HDTBootImageDriver -Line $line -Clear'
    }

    return [pscustomobject] @{
        Title                     = 'Windows PE  -  {0}' -f [string] $bootImage.Name
        DocumentPath              = $Path

        # THE SHARE, WHICH IS THE DOCUMENT'S FOLDER. Everything the boot image
        # names - the answer file, the background, extraContent's sources - is
        # stored relative to it, and neither a text box nor a file picker hands
        # a root back. Worked out here so the window resolves nothing.
        WorkspaceRoot             = [string] (Split-Path -Path $Path -Parent)

        General                   = $general
        Component                 = [pscustomobject[]] @($componentRow)

        # WHAT THE DOCUMENT CURRENTLY DECLARES, so a window can tell a real tick
        # from one WPF raised while building a row. A TabControl does not realise
        # an unselected tab's content, so every checkbox on the Features tab is
        # created - and raises Checked - the first time an administrator clicks
        # that tab. No timing guard can cover that; comparing against this can.
        DeclaredName              = [string[]] @($declaredName)
        SelectedSizeText          = $selectedSizeText
        Driver                    = $driver
        Content                   = [pscustomobject[]] @($contentRow)
        StartCommand              = [pscustomobject[]] @($startCommandRow)

        TimeZone                    = $timeZoneRow
        Certificate                 = [pscustomobject[]] @($certificateRow)
        CertificateSummaryText      = $certificateSummaryText
        ClientCertificate           = $clientCertificate
        AddCertificateCommandFormat = 'Add-HDTBootImageCertificate -Line $line -Path ''{0}'''

        AddContentCommandFormat   = 'Add-HDTBootImageContent -Line $line -Source ''{0}'' -Destination ''{1}'''
        AddStartCommandFormat     = 'Add-HDTBootImageStartCommand -Line $line -Command ''{0}'''
        AddStartCommandFirstFormat = 'Add-HDTBootImageStartCommand -Line $line -Command ''{0}'' -First'

        Command                   = "Get-HDTConsoleBootImageSetting -Line `$line -Path '{0}'" -f $Path
    }
}
