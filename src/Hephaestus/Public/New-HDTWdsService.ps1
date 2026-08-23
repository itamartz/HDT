function New-HDTWdsService {
    <#
        .SYNOPSIS
            Creates the real IWdsService adapter over the WDS module.

        .DESCRIPTION
            A THIN ADAPTER, AND DELIBERATELY DUMB. It constructs arguments for
            three WDS cmdlets and projects
            what they return; every decision that could be got wrong - whether an
            image of that name already exists, whether it has to be removed
            first, what to call it - lives in Import-HDTBootImageToWds, where it
            is unit tested against New-HDTFakeWdsService.

              GetBootImage(architecture)                     Get-WdsBootImage
              ImportBootImage(path, imageName, architecture) Import-WdsBootImage
              RemoveBootImage(imageName, architecture)       Remove-WdsBootImage

            THIS FILE HAS NEVER RUN ON THIS HOST, AND AS OF 2026-08-14 IT HAS
            NEVER RUN ANYWHERE IN THIS REPOSITORY. That is not an oversight, it
            is a refusal:

              * this machine is Windows 11 Pro. The WDS PowerShell module and
                wdsutil.exe ship with a Windows SERVER role, so there is nothing
                here to adapt;
              * standing one up is forbidden by PROJECT.md's lab safety rules.
                CM01 runs a PXE responder on 'Default Switch', and PROJECT.md
                rule 3 confines PXE/WDS testing to the isolated 'HDT Lab' switch
                - a second responder beside CM01's would either break the user's
                SCCM lab or answer our test VMs and silently invalidate the test.

            SO IT GETS NO CONTRACT ROW against the real implementation, and
            tests/contract carries no IWdsService file at all. The ONE thing this
            machine can prove about it is asserted in
            tests/unit/Import-HDTBootImageToWds.Tests.ps1, against this function
            rather than a simulation of it: on a host with no WDS module, the
            constructor refuses with a named HDTDependencyError. Everything else
            about the WDS path is asserted against the fake, and that is said
            here in a plain sentence rather than implied away.

            THE CONSTRUCTOR IS THE ONLY BRANCH, for the same reason
            Get-HDTAdkPath's existence check is: an adapter that is not unit
            tested must stay branch-free, and a dependency gate that names what
            is missing is the exception every adapter here is allowed - because
            the alternative is "The term 'Get-WdsBootImage' is not recognized",
            which tells an administrator nothing about which role to install.

            Import-WdsBootImage is invoked with -SkipVerify:$false. Verification
            is the slow half of an import and it is the half that catches a
            truncated WIM before a fleet tries to boot it.

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with the three
            IWdsService ScriptMethods. Note that Get-Member -MemberType Method
            does NOT list a ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $wds = New-HDTWdsService
            Import-HDTBootImageToWds -Path 'C:\HDTLab\Share\Boot\HDTPE_x64.wim' -WdsService $wds

            Publishes the boot image for PXE. On a Windows Server with the WDS role;
            on a client OS the first line throws HDTDependencyError naming both
            the module and the role rather than failing somewhere further in.

        .EXAMPLE
            @($wds.GetOperationName())

            What was asked of it. WDS is a Microsoft product HDT uses, not part of MDT -
            nothing here depends on a deprecated toolkit being installed.

    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE DEPENDENCY GATE. See the help: the alternative message is "The term
    # 'Get-WdsBootImage' is not recognized", which names neither the module nor
    # the role that carries it.
    if (@(Get-Module -ListAvailable -Name 'WDS' -ErrorAction SilentlyContinue).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -ErrorId 'HDTDependencyError' -Category NotInstalled `
                    -TargetObject 'WDS' `
                    -Message ("the WDS PowerShell module is not available on this machine, so HDT cannot import a boot image into Windows Deployment Services. WDS is a Windows Server role: install it with Install-WindowsFeature WDS -IncludeManagementTools on a Windows Server, and run HDT's import from there. HDT does not ship a PXE server; for a site with an existing TFTP or HTTP stack instead, use New-HDTPxePayload.")))
    }

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'WdsService'
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return , ([string[]] @($this.Operations | ForEach-Object { $_.Operation }))
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetBootImage -Value {
        param([string] $Architecture)

        $this.Record('GetBootImage', @($Architecture))

        $row = @(Get-WdsBootImage -Architecture $Architecture -ErrorAction SilentlyContinue |
                ForEach-Object {
                    [pscustomobject] @{
                        ImageName    = [string] $_.ImageName
                        Architecture = [string] $_.Architecture
                        FileName     = [string] $_.FileName
                        Version      = [string] $_.Version
                    }
                })

        # The unary comma is mandatory: a ScriptMethod collapses a single-element
        # array to a scalar without it (tests/helpers/README.md F3), and one boot
        # image is the normal case.
        return , ([object[]] $row)
    }

    $service | Add-Member -MemberType ScriptMethod -Name ImportBootImage -Value {
        param([string] $Path, [string] $ImageName, [string] $Architecture)

        $this.Record('ImportBootImage', @($Path, $ImageName, $Architecture))

        Import-WdsBootImage -Path $Path -NewImageName $ImageName -SkipVerify:$false | Out-Null
    }

    $service | Add-Member -MemberType ScriptMethod -Name RemoveBootImage -Value {
        param([string] $ImageName, [string] $Architecture)

        $this.Record('RemoveBootImage', @($ImageName, $Architecture))

        Remove-WdsBootImage -ImageName $ImageName -Architecture $Architecture | Out-Null
    }

    return $service
}
