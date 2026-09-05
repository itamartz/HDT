function Get-HDTWindowsUpdateStepDescription {
    <#
        .SYNOPSIS
            Describes a WindowsUpdate step by the server it will patch from and
            how many passes it will make.

        .DESCRIPTION
            The optional third of the step contract's triple. This string goes to
            the progress display and to the master log at Info.

            A TOKEN IS REPORTED, NOT RESOLVED. The description is built from the
            step as authored, with no context to expand '%HDTWSUSServer%'
            against - so a server that is a variable is named as the variable it
            will read rather than as a guess at what that variable will hold.
            The step logs the server it actually used, and where the value came
            from, once it has one. (Get-HDTInstallApplicationsStepDescription
            says the same thing at length; this matches it.)

            NO SERVER READS AS 'Windows Update', WHICH IS WHAT WILL HAPPEN.
            DESIGN 10.1: an empty server leaves the agent on its default service
            and the machine patches from Microsoft. Saying 'WindowsUpdate: ' and
            then nothing would leave a technician reading the progress display
            unable to tell an unset variable from a step about to reach the
            internet.

            THE PASS COUNT IS IN THE LINE BECAUSE THE LOOP IS THE POINT OF THE
            STEP. A reader of the log who sees the step name three times needs
            the line to say that three was the limit, not to wonder whether
            something retried.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\UPD-WSUS\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'WindowsUpdate' })[0]

            Get-HDTWindowsUpdateStepDescription -Step $step

            The one line the log and the progress display carry for this step.

        .EXAMPLE
            Get-HDTStepDescription -Step $step

            The same line through the dispatcher, which is how the engine asks.
            It finds this function by name; a step type that declares none gets
            '<Type>: <name>' instead.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $property = $Step.Property

    # THE DEFAULTS ARE THE STEP'S OWN, quoted from Invoke-HDTWindowsUpdateStep.
    # A description that named a different number would be worse than one that
    # named none: it would say, in the log, that the step will do something it
    # will not.
    $server = 'Windows Update'
    $pass = 3

    if ($null -ne $property) {
        if ($property.Contains('server') -and -not [string]::IsNullOrWhiteSpace([string] $property['server'])) {
            $server = [string] $property['server']
        }

        if ($property.Contains('maxPasses')) {
            $candidate = 0

            if ([int]::TryParse([string] $property['maxPasses'], [ref] $candidate) -and $candidate -gt 0) {
                $pass = $candidate
            }
        }
    }

    return ('WindowsUpdate: {0}, up to {1} passes' -f $server, $pass)
}
