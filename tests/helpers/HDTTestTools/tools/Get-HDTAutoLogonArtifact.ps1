function Get-HDTAutoLogonArtifact {
    <#
        .SYNOPSIS
            Lists the DESIGN 4.5.3 autologon artifacts still present on a
            (usually faked) machine.

        .DESCRIPTION
            The single assertion every teardown test in this phase leans on:

                Get-HDTAutoLogonArtifact -Registry $r -Lsa $l -FileSystem $f -State $s |
                    Should -BeNullOrEmpty

            Nine separate assertions would stop at the first failure and tell you
            about one survivor. This returns them all, so a failure prints
            exactly what teardown left behind - which is worth more than the
            first thing it happened to miss.

            The nine items, in DESIGN 4.5.3 order, and the name each is reported
            under:

                AutoAdminLogon              registry value
                DefaultUserName             registry value
                DefaultDomainName           registry value
                DefaultPassword             registry value (must never exist)
                AutoLogonCount              registry value
                LsaSecret:DefaultPassword   LSA private data
                RunOnce:HDTResume           registry value
                Unattend:<path>             one per staged unattend found

            PRESENCE is the artifact, not content. DESIGN 4.5.1 writes an empty
            string to DefaultDomainName on a workgroup machine, and
            AutoAdminLogon=0 is what Windows itself leaves when the count is
            spent (SPIKES.md S8) - both are values teardown must remove, so both
            are reported.

            The one exception is the LSA secret: S8 observed Windows blanking it
            to zero length rather than deleting it when the count ran out. A
            zero-length secret is not an armed machine, so it is not reported.

            It lives in HDTTestTools rather than HDTFakes because it inspects
            services rather than being one. It reads through the same injected
            services the engine uses, so it works against a fake or against a
            real machine unchanged - but note that those reads ARE recorded by
            the services, so call it after any assertion about the operation
            list, not before.

        .PARAMETER Registry
            An IRegistryService. The only required service: five of the nine
            items live there.

        .PARAMETER Lsa
            An ILsaService. Omit it in a registry-only test.

        .PARAMETER FileSystem
            An IFileSystem, for the staged unattend files.

        .PARAMETER State
            The run state document. Kept for the shape of the call; the state
            no longer carries a secret of its own.

        .PARAMETER UnattendPath
            Where a staged unattend might be. Defaults to the three locations
            DESIGN 4.5.3 names.

        .OUTPUTS
            System.String[] - one entry per artifact still present, empty when
            the machine is clean.

        .EXAMPLE
            Get-HDTAutoLogonArtifact -Registry $registry | Should -BeNullOrEmpty
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Registry,

        [Parameter()]
        [AllowNull()]
        [object] $Lsa,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $State,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $UnattendPath = @(
            'C:\HDT\unattend.xml',
            'C:\Windows\Panther\unattend.xml',
            'C:\Windows\System32\Sysprep\unattend.xml'
        )
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'

    $artifact = New-Object -TypeName System.Collections.ArrayList

    foreach ($name in @('AutoAdminLogon', 'DefaultUserName', 'DefaultDomainName', 'DefaultPassword', 'AutoLogonCount')) {
        if ($null -ne $Registry.GetValue($winlogonPath, $name)) {
            [void] $artifact.Add($name)
        }
    }

    if ($null -ne $Lsa) {
        $secret = $Lsa.GetSecret('DefaultPassword')
        if (-not [string]::IsNullOrEmpty($secret)) {
            [void] $artifact.Add('LsaSecret:DefaultPassword')
        }
    }

    if ($null -ne $Registry.GetValue($runOncePath, 'HDTResume')) {
        [void] $artifact.Add('RunOnce:HDTResume')
    }

    if ($null -ne $FileSystem) {
        foreach ($path in $UnattendPath) {
            if ($FileSystem.TestPath($path)) {
                [void] $artifact.Add("Unattend:$path")
            }
        }
    }

    # THE STATE DOCUMENT CARRIES NO SECRET OF ITS OWN. It used to hold a
    # generated per-deployment password, and that was one of the artifacts a
    # machine could be left armed with. The engine now arms with
    # HDTAdminPassword - the administrator's own value, which belongs to the
    # machine afterwards - so the only copy anything has to clear is the LSA
    # secret above.
    if ($null -ne $State -and $null -ne $State.PSObject.Properties['autoLogon'] -and
        [bool] $State.autoLogon.armed) {

        [void] $artifact.Add('State:autoLogon.armed')
    }

    # No unary comma here. The comma is mandatory in an array-returning
    # ScriptMethod (tests/helpers/README.md F3) but wrong in a function: it emits
    # ONE object that happens to be an array, so @(...) around the call yields a
    # single nested element and every count assertion reads 1. Watched failing
    # exactly that way.
    return [string[]] $artifact.ToArray()
}
