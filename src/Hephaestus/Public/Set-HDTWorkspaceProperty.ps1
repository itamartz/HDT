function Set-HDTWorkspaceProperty {
    <#
        .SYNOPSIS
            Changes the single-value settings of a workspace document, leaving
            every other line byte-identical.

        .DESCRIPTION
            The command an administrator types to change what a share is called,
            where its clients reach it, how loudly it logs and how its boot image
            is built - and the one anything with a properties page has to run.

            IT REPLACES A KEY, NOT A FILE. Each setting is a line, and only the
            lines named are rewritten. The comment header, the notes beside the
            keys and the spacing between everything come back exactly as they went
            in, which is the whole point: workspace.yaml is hand-edited from the
            day it is created, and an editor that reformats it makes every change
            unreviewable.

            THE ID IS NOT HERE, AND THAT IS DELIBERATE. It is carried into every
            boot image and written into log and artifact names, so changing it
            after a share has produced anything leaves artifacts that no longer
            agree with the share that made them. Create the share you meant with
            New-HDTWorkspace.

            IT BUILDS THE bootImage BLOCK WHEN THERE IS NONE. New-HDTWorkspace
            writes no boot image settings at all - an omitted setting takes the
            engine's default, and a copied-out default is one that goes stale - so
            the first one written has to create the block.

            EVERY VALUE IS CHECKED BEFORE ANY LINE IS RETURNED, against the same
            rules the engine applies when it loads the file. A scratch space
            outside the range DISM accepts is refused here, naming the range,
            rather than at Save with several more edits stacked on top.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTWorkspaceDocument is what
            touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The display name an administrator reads in the console and in a log
            line.

        .PARAMETER DeployRoot
            The path a machine that has booted the image uses to reach this share
            - usually a UNC path, and not necessarily the path you are editing
            through. It is carried into the boot image, so a change here takes
            effect the next time the image is built. Empty means the technician is
            asked for one at the Welcome screen.

        .PARAMETER LogLevel
            How much every deployment from this share writes.

        .PARAMETER CredentialUser
            The account a boot image signs in to the share as, written as
            credential.username. The PASSWORD is not here and never will be -
            Set-HDTShareCredential writes that into
            Control\share-credential.json, because this document is hand-edited
            and committed.

        .PARAMETER BootImageName
            The artifact base name, which becomes Boot\<name>.wim and
            Boot\<name>.iso.

        .PARAMETER Architecture
            The WinPE architecture the ADK ships.

        .PARAMETER Language
            The ADK language folder, for example en-us.

        .PARAMETER ScratchSpaceMB
            The writable RAM disk inside WinPE, in megabytes. DISM accepts 32 to
            1024.

        .PARAMETER PromptForKey
            Whether the ISO stops at "Press any key to boot from CD or DVD".
            False - the default for every image HDT has ever built - is the
            quiet UEFI boot sector, so a machine nobody is standing at boots
            without a keypress. It is written whichever way it is passed,
            because 'false' stated is what tells the next reader that somebody
            decided rather than never looked.

        .PARAMETER EntryCommand
            What startnet.cmd launches instead of the deployment payload - a
            diagnostic image, or standalone media with its own entry point.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with those settings changed.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\workspace.yaml'))
            Set-HDTWorkspaceProperty -Line $line -DeployRoot '\\HDT-HOST\HdtShare'

        .EXAMPLE
            Set-HDTWorkspaceProperty -Line $line -LogLevel 'Debug' -ScratchSpaceMB 1024

        .EXAMPLE
            Set-HDTWorkspaceProperty -Line $line -EntryCommand 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTDiagnostic.ps1'

            A diagnostic image, which boots to something other than a deployment.

        .LINK
            Save-HDTWorkspaceDocument

        .LINK
            New-HDTWorkspace
    #>
    # NAMED, NOT BLANKET. The analyzer reads 'Credential' in the parameter name
    # and asks for a SecureString; this one is a USERNAME, and the reason it is
    # a plain string is the same reason there is no -Password here at all -
    # workspace.yaml is hand-edited and committed, so the secret lives in
    # Control\share-credential.json and Set-HDTShareCredential writes it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialUser',
        Justification = 'A username, not a secret. No password may be written to workspace.yaml; Set-HDTShareCredential owns that.')]
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter()]
        [AllowEmptyString()]
        [string] $DeployRoot,

        [Parameter()]
        [ValidateSet('Error', 'Warning', 'Info', 'Debug')]
        [string] $LogLevel,

        # THE DECLARATION, NOT THE SECRET, AND THERE IS NO -Password HERE.
        # Set-HDTShareCredential writes the password into
        # Control\share-credential.json; workspace.yaml is the document an
        # administrator hand-edits and commits, and a secret in it ends up in
        # git. Update-HDTBootImage refuses a build where the document declares
        # an account and no secret has been written for it, so both halves have
        # to be settable.
        [Parameter()]
        [AllowEmptyString()]
        [string] $CredentialUser,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $BootImageName,

        [Parameter()]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Language,

        # NOT ValidateRange. The range is DISM's, and a caller who computed a
        # number outside it deserves the sentence that says whose range it is and
        # what it is - which is a terminating HDTConfigurationError like every
        # other refusal here, rather than a parameter binding failure.
        [Parameter()]
        [int] $ScratchSpaceMB,

        [Parameter()]
        [bool] $PromptForKey,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $EntryCommand
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $minimumScratchSpaceMB = 32
    $maximumScratchSpaceMB = 1024

    # The root settings and the boot image settings, in the order a workspace
    # document is written in. Written once so the loop below is the only place
    # that knows how a scalar is spliced.
    $setting = @(
        @{ Parameter = 'Name'; Path = @('name') }
        @{ Parameter = 'DeployRoot'; Path = @('deployRoot') }
        @{ Parameter = 'LogLevel'; Path = @('logLevel') }
        @{ Parameter = 'CredentialUser'; Path = @('credential', 'username') }
        @{ Parameter = 'BootImageName'; Path = @('bootImage', 'name') }
        @{ Parameter = 'Architecture'; Path = @('bootImage', 'architecture') }
        @{ Parameter = 'Language'; Path = @('bootImage', 'language') }
        @{ Parameter = 'ScratchSpaceMB'; Path = @('bootImage', 'scratchSpaceMB') }
        @{ Parameter = 'PromptForKey'; Path = @('bootImage', 'promptForKey') }
        @{ Parameter = 'EntryCommand'; Path = @('bootImage', 'entryCommand') }
    )

    $asked = @($setting | Where-Object { $PSBoundParameters.ContainsKey([string] $_.Parameter) })

    if (@($asked).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject 'workspace.yaml' `
                    -Message ("nothing was asked to change. Pass one of -{0}." -f
                        (@($setting | ForEach-Object { [string] $_.Parameter }) -join ', -'))))
    }

    # -- what is being asked for ---------------------------------------------

    if ($PSBoundParameters.ContainsKey('DeployRoot') -and $DeployRoot -like '*..*') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $DeployRoot `
                    -Message ("deployRoot '{0}' contains '..'. A deployment root is named outright, not walked up to." -f $DeployRoot)))
    }

    if ($PSBoundParameters.ContainsKey('ScratchSpaceMB') -and
        ($ScratchSpaceMB -lt $minimumScratchSpaceMB -or $ScratchSpaceMB -gt $maximumScratchSpaceMB)) {

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $ScratchSpaceMB `
                    -Message ("scratchSpaceMB {0} is outside the range DISM accepts. It must be between {1} and {2}." -f
                        $ScratchSpaceMB, $minimumScratchSpaceMB, $maximumScratchSpaceMB)))
    }

    if ($PSBoundParameters.ContainsKey('BootImageName') -and
        $BootImageName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $BootImageName `
                    -Message ("bootImage name '{0}' is not a legal artifact name. It becomes the base name of the .wim and the .iso under Boot\, so it must start with a letter or a digit and hold only letters, digits, underscore, dot and hyphen." -f $BootImageName)))
    }

    if ($PSBoundParameters.ContainsKey('EntryCommand') -and
        $EntryCommand.IndexOfAny([char[]] @("`r", "`n")) -ge 0) {

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $EntryCommand `
                    -Message 'entryCommand must be one command on one line. A line break here becomes a second command inside startnet.cmd that nobody reading the workspace document would see.'))
    }

    # The document has to be readable before it is worth editing.
    [void] (ConvertFrom-HDTWorkspaceLine -Line $Line)

    if (-not $PSCmdlet.ShouldProcess((@($asked | ForEach-Object { [string] $_.Parameter }) -join ', '),
            'Change the workspace settings')) {
        return [string[]] @($Line)
    }

    # -- the splices ----------------------------------------------------------
    #
    # ONE KEY AT A TIME, RESOLVED AGAINST THE RESULT OF THE LAST. Each splice
    # changes how many lines are above the next, so a range held across two of
    # them points at the wrong lines for the second.

    $result = [string[]] @($Line)

    foreach ($current in $asked) {
        $path = [string[]] @($current.Path)
        $key = [string] $path[@($path).Count - 1]
        $value = $PSBoundParameters[[string] $current.Parameter]

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $result -Path $path `
                -Text ([string[]] @('{0}: {1}' -f $key, (ConvertTo-HDTRuleScalarText -Value $value))))
    }

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
