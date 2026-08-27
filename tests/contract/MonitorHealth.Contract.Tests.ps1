# Every health a monitored run can have, every command that takes one must accept.
#
# THIS EXISTS BECAUSE THE TWO SIDES DRIFTED AND A CONSOLE DIED OF IT.
# New-HDTConsoleMonitorRow answers six healths - Live, Finished, Failed,
# Rebooting, Stalled, Unreadable - and Get-HDTConsoleMonitorReport's ValidateSet
# accepted four. Opening the report on a run that had FAILED threw
#
#   Cannot validate argument on parameter 'Health'. The argument "Failed" does
#   not belong to the set "Live,Stalled,Finished,Unreadable"
#
# out of a click handler, which closed the window. Failed and Rebooting arrived
# with a866d60 - the fix for a failed deployment being drawn as a green finished
# one - and only the producing side learned about them.
#
# A ValidateSet IS A CONTRACT WITH WHOEVER CALLS IT, and half a contract is worse
# than none: it holds until the day somebody's deployment fails, and then it
# fails at the call site instead of at the build.
#
# THE PRODUCER IS THE SOURCE OF TRUTH, read out of the source rather than listed
# here, so a seventh health added tomorrow is covered on the day it appears
# rather than on the day somebody remembers this file.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:rowPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Private/New-HDTConsoleMonitorRow.ps1'
    $script:rowText = [System.IO.File]::ReadAllText($script:rowPath)

    # Every literal assigned to $health in the producer: $health = 'Something'.
    $script:produced = @([regex]::Matches($script:rowText, "(?m)\`$health\s*=\s*'([A-Za-z]+)'") |
            ForEach-Object { $_.Groups[1].Value } |
            Select-Object -Unique |
            Sort-Object)

    $script:consumer = @('Get-HDTConsoleMonitorReport')
}

Describe 'the monitor health vocabulary' {

    It 'finds the healths the producer can answer' {
        # A guard on the guard: if the regex ever stops matching, every
        # assertion below passes vacuously and this file becomes decoration.
        $script:produced.Count | Should -BeGreaterThan 3
        $script:produced | Should -Contain 'Failed'
    }

    It 'accepts every health the producer can answer, in every command that takes one' {
        $missing = New-Object -TypeName System.Collections.ArrayList

        foreach ($name in $script:consumer) {
            $command = Get-Command -Name $name -ErrorAction SilentlyContinue

            if ($null -eq $command) {
                # PRIVATE COMMANDS ARE NOT VISIBLE FROM OUT HERE, so it is
                # fetched from inside the module rather than skipped - a
                # contract that quietly tests nothing is the failure this whole
                # file is about.
                $command = (Get-Module -Name Hephaestus).Invoke({ param($N) Get-Command -Name $N } , $name)
            }

            $command | Should -Not -BeNullOrEmpty -Because "$name has to exist for this contract to mean anything"

            $accepted = @($command.Parameters['Health'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                    ForEach-Object { $_.ValidValues })

            foreach ($health in $script:produced) {
                if ($accepted -notcontains $health) {
                    [void] $missing.Add(('{0} rejects {1}' -f $name, $health))
                }
            }
        }

        # THE WHOLE LIST, NOT THE FIRST ONE. Two values drifted last time, and
        # fixing them one red run at a time is how the second gets missed.
        ($missing -join ' | ') | Should -BeNullOrEmpty
    }
}
