function Get-HDTConsoleNewSequence {
    <#
        .SYNOPSIS
            What the New Task Sequence wizard offers: templates, images, and the
            settings it writes.

        .DESCRIPTION
            MDT'S New Task Sequence WIZARD, answered without a window. It asks
            seven pages of questions and writes one file; what it asks is the
            interesting part, and it is decided here so the window can show rows
            and run a command without deciding anything.

            THE LISTS ARE THE SHARE'S AND THE TOOLKIT'S OWN - the templates this
            module ships and the images this workspace holds, through the same
            commands the browser and the editor use. A wizard that offered
            something the engine cannot resolve would be a wizard that produces a
            sequence which fails at the machine.

            A SHARE WITH NO CATALOG STILL OFFERS TEMPLATES. Creating the sequence
            before importing the image is an ordinary order of work, and the
            image is a variable an author can fill in later.

            THE ADMINISTRATOR PASSWORD IS READABLE IN THE FILE AND THE PAGE SAYS
            SO. A value WinPE must use with no human present cannot be protected
            by a key that ships in the same boot image (DESIGN 4.5.2); the real
            control is to treat the workspace and the boot media as credentials.
            A wizard with a masked box and no warning implies a secret it is not
            keeping.

        .PARAMETER Workspace
            The deployment share's root.

        .PARAMETER TemplatePath
            Where templates are read from. Defaults to the ones this module
            ships.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Template, Image,
            Setting and Command.

        .EXAMPLE
            (Get-HDTConsoleNewSequence -Workspace C:\HDTLab\Share).Template
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Workspace,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $TemplatePath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'Templates'),

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # -FileSystem IS FORWARDED, and it was not. Get-HDTSequenceTemplate defaults
    # to the real adapter, so this command - which takes an injected file system
    # and forwards it to Get-HDTConsoleWorkspace five lines below - reached the
    # REAL disk for the template list while every other read went to the fake.
    #
    # UNDER A TEST THAT MEANS THE ANSWER CAME FROM THE DEVELOPER'S OWN MACHINE
    # rather than from the seeded workspace, which is the kind of pass that
    # holds until it runs somewhere else. The same shape put a real
    # C:\ws\Logs\Console.log on disk from Show-HDTConsole on 2026-08-28; this is
    # the other instance of it.
    #
    # THE CATCH STAYS, and it is why nobody noticed: a template folder that
    # cannot be read is an empty list and a dialog with no templates in it, not
    # an error. That is right for a dialog and it is also very quiet.
    $template = @()
    try { $template = @(Get-HDTSequenceTemplate -Path $TemplatePath -FileSystem $FileSystem) } catch { $template = @() }

    $image = New-Object -TypeName System.Collections.ArrayList

    try {
        foreach ($current in @((Get-HDTConsoleWorkspace -Path $Workspace -FileSystem $FileSystem).OperatingSystem)) {
            if ($null -eq $current) { continue }

            $display = [string] $current.Id
            if (-not [string]::IsNullOrWhiteSpace([string] $current.Name)) { $display = [string] $current.Name }

            [void] $image.Add([pscustomobject] @{
                    Id      = [string] $current.Id
                    Name    = [string] $current.Name
                    Display = $display
                })
        }
    } catch {
        # A share with no catalog, or one that will not read. Templates still
        # answer, because creating the sequence before importing the image is an
        # ordinary order of work.
        $image.Clear()
    }

    # MDT'S "OS Settings" AND "Admin Password" PAGES, as data. Each row is a
    # variable the new sequence carries, so adding one here is a row plus
    # whatever consumes it - not a new box wired to a new handler.
    $setting = [pscustomobject[]] @(
        [pscustomobject] @{
            Key    = 'HDTFullName'
            Label  = 'Full name'
            Hint   = 'The registered owner written into the answer file - a person or a team.'
            Secret = $false
        }

        [pscustomobject] @{
            Key    = 'HDTOrgName'
            Label  = 'Organization'
            Hint   = 'The registered organisation written into the answer file.'
            Secret = $false
        }

        [pscustomobject] @{
            Key    = 'HDTAdminPassword'
            Label  = 'Administrator password'
            Hint   = 'The local administrator password for the deployed machine. It is stored readable in this sequence, because WinPE has to use it with nobody present - treat the share and the boot media as credentials. It never appears in a log.'
            Secret = $true
        }
    )

    return [pscustomobject] @{
        Template      = [pscustomobject[]] @($template)
        Image         = [pscustomobject[]] @($image)
        Setting       = $setting

        # WHAT CREATE WOULD RUN IS RENDERED, NOT FORMATTED. There was a format
        # string here taking three of the seven answers this window collects, so
        # the footer named a command that produced a different sequence from the
        # button beside it. Get-HDTConsoleNewSequenceCommand builds the whole
        # line, -Variable included, and masks whatever these rows mark Secret.
        Command       = "Get-HDTConsoleNewSequence -Workspace '$Workspace'"
    }
}
