# VIRTUAL FOLDERS, FOR THE WINDOW AND NOTHING ELSE.
#
# Deployment Workbench organises task sequences into folders, and a share with
# thirty of them is unreadable without something like it. MDT's folders are real
# directories under Control\; HDT's cannot be, because the folder a sequence
# sits in would then be part of the path the engine resolves its id from - and
# moving a sequence between folders would break every rule, boot image and
# half-finished deployment that names it.
#
# SO THE FOLDER IS A LABEL ON THE SEQUENCE, not a place it lives.
# TaskSequences\DEMO-05\sequence.yaml stays exactly where it is; the document
# gains one optional key saying which folder the CONSOLE should draw it under.
#
# THE ENGINE MUST NOT CARE, and the test at the bottom of this file is the one
# that keeps it that way: a document with a folder and one without resolve to
# the same run.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:path = 'C:\ws\TaskSequences\DEMO\sequence.yaml'

    $script:plain = [string[]] @(
        'schemaVersion: 1'
        'id: DEMO'
        'name: Demo'
        'steps:'
        '  - name: Gather'
        '    type: Gather'
    )

    function Get-HDTTestSequenceDocument {
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Line)

        return InModuleScope -ModuleName 'Hephaestus' -Parameters @{ Body = $Line } {
            param($Body)
            ConvertFrom-HDTSequenceLine -Line ([string[]] $Body)
        }
    }
}

Describe 'the folder key' {

    It 'is accepted by the reader' {
        $line = [string[]] @(
            'schemaVersion: 1'; 'id: DEMO'; 'name: Demo'
            'folder: Clients\Laptops'
            'steps:'; '  - name: Gather'; '    type: Gather')

        (Get-HDTTestSequenceDocument -Line $line).Folder | Should -BeExactly 'Clients\Laptops'
    }

    It 'is empty when the document does not carry one' {
        # EVERY SEQUENCE EVER WRITTEN HAS NO FOLDER, so the absence has to be
        # ordinary rather than a missing property somebody has to guard against.
        (Get-HDTTestSequenceDocument -Line $script:plain).Folder | Should -BeExactly ''
    }

    It 'validates against the schema' {
        $schemaPath = Join-Path -Path $script:repoRoot -ChildPath 'schemas/sequence.schema.json'
        $schema = Get-Content -LiteralPath $schemaPath -Raw

        # additionalProperties is false, so an unlisted key is a document the
        # schema refuses and the engine accepts - which is worse than either.
        $schema | Should -BeLike '*"folder"*'
    }
}

Describe 'Set-HDTTaskSequenceProperty -Folder' {

    It 'writes the folder into a document that has none' {
        $after = Set-HDTTaskSequenceProperty -Line $script:plain -Folder 'Clients' -Confirm:$false

        (Get-HDTTestSequenceDocument -Line $after).Folder | Should -BeExactly 'Clients'
    }

    It 'moves one that is already in a folder' {
        $line = [string[]] @(
            'schemaVersion: 1'; 'id: DEMO'; 'name: Demo'
            'folder: Clients'
            'steps:'; '  - name: Gather'; '    type: Gather')

        $after = Set-HDTTaskSequenceProperty -Line $line -Folder 'Servers\2025' -Confirm:$false

        (Get-HDTTestSequenceDocument -Line $after).Folder | Should -BeExactly 'Servers\2025'
    }

    It 'takes it out of every folder when cleared' {
        $line = [string[]] @(
            'schemaVersion: 1'; 'id: DEMO'; 'name: Demo'
            'folder: Clients'
            'steps:'; '  - name: Gather'; '    type: Gather')

        $after = Set-HDTTaskSequenceProperty -Line $line -Folder '' -Confirm:$false

        (Get-HDTTestSequenceDocument -Line $after).Folder | Should -BeExactly ''
        @($after | Where-Object { $_ -like 'folder:*' }) | Should -BeNullOrEmpty
    }

    It 'refuses <Bad>, which would not draw as one folder' -ForEach @(
        @{ Bad = '\Clients' }
        @{ Bad = 'Clients\' }
        @{ Bad = 'Clients\\Laptops' }
        @{ Bad = 'Clients/Laptops' }
    ) {
        # A folder is drawn from its own text, so a leading or trailing
        # separator produces a nameless level in the tree and a doubled one
        # produces two.
        { Set-HDTTaskSequenceProperty -Line $script:plain -Folder $Bad -Confirm:$false } |
            Should -Throw -ExpectedMessage '*folder*'
    }

    It 'leaves every other line byte-identical' {
        $after = Set-HDTTaskSequenceProperty -Line $script:plain -Folder 'Clients' -Confirm:$false
        $removed = @(Compare-Object -ReferenceObject $script:plain -DifferenceObject $after |
                Where-Object { $_.SideIndicator -eq '<=' })

        $removed | Should -BeNullOrEmpty
    }
}

Describe 'the engine does not care' {

    It 'runs a foldered sequence exactly as it runs one with no folder' {
        # THE TEST THAT KEEPS IT VIRTUAL. If this ever fails, the folder has
        # stopped being a label on a document and started being part of what
        # the sequence does.
        $foldered = [string[]] @(
            'schemaVersion: 1'; 'id: DEMO'; 'name: Demo'
            'folder: Clients\Laptops'
            'steps:'; '  - name: Gather'; '    type: Gather')

        $withFolder = Get-HDTTestSequenceDocument -Line $foldered
        $without = Get-HDTTestSequenceDocument -Line $script:plain

        @($withFolder.Step).Count | Should -Be @($without.Step).Count
        [string] $withFolder.Step[0].Name | Should -BeExactly ([string] $without.Step[0].Name)
        [string] $withFolder.Id | Should -BeExactly ([string] $without.Id)
    }
}
