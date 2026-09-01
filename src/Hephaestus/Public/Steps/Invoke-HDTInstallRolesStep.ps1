function Invoke-HDTInstallRolesStep {
    <#
        .SYNOPSIS
            Installs Windows Server roles and features.

        .DESCRIPTION
            DESIGN 10.2, wrapping Install-WindowsFeature behind IFeatureService so
            the whole step runs under Pester with no server.

              - name: Install Roles
                type: InstallRoles
                features: [Web-Server, Web-Mgmt-Console, NET-Framework-45-Core]
                includeManagementTools: true
                source: "%HDTDeployRoot%\Sources\SxS"

            A TYPO'D NAME FAILS BEFORE ANYTHING IS INSTALLED. DESIGN 10.2: "a
            typo'd feature name should fail fast with the list of valid names, not
            halfway through a server build" - halfway through being the expensive
            place to find out, because the machine is then neither the old thing
            nor the new one. Every name is checked against the flat listing first,
            and only then is anything installed.

            THE MESSAGE OFFERS NAMES, NOT A CATALOGUE. A real server knows several
            hundred features, and printing all of them tells an administrator
            nothing. The refusal lists the ones that share the typo's leading
            segment - 'Web-Srever' offers every Web- feature - and falls back to
            the COUNT when nothing looks similar, because a number is honest and a
            wall of names is not.

            ALREADY-INSTALLED FEATURES ARE LEFT OUT. Install-WindowsFeature would
            tolerate being asked again, but this step has to be re-runnable across
            the reboot a role asks for, and reinstalling what is already there on
            every leg is how a server build takes an hour longer than it needs to.
            Removed is NOT installed: it is the .NET 3.5 case, where the payload is
            gone from the image, and it is exactly the one that needs source:.

            ONE CALL, NOT ONE PER FEATURE. Install-WindowsFeature takes the whole
            list and resolves the dependency graph itself; calling it per feature
            would be slower and would leave a partial state visible between calls.

            source: RESOLVES THROUGH THE CONTENT PROVIDER when it is relative, so
            the same sequence works from a share and from standalone media (DESIGN
            6). A rooted path is passed through as it stands.

            A RESTART REQUEST IS A PLAIN RebootRequested, not a re-entering one.
            Unlike InstallApplications this step installs its whole list in a
            single call, so there is no position in a list to come back to - the
            normal restart and resume path is all it needs.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry a
            Feature service.

        .OUTPUTS
            A New-HDTStepResult. Data carries requested, installed and skipped.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'InstallRoles' })[0]

            Invoke-HDTInstallRolesStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTInstallRolesStep -Step $step -Context $context
            $result.Data.Feature

            The features it installed. On a client OS this is a Failed step, not a
            crash: ServerManager is not there to ask.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $fail = {
        param([string] $Message, [System.Collections.IDictionary] $Data)

        $payload = $Data
        if ($null -eq $payload) { $payload = [ordered] @{} }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component 'InstallRoles' -Data $payload

        return (New-HDTStepResult -Status Failed -Message $Message -Data $payload)
    }

    # -- what was asked for ---------------------------------------------------

    $property = $Step.Property
    $requested = @()

    # BOTH SHAPES EXPAND, and only one of them used to. `source` next to this
    # already went through Get-HDTStepProperty -Expand while the feature names
    # beside it did not, so a site whose role set is chosen by a rule -
    # `features: '%HDTServerRole%'` - was told its feature was not one Windows
    # knows, quoting the token back at it.
    #
    # A LIST EXPANDS ELEMENT BY ELEMENT. The reader expands a string, so a YAML
    # sequence has to be walked here; expanding only the flat form would leave
    # the two ways of writing the same thing behaving differently.
    if ($null -ne $property -and $property.Contains('features')) {
        $raw = $property['features']

        if ($raw -is [System.Collections.IList] -and -not ($raw -is [string])) {
            $requested = @(@($raw) |
                    ForEach-Object { ([string] (Expand-HDTVariableToken -Value ([string] $_) -Scope $Context.Variable)).Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        } else {
            $written = [string] (Expand-HDTVariableToken -Value ([string] $raw) -Scope $Context.Variable)

            $requested = @(@($written -split '[,;\r\n]') | ForEach-Object { $_.Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }

    if (@($requested).Count -eq 0) {
        return (& $fail ("step '{0}' declares no features. An InstallRoles step names at least one." -f $Step.Name) `
            ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    try {
        $featureService = $Context.Service.GetRequired('Feature', 'InstallRoles')
    } catch {
        return (& $fail ([string] $_.Exception.Message) $null)
    }

    # -- what the OS knows ----------------------------------------------------

    try {
        $known = @($featureService.GetFeature())
    } catch {
        return (& $fail ("the installed features could not be listed: {0}" -f [string] $_.Exception.Message) $null)
    }

    $stateByName = @{}
    foreach ($row in $known) {
        $stateByName[[string] $row.Name] = [string] $row.InstallState
    }

    foreach ($name in $requested) {
        if ($stateByName.ContainsKey($name)) { continue }

        # The leading segment is the part a typo usually gets right - 'Web-Srever'
        # is still recognisably a Web- feature - so it is what the suggestion is
        # built from.
        $prefix = @($name -split '-')[0]
        $candidate = @()

        if (-not [string]::IsNullOrWhiteSpace($prefix)) {
            $candidate = [string[]] @(@($known | Where-Object {
                        ([string] $_.Name).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
                    } | ForEach-Object { [string] $_.Name }))

            [array]::Sort($candidate, [System.StringComparer]::Ordinal)
        }

        if (@($candidate).Count -gt 0) {
            return (& $fail ("'{0}' is not a feature this operating system knows. Did you mean one of: {1}?" -f
                    $name, (@($candidate) -join ', ')) ([ordered] @{
                        errorId = 'HDTConfigurationError'
                        feature = $name
                    }))
        }

        return (& $fail ("'{0}' is not a feature this operating system knows, and nothing in its {1} feature(s) looks similar. Check the name against Get-WindowsFeature on the target OS." -f
                $name, @($known).Count) ([ordered] @{
                    errorId = 'HDTConfigurationError'
                    feature = $name
                }))
    }

    # -- what still has to be installed ---------------------------------------

    $toInstall = New-Object -TypeName System.Collections.ArrayList
    $skipped = New-Object -TypeName System.Collections.ArrayList

    foreach ($name in $requested) {
        if ([string] $stateByName[$name] -eq 'Installed') {
            [void] $skipped.Add($name)
            continue
        }

        [void] $toInstall.Add($name)
    }

    $data = [ordered] @{
        requested = [string[]] @($requested)
        installed = [string[]] @()
        skipped   = [string[]] @($skipped)
    }

    if ($toInstall.Count -eq 0) {
        $message = 'every requested feature is already installed: {0}.' -f (@($skipped) -join ', ')

        Write-HDTLog -Context $Context.Log -Message $message -Component 'InstallRoles' -Data $data

        return (New-HDTStepResult -Status Completed -Message $message -Data $data)
    }

    # -- the options ----------------------------------------------------------

    # -As Bool PARSES rather than casts: [bool] 'false' is $true, so a quoted no
    # in the document used to switch the management tools ON.
    $includeManagementTools = Get-HDTStepProperty -Step $Step -Name 'includeManagementTools' -Default $false `
        -Context $Context -Expand -As Bool

    $source = ''
    if ($null -ne $property -and $property.Contains('source')) {
        try {
            $source = [string] (Get-HDTStepProperty -Step $Step -Name 'source' -Context $Context -Expand -As String)
        } catch {
            return (& $fail ([string] $_.Exception.Message) ([ordered] @{ errorId = 'HDTConfigurationError' }))
        }

        if ((-not [string]::IsNullOrWhiteSpace($source)) -and
            (-not [System.IO.Path]::IsPathRooted($source)) -and
            ($null -ne $Context.Service.Content)) {

            # DESIGN 6: a relative source is content, and content is the
            # provider's business. A rooted path is passed through as it stands -
            # an administrator who typed a drive letter meant that drive letter.
            try {
                $source = [string] $Context.Service.Content.ResolveContent($source)
            } catch {
                return (& $fail ("the side-by-side source '{0}' could not be resolved: {1}" -f
                        $source, [string] $_.Exception.Message) ([ordered] @{ errorId = 'HDTConfigurationError' }))
            }
        }
    }

    # -- the install ----------------------------------------------------------

    Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component 'InstallRoles' `
        -Message ('installing feature(s): {0}' -f (@($toInstall) -join ', ')) `
        -Data ([ordered] @{
            feature                = [string[]] @($toInstall)
            includeManagementTools = $includeManagementTools
            source                 = $source
        })

    try {
        $result = $featureService.InstallFeature([string[]] @($toInstall), $includeManagementTools, $source)
    } catch {
        return (& $fail ("installing {0} failed: {1}" -f (@($toInstall) -join ', '), [string] $_.Exception.Message) $data)
    }

    $data['installed'] = [string[]] @($toInstall)
    $data['exitCode'] = [int] $result.ExitCode

    if (-not [bool] $result.Success) {
        return (& $fail ("installing {0} did not succeed (exit code {1}). {2}" -f
                (@($toInstall) -join ', '), [int] $result.ExitCode, [string] $result.Message).Trim() $data)
    }

    if ([bool] $result.RestartNeeded) {
        $message = 'installed {0} and the server must restart.' -f (@($toInstall) -join ', ')

        Write-HDTLog -Context $Context.Log -Message $message -Event 'native.exec' `
            -Component 'InstallRoles' -Data $data

        return (New-HDTStepResult -Status RebootRequested -ExitCode ([int] $result.ExitCode) `
                -Message $message -Data $data)
    }

    $message = 'installed {0}.' -f (@($toInstall) -join ', ')
    if (@($skipped).Count -gt 0) {
        $message = '{0} {1} were already installed.' -f $message, (@($skipped) -join ', ')
    }

    Write-HDTLog -Context $Context.Log -Message $message -Event 'native.exec' -Component 'InstallRoles' -Data $data

    return (New-HDTStepResult -Status Completed -ExitCode ([int] $result.ExitCode) -Message $message -Data $data)
}
