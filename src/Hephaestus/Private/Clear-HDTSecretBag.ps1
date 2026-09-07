function Clear-HDTSecretBag {
    <#
        .SYNOPSIS
            Removes the reboot-surviving secret bag from LSA private data.

        .DESCRIPTION
            The teardown half of DESIGN 4.5.2's secret bag, and it belongs to
            DESIGN 4.5.4's checklist rather than to a step for the reason the
            rest of that checklist does: "MDT's cleanup is a task sequence step,
            so a failure before it leaves autologon armed." A domain credential
            left in the LSA of a machine whose deployment failed is exactly the
            artifact 4.5.2 is careful about - it outlives the run, it is readable
            by anything with administrator rights on that machine, and nothing
            afterwards has a reason to look for it.

            So it is cleared from the two places that always run:
            Clear-HDTAutoLogon, which the engine calls from its finally on
            success and on failure alike, and the boot-time reconcile in
            Start-HDTResume.ps1, which calls Clear-HDTAutoLogon on any boot where
            the state document says the run is finished, failed or missing.

            IT IS IDEMPOTENT AND IT DOES NOT THROW. Teardown runs on machines in
            unknown states, from a block that may itself be unwinding a failure,
            and the return value is what says whether there was anything there -
            not an exception. ILsaService.RemoveSecret is already idempotent; the
            read in front of it is what makes 'there was one' reportable, which
            is the difference between a log that says teardown ran and a log that
            says what teardown found.

        .PARAMETER Lsa
            An ILsaService.

        .PARAMETER LogContext
            A log context. Without one this writes no log at all.

        .OUTPUTS
            System.Boolean - $true when a bag was there and was removed, $false
            when the machine had none or the store refused.

        .EXAMPLE
            $lsa = New-HDTLsaService
            Clear-HDTSecretBag -Lsa $lsa

            True on a machine that has just finished a deployment carrying a
            domain credential; False on one that never had a bag, which is every
            machine nobody has deployed to.

        .EXAMPLE
            Clear-HDTSecretBag -Lsa $lsa

            False, run straight after the call above. Teardown runs from a
            finally AND again at the next boot, so this is asked twice on most
            machines and must not throw the second time.

        .LINK
            Save-HDTSecretBag

        .LINK
            Clear-HDTAutoLogon
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Lsa,

        [Parameter()]
        [AllowNull()]
        [object] $LogContext
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $secretName = Get-HDTSecretBagName

    if (-not $PSCmdlet.ShouldProcess($secretName, 'Remove the run secret bag')) {
        return $false
    }

    try {
        $existing = [string] $Lsa.GetSecret($secretName)

        if ([string]::IsNullOrEmpty($existing)) {
            if ($null -ne $LogContext) {
                Write-HDTLog -Context $LogContext -Severity Debug -Component 'SecretBag' `
                    -Message ("there was no '{0}' LSA secret to remove." -f $secretName) `
                    -Data ([ordered] @{ secretName = $secretName; removed = $false })
            }

            return $false
        }

        $Lsa.RemoveSecret($secretName)
    } catch {
        if ($null -ne $LogContext) {
            Write-HDTLog -Context $LogContext -Severity Warning -Component 'SecretBag' `
                -Message ("the LSA secret '{0}' could not be removed, so this machine may still be carrying the run's secrets: {1}: {2}" -f
                    $secretName, $_.Exception.GetType().FullName, $_.Exception.Message) `
                -Data ([ordered] @{ secretName = $secretName; removed = $false; exceptionType = [string] $_.Exception.GetType().FullName })
        }

        return $false
    }

    if ($null -ne $LogContext) {
        Write-HDTLog -Context $LogContext -Component 'SecretBag' `
            -Message ("the LSA secret '{0}' was removed, so this machine no longer carries the run's secrets. Its lifetime was this deployment and nothing longer." -f $secretName) `
            -Data ([ordered] @{ secretName = $secretName; removed = $true })
    }

    return $true
}
