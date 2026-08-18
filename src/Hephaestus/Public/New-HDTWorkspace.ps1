function New-HDTWorkspace {
    <#
        .SYNOPSIS
            Creates a deployment share: the folder tree, workspace.yaml and
            rules.yaml.

        .DESCRIPTION
            The first thing an administrator does. Everything else in HDT reads
            a deployment share - the importers, the boot image builder, the
            console - and until this existed, every one of them needed a share
            somebody had assembled by hand.

            IT CREATES, IT NEVER REPLACES. If the directory already holds a
            workspace.yaml or a rules.yaml, the command stops and names the file
            it found. There is no switch that overrides that: rules.yaml is the
            file an administrator edits for months, and a command that can
            overwrite it is a command that will. A directory that merely exists,
            or one holding content but neither document, is filled in rather
            than refused - so a share can be assembled around media that is
            already staged there.

            THE FOLDER LIST IS NOT WRITTEN DOWN HERE. It is read from
            Get-HDTWorkspacePath, which is the one place in the engine that
            knows the layout. A folder added to the layout is created by this
            command without it being touched, and the two cannot drift apart
            into a share whose folders the engine does not look in.

            WHAT IT LEAVES UNSAID IS DELIBERATE. The new workspace.yaml declares
            its identity and nothing about the boot image, because an omitted
            setting takes the engine's default and a copied-out default is a
            default that goes stale the day the engine's changes. Supply
            -DeployRoot when the share already has an address; without one the
            boot image is built with an empty share box and asks the technician
            for it at the Welcome screen, which is a working image rather than a
            broken one.

            rules.yaml is written with a working fallback rule rather than an
            empty list - a name for the machine and a workgroup to join - so a
            share created here can complete a deployment before anything is
            edited. The file is commented, and its comments are the only
            documentation of the rule language an administrator needs at the
            point of editing it.

        .PARAMETER Path
            Where the share is created - a local path or a UNC share. The folder
            need not exist.

        .PARAMETER Id
            The share id. It is carried into the boot image and written into log
            and artifact names, so it may hold only letters, digits, hyphen and
            underscore, and at most 64 of them.

        .PARAMETER Name
            The display name an administrator reads in the console and in a log
            line. Defaults to the id.

        .PARAMETER DeployRoot
            The path a machine that has booted the image uses to reach this
            share - usually a UNC path, and not necessarily the path you are
            creating the share through. Omitted, the share declares none and the
            technician is asked for one at the Welcome screen.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one, which is what an
            administrator wants; a test passes New-HDTFakeFileSystem instead and
            the share is created in memory.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Root, Path (the workspace.yaml), RulePath (the rules.yaml),
              Id, Name, DeployRoot, Folder [string[]]

            Nothing is returned when -WhatIf suppressed the work.

        .EXAMPLE
            New-HDTWorkspace -Path 'C:\HDTShare' -Id 'HDT-LAB'

            The smallest useful call: a complete share, named after its id,
            whose address the technician supplies at the machine.

        .EXAMPLE
            New-HDTWorkspace -Path 'C:\HDTShare' -Id 'HDT-LAB' `
                -Name 'HDT lab deployment share' -DeployRoot '\\HDT-HOST\HdtShare'

            The same share, told the address its clients will reach it on, which
            is what gets carried into the boot image.

        .EXAMPLE
            New-HDTWorkspace -Path 'D:\NewShare' -Id 'HDT-LAB' -WhatIf

            Describes the share it would create and touches nothing.

        .LINK
            Import-HDTWorkspaceDocument

        .LINK
            Import-HDTRuleDocument

        .LINK
            Get-HDTVariableMap
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter()]
        [string] $Name,

        [Parameter()]
        [string] $DeployRoot,

        # DEFAULTED, NOT MANDATORY, because this is a command an administrator
        # types. The engine's hot path threads a service catalog through and
        # takes its filesystem mandatory; the authoring commands - the boot image
        # builder, the credential writer, the sequence saver - default it, so
        # that a working call is a short one. A test still passes the fake
        # explicitly, and must.
        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # -- the id, before anything is built -------------------------------------

    # The same rule Assert-HDTWorkspaceDocument enforces, checked here so the
    # error names the ID rather than a file that does not exist yet.
    if ($Id.Length -gt 64 -or $Id -notmatch '^[A-Za-z0-9_-]+$') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                    -Message ("'{0}' is not a legal workspace id. It is carried into the boot image and written into log and artifact names, so it may hold only letters, digits, hyphen and underscore, and at most 64 of them." -f $Id)))
    }

    if ($DeployRoot -like '*..*') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $DeployRoot `
                    -Message ("deployRoot '{0}' contains '..'. A deployment root is named outright, not walked up to." -f $DeployRoot)))
    }

    # [IO.Path]::Combine, not Join-Path, for Get-HDTWorkspacePath's reason: a
    # share root is routinely a drive that is not mounted in the session doing
    # the authoring, and Join-Path throws "Cannot find drive" for one.
    $workspacePath = [System.IO.Path]::Combine($Path, 'workspace.yaml')
    $rulePath = [System.IO.Path]::Combine($Path, 'rules.yaml')

    # -- refuse to replace ----------------------------------------------------

    foreach ($existing in @($workspacePath, $rulePath)) {
        if ($FileSystem.TestPath($existing)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $existing `
                        -Message 'this directory already holds a deployment share, and New-HDTWorkspace never replaces one. Create the new share somewhere else, or edit the documents that are already here.'))
        }
    }

    # -- the folder tree ------------------------------------------------------

    # THE LAYOUT IS READ, NOT RESTATED. Get-HDTWorkspacePath's -Kind set is the
    # one place the folder names live; taking them from its ValidateSet means a
    # folder added there is created here without this file being touched.
    $kind = @((Get-Command -Name Get-HDTWorkspacePath).Parameters['Kind'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
            ForEach-Object { $_.ValidValues })

    $folder = New-Object -TypeName System.Collections.ArrayList
    [void] $folder.Add($Path)

    foreach ($current in $kind) {
        [void] $folder.Add((Get-HDTWorkspacePath -Root $Path -Kind $current))
    }

    # Control\machines is part of the layout too - it is where a per-machine
    # override lands, the file-based equivalent of the MDT database - but it is
    # a child of Control rather than a -Kind of its own, so Get-HDTMachineOverride
    # composes it the same way.
    [void] $folder.Add((Get-HDTWorkspacePath -Root $Path -Kind Control -ChildPath 'machines'))

    # -- the documents --------------------------------------------------------

    $displayName = $Id
    if (-not [string]::IsNullOrWhiteSpace($Name)) { $displayName = $Name }

    $workspaceDocument = [System.Collections.Specialized.OrderedDictionary]::new()
    $workspaceDocument['schemaVersion'] = 1
    $workspaceDocument['id'] = $Id
    $workspaceDocument['name'] = $displayName

    # Written only when there is one. A key present and blank reads as a failed
    # template substitution rather than as a decision.
    if (-not [string]::IsNullOrWhiteSpace($DeployRoot)) {
        $workspaceDocument['deployRoot'] = $DeployRoot
    }

    $workspaceDocument['logLevel'] = 'Info'

    # THE LANGUAGE AND REGION, WRITTEN OUT RATHER THAN ASSUMED. unattend.xml asks
    # for these four by name, and the engine seeds US English when nothing else
    # answers - but a default nobody can see is a default nobody changes. MDT
    # shipped CustomSettings.ini with KeyboardLocale, UILanguage and UserLocale
    # already in it for the same reason: the line you edit has to be there.
    #
    # ITS OWN RULE, ABOVE THE FALLBACK. An administrator changing the keyboard
    # should not have to read a rule about computer names, and a site rule added
    # above this one still wins - first match wins per variable.
    #
    # KeyboardLocale IS THE UNATTEND'S InputLocale. 0409:00000409 is US English
    # with the US keyboard; the pair is language:layout, and both halves change
    # together.
    $locale = [System.Collections.Specialized.OrderedDictionary]::new()
    $locale['name'] = 'Language and region'
    $localeSet = [System.Collections.Specialized.OrderedDictionary]::new()
    $localeSet['HDTKeyboardLocale'] = '0409:00000409'
    $localeSet['HDTSystemLocale'] = 'en-US'
    $localeSet['HDTUILanguage'] = 'en-US'
    $localeSet['HDTUserLocale'] = 'en-US'
    $locale['set'] = $localeSet

    $fallback = [System.Collections.Specialized.OrderedDictionary]::new()
    $fallback['name'] = 'Fallback'
    $fallbackSet = [System.Collections.Specialized.OrderedDictionary]::new()
    $fallbackSet['HDTComputerName'] = 'PC-%HDTSerialNumber%'
    $fallbackSet['HDTJoinWorkgroup'] = 'WORKGROUP'
    $fallback['set'] = $fallbackSet

    $ruleDocument = [System.Collections.Specialized.OrderedDictionary]::new()
    $ruleDocument['schemaVersion'] = 1
    $ruleDocument['rules'] = [object[]] @($locale, $fallback)

    # The writer is held to the engine's own validators, here, before anything
    # is written - the same arrangement Import-HDTOperatingSystem uses. A share
    # this command creates and the engine then refuses to read would be the
    # worst possible first experience of HDT.
    Assert-HDTWorkspaceDocument -Document $workspaceDocument -Path $workspacePath
    Assert-HDTRuleDocument -Document $ruleDocument -Path $rulePath

    # THE COMMENTS ARE THE FEATURE, not decoration. These two files are edited by
    # hand from the day they are written, and the serialiser cannot emit a
    # comment - so the header is prepended to what it emits. The rules header
    # carries a worked conditional example, the way CustomSettings.ini shipped
    # with one, because the point of editing rules.yaml is reached long before
    # the point of reading the documentation for it.
    $workspaceComment = @(
        '# The identity of this deployment share, and the defaults every deployment',
        '# from it starts with. Created by New-HDTWorkspace; edited by hand or from',
        '# the console.',
        '#',
        '# deployRoot is the path a machine that has booted the image uses to reach',
        '# this share - usually a UNC path, and not necessarily the path you are',
        '# editing this file through. It is carried into the boot image, so a change',
        '# here takes effect the next time the image is built. With no deployRoot the',
        '# technician is asked for one at the Welcome screen.',
        '#',
        '# Everything not stated here takes an engine default, including the whole',
        '# bootImage block. Run Get-Help Import-HDTWorkspaceDocument to see them.',
        ''
    )

    $ruleComment = @(
        '# Variable rules for this deployment share - what CustomSettings.ini was.',
        '#',
        '# Rules are walked top to bottom. A rule applies when every key under its',
        '# when: matches, and a set: value only takes effect if that variable is not',
        '# already resolved - so first match wins per variable, and the rules at the',
        '# bottom act as fallbacks. %HDTSomething% expands against the variables',
        '# already resolved.',
        '#',
        '# Every variable a rule may set is listed at the bottom of this file with',
        '# the name it had in MDT. Get-HDTVariableMap prints the same table.',
        '#',
        '# A conditional rule looks like this:',
        '#',
        '#   - name: Latitude naming',
        "#     when: { HDTModel: 'Latitude*', HDTIsLaptop: true }",
        '#     set:',
        "#       HDTComputerName: 'LT-%HDTSerialNumber%'",
        "#       HDTDriverGroup: 'Dell\%HDTModel%'",
        '#',
        '# A rule that needs real logic calls a script instead, and the object it',
        '# writes to stdout becomes the variable set:',
        '#',
        '#   - name: Naming service',
        '#     setFrom: Scripts\Get-ComputerName.ps1',
        ''
    )

    # -- the catalogue, generated ---------------------------------------------
    #
    # WHAT CustomSettings.ini NEVER HAD. An .ini has no vocabulary, so an MDT
    # administrator learns the names from a wiki, a blog and somebody else's
    # file - and gets them subtly wrong, with no error, because a misspelt key
    # in an .ini is just a key nothing reads. A file that ships the list cannot
    # be wrong about it.
    #
    # GENERATED FROM Get-HDTVariableMap, NEVER TYPED. A hand-copied list goes
    # stale the first time a variable is added, and a stale catalogue is worse
    # than none: it is wrong with authority.
    #
    # COMMENTED, EVERY LINE. A set: for fifty variables would override every
    # fact the gather produced, on every machine, for ever. This is a reference
    # to uncomment from, not a configuration.
    #
    # ENGINE-OWNED VARIABLES ARE LEFT OUT. They start with _ and
    # Assert-HDTRuleDocument refuses them, so listing them would be teaching a
    # mistake that the engine then has to refuse.
    $catalogue = @(
        '',
        '# ---------------------------------------------------------------------',
        '# EVERY VARIABLE A RULE MAY SET.',
        '#',
        '# name                     MDT name                 value when no rule sets one',
        '# ---------------------------------------------------------------------'
    )

    foreach ($variable in @(Get-HDTVariableMap | Where-Object { $_.Writable })) {
        $mdtName = [string] $variable.MdtName
        if ([string]::IsNullOrWhiteSpace($mdtName)) { $mdtName = '-' }

        $catalogue += ('#   {0} {1} {2}' -f
            ([string] $variable.HDTName).PadRight(24),
            $mdtName.PadRight(24),
            [string] $variable.Origin)
    }

    $catalogue += ''

    $newLine = [System.Environment]::NewLine

    $workspaceText = (($workspaceComment -join $newLine) + $newLine) + (ConvertTo-HDTYaml -Document $workspaceDocument -Path $workspacePath)
    # THE CATALOGUE GOES AFTER THE RULES, not before them. It is fifty lines
    # long; a file that opens with it buries the two rules an administrator
    # actually has to read.
    $ruleText = (($ruleComment -join $newLine) + $newLine) +
    (ConvertTo-HDTYaml -Document $ruleDocument -Path $rulePath) +
    (($catalogue -join $newLine) + $newLine)

    # -- write ----------------------------------------------------------------

    if (-not $PSCmdlet.ShouldProcess($Path, ("Create deployment share '{0}' - {1} folders, workspace.yaml and rules.yaml" -f $Id, @($folder).Count))) {
        return $null
    }

    foreach ($current in @($folder)) {
        $FileSystem.CreateDirectory($current)
    }

    $FileSystem.WriteAllText($workspacePath, $workspaceText)
    $FileSystem.WriteAllText($rulePath, $ruleText)

    return [pscustomobject] @{
        Root       = $Path
        Path       = $workspacePath
        RulePath   = $rulePath
        Id         = $Id
        Name       = $displayName
        DeployRoot = $DeployRoot
        Folder     = [string[]] @($folder)
    }
}
