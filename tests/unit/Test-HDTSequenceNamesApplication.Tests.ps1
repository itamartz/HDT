# DOES THIS SEQUENCE INSTALL THIS APPLICATION?
#
# Remove-HDTApplication has to answer it before it deletes anything, and the
# answer is not a text search: an id that appears in a comment, in a step's
# name, or as another application's dependency is not this sequence installing
# it. It is the selection of an InstallApplications step and nothing else.
#
# AND A SELECTION CAN BE A VARIABLE. `selection: '%HDTApplications%'` is
# resolved from the rules at run time, so a sequence that installs whatever the
# rules say cannot be traced from the document - there is nothing in it to read.
# Answering "yes" for those would name every such sequence for every
# application; answering "no" is what the document actually says.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function Test-HDTTestSelection {
        [CmdletBinding()]
        [OutputType([bool])]
        param([string] $Yaml, [string] $Id)

        return InModuleScope -ModuleName 'Hephaestus' -Parameters @{ Y = $Yaml; I = $Id } {
            param($Y, $I)

            $document = ConvertFrom-HDTYaml -Yaml $Y -Path 'sequence.yaml'
            Test-HDTSequenceNamesApplication -Document $document -Id $I
        }
    }

    $script:listed = @'
schemaVersion: 1
id: DEMO
name: Demo
steps:
  - name: Install Applications
    type: InstallApplications
    selection: [7Zip-24.09, Contoso-Suite]
'@
}

Describe 'Test-HDTSequenceNamesApplication' {

    It 'says yes when a selection list names it' {
        Test-HDTTestSelection -Yaml $script:listed -Id '7Zip-24.09' | Should -BeTrue
    }

    It 'says no when the list names something else' {
        Test-HDTTestSelection -Yaml $script:listed -Id 'Notepad-Plus' | Should -BeFalse
    }

    It 'reads a selection written as one string' {
        $yaml = @'
schemaVersion: 1
id: DEMO
name: Demo
steps:
  - name: Install Applications
    type: InstallApplications
    selection: '7Zip-24.09, Contoso-Suite'
'@

        Test-HDTTestSelection -Yaml $yaml -Id 'Contoso-Suite' | Should -BeTrue
    }

    It 'says no to a selection that is a variable, because it cannot be read' {
        $yaml = @'
schemaVersion: 1
id: DEMO
name: Demo
steps:
  - name: Install Applications
    type: InstallApplications
    selection: '%HDTApplications%'
'@

        Test-HDTTestSelection -Yaml $yaml -Id '7Zip-24.09' | Should -BeFalse
    }

    It 'ignores the id appearing anywhere that is not a selection' {
        # A step NAMED after the application is not a step that installs it.
        $yaml = @'
schemaVersion: 1
id: DEMO
name: Demo
steps:
  - name: Install 7Zip-24.09 by hand
    type: RunCommand
    command: echo 7Zip-24.09
'@

        Test-HDTTestSelection -Yaml $yaml -Id '7Zip-24.09' | Should -BeFalse
    }

    It 'looks inside groups, where most steps actually live' {
        # A sequence of any size is a tree - DEMO-05 has six groups - so a scan
        # of the top level only would miss nearly every step in the share.
        $yaml = @'
schemaVersion: 1
id: DEMO
name: Demo
steps:
  - name: State Restore
    type: Group
    steps:
      - name: Install Applications
        type: InstallApplications
        selection: [7Zip-24.09]
'@

        Test-HDTTestSelection -Yaml $yaml -Id '7Zip-24.09' | Should -BeTrue
    }

    It 'compares without regard to case, as the rest of the catalog does' {
        Test-HDTTestSelection -Yaml $script:listed -Id '7ZIP-24.09' | Should -BeTrue
    }

    It 'says no for a sequence with no steps at all' {
        $yaml = "schemaVersion: 1`nid: DEMO`nname: Demo`n"

        Test-HDTTestSelection -Yaml $yaml -Id '7Zip-24.09' | Should -BeFalse
    }
}
