# A DEPLOYMENT WITH NOWHERE TO COPY ITS LOG IS NOW A LEGITIMATE DEPLOYMENT.
#
# Under MEDIA the deploy root is read-only content, so Get-HDTLogDestination
# answers with no destination at all unless an admin named HDTSLShare. That is
# the behaviour offline media asked for and it works: the WinPE leg says
#
#   the log copy-back to 'D:\Share\Logs' was skipped because
#   HDTDeploymentMethod is MEDIA: the deploy root is read-only content, and
#   this machine's own log is at <osvolume>\HDT\Logs
#
# and then the run died before its first step with
#
#   Cannot validate argument on parameter 'LogDestination'. The argument is
#   null or empty.
#
# Start-HDTDeployment passes -LogDestination NAMED on the one call it exists to
# make, and a contract test reads the arguments off that call site to prove it -
# so the payload cannot simply drop the parameter when there is no destination.
# The validator is what was wrong: Invoke-HDTTaskSequence had already been
# written to tolerate an empty value at its status-mirror guard ("NO
# DESTINATION, NO MIRROR"), and could never receive one.
#
# WATCHED ON A REAL MACHINE, 2026-09-03, on the first offline media disc.
#
# BOTH DIRECTIONS. A real destination must still mirror and still copy back -
# every share deployment in this lab depends on it, and a fix made for a disc
# that quietly stopped the copy-back would be far worse than the bug.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:command = Get-Command -Name Invoke-HDTTaskSequence
}

Describe 'Invoke-HDTTaskSequence -LogDestination' {

    It 'accepts an empty destination, because media has none to give' {
        # THE PARAMETER IS READ OFF THE COMMAND, not off the file, so a
        # validator moved or re-spelled is still caught.
        $parameter = $script:command.Parameters['LogDestination']
        $parameter | Should -Not -BeNullOrEmpty

        $validator = @($parameter.Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateNotNullOrEmptyAttribute] })

        $validator.Count | Should -Be 0 -Because 'a MEDIA run resolves no log destination at all, and Start-HDTDeployment still passes the parameter by name because a contract test reads it off that call site'
    }

    It 'still declares the parameter, so the call site keeps its name' {
        # The fix must not be "delete the parameter". The payload names it.
        $script:command.Parameters.ContainsKey('LogDestination') | Should -BeTrue
    }

    It 'guards the copy-back on a value, not merely on the parameter being bound' {
        # ContainsKey ALONE IS NOT ENOUGH ANY MORE. Once an empty string can be
        # bound, a guard that only asks whether the parameter was supplied hands
        # Copy-HDTLog an empty destination and turns "there is nowhere to copy
        # to" into a failed copy.
        #
        # Read off the source, because the finally block cannot be reached
        # without running a whole sequence - and the assertion is about which
        # condition guards it.
        $path = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1'

        $token = $null
        $parseError = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $token, [ref] $parseError)
        $parseError | Should -BeNullOrEmpty

        # Every `if` whose condition mentions LogDestination must also test the
        # value, not just the binding.
        $guard = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.IfStatementAst]
                }, $true) |
                Where-Object { $_.Clauses[0].Item1.Extent.Text -match 'LogDestination' })

        $guard.Count | Should -BeGreaterThan 0

        foreach ($clause in $guard) {
            $condition = [string] $clause.Clauses[0].Item1.Extent.Text

            $condition | Should -Match 'IsNullOrWhiteSpace' -Because ("this guard admits an empty destination and hands it to Copy-HDTLog: {0}" -f $condition)
        }
    }
}
