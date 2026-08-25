# Opening the full report on a run the monitoring view is showing.
#
# DESIGN 12, the monitoring view: "tails Logs\_active\, showing in-flight
# deployments, current step, and elapsed time; OPENS THE FULL REPORT ON
# COMPLETION". ConvertTo-HDTReport has rendered that report since M2 and nothing
# in the console ever called it, so the last clause was the one bullet of the
# monitoring view that was never built.
#
# THE HEARTBEAT DOES NOT SAY WHICH MACHINE IT IS. Write-HDTStatus writes runId,
# phase, status, step and updated - no computer name - while Copy-HDTLog files
# the finished log under '<ComputerName>-<RunId>'. So finding a run's log is a
# search for the folder ending in that run id, and the machine's name is what is
# left when the suffix comes off. That asymmetry is the whole reason this is a
# command with tests rather than a Join-Path in the window.
#
# NOT FOUND IS THREE DIFFERENT ANSWERS AND THEY ARE NOT INTERCHANGEABLE. A run
# still going has no log on the share YET; a run that died before copy-back has
# none and never will; a share that has never deployed has no Logs folder at
# all. Telling a technician "no report" in all three cases is how a screen
# teaches people to stop reading it.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:root = 'C:\ws'
    $script:logRoot = 'C:\ws\Logs'
    $script:runId = 'run-0007'
    $script:runFolder = 'C:\ws\Logs\PC-0001-run-0007'
    $script:jsonl = 'C:\ws\Logs\PC-0001-run-0007\HDT.jsonl'

    function New-HDTTestReportFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter()] [hashtable] $File = @{},
            [Parameter()] [string[]] $Directory = @()
        )

        $content = @{}
        foreach ($key in $File.Keys) { $content[$key] = $File[$key] }

        return New-HDTFakeFileSystem -File $content -Directory ([string[]] @($Directory))
    }

    # A copied-back run: the folder Copy-HDTLog makes, with the stream in it.
    function New-HDTTestCopiedBackFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param()

        return New-HDTTestReportFileSystem -File @{ $script:jsonl = '{"event":"run.begin"}' } `
            -Directory @($script:logRoot, $script:runFolder)
    }
}

Describe 'Get-HDTConsoleMonitorReport' {

    Context 'a finished run whose log came back to the share' {

        BeforeAll {
            $script:answer = Get-HDTConsoleMonitorReport -Path $script:root -RunId $script:runId `
                -Health 'Finished' -FileSystem (New-HDTTestCopiedBackFileSystem)
        }

        It 'has a report to open' {
            $script:answer.Status | Should -BeExactly 'Ok'
        }

        It 'renders from the stream Copy-HDTLog filed under the run id' {
            $script:answer.JsonlPath | Should -BeExactly $script:jsonl
        }

        # BESIDE THE LOG IT WAS RENDERED FROM, not in a temp folder and not at
        # the share root: a folder somebody copies to a ticket carries its own
        # report, and clicking twice does not leave two files.
        It 'writes the report into the run folder' {
            $script:answer.ReportPath | Should -BeExactly 'C:\ws\Logs\PC-0001-run-0007\report.html'
        }

        # The name is what is left when the run id suffix comes off, which is
        # the only place on the share it is written down.
        It 'recovers the computer name the heartbeat never carried' {
            $script:answer.ComputerName | Should -BeExactly 'PC-0001'
        }

        It 'titles the report for the machine rather than for HDT' {
            $script:answer.Title | Should -BeLike '*PC-0001*'
        }

        # M8's other half - every action displays the cmdlet it invokes.
        It 'names the command a person could type instead' {
            $script:answer.Command | Should -BeLike 'ConvertTo-HDTReport -JsonlPath *HDT.jsonl* -Path *report.html*'
        }
    }

    Context 'a run that is still going' {

        BeforeAll {
            $script:live = Get-HDTConsoleMonitorReport -Path $script:root -RunId $script:runId `
                -Health 'Live' -FileSystem (New-HDTTestReportFileSystem -Directory @($script:logRoot))
        }

        # ON COMPLETION. The log is copied back when the sequence ends, so there
        # is nothing to render yet - and saying so is different from saying the
        # report is missing.
        It 'is pending rather than missing' {
            $script:live.Status | Should -BeExactly 'Pending'
        }

        It 'says the report arrives when the run does' {
            $script:live.Message | Should -BeLike '*finishes*'
        }

        It 'offers no path to a file that does not exist' {
            $script:live.JsonlPath | Should -BeExactly ''
        }
    }

    # A DEPLOYMENT THAT DIED IS THE ONE SOMEBODY WANTS THE REPORT FOR, and it is
    # exactly the one that never reached Copy-HDTLog. Promising it "when the run
    # finishes" would be a lie about a run that already ended.
    Context 'a stalled run that never copied its log back' {

        BeforeAll {
            $script:stalled = Get-HDTConsoleMonitorReport -Path $script:root -RunId $script:runId `
                -Health 'Stalled' -FileSystem (New-HDTTestReportFileSystem -Directory @($script:logRoot))
        }

        It 'is missing, not pending' {
            $script:stalled.Status | Should -BeExactly 'Missing'
        }

        It 'names the run id it searched for' {
            $script:stalled.Message | Should -BeLike ('*{0}*' -f $script:runId)
        }

        It 'names the folder it searched' {
            $script:stalled.Message | Should -BeLike '*Logs*'
        }
    }

    # A share that has never deployed anything has no Logs folder, and a console
    # that threw on it would throw on the commonest share there is - a new one.
    Context 'a share with no Logs folder at all' {

        It 'answers Missing rather than failing' {
            $answer = Get-HDTConsoleMonitorReport -Path $script:root -RunId $script:runId `
                -Health 'Finished' -FileSystem (New-HDTTestReportFileSystem)

            $answer.Status | Should -BeExactly 'Missing'
        }
    }

    # A folder named for the run with nothing in it is what a half-finished
    # copy-back leaves. There is no stream to render, so it is not a report.
    Context 'a run folder holding no stream' {

        It 'does not offer a report it cannot render' {
            $answer = Get-HDTConsoleMonitorReport -Path $script:root -RunId $script:runId `
                -Health 'Finished' `
                -FileSystem (New-HDTTestReportFileSystem -Directory @($script:logRoot, $script:runFolder))

            $answer.Status | Should -BeExactly 'Missing'
        }
    }

    # THE RUN ID IS A SUFFIX, NOT A SUBSTRING. 'run-0007' and 'run-00071' are
    # different deployments, and a match on Contains would open the wrong one.
    Context 'a share holding a run whose id starts with this one' {

        It 'does not match the longer run id' {
            $answer = Get-HDTConsoleMonitorReport -Path $script:root -RunId $script:runId -Health 'Finished' `
                -FileSystem (New-HDTTestReportFileSystem `
                    -File @{ 'C:\ws\Logs\PC-0002-run-00071\HDT.jsonl' = '{}' } `
                    -Directory @($script:logRoot, 'C:\ws\Logs\PC-0002-run-00071'))

            $answer.Status | Should -BeExactly 'Missing'
        }
    }
}

}
