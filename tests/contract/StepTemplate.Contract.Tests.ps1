# Every step template has to produce YAML that loads.
#
# THIS EXISTS BECAUSE ONE DID NOT. The ApplyDrivers template shipped
# `group: "Win11\%HDTMake%\%HDTModel%"` - a DOUBLE-quoted YAML scalar, where a
# backslash starts an escape sequence. \% is not one, so powershell-yaml
# refused the entire document with "found unknown escape character", and the
# step whose whole job is to teach an administrator the variable path would have
# written them a sequence.yaml that will not open. Single quotes are literal.
#
# NOTHING CAUGHT IT. Every Get-HDT*StepTemplate emits YAML by string
# concatenation and no test parsed the result, so a template was free to emit
# anything at all. A step type is added by convention here - drop in three
# functions and the registry finds them - which means the next one can make the
# same mistake unless the contract covers the whole set rather than the one
# that failed.
#
# IT PARSES EVERY REGISTERED TYPE, not a list written down here, so a step type
# added tomorrow is covered on the day it appears.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name powershell-yaml -ErrorAction Stop

    $script:type = @(Get-HDTStepType | Where-Object { $null -ne $_.TemplateCommand })
}

Describe 'Step template contract' {

    It 'registers at least one templated step type' {
        # A guard on the guard: if Get-HDTStepType ever answers nothing, every
        # assertion below passes vacuously and this file becomes decoration.
        $script:type.Count | Should -BeGreaterThan 5
    }

    It 'produces YAML that loads, for every registered step type' {
        $broken = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in $script:type) {
            $line = @(& $current.TemplateCommand.Name)
            $yaml = ($line -join "`n")

            try {
                $document = ConvertFrom-Yaml -Yaml $yaml -Ordered

                if ($null -eq $document) {
                    [void] $broken.Add(('{0}: parsed to nothing' -f $current.Type))
                }
            } catch {
                [void] $broken.Add(('{0}: {1}' -f $current.Type, [string] $_.Exception.Message))
            }
        }

        # THE WHOLE LIST, NOT THE FIRST ONE. A template bug is usually a habit,
        # and fixing them one failing run at a time is how the second and third
        # get missed.
        ($broken -join ' | ') | Should -BeNullOrEmpty
    }

    It 'declares the type it is the template for, for every registered step type' {
        $wrong = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in $script:type) {
            $line = @(& $current.TemplateCommand.Name)
            $document = ConvertFrom-Yaml -Yaml ($line -join "`n") -Ordered
            $step = @($document)[0]

            if ([string] $step['type'] -ne [string] $current.Type) {
                [void] $wrong.Add(('{0}: template says type {1}' -f $current.Type, [string] $step['type']))
            }
        }

        ($wrong -join ' | ') | Should -BeNullOrEmpty
    }

    It 'keeps every variable reference loadable, for every registered step type' {
        # THE SPECIFIC TRAP, ASSERTED SPECIFICALLY. A %Variable% in a Windows
        # path is the case that breaks: it puts a backslash next to a percent,
        # and a double-quoted scalar reads the backslash as an escape. Any
        # template carrying one has to survive a round trip with the token
        # intact rather than merely parsing.
        $lost = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in $script:type) {
            $line = @(& $current.TemplateCommand.Name)
            $yaml = ($line -join "`n")

            if ($yaml -notmatch '%HDT') { continue }

            $document = ConvertFrom-Yaml -Yaml $yaml -Ordered
            $step = @($document)[0]

            $survived = $false
            foreach ($key in @($step.Keys)) {
                if ([string] $step[$key] -match '%HDT') { $survived = $true }
            }

            if (-not $survived) {
                [void] $lost.Add(('{0}: a %HDT token did not survive the parse' -f $current.Type))
            }
        }

        ($lost -join ' | ') | Should -BeNullOrEmpty
    }
}
