function Get-HDTUpdateApplyOutcome {
    <#
        .SYNOPSIS
            Decides what actually happened when a Windows update was applied.

        .DESCRIPTION
            THE EXIT CODE IS EVIDENCE, NOT THE VERDICT, and this function exists
            because trusting it would be wrong in both directions.

            Measured on 2026-09-01, applying the same way to two mounted images:

              Windows 11 24H2, KB5094126  dism exited 0xC0000409 - a stack buffer
                                          overrun - AFTER printing "The operation
                                          completed successfully". The image was
                                          correctly serviced: 85 packages became
                                          159, ntoskrnl.exe read 10.0.26100.8655.
              Server 2025, KB5094125      the same command exited 0, also correct.

            An AssertExitCode in the adapter would have failed a perfectly good
            deployment on the first machine and passed on the second. Reading
            dism's prose instead is no better: nothing in the adapter pins a
            language, so the sentence is whatever the technician's DISM speaks.

            SO THE IMAGE IS THE WITNESS. The caller re-reads the package list and
            says whether the update's own package identity is now there; that is
            language-independent, version-exact, and the same evidence a human
            would go and check.

            0x800F081E IS NOT A FAILURE, AND THIS IS THE OTHER HALF OF THE
            DECISION. It means the package does not apply to this image, which is
            the ORDINARY outcome of importing a broad set and letting a sequence
            pick from it. Treating it as failure would make the feature unusable
            for the workflow it was built for.

            0x800F0823 AND 0x800F0922 NAME A MISSING PREREQUISITE rather than a
            broken package, and they get their own outcome so the log says "this
            wanted something you have not imported" rather than "this failed" -
            which is the difference between a message that tells an administrator
            what to do and one that tells them to go and read dism.log.

            AN UPDATE WITH NO KNOWN PACKAGE IDENTITY CANNOT BE VERIFIED, and it
            says so instead of quietly passing. That is the package whose
            metadata could not be read; the exit code is all there is, so the
            exit code is used and the outcome is honest about why.

        .PARAMETER ExitCode
            What dism returned.

        .PARAMETER Landed
            Whether the update's package identity is on the image now.

        .PARAMETER HasPackageId
            Whether the update knows its own package identity at all. Without one
            there is nothing to verify against.

        .PARAMETER PackageCountChanged
            Whether the image's package count moved. The weaker witness, used
            only when there is no package identity to look for.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Outcome
            (Applied, NotApplicable, PrerequisiteMissing, Failed, Unverified),
            Severity and Message.

        .EXAMPLE
            Get-HDTUpdateApplyOutcome -ExitCode -1073740791 -Landed $true -HasPackageId $true -PackageCountChanged $true

            Applied. dism crashed on its way out and the package is on the image;
            the image wins.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [int] $ExitCode,

        [Parameter(Mandatory = $true)]
        [bool] $Landed,

        [Parameter(Mandatory = $true)]
        [bool] $HasPackageId,

        [Parameter()]
        [bool] $PackageCountChanged = $false
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE IMAGE FIRST. If the package is there, it is applied, whatever dism said
    # on its way out - which is the 0xC0000409 case and the reason this order is
    # not the obvious one.
    if ($Landed) {
        return [pscustomobject] @{
            Outcome  = 'Applied'
            Severity = 'Info'
            Message  = 'applied (verified on the image)'
        }
    }

    # 0x800F081E - CBS_E_NOT_APPLICABLE. The package does not apply to this
    # image, which is the ordinary result of a broad import.
    if ($ExitCode -eq -2146498530) {
        return [pscustomobject] @{
            Outcome  = 'NotApplicable'
            Severity = 'Info'
            Message  = 'not applicable to this image, so it was skipped'
        }
    }

    # 0x800F0823 and 0x800F0922 - a prerequisite the image does not have.
    if ($ExitCode -eq -2146498525 -or $ExitCode -eq -2146498270) {
        return [pscustomobject] @{
            Outcome  = 'PrerequisiteMissing'
            Severity = 'Error'
            Message  = ('a prerequisite is missing (0x{0:X8}); import the checkpoint or servicing stack update this one builds on and put it before this one' -f $ExitCode)
        }
    }

    # NOTHING TO VERIFY AGAINST. The exit code is all there is, so it is used -
    # and the outcome says the verification did not happen rather than implying
    # it passed.
    if (-not $HasPackageId) {
        if ($ExitCode -eq 0 -or $PackageCountChanged) {
            return [pscustomobject] @{
                Outcome  = 'Unverified'
                Severity = 'Warning'
                Message  = 'dism reported success, but this package declares no identity so the result could not be verified against the image'
            }
        }

        return [pscustomobject] @{
            Outcome  = 'Failed'
            Severity = 'Error'
            Message  = ('dism exited 0x{0:X8} and this package declares no identity to verify against' -f $ExitCode)
        }
    }

    return [pscustomobject] @{
        Outcome  = 'Failed'
        Severity = 'Error'
        Message  = ('dism exited 0x{0:X8} and the package is not on the image afterwards' -f $ExitCode)
    }
}
