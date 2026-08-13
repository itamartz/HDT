function Clear-HDTAutoLogon {
    <#
        .SYNOPSIS
            Runs the DESIGN 4.5.3 teardown checklist, item by item, best effort.

        .DESCRIPTION
            "At sequence end - success or failure - the engine clears:
            AutoAdminLogon, DefaultUserName, DefaultDomainName, DefaultPassword
            (registry AND LSA secret), AutoLogonCount, the RunOnce entry, the
            staged unattend, and the deployment password from state.json."

            Nine items, attempted INDEPENDENTLY:

              1  AutoAdminLogon              registry
              2  DefaultUserName             registry
              3  DefaultDomainName           registry
              4  DefaultPassword             registry
              5  DefaultPassword             LSA secret
              6  AutoLogonCount              registry
              7  RunOnce\HDTResume           registry
              8  the staged unattend files   filesystem
              9  deploymentPassword          state document, then saved

            ONE ITEM FAILING MUST NOT STOP THE OTHERS, and that is the whole
            design of this function. Teardown runs on machines in unknown states
            and from a finally block that may itself be unwinding a failure. A
            checklist that threw on item 3 would leave a machine armed with two
            of nine artifacts cleared - and a log saying teardown ran, which is
            worse than not running it. Each item is wrapped, a failure is
            appended to Failed with the item name and the message, and the
            function returns rather than throwing.

            It is idempotent: an already-clear machine returns empty Cleared and
            empty Failed. Cleared lists only what was actually there, which is
            why each item is read before it is removed.

            OUT OF SCOPE, DELIBERATELY. DESIGN 4.5.3 continues: "It then applies
            the final Administrator password policy: rotate, hand off to LAPS, or
            disable the account - whichever the sequence declares." That needs a
            step type M2 does not ship. It is a phase 07 item, and it is said out
            loud here so it stays a documented gap rather than a forgotten one.

        .PARAMETER Registry
            An IRegistryService.

        .PARAMETER Lsa
            An ILsaService.

        .PARAMETER FileSystem
            An IFileSystem. Without it, items 8 and 9's save are skipped.

        .PARAMETER State
            The run state document. Its deploymentPassword is set to $null and
            its autoLogon block is marked disarmed.

        .PARAMETER StatePath
            Where to save the state afterwards. Requires -FileSystem and -Clock.

        .PARAMETER Clock
            An IClock, needed only to stamp the saved state.

        .PARAMETER UnattendPath
            Where a staged unattend might be. Defaults to the three locations
            DESIGN 4.5.3 names.

        .PARAMETER LogContext
            A log context. One reboot.teardown record is written when supplied.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Cleared
            ([string[]]) and Failed ([object[]] of Item and Message).

        .EXAMPLE
            $result = Clear-HDTAutoLogon -Registry $registry -Lsa $lsa -FileSystem $fs -State $state
            $result.Failed | ForEach-Object { $_.Item }
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Registry,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Lsa,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $State,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $StatePath,

        [Parameter()]
        [AllowNull()]
        [object] $Clock,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $UnattendPath = @(
            'C:\HDT\unattend.xml',
            'C:\Windows\Panther\unattend.xml',
            'C:\Windows\System32\Sysprep\unattend.xml'
        ),

        [Parameter()]
        [AllowNull()]
        [object] $LogContext
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    $secretName = 'DefaultPassword'
    $runOnceName = 'HDTResume'

    $cleared = New-Object -TypeName System.Collections.ArrayList
    $failed = New-Object -TypeName System.Collections.ArrayList

    if (-not $PSCmdlet.ShouldProcess($winlogonPath, 'Clear autologon')) {
        return [pscustomobject] ([ordered] @{
                Cleared = [string[]] @()
                Failed  = [object[]] @()
            })
    }

    # Items 1-4 and 6: the Winlogon values. AutoLogonCount is last of them so
    # that a failure there - the case the tests exercise - is provably not what
    # stopped the LSA secret from going.
    foreach ($name in @('AutoAdminLogon', 'DefaultUserName', 'DefaultDomainName', $secretName, 'AutoLogonCount')) {
        try {
            if ($null -ne $Registry.GetValue($winlogonPath, $name)) {
                $Registry.RemoveValue($winlogonPath, $name)
                [void] $cleared.Add($name)
            }
        } catch {
            [void] $failed.Add([pscustomobject] @{ Item = $name; Message = $_.Exception.Message })
        }
    }

    # Item 5: the LSA secret. The artifact worth most - it is the password
    # itself - so it is never behind an earlier item's failure.
    try {
        $secret = $Lsa.GetSecret($secretName)
        if (-not [string]::IsNullOrEmpty($secret)) {
            $Lsa.RemoveSecret($secretName)
            [void] $cleared.Add("LsaSecret:$secretName")
        }
    } catch {
        [void] $failed.Add([pscustomobject] @{ Item = "LsaSecret:$secretName"; Message = $_.Exception.Message })
    }

    # Item 7: the RunOnce entry.
    try {
        if ($null -ne $Registry.GetValue($runOncePath, $runOnceName)) {
            $Registry.RemoveValue($runOncePath, $runOnceName)
            [void] $cleared.Add("RunOnce:$runOnceName")
        }
    } catch {
        [void] $failed.Add([pscustomobject] @{ Item = "RunOnce:$runOnceName"; Message = $_.Exception.Message })
    }

    # Item 8: the staged unattend files. Each one independently, because one
    # being locked says nothing about the others.
    if ($null -ne $FileSystem) {
        foreach ($path in $UnattendPath) {
            try {
                if ($FileSystem.TestPath($path)) {
                    $FileSystem.RemoveItem($path, $false)
                    [void] $cleared.Add("Unattend:$path")
                }
            } catch {
                [void] $failed.Add([pscustomobject] @{ Item = "Unattend:$path"; Message = $_.Exception.Message })
            }
        }
    }

    # Item 9: the deployment password in the state document, and the save.
    if ($null -ne $State) {
        try {
            if ($State.PSObject.Properties['deploymentPassword'] -and -not [string]::IsNullOrEmpty($State.deploymentPassword)) {
                $State.deploymentPassword = $null
                [void] $cleared.Add('DeploymentPassword')
            }
            if ($State.PSObject.Properties['autoLogon']) {
                $State.autoLogon.armed = $false
            }
        } catch {
            [void] $failed.Add([pscustomobject] @{ Item = 'DeploymentPassword'; Message = $_.Exception.Message })
        }

        if ($PSBoundParameters.ContainsKey('StatePath') -and $null -ne $FileSystem -and $null -ne $Clock) {
            try {
                Save-HDTRunState -State $State -Path $StatePath -FileSystem $FileSystem -Clock $Clock
            } catch {
                [void] $failed.Add([pscustomobject] @{ Item = 'StateDocument'; Message = $_.Exception.Message })
            }
        }
    }

    if ($null -ne $LogContext) {
        $severity = 'Info'
        if ($failed.Count -gt 0) {
            $severity = 'Warning'
        }

        Write-HDTLog -Context $LogContext -Event 'reboot.teardown' -Severity $severity `
            -Message ("Autologon teardown cleared {0} artifact(s), {1} failed" -f $cleared.Count, $failed.Count) `
            -Data ([ordered] @{
                cleared = [string[]] $cleared.ToArray()
                failed  = [string[]] @($failed | ForEach-Object { $_.Item })
            })
    }

    return [pscustomobject] ([ordered] @{
            Cleared = [string[]] $cleared.ToArray()
            Failed  = [object[]] $failed.ToArray()
        })
}
