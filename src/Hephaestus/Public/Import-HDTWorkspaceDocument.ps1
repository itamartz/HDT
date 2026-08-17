function Import-HDTWorkspaceDocument {
    <#
        .SYNOPSIS
            Reads workspace.yaml and projects it with every default already
            applied.

        .DESCRIPTION
            workspace.yaml sits at the root of the share and carries the share's
            identity, its version and its defaults. The boot image's
            optional-component list lives in it too, which is what turns that
            list from a constant into configuration.

            Four steps, and a failure at any of them is a terminating
            HDTConfigurationError naming the file:

              1. read through IFileSystem - never Get-Content, so the whole
                 authoring path is provable under Pester with no share and no
                 disk;
              2. parse with ConvertFrom-HDTYaml, which turns a parser exception
                 into an error naming the file and the LINE;
              3. validate with Assert-HDTWorkspaceDocument, which names the file
                 and the offending key;
              4. project, WITH THE DEFAULTS ALREADY APPLIED.

            THE DEFAULTS ARE APPLIED HERE, ONCE, so no caller repeats them and
            no two callers disagree about them:

              logLevel                    Info
              bootImage.architecture      amd64
              bootImage.language          en-us
              bootImage.scratchSpaceMB    512
              bootImage.name              HDTPE_x64 for amd64, HDTPE_arm64 for
                                          arm64 - the artifacts are named
                                          HDTPE_x64.wim and HDTPE_x64.iso, so
                                          the amd64 folder name maps to the x64
                                          artifact name rather than producing an
                                          HDTPE_amd64.wim nothing else refers to
              bootImage.optionalComponent SecureStartup, EnhancedStorage and
                                          WDS-Tools, WHEN THE KEY IS ABSENT

            UNSET AND SET-TO-NOTHING ARE DIFFERENT INSTRUCTIONS. An absent
            optionalComponents key means "the admin did not say", and takes
            those three defaults. An explicit
            empty list means "the required set and nothing else", and is
            honoured. Get-HDTBootImageComponent makes the same distinction, and
            this is where it starts.

            BootImage IS NEVER $null. An absent bootImage: block yields the
            defaults, because "the admin did not say" and "the admin said nothing
            unusual" are the same build.

            THE CREDENTIAL CARRIES A USERNAME AND NOTHING ELSE. The share
            password is not in this file and there is no property here for it to
            arrive in; Set-HDTShareCredential writes it to
            Control\share-credential.json (see Assert-HDTWorkspaceDocument).

            deployRoot IS PROJECTED VERBATIM, including the volume-relative form
            (\Share). Resolving that is Resolve-HDTDeployRoot's job, inside
            WinPE, where the volume can actually be probed for - a lab test
            recorded WinPE giving the content disk C: while the RAM disk was X:,
            which is exactly why a boot image cannot carry a drive letter.

        .PARAMETER Path
            The workspace.yaml to read.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production,
            New-HDTFakeFileSystem in a test.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              SchemaVersion, Id, Name, DeployRoot, LogLevel, Path,
              Credential  -> { Username }, or $null when there is no block
              BootImage   -> { Name, Architecture, Language, ScratchSpaceMB,
                               OptionalComponent [string[]],
                               ExtraContent [rows of { Source, Destination }],
                               Drivers, Unattend, Background,
                               RootCertificate [string[]], ClientCertificate,
                               EntryCommand, StartCommand [string[]] }

        .EXAMPLE
            Import-HDTWorkspaceDocument -Path 'X:\Deploy\workspace.yaml' -FileSystem (New-HDTFileSystem)

        .EXAMPLE
            $workspace = Import-HDTWorkspaceDocument -Path $path -FileSystem $fs
            Get-HDTBootImageComponent -OptionalComponent $workspace.BootImage.OptionalComponent `
                -ComponentRoot (Get-HDTAdkPath -Asset WinPeOptionalComponent) -FileSystem $fs

            The document and the component plan, which is how Update-HDTBootImage
            will use both.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # DESIGN 5.1's default optional components, applied only when the key is
    # absent. The required six are not here: they are Get-HDTBootImageComponent's
    # constant, because they are not configuration.
    $defaultOptionalComponent = @('WinPE-SecureStartup', 'WinPE-EnhancedStorage', 'WinPE-WDS-Tools')

    # The ADK's architecture folder name -> the artifact name DESIGN 2.1 uses.
    $artifactArchitecture = @{ amd64 = 'x64'; arm64 = 'arm64' }

    if (-not $FileSystem.TestPath($Path)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'there is no workspace document here. A workspace declares its identity and its deployRoot in workspace.yaml at the root of the share.' `
                    -Category ObjectNotFound))
    }

    $text = $FileSystem.ReadAllText($Path)

    $document = ConvertFrom-HDTYaml -Yaml $text -Path $Path
    Assert-HDTWorkspaceDocument -Document $document -Path $Path

    # -- the credential -------------------------------------------------------

    $credential = $null
    if ($document.Contains('credential')) {
        $credential = [pscustomobject] @{
            Username = [string] $document['credential']['username']
        }
    }

    # -- the boot image -------------------------------------------------------

    $bootImage = $null
    if ($document.Contains('bootImage')) { $bootImage = $document['bootImage'] }

    $architecture = 'amd64'
    if ($null -ne $bootImage -and $bootImage.Contains('architecture')) {
        $architecture = [string] $bootImage['architecture']
    }

    $imageName = 'HDTPE_{0}' -f $artifactArchitecture[$architecture]
    if ($null -ne $bootImage -and $bootImage.Contains('name')) {
        $imageName = [string] $bootImage['name']
    }

    $language = 'en-us'
    if ($null -ne $bootImage -and $bootImage.Contains('language')) {
        $language = [string] $bootImage['language']
    }

    $scratchSpaceMB = 512
    if ($null -ne $bootImage -and $bootImage.Contains('scratchSpaceMB')) {
        $scratchSpaceMB = [int] $bootImage['scratchSpaceMB']
    }

    $drivers = ''
    if ($null -ne $bootImage -and $bootImage.Contains('drivers')) {
        $drivers = [string] $bootImage['drivers']
    }

    # The WinPE answer file, relative to the share. Empty means wpeinit runs
    # with no -unattend: argument, which is the ordinary case.
    $unattend = ''
    if ($null -ne $bootImage -and $bootImage.Contains('unattend')) {
        $unattend = [string] $bootImage['unattend']
    }

    # The WinPE background, relative to the share or rooted. Empty means the
    # one Microsoft ships.
    $background = ''
    if ($null -ne $bootImage -and $bootImage.Contains('background')) {
        $background = [string] $bootImage['background']
    }

    # The certificate authorities WinPE is to trust. Empty is the ordinary case:
    # an image that only ever talks to an SMB share needs none, and one that
    # reaches an internal HTTPS endpoint needs the CA that signed it - WinPE
    # boots with Microsoft's roots and nothing else.
    $rootCertificate = New-Object -TypeName System.Collections.ArrayList
    if ($null -ne $bootImage -and $bootImage.Contains('rootCertificates')) {
        foreach ($current in @($bootImage['rootCertificates'])) {
            [void] $rootCertificate.Add([string] $current)
        }
    }

    # The machine's own certificate, for a network that authenticates before it
    # gives out an address. Empty means the image has no identity of its own,
    # which is every network that is not running 802.1X.
    $clientCertificate = ''
    if ($null -ne $bootImage -and $bootImage.Contains('clientCertificate')) {
        $clientCertificate = [string] $bootImage['clientCertificate']
    }

    # Empty means "the builder decides". The default command lives in
    # Get-HDTStartnetScript's parameter and is not repeated here: two defaults
    # for one string is one of them being wrong after the next edit.
    $entryCommand = ''
    if ($null -ne $bootImage -and $bootImage.Contains('entryCommand')) {
        $entryCommand = [string] $bootImage['entryCommand']
    }

    # The tools that have to RUN rather than merely be copied in. Empty is the
    # ordinary case: startnet.cmd is wpeinit and then the payload.
    $startCommand = New-Object -TypeName System.Collections.ArrayList
    if ($null -ne $bootImage -and $bootImage.Contains('startCommand')) {
        foreach ($current in @($bootImage['startCommand'])) {
            [void] $startCommand.Add([string] $current)
        }
    }

    # Unset takes the defaults; set-to-nothing is honoured as nothing.
    $optionalComponent = $defaultOptionalComponent
    if ($null -ne $bootImage -and $bootImage.Contains('optionalComponents')) {
        $optionalComponent = @($bootImage['optionalComponents'] | ForEach-Object { [string] $_ })
    }

    $extraContent = New-Object -TypeName System.Collections.ArrayList
    if ($null -ne $bootImage -and $bootImage.Contains('extraContent')) {
        foreach ($current in @($bootImage['extraContent'])) {
            [void] $extraContent.Add([pscustomobject] @{
                    Source      = [string] $current['source']
                    Destination = [string] $current['destination']
                })
        }
    }

    # MDT's Skip* properties, the four that must be decided INSIDE the boot
    # image because the Welcome screen runs before the share is reachable
    # (.planning/WPF-FIRST.md, W2).
    #
    # $null MEANS THE WORKSPACE SAID NOTHING, and that is a different fact from
    # false: Update-HDTBootImage omits an unstated rule from bootstrap.json
    # entirely, and Get-HDTWizardSkip's defaults are what turn silence into the
    # unattended path. Defaulting to $false anywhere in this chain would move
    # that decision to build time and quietly make every image show a wizard.
    $skip = [ordered] @{
        SkipWelcome    = $null
        SkipStaticIp   = $null
        SkipDeployRoot = $null
        SkipCredential = $null
    }

    if ($null -ne $bootImage -and $bootImage.Contains('skip')) {
        $skipDocument = $bootImage['skip']

        foreach ($pair in @(
                @{ Key = 'welcome'; Property = 'SkipWelcome' },
                @{ Key = 'staticIp'; Property = 'SkipStaticIp' },
                @{ Key = 'deployRoot'; Property = 'SkipDeployRoot' },
                @{ Key = 'credential'; Property = 'SkipCredential' })) {

            $key = [string] $pair.Key
            if ($null -ne $skipDocument -and $skipDocument.Contains($key)) {
                $skip[[string] $pair.Property] = [bool] $skipDocument[$key]
            }
        }
    }

    $logLevel = 'Info'
    if ($document.Contains('logLevel')) { $logLevel = [string] $document['logLevel'] }

    return [pscustomobject] @{
        SchemaVersion = [int] $document['schemaVersion']
        Id            = [string] $document['id']
        Name          = [string] $document['name']
        DeployRoot    = [string] $document['deployRoot']
        LogLevel      = $logLevel
        Path          = $Path
        Credential    = $credential
        BootImage     = [pscustomobject] @{
            Name              = $imageName
            Architecture      = $architecture
            Language          = $language
            ScratchSpaceMB    = $scratchSpaceMB
            OptionalComponent = [string[]] @($optionalComponent)
            ExtraContent      = [pscustomobject[]] @($extraContent)
            Drivers           = $drivers
            Unattend          = $unattend
            Background        = $background
            RootCertificate   = [string[]] @($rootCertificate)
            ClientCertificate = $clientCertificate
            EntryCommand      = $entryCommand
            StartCommand      = [string[]] @($startCommand)
            SkipWelcome       = $skip['SkipWelcome']
            SkipStaticIp      = $skip['SkipStaticIp']
            SkipDeployRoot    = $skip['SkipDeployRoot']
            SkipCredential    = $skip['SkipCredential']
        }
    }
}
