function Assert-HDTWorkspaceDocument {
    <#
        .SYNOPSIS
            Validates a parsed workspace.yaml against the authoring rules.

        .DESCRIPTION
            The engine's own validator, and the one that actually runs in WinPE:
            Test-Json does not exist under Windows PowerShell 5.1, so
            schemas/workspace.schema.json is a gate for the console, editors and
            CI while this is the gate for a boot image build and a deployment.

            It throws on the first violation and returns nothing otherwise. Every
            failure is a terminating HDTConfigurationError built by
            New-HDTErrorRecord, so it names the file, carries the file as its
            TargetObject, and says which key is wrong - "fail fast
            and point at the file".

            The authoring rules, in the order they are checked:

              document    not empty; a mapping; only the seven known keys;
                          schemaVersion present, an integer, not newer than this
                          engine (delegated to Test-HDTSchemaVersion)
              identity    id present, [A-Za-z0-9-_]{1,64}; name present
              deployRoot  present, not whitespace, no '..'
              logLevel    one of Error, Warning, Info, Debug
              credential  a mapping; username only; NO password
              bootImage   a mapping; only the seven known keys; architecture
                          amd64 or arm64; scratchSpaceMB 32..1024;
                          optionalComponents a list of ^WinPE-[A-Za-z0-9-]+$ with
                          no case-insensitive duplicate; extraContent rows
                          carrying source and destination, destination rooted and
                          free of '..'

            A PASSWORD KEY HERE IS AN ERROR, NOT AN OVERSIGHT. workspace.yaml is
            the file an administrator hand-edits and commits, so a share
            password in it is a share password in git. The refusal names
            Set-HDTShareCredential and says where the secret does live -
            Control\share-credential.json, written by that command. The message
            deliberately does not echo the value back: a validator that quotes
            the secret it is refusing has just written it to the log.

            deployRoot HAS THREE LEGAL FORMS and the third is not decoration:

              \\server\HdtShare   UNC, reached with the Smb provider
              C:\HDTLab\Share     rooted local; correct on a build host, wrong
                                  inside a boot image
              \Share              VOLUME-RELATIVE - the volume is discovered at
                                  boot, and it is the only form a Local boot
                                  image may carry, because a lab test recorded
                                  WinPE handing the content disk C: while the RAM
                                  disk was X:

            Nothing here resolves the third form. Resolve-HDTDeployRoot (05-03)
            does that inside WinPE, by probing every ready drive for the
            workspace marker. This function only has to ACCEPT it.

        .PARAMETER Document
            The parsed document, as returned by ConvertFrom-HDTYaml. $null is
            accepted and reported as an empty file rather than crashing.

        .PARAMETER Path
            The file the document came from. Used for the message and the
            TargetObject; this function reads nothing.

        .OUTPUTS
            None. It throws or it returns nothing.

        .EXAMPLE
            Assert-HDTWorkspaceDocument -Document (ConvertFrom-HDTYaml -Yaml $text -Path $path) -Path $path

        .NOTES
            The locator in a message is the KEY or the extraContent INDEX, not a
            line number: the YAML parser does not carry line information onto the
            object graph it returns. Only ConvertFrom-HDTYaml, which still holds
            the parser's own exception, can name a line.
    #>
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

    $supportedSchemaVersion = 1

    # THE REQUIRED KEYS LIVE HERE, IN ONE PLACE, AND THEY ARE COMPARED AGAINST
    # schemas/workspace.schema.json's own "required" array by
    # tests/contract/WorkspaceSchema.Contract.Tests.ps1, which reads this very
    # variable out of this file. A key added to one and forgotten in the other
    # turns that contract red. Do not inline this list into the loop below.
    $requiredRootKey = @('schemaVersion', 'id', 'name')

    $allowedRootKey = @('schemaVersion', 'id', 'name', 'deployRoot', 'logLevel',
        'credential', 'bootImage')
    $allowedCredentialKey = @('username')
    $allowedBootImageKey = @('name', 'architecture', 'language', 'scratchSpaceMB',
        'optionalComponents', 'extraContent', 'drivers', 'unattend', 'background',
        'entryCommand', 'startCommand', 'skip')
    $allowedSkipKey = @('welcome', 'staticIp', 'deployRoot', 'credential')
    $allowedExtraContentKey = @('source', 'destination')
    $allowedArchitecture = @('amd64', 'arm64')
    $allowedLogLevel = @('Error', 'Warning', 'Info', 'Debug')

    $minimumScratchSpaceMB = 32
    $maximumScratchSpaceMB = 1024

    # -- the document ---------------------------------------------------------

    if ($null -eq $Document) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the file is empty. A workspace document must declare schemaVersion, id, name and deployRoot.'))
    }

    if (-not ($Document -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the document must be a mapping with schemaVersion, id, name and deployRoot keys, but it is a {0}." -f $Document.GetType().Name)))
    }

    foreach ($key in @($Document.Keys)) {
        if ($allowedRootKey -notcontains [string] $key) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("'{0}' is not a key a workspace document may declare. The allowed keys are {1}." -f $key, ($allowedRootKey -join ', '))))
        }
    }

    foreach ($key in $requiredRootKey) {
        if (-not $Document.Contains($key)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0} is missing. A workspace document declares {1}." -f $key, ($requiredRootKey -join ', '))))
        }
    }

    $schemaVersion = $Document['schemaVersion']
    if (-not (($schemaVersion -is [int]) -or ($schemaVersion -is [long]))) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("schemaVersion must be an integer, but it is '{0}'." -f $schemaVersion)))
    }

    $supported = $false
    try {
        $supported = Test-HDTSchemaVersion -SchemaVersion ([int] $schemaVersion) -Supported $supportedSchemaVersion
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("schemaVersion {0} is not a valid schema version. It must be 1 or greater." -f $schemaVersion)))
    }

    if (-not $supported) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("schemaVersion {0} is newer than this engine understands (schemaVersion {1}). Upgrade the engine rather than the workspace." -f $schemaVersion, $supportedSchemaVersion)))
    }

    # -- the identity ---------------------------------------------------------

    $id = [string] $Document['id']

    if ([string]::IsNullOrWhiteSpace($id)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'id is missing. The id names this share in a log line, in a boot image manifest and on a client that connected to it.'))
    }

    if ($id.Length -gt 64) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("id '{0}' is {1} characters. A workspace id is at most 64." -f $id, $id.Length)))
    }

    if ($id -notmatch '^[A-Za-z0-9_-]+$') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("id '{0}' is not a legal workspace id. It is carried into the boot image and written into log and artifact names, so it may hold only letters, digits, hyphen and underscore." -f $id)))
    }

    $name = [string] $Document['name']

    if ([string]::IsNullOrWhiteSpace($name)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'name is missing. The name is what an administrator reads in the console and in a log line.'))
    }

    # -- deployRoot -----------------------------------------------------------

    # NO SHARE IS NO SHARE, however it was spelled. An omitted key, an empty
    # value and a whitespace value all mean the same thing here: the image is
    # built without a deployment root, reaches the Welcome screen with an empty
    # box, and asks the technician for one.
    #
    # An earlier version refused the empty spelling on the grounds that a
    # written-but-blank key looks like a failed template substitution rather
    # than a decision. That is true, and it is still not worth two documents
    # that mean the same thing behaving differently - the surprise costs more
    # than the typo it caught, and an image that asks for its share is not a
    # broken image.
    $deployRoot = ''
    if ($Document.Contains('deployRoot')) { $deployRoot = [string] $Document['deployRoot'] }
    if ([string]::IsNullOrWhiteSpace($deployRoot)) { $deployRoot = '' }

    if ($deployRoot -like '*..*') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("deployRoot '{0}' contains '..'. A deployment root is named outright, not walked up to." -f $deployRoot)))
    }

    # -- logLevel -------------------------------------------------------------

    if ($Document.Contains('logLevel')) {
        $logLevel = [string] $Document['logLevel']

        if ($allowedLogLevel -notcontains $logLevel) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("logLevel '{0}' is not a level HDT logs at. The levels are {1}." -f $logLevel, ($allowedLogLevel -join ', '))))
        }
    }

    # -- the credential -------------------------------------------------------

    if ($Document.Contains('credential')) {
        $credential = $Document['credential']

        if (-not ($credential -is [System.Collections.IDictionary])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'credential must be a mapping carrying a username.'))
        }

        foreach ($key in @($credential.Keys)) {
            $keyName = [string] $key

            # Checked before the generic unknown-key message, because THIS one is
            # the sentence that has to be read: it says where the secret goes.
            if ($keyName -eq 'password') {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message "credential declares a password. The share password does not belong in this file: this is the document an administrator hand-edits and commits. Remove the key and run Set-HDTShareCredential, which writes the secret to Control\share-credential.json instead."))
            }

            if ($allowedCredentialKey -notcontains $keyName) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("'{0}' is not a key credential may declare. The allowed keys are {1}; the secret is written by Set-HDTShareCredential." -f $keyName, ($allowedCredentialKey -join ', '))))
            }
        }

        $username = ''
        if ($credential.Contains('username')) { $username = [string] $credential['username'] }

        if ([string]::IsNullOrWhiteSpace($username)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'credential is declared with no username. Name the deployment account, or remove the credential block entirely.'))
        }
    }

    # -- the boot image -------------------------------------------------------

    if (-not $Document.Contains('bootImage')) {
        return
    }

    $bootImage = $Document['bootImage']

    if (-not ($bootImage -is [System.Collections.IDictionary])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'bootImage must be a mapping. Its keys are the boot image build settings.'))
    }

    foreach ($key in @($bootImage.Keys)) {
        if ($allowedBootImageKey -notcontains [string] $key) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("bootImage: '{0}' is not a key it may declare. The allowed keys are {1}." -f $key, ($allowedBootImageKey -join ', '))))
        }
    }

    if ($bootImage.Contains('name')) {
        $imageName = [string] $bootImage['name']

        if ($imageName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("bootImage: name '{0}' is not a legal artifact name. It becomes the base name of the .wim and the .iso under Boot\, so it must start with a letter or a digit and hold only letters, digits, underscore, dot and hyphen." -f $imageName)))
        }
    }

    if ($bootImage.Contains('architecture')) {
        $architecture = [string] $bootImage['architecture']

        if ($allowedArchitecture -notcontains $architecture) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("bootImage: architecture '{0}' is not an architecture the ADK ships a WinPE for. The architectures are {1}." -f $architecture, ($allowedArchitecture -join ', '))))
        }
    }

    if ($bootImage.Contains('language')) {
        $language = [string] $bootImage['language']

        if ([string]::IsNullOrWhiteSpace($language)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'bootImage: language is empty. It names the ADK language folder, for example en-us.'))
        }
    }

    if ($bootImage.Contains('scratchSpaceMB')) {
        $scratchSpace = $bootImage['scratchSpaceMB']

        if (-not (($scratchSpace -is [int]) -or ($scratchSpace -is [long]))) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("bootImage: scratchSpaceMB must be an integer, but it is '{0}'." -f $scratchSpace)))
        }

        if (([int] $scratchSpace -lt $minimumScratchSpaceMB) -or ([int] $scratchSpace -gt $maximumScratchSpaceMB)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("bootImage: scratchSpaceMB {0} is outside the range DISM accepts. It must be between {1} and {2}." -f $scratchSpace, $minimumScratchSpaceMB, $maximumScratchSpaceMB)))
        }
    }

    # -- the WinPE answer file ------------------------------------------------
    #
    # A PATH IS A PATH HERE, exactly as it is for extraContent's SOURCE:
    # relative to the share, or rooted on the build host. An earlier version
    # refused a rooted one on the grounds that the answer file was share
    # content - which was a rule this file invented and nothing else in the
    # workspace holds. The file an administrator browses to is wherever they
    # keep it.
    #
    # WHAT IS INSIDE THE FILE IS NOT CHECKED HERE. wpeinit accepts a fixed set
    # of settings and ignores the rest; deciding which of them an administrator
    # meant is not a YAML validator's job. Whether the file EXISTS is
    # Update-HDTBootImage's business, and it refuses before it mounts.

    if ($bootImage.Contains('unattend')) {
        $unattend = $bootImage['unattend']

        if ($null -ne $unattend -and -not ($unattend -is [string])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("bootImage: unattend must be a path to a WinPE answer file, but it is '{0}'." -f $unattend)))
        }

        if ([string]::IsNullOrWhiteSpace([string] $unattend)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'bootImage: unattend is empty. Remove the key to build the image with no answer file.'))
        }
    }

    # -- the WinPE background --------------------------------------------------
    #
    # JUDGED THE WAY THE ANSWER FILE IS - a path is a path - plus the one rule
    # that is not about paths: WinPE reads \Windows\System32\winpe.jpg and
    # nothing else, so a .png named here is a file the image carries and never
    # shows. A build that succeeds and a background that does not appear is the
    # worst way to learn that.

    if ($bootImage.Contains('background')) {
        $background = $bootImage['background']

        if ($null -ne $background -and -not ($background -is [string])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("bootImage: background must be a path to a .jpg, but it is '{0}'." -f $background)))
        }

        if ([string]::IsNullOrWhiteSpace([string] $background)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'bootImage: background is empty. Remove the key to use the background WinPE ships.'))
        }

        if (([string] $background) -notmatch '\.(jpg|jpeg)$') {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("bootImage: background '{0}' is not a .jpg. WinPE's background is \Windows\System32\winpe.jpg and it must be a JPEG." -f $background)))
        }
    }

    # -- the entry command ----------------------------------------------------
    #
    # It is written into startnet.cmd verbatim (DESIGN 5.1), so the two things
    # checked here are the two that make the written file mean something other
    # than what the document says: nothing to run, and more than one thing to
    # run. What the command DOES is not this validator's business - a diagnostic
    # image exists to run something other than the deployment payload.

    if ($bootImage.Contains('entryCommand')) {
        $entryCommand = $bootImage['entryCommand']

        if ($null -ne $entryCommand -and -not ($entryCommand -is [string])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("bootImage: entryCommand must be a command to run, but it is '{0}'." -f $entryCommand)))
        }

        if ([string]::IsNullOrWhiteSpace([string] $entryCommand)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'bootImage: entryCommand must be a command to run. Remove the key to launch the deployment payload.'))
        }

        if (([string] $entryCommand).IndexOfAny([char[]] @("`r", "`n")) -ge 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'bootImage: entryCommand must be one command on one line. A line break here becomes a second command inside startnet.cmd that nobody reading this document would see.'))
        }
    }

    # -- the start commands ---------------------------------------------------
    #
    # WHAT MAKES A COPIED TOOL A RUNNING TOOL. extraContent puts BGInfo or a VNC
    # server inside the image and nothing starts it; entryCommand is one slot,
    # already holding the deployment payload, and that payload does not return.
    # So these run between the two, after wpeinit has brought the network up.
    #
    # Each one is written into startnet.cmd verbatim, which is why the two things
    # checked are the two that make the written file mean something other than
    # what this document says: nothing to run, and more than one thing to run on
    # a line that claims to be one.

    if ($bootImage.Contains('startCommand')) {
        $startCommand = $bootImage['startCommand']

        # An explicit empty list is legal and means "run nothing extra", which is
        # the same build as omitting the key.
        if ($null -ne $startCommand -and -not ($startCommand -is [System.Collections.IList])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'bootImage: startCommand must be a list of commands, run in the order they are written. One command on its own is still a list of one.'))
        }

        $position = 0

        foreach ($current in @($startCommand)) {
            $position++

            if ($null -ne $current -and -not ($current -is [string])) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("bootImage: startCommand {0} must be a command to run, but it is '{1}'." -f $position, $current)))
            }

            if ([string]::IsNullOrWhiteSpace([string] $current)) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("bootImage: startCommand {0} is empty. Name the command to run, or remove the entry." -f $position)))
            }

            if (([string] $current).IndexOfAny([char[]] @("`r", "`n")) -ge 0) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("bootImage: startCommand {0} must be one command on one line. A line break here becomes a second command inside startnet.cmd that nobody reading this document would see." -f $position)))
            }
        }
    }

    # -- the skip block -------------------------------------------------------
    #
    # MDT's Skip* properties for the Welcome screen, which live here rather than
    # in rules.yaml because that screen runs BEFORE the share is reachable
    # (.planning/WPF-FIRST.md, W2).
    #
    # AN OMITTED KEY IS NOT false, and this validator must not turn it into one:
    # it checks shape and says nothing about defaults. Get-HDTWizardSkip is the
    # only place "the workspace said nothing" becomes a decision.
    #
    # A NON-BOOLEAN IS REFUSED RATHER THAN COERCED. 'yes', 'no' and '' are all
    # truthy or falsy in PowerShell in ways nobody reading the YAML would
    # predict, and the wrong guess here is a wizard that does not appear on a
    # machine somebody is standing in front of.

    if ($bootImage.Contains('skip')) {
        $skip = $bootImage['skip']

        if ($null -ne $skip -and -not ($skip -is [System.Collections.IDictionary])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("bootImage: skip must be a mapping of {0}, but it is a {1}." -f ($allowedSkipKey -join ', '), $skip.GetType().Name)))
        }

        if ($null -ne $skip) {
            foreach ($key in @($skip.Keys)) {
                if ($allowedSkipKey -notcontains [string] $key) {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                                -Message ("bootImage: skip: '{0}' is not a rule it may declare. The allowed rules are {1}." -f $key, ($allowedSkipKey -join ', '))))
                }

                $value = $skip[$key]

                if ($null -ne $value -and -not ($value -is [bool])) {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                                -Message ("bootImage: skip: {0} must be true or false, but it is '{1}'. Remove the rule to leave it unstated." -f $key, $value)))
                }
            }
        }
    }

    if ($bootImage.Contains('drivers')) {
        $driverGroup = [string] $bootImage['drivers']

        if ([string]::IsNullOrWhiteSpace($driverGroup)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'bootImage: drivers is empty. Name a driver group under Drivers\, or remove the key.'))
        }
    }

    # -- the optional components ----------------------------------------------

    if ($bootImage.Contains('optionalComponents')) {
        $component = $bootImage['optionalComponents']

        # An explicit empty list is LEGAL and means "the required set and nothing
        # else" - a different instruction from omitting the key, which takes the
        # DESIGN 5.1 defaults.
        if ($null -ne $component -and -not ($component -is [System.Collections.IList])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message 'bootImage: optionalComponents must be a list of WinPE optional component names.'))
        }

        $seen = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in @($component)) {
            $componentName = [string] $current

            if ($componentName -notmatch '^WinPE-[A-Za-z0-9-]+$') {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("bootImage: '{0}' is not a WinPE optional component name. A component is named as the ADK names its cab, for example WinPE-WMI or WinPE-NetFx - note the lowercase x." -f $componentName)))
            }

            $comparable = $componentName.ToLowerInvariant()
            if ($seen -contains $comparable) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("bootImage: optionalComponents declares '{0}' twice. Component names are compared without regard to case, and applying a cab twice is not a thing to ask for by accident." -f $componentName)))
            }
            [void] $seen.Add($comparable)
        }
    }

    # -- the extra content ----------------------------------------------------

    if (-not $bootImage.Contains('extraContent')) {
        return
    }

    $extraContent = $bootImage['extraContent']

    if ($null -ne $extraContent -and -not ($extraContent -is [System.Collections.IList])) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'bootImage: extraContent must be a list of source and destination pairs.'))
    }

    $position = 0

    foreach ($current in @($extraContent)) {
        $position++
        $locator = 'bootImage: extraContent {0}' -f $position

        if (-not ($current -is [System.Collections.IDictionary])) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: an entry must be a mapping with a source and a destination." -f $locator)))
        }

        foreach ($key in @($current.Keys)) {
            if ($allowedExtraContentKey -notcontains [string] $key) {
                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                            -Message ("{0}: '{1}' is not a key an entry may declare. The allowed keys are {2}." -f $locator, $key, ($allowedExtraContentKey -join ', '))))
            }
        }

        $source = ''
        if ($current.Contains('source')) { $source = [string] $current['source'] }

        if ([string]::IsNullOrWhiteSpace($source)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: source is missing. It names what to copy, relative to the workspace root unless it is rooted." -f $locator)))
        }

        $destination = ''
        if ($current.Contains('destination')) { $destination = [string] $current['destination'] }

        if ([string]::IsNullOrWhiteSpace($destination)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: destination is missing. It names where inside the boot image the content lands, for example \HDT\Modules\MyVendorTools." -f $locator)))
        }

        if (-not $destination.StartsWith('\')) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: destination '{1}' does not start with a separator, and a destination is a path inside the image - it is rooted at the image, not at the machine building it." -f $locator, $destination)))
        }

        if ($destination -like '*..*') {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                        -Message ("{0}: destination '{1}' contains '..', which escapes the image. Name a path under the image root." -f $locator, $destination)))
        }
    }
}
