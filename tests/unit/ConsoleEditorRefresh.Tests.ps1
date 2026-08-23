# ONE PARSE PER REFRESH, NOT FOUR.
#
# The editor rebuilds its whole right pane after every edit, and four separate
# view models each turned the same lines back into a document to do it - about
# 70ms apiece, on the UI thread, while somebody waited for a checkbox to tick.
# Injecting the share's operating system catalogue took a click from 950ms to
# 361ms; this is the rest of it.
#
# THE PARAMETER IS FOR THE HOST, and the tests below say what it promises: when
# a document is handed in, THAT is what the command reports on. A caller with no
# document to hand - a script, a test - passes lines and the command parses them
# exactly as it always did.
#
# THEY MUST AGREE, and only the host can guarantee it: it parses $book.Line once
# and hands the result to all four in the same refresh. A caller that passed
# lines from one document and a parse of another would get an answer about the
# second, which is why this parameter is documented as the host's and not
# offered as a way to ask about something else.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:path = 'C:\ws\TaskSequences\DEMO\sequence.yaml'

    $script:line = [string[]] @(
        'schemaVersion: 1'
        'id: DEMO'
        'name: Demo'
        'variables:'
        '  HDTOSImage: Win11-LTSC-2024'
        'steps:'
        '  - name: Install Operating System'
        '    type: ApplyImage'
        '    os: "%HDTOSImage%"'
        '    target: primary'
        '  - name: Validate'
        '    type: Validate'
        '    minRamMB: 4096'
        '  - name: Format and Partition Disk (UEFI)'
        '    type: DiskPartition'
        '    disk: 0'
        '    layout: UEFI'
    )

    function Get-HDTTestParsedDocument {
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Line)

        # New-HDTFileSystemFromText is private, so the parse goes through the
        # module's own scope - the same way the commands under test do it.
        return InModuleScope -ModuleName 'Hephaestus' -Parameters @{ Body = $Line; Where = $script:path } {
            param($Body, $Where)

            $reader = New-HDTFileSystemFromText -Path $Where `
                -Text (($Body) -join [System.Environment]::NewLine)

            Import-HDTSequenceDocument -Path $Where -FileSystem $reader
        }
    }

    $script:document = Get-HDTTestParsedDocument -Line $script:line
}

Describe '<Command> takes a document the host already parsed' -ForEach @(
    @{ Command = 'Get-HDTConsoleEditorState' }
    @{ Command = 'Get-HDTConsolePartitionRow' }
    @{ Command = 'Get-HDTConsoleImageChoice' }
    @{ Command = 'Get-HDTConsoleValidateCheck' }
) {

    It 'offers a Document parameter' {
        (Get-Command -Name $Command -Module 'Hephaestus').Parameters.Keys | Should -Contain 'Document'
    }

    It 'does not demand one, so a caller with only lines still works' {
        $parameter = (Get-Command -Name $Command -Module 'Hephaestus').Parameters['Document']
        $attribute = @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] })

        @($attribute | ForEach-Object { $_.Mandatory }) | Should -Not -Contain $true
    }
}

Describe 'what the handed document decides' {

    It 'Get-HDTConsolePartitionRow reports on the document, not the lines' {
        # The lines say layout UEFI; the document handed in says BIOS. A command
        # that re-parsed the lines would report UEFI, and this is how the tests
        # can tell the difference at all.
        $other = Get-HDTTestParsedDocument -Line ([string[]] @(
                'schemaVersion: 1'; 'id: DEMO'; 'name: Demo'; 'steps:'
                '  - name: Format and Partition Disk (UEFI)'; '    type: DiskPartition'
                '    disk: 0'; '    layout: BIOS'))

        $row = Get-HDTConsolePartitionRow -Line $script:line -Path $script:path `
            -Name 'Format and Partition Disk (UEFI)' -Document $other

        $row.Layout | Should -BeExactly 'BIOS'
    }

    It 'Get-HDTConsoleImageChoice reads the variables off the document it was given' {
        $other = Get-HDTTestParsedDocument -Line ([string[]] @(
                'schemaVersion: 1'; 'id: DEMO'; 'name: Demo'
                'variables:'; '  HDTOSImage: WS2025-Std'
                'steps:'
                '  - name: Install Operating System'; '    type: ApplyImage'
                '    os: "%HDTOSImage%"'; '    target: primary'))

        $choice = Get-HDTConsoleImageChoice -Line $script:line -Path $script:path `
            -Name 'Install Operating System' -Workspace 'C:\ws' `
            -FileSystem (New-HDTFakeFileSystem) -Catalog @() -Document $other

        $choice.Selected | Should -BeExactly 'WS2025-Std'
    }

    It 'Get-HDTConsoleEditorState counts the document s steps' {
        $other = Get-HDTTestParsedDocument -Line ([string[]] @(
                'schemaVersion: 1'; 'id: DEMO'; 'name: Demo'; 'steps:'
                '  - name: Only one'; '    type: NoOp'))

        (Get-HDTConsoleEditorState -Line $script:line -Path $script:path -Document $other).StepCount |
            Should -Be 1
    }

    It 'every one of them still parses the lines when handed nothing' {
        # THE OLD BEHAVIOUR IS THE DEFAULT. Everything that called these before
        # the parameter existed keeps working unchanged.
        (Get-HDTConsoleEditorState -Line $script:line -Path $script:path).StepCount | Should -Be 3

        (Get-HDTConsolePartitionRow -Line $script:line -Path $script:path `
                -Name 'Format and Partition Disk (UEFI)').Layout | Should -BeExactly 'UEFI'
    }
}


}
