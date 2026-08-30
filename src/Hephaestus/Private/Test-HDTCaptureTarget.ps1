function Test-HDTCaptureTarget {
    <#
        .SYNOPSIS
            Whether this deployment could write a captured image, asked before
            anything expensive has happened.

        .DESCRIPTION
            TWO STEPS ASK THE SAME QUESTION AT TWO DIFFERENT MOMENTS, WHICH IS
            WHY IT IS ONE FUNCTION.

            Invoke-HDTCaptureImageStep asks because it is about to write. That is
            the obvious caller and the useless one: by then the reference machine
            has been built, customized, generalized and restarted, and a share
            the account cannot write costs the entire run - after the machine can
            no longer be picked up where it left off, because it has been
            sysprepped.

            Invoke-HDTSysprepStep asks because it is the LAST MOMENT THE ANSWER
            IS STILL CHEAP. DESIGN 9.3 note 5 is explicit that the check goes
            before the Sysprep step rather than at the moment of writing, and
            ROADMAP M7's capture exit makes it a criterion in its own words:
            "the Captures\ write was proven BEFORE sysprep ran, not after the
            build". A write probe against an ordinary running Windows costs
            milliseconds; the same discovery an hour later costs the build.

            SO NEITHER CALLER OWNS IT AND NEITHER CAN DRIFT. A second copy of
            this test in the second step is two tests that agree until somebody
            edits one - and the one that would go stale is the Sysprep copy,
            because nothing about sysprep looks like it has anything to do with
            Captures\.

            IT REFUSES MEDIA BEFORE IT PROBES ANYTHING. Under the Local provider
            the deploy root is a read-only disc: Captures\ cannot be written at
            all, and there is no correction a technician standing at the machine
            could make (DESIGN 9.3 note 6). Probing it would report a failed
            write - the symptom - rather than the reason it could never have
            succeeded.

            THE PROBE'S NAME COMES FROM THE RUN ID, NOT FROM A GUID. A path that
            differs on every call is a path no test can seed as unwritable, and
            "the account cannot write Captures\" is exactly the branch that has
            to be provable against a fake.

            IT CLEANS UP AFTER ITSELF, AND A FAILURE TO DO SO IS NOT A REFUSAL.
            A probe that wrote and would not delete has already proved the thing
            it was asked; throwing away a reference build over a stray temporary
            file would be the tidier answer and the wrong one.

            IT RETURNS A VERDICT RATHER THAN THROWING, because both callers turn
            it into a New-HDTStepResult with their own component name on it, and
            a step that threw here would break the closed-set contract every
            step type is held to.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its WorkspaceRoot says where
            Captures\ is, its RunId names the probe, and its Service catalog
            supplies the content provider whose transport decides the refusal.

        .PARAMETER FileSystem
            An IFileSystem - the caller's, so the probe is recorded on the same
            fake the rest of the step is asserted against.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with:

              Ok       whether a capture could be written
              Message  what to tell the technician, empty when Ok
              ErrorId  the HDT error id, empty when Ok
              Path     the probe path, for a caller that wants to log it

        .EXAMPLE
            $verdict = Test-HDTCaptureTarget -Context $context -FileSystem $fileSystem
            if (-not $verdict.Ok) { return (New-HDTStepResult -Status Failed -Message $verdict.Message) }

            How both steps use it: a verdict, turned into that step's own result.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $verdict = [ordered] @{
        Ok      = $true
        Message = ''
        ErrorId = ''
        Path    = ''
    }

    # -- media first, because there is nothing to probe --------------------

    $provider = $Context.Service.Content

    if ($null -ne $provider -and $null -ne $provider.PSObject.Properties['Kind'] -and
        [string] $provider.Kind -eq 'Local') {

        $verdict['Ok'] = $false
        $verdict['ErrorId'] = 'HDTConfigurationError'
        $verdict['Message'] = 'a captured image is written to Captures\ on the deployment share, and this deployment is running from standalone media, which is read-only. There is nowhere to put the image and no correction a technician could make; run the reference build from the share instead.'

        return [pscustomobject] $verdict
    }

    # -- and then the write itself -----------------------------------------

    $probePath = Get-HDTWorkspacePath -Root ([string] $Context.WorkspaceRoot) -Kind Captures `
        -ChildPath ('.hdt-write-probe-{0}.tmp' -f [string] $Context.RunId)

    $verdict['Path'] = $probePath

    try {
        $FileSystem.WriteAllText($probePath, 'HDT capture write probe')
    } catch {
        $verdict['Ok'] = $false
        $verdict['ErrorId'] = 'HDTShareAclError'
        $verdict['Message'] = ("the deployment account cannot write Captures\ on this share, so a captured image would have nowhere to go: {0}. DESIGN 2.1 makes Logs\ and Captures\ the only two folders it may write, and Test-HDTShareAcl checks that pair." -f
            [string] $_.Exception.Message)

        return [pscustomobject] $verdict
    }

    try {
        $FileSystem.RemoveItem($probePath, $false)
    } catch {
        # PROVED, AND UNTIDY. See the header: the write succeeded, which is the
        # whole question, and a stray temporary file is not worth a refusal.
        $verdict['Path'] = $probePath
    }

    return [pscustomobject] $verdict
}
