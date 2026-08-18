# A FOLDER THAT NOTHING IS IN YET.
#
# Folders are labels on documents (see SequenceFolder.Tests.ps1), which is
# enough for every folder that has something in it and no use at all for the one
# somebody has just made: right-click, New Folder, type a name, and the tree is
# built from the documents again and the folder is gone. Workbench's folders are
# real directories, so an empty one is a thing that exists.
#
# SO THE SHARE REMEMBERS THE FOLDERS ITSELF, in workspace.yaml, beside the rest
# of what the share is. The tree draws the union of these and the folders the
# documents name, so a folder made here survives having nothing in it and a
# folder named by a hand-edited document still draws without being listed twice.
#
# ONE LIST PER CATEGORY. 'Clients' under task sequences and 'Clients' under
# operating systems are different folders, in the tree and here.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:plain = [string[]] @(
        '# The share.'
        'schemaVersion: 1'
        'id: DEMO'
        'name: Demo share'
        'deployRoot: \\server\share'
    )

    function Get-HDTTestWorkspace {
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Line)

        return InModuleScope -ModuleName 'Hephaestus' -Parameters @{ Body = $Line } {
            param($Body)
            ConvertFrom-HDTWorkspaceLine -Line ([string[]] $Body)
        }
    }
}

Describe 'the folders key' {

    It 'is empty on a share that has never used one' {
        # EVERY SHARE THAT EXISTS TODAY, so the absence has to be ordinary
        # rather than a missing property every caller guards against.
        $folder = (Get-HDTTestWorkspace -Line $script:plain).Folder

        @($folder.TaskSequence) | Should -BeNullOrEmpty
        @($folder.OperatingSystem) | Should -BeNullOrEmpty
        @($folder.Application) | Should -BeNullOrEmpty
    }

    It 'is read back per category' {
        $line = [string[]] @(
            'schemaVersion: 1'; 'id: DEMO'; 'name: Demo share'
            'folders:'
            '  taskSequences:'
            '    - Clients\Laptops'
            '    - Servers'
            '  operatingSystems:'
            '    - Windows 11')

        $folder = (Get-HDTTestWorkspace -Line $line).Folder

        @($folder.TaskSequence) | Should -Be @('Clients\Laptops', 'Servers')
        @($folder.OperatingSystem) | Should -Be @('Windows 11')
        @($folder.Application) | Should -BeNullOrEmpty
    }

    It 'validates against the schema' {
        $schema = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'schemas/workspace.schema.json') -Raw

        # additionalProperties is false, so an unlisted key is a document the
        # schema refuses and the engine accepts - worse than either.
        $schema | Should -BeLike '*"folders"*'
    }
}

Describe 'Add-HDTWorkspaceFolder' {

    It 'builds the block on a share that has none' {
        $after = Add-HDTWorkspaceFolder -Line $script:plain -Category TaskSequence -Folder 'Clients' -Confirm:$false

        @((Get-HDTTestWorkspace -Line $after).Folder.TaskSequence) | Should -Be @('Clients')
    }

    It 'adds beside the folders already listed' {
        $first = Add-HDTWorkspaceFolder -Line $script:plain -Category TaskSequence -Folder 'Clients' -Confirm:$false
        $after = Add-HDTWorkspaceFolder -Line $first -Category TaskSequence -Folder 'Servers' -Confirm:$false

        @((Get-HDTTestWorkspace -Line $after).Folder.TaskSequence) | Should -Be @('Clients', 'Servers')
    }

    It 'keeps the categories apart' {
        $first = Add-HDTWorkspaceFolder -Line $script:plain -Category TaskSequence -Folder 'Clients' -Confirm:$false
        $after = Add-HDTWorkspaceFolder -Line $first -Category OperatingSystem -Folder 'Clients' -Confirm:$false

        $folder = (Get-HDTTestWorkspace -Line $after).Folder

        @($folder.TaskSequence) | Should -Be @('Clients')
        @($folder.OperatingSystem) | Should -Be @('Clients')
    }

    It 'writes the parent of a nested folder too' {
        # A TREE CANNOT DRAW 'Clients\Laptops' WITHOUT 'Clients'. The grouping
        # builds the parent from the child's path, so listing only the child
        # would be a document that says less than the tree shows - and removing
        # the child would then take a folder nobody removed with it.
        $after = Add-HDTWorkspaceFolder -Line $script:plain -Category TaskSequence -Folder 'Clients\Laptops' -Confirm:$false

        @((Get-HDTTestWorkspace -Line $after).Folder.TaskSequence) | Should -Be @('Clients', 'Clients\Laptops')
    }

    It 'refuses one that is already there' {
        $first = Add-HDTWorkspaceFolder -Line $script:plain -Category TaskSequence -Folder 'Clients' -Confirm:$false

        { Add-HDTWorkspaceFolder -Line $first -Category TaskSequence -Folder 'Clients' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*already*'
    }

    It 'refuses <Bad>, which would not draw as one folder' -ForEach @(
        @{ Bad = '\Clients' }
        @{ Bad = 'Clients\' }
        @{ Bad = 'Clients\\Laptops' }
        @{ Bad = 'Clients/Laptops' }
        @{ Bad = ' ' }
    ) {
        { Add-HDTWorkspaceFolder -Line $script:plain -Category TaskSequence -Folder $Bad -Confirm:$false } |
            Should -Throw -ExpectedMessage '*folder*'
    }

    It 'leaves every other line byte-identical' {
        $after = Add-HDTWorkspaceFolder -Line $script:plain -Category TaskSequence -Folder 'Clients' -Confirm:$false
        $removed = @(Compare-Object -ReferenceObject $script:plain -DifferenceObject $after |
                Where-Object { $_.SideIndicator -eq '<=' })

        $removed | Should -BeNullOrEmpty
    }
}

Describe 'Remove-HDTWorkspaceFolder' {

    BeforeAll {
        $script:filled = [string[]] @(
            'schemaVersion: 1'; 'id: DEMO'; 'name: Demo share'
            'folders:'
            '  taskSequences:'
            '    - Clients'
            '    - Clients\Laptops'
            '    - Servers')
    }

    It 'takes one out and leaves the rest' {
        $after = Remove-HDTWorkspaceFolder -Line $script:filled -Category TaskSequence -Folder 'Servers' -Confirm:$false

        @((Get-HDTTestWorkspace -Line $after).Folder.TaskSequence) | Should -Be @('Clients', 'Clients\Laptops')
    }

    It 'takes what is inside it out with it' {
        # THE TREE WOULD DRAW 'Clients' AGAIN from the child's path, so removing
        # a folder that still lists a child removes nothing a technician can see.
        $after = Remove-HDTWorkspaceFolder -Line $script:filled -Category TaskSequence -Folder 'Clients' -Confirm:$false

        @((Get-HDTTestWorkspace -Line $after).Folder.TaskSequence) | Should -Be @('Servers')
    }

    It 'refuses one that is not listed' {
        { Remove-HDTWorkspaceFolder -Line $script:filled -Category TaskSequence -Folder 'Kiosks' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*Kiosks*'
    }
}
