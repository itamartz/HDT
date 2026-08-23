function Invoke-HDTInstallApplicationsStep {
    <#
        .SYNOPSIS
            Installs the selected applications, in dependency order, surviving the
            reboots they ask for.

        .DESCRIPTION
            MDT's Install Applications, rebuilt on the catalog, the ordering and
            the detection of 07-01.

              - name: Install Applications
                type: InstallApplications
                selection: "%HDTApplications%"

            or a fixed list:

                selection: [7Zip-24.09, Contoso-Suite]

            and with neither, the HDTApplications variable is read directly -
            which is what a wizard answer or a rule sets. DESIGN 8: both forms
            "resolve to the same ordered install plan", because both are handed
            to the same Resolve-HDTApplicationOrder.

            THE PLAN IS LOGGED BEFORE ANYTHING RUNS. A technician reading the log
            of a build that went wrong needs to know what the step INTENDED, not
            only what it got through - and the plan is what shows the dependency
            closure pulled in an application the selection never named.

            SELECTING AN APPLICATION SELECTS WHAT IT NEEDS. The plan is the
            selection plus its transitive dependencies, ordered dependencies
            first, deterministically (Resolve-HDTApplicationOrder).

            DETECTION SKIPS, IT DOES NOT FAIL. An application whose rule reports
            it already installed is skipped and recorded as skipped. An
            application that declares no rule installs every time - DESIGN 8's
            documented behaviour, and the author's stated choice rather than an
            engine limitation.

            A 3010 REBOOTS AND COMES BACK. The step returns
            RebootRequested -Reenter and checkpoints what it has installed into
            _HDTApplicationInstalled, which the state document persists across
            legs. The next leg runs the step again and resumes at the NEXT
            application. THE TWO WAYS THIS FEATURE IS USUALLY GOT WRONG:

              no Reenter    the loop advances past the step and every application
                            after the one that rebooted is silently skipped,
                            while the run reports success
              no progress   the step restarts the list on every leg, reinstalling
                            everything ahead of the reboot each time

            The application that asked for the restart is checkpointed as
            INSTALLED, because 3010 means "installed, reboot required" - re-running
            it on the next leg would install it twice.

            AN INSTALL COMMAND IS A SHELL LINE, run through %ComSpec% /c exactly
            as the CommandLine step's command: is. Quoting, chaining and
            redirection are routine in what a vendor documents as their silent
            install. The comspec comes from the injected IEnvironmentProvider,
            never from $env:, and the working directory is the application's
            source folder so a relative installer path resolves.

            THAT FOLDER HAS TO BE ONE cmd.exe CAN STAND IN, which is why the Smb
            provider maps the share to a drive letter (DESIGN 6). Handed a UNC
            working directory, cmd.exe prints "UNC paths are not supported",
            moves itself to %SystemRoot%, and the vendor's own
            'msiexec /i setup.msi' runs in C:\Windows against a file that is not
            there. SourcePath comes from the provider for exactly that reason -
            the mapped drive in a network deployment, the media itself on
            standalone media.

            A FAILURE STOPS THE LIST. An application that returns a code in
            neither its successCodes nor its rebootCodes fails the step naming the
            application and the code, and the applications after it do not run -
            installing software on top of a failed dependency is how a machine
            ends up subtly broken. continueOnError on the step is how a sequence
            says otherwise, and that belongs to the loop rather than here.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry
            FileSystem and Process services; Registry and ScriptInvoker are needed
            only by the detection rules that use them.

        .OUTPUTS
            A New-HDTStepResult. Data carries planned, installed, skipped and, on
            a failure, the application and its exit code.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'InstallApplications' })[0]

            Invoke-HDTInstallApplicationsStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTInstallApplicationsStep -Step $step -Context $context
            $result.Data.Installed

            The applications it installed, in the dependency order it worked out. A
            step that asked for a reboot comes back Completed with the engine told
            to restart.
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

    $progressVariable = '_HDTApplicationInstalled'

    $fail = {
        param([string] $Message, [System.Collections.IDictionary] $Data)

        $payload = $Data
        if ($null -eq $payload) { $payload = [ordered] @{} }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component 'InstallApplications' -Data $payload

        return (New-HDTStepResult -Status Failed -Message $Message -Data $payload)
    }

    # -- the selection --------------------------------------------------------

    # A list in YAML stays a list; a token is expanded and then split, because
    # HDTApplications holds what a wizard or a rule wrote into one string.
    $split = {
        param([string] $Text)

        return @(@($Text -split '[,;\r\n]') |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $property = $Step.Property
    $selection = @()

    if ($null -ne $property -and $property.Contains('selection')) {
        $raw = $property['selection']

        if ($raw -is [System.Collections.IList] -and -not ($raw -is [string])) {
            $selection = @(@($raw) | ForEach-Object { ([string] $_).Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        } else {
            try {
                $expanded = Get-HDTStepProperty -Step $Step -Name 'selection' -Context $Context -Expand -As String
            } catch {
                return (& $fail ([string] $_.Exception.Message) ([ordered] @{ errorId = 'HDTConfigurationError' }))
            }

            $selection = & $split ([string] $expanded)
        }
    } elseif ($Context.Variable.Contains('HDTApplications')) {
        $selection = & $split ([string] $Context.Variable['HDTApplications'])
    }

    # -- what the site installs whatever the technician picked ----------------
    #
    # MDT's MandatoryApplications, and it is a SECOND list rather than a default
    # for the first: a default is what you get when nobody chose, and this is
    # what you get when somebody did. The management agent, the antivirus, the
    # certificate deployer - the things a site does not let a person opt out of
    # by clicking past a page.
    #
    # IT SURVIVES A PINNED SELECTION. A sequence naming an exact list is the
    # case this exists for; if a pinned selection could drop it, the property
    # would mean "mandatory unless a sequence author forgot", which is not a
    # guarantee anybody can build a compliance story on.
    #
    # IT DOES NOT JUMP THE QUEUE, and that is where HDT parts company with MDT.
    # MDT installs its mandatory list first, for no better reason than that it
    # processes two lists in two loops. Resolve-HDTApplicationOrder emits ready
    # applications smallest id first precisely so a plan does not depend on the
    # order a selection was written in, and spending that determinism on the
    # convention would be the wrong trade. A site that needs its agent in place
    # before everything else declares a dependency edge - the mechanism that
    # already exists, and the only one that survives somebody adding a third
    # application next year.
    if ($Context.Variable.Contains('HDTMandatoryApplications')) {
        $mandatory = & $split ([string] $Context.Variable['HDTMandatoryApplications'])

        if (@($mandatory).Count -gt 0) {
            $merged = New-Object -TypeName System.Collections.ArrayList
            $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

            foreach ($id in (@($mandatory) + @($selection))) {
                if ($seen.Add([string] $id)) {
                    [void] $merged.Add([string] $id)
                }
            }

            $selection = [string[]] @($merged)
        }
    }

    if (@($selection).Count -eq 0) {
        # A sequence that offers applications and a technician who picked none is
        # an ordinary deployment.
        $message = 'no applications were selected.'

        Write-HDTLog -Context $Context.Log -Message $message -Component 'InstallApplications' `
            -Data ([ordered] @{ planned = 0 })

        return (New-HDTStepResult -Status Completed -Message $message -Data ([ordered] @{
                    planned   = [string[]] @()
                    installed = [string[]] @()
                    skipped   = [string[]] @()
                }))
    }

    # -- the services ---------------------------------------------------------

    try {
        $fileSystem = $Context.Service.GetRequired('FileSystem', 'InstallApplications')
        $process = $Context.Service.GetRequired('Process', 'InstallApplications')
    } catch {
        return (& $fail ([string] $_.Exception.Message) $null)
    }

    # -- the plan -------------------------------------------------------------

    try {
        $catalog = @(Get-HDTApplication -WorkspaceRoot ([string] $Context.WorkspaceRoot) `
                -FileSystem $fileSystem -Content $Context.Service.Content)

        $plan = @(Resolve-HDTApplicationOrder -Application $catalog -Id $selection)
    } catch {
        return (& $fail ([string] $_.Exception.Message) ([ordered] @{ errorId = 'HDTConfigurationError' }))
    }

    $plannedId = [string[]] @($plan | ForEach-Object { [string] $_.Id })

    # No -Event: DESIGN 4.4's event vocabulary is closed, and the plan is a
    # message rather than a lifecycle event. step.start already fired for this
    # step; a second one would make the stream lie about how many steps ran.
    Write-HDTLog -Context $Context.Log -Component 'InstallApplications' `
        -Message ('install plan, in order: {0}' -f ($plannedId -join ', ')) `
        -Data ([ordered] @{ planned = $plannedId; selected = [string[]] @($selection) })

    # -- the progress this run already made -----------------------------------

    $installed = New-Object -TypeName System.Collections.ArrayList

    if ($Context.Variable.Contains($progressVariable)) {
        foreach ($current in @($Context.Variable[$progressVariable])) {
            if (-not [string]::IsNullOrWhiteSpace([string] $current)) {
                [void] $installed.Add([string] $current)
            }
        }
    }

    $skipped = New-Object -TypeName System.Collections.ArrayList

    $comSpec = 'cmd.exe'
    if ($null -ne $Context.Service.Environment) {
        $fromEnvironment = [string] $Context.Service.Environment.GetVariable('ComSpec')
        if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) { $comSpec = $fromEnvironment }
    }

    $timeoutMillisecond = 0
    if ([int] $Step.TimeoutMinutes -gt 0) {
        $timeoutMillisecond = [int] $Step.TimeoutMinutes * 60000
    }

    $checkpoint = {
        # The live variable dictionary is copied into the state document on every
        # save, so writing the progress here is what makes it survive the reboot.
        $Context.Variable[$progressVariable] = [string[]] @($installed)
    }

    # -- the list -------------------------------------------------------------

    foreach ($application in $plan) {
        $id = [string] $application.Id

        # Already done on an earlier leg of THIS run. Resuming at the next
        # application rather than restarting the list is the whole point of
        # checkpointing.
        if ($installed -contains $id) {
            Write-HDTLog -Context $Context.Log -Severity Debug -Component 'InstallApplications' `
                -Message ("'{0}' was installed on an earlier leg of this run." -f $id) `
                -Data ([ordered] @{ application = $id })

            continue
        }

        try {
            $alreadyInstalled = Test-HDTApplicationDetection -Detect $application.Detect `
                -FileSystem $fileSystem -Registry $Context.Service.Registry `
                -ScriptInvoker $Context.Service.ScriptInvoker -Variable $Context.Variable
        } catch {
            return (& $fail ("'{0}': {1}" -f $id, [string] $_.Exception.Message) ([ordered] @{
                        application = $id
                        planned     = $plannedId
                        installed   = [string[]] @($installed)
                        skipped     = [string[]] @($skipped)
                    }))
        }

        if ($alreadyInstalled) {
            [void] $skipped.Add($id)

            Write-HDTLog -Context $Context.Log -Component 'InstallApplications' `
                -Message ("'{0}' is already installed; skipping it." -f $application.Name) `
                -Data ([ordered] @{ application = $id })

            continue
        }

        $argument = '/c {0}' -f [string] $application.Install

        # DESIGN 4.4.5: the full command line is a Debug-only detail, because an
        # install command routinely carries a licence key or a service account.
        Write-HDTLog -Context $Context.Log -Severity Debug -Event 'native.exec' -Component 'InstallApplications' `
            -Message ('installing {0}: {1} {2}' -f $id, $comSpec, $argument) `
            -Data ([ordered] @{ application = $id; workingDirectory = [string] $application.SourcePath })

        $result = $process.Start($comSpec, $argument, [string] $application.SourcePath, $timeoutMillisecond)

        $exitCode = [int] $result.ExitCode

        $data = [ordered] @{
            application = $id
            exitCode    = $exitCode
            planned     = $plannedId
            installed   = [string[]] @($installed)
            skipped     = [string[]] @($skipped)
        }

        if ([bool] $result.TimedOut) {
            return (& $fail ("'{0}' timed out after {1} minute(s) and was stopped." -f $id, $Step.TimeoutMinutes) $data)
        }

        # rebootCodes is checked FIRST, the same precedence the CommandLine step
        # states: an installer reporting 3010 that also lists it as successful is
        # a real configuration, and treating it as plain success would drop the
        # restart it asked for.
        if (@($application.RebootCodes) -contains $exitCode) {
            # 3010 is "installed, reboot required" - so it IS installed, and the
            # next leg must not run it again.
            [void] $installed.Add($id)
            & $checkpoint

            $message = "'{0}' returned {1} and asked for a restart. {2} of {3} application(s) done." -f
            $id, $exitCode, @($installed).Count, @($plannedId).Count

            Write-HDTLog -Context $Context.Log -Message $message -Event 'native.exec' `
                -Component 'InstallApplications' -Data ([ordered] @{
                    application = $id
                    exitCode    = $exitCode
                    installed   = [string[]] @($installed)
                    skipped     = [string[]] @($skipped)
                })

            return (New-HDTStepResult -Status RebootRequested -ExitCode $exitCode -Reenter `
                    -Message $message -Data ([ordered] @{
                        application = $id
                        exitCode    = $exitCode
                        planned     = $plannedId
                        installed   = [string[]] @($installed)
                        skipped     = [string[]] @($skipped)
                    }))
        }

        if (-not (@($application.SuccessCodes) -contains $exitCode)) {
            return (& $fail ("'{0}' returned {1}, which is not in its successCodes ({2}) or rebootCodes ({3}). The applications after it were not installed." -f
                    $id, $exitCode, (@($application.SuccessCodes) -join ', '), (@($application.RebootCodes) -join ', ')) $data)
        }

        [void] $installed.Add($id)
        & $checkpoint

        Write-HDTLog -Context $Context.Log -Message ("installed '{0}' ({1})." -f $application.Name, $exitCode) `
            -Event 'native.exec' -Component 'InstallApplications' `
            -Data ([ordered] @{ application = $id; exitCode = $exitCode })
    }

    $message = 'installed {0} application(s), skipped {1} already present.' -f @($installed).Count, @($skipped).Count

    Write-HDTLog -Context $Context.Log -Message $message -Component 'InstallApplications' `
        -Data ([ordered] @{ installed = [string[]] @($installed); skipped = [string[]] @($skipped) })

    return (New-HDTStepResult -Status Completed -Message $message -Data ([ordered] @{
                planned   = $plannedId
                installed = [string[]] @($installed)
                skipped   = [string[]] @($skipped)
            }))
}
