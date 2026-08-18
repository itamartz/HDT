# APPLICATIONS IN THE CONSOLE, asserted with no window and no share.
#
# Deployment Workbench's tree has Applications beside Operating Systems and Task
# Sequences, and HDT's had everything but. The engine has had the whole
# application catalog since M7 - Import, Get, Set, the detection rules, the
# dependency order - and none of it was on screen, so the one part of a share an
# administrator changes weekly could only be reached from a prompt.
#
# THE ROWS COME FROM Get-HDTApplication, which is the command an administrator
# would type. Nothing here re-parses app.yaml: DESIGN 12's rule is that the
# console may not do anything the cmdlets cannot, and re-reading a document the
# engine already reads is how the two come to disagree.
#
# AND ONE UNREADABLE app.yaml DOES NOT EMPTY THE CATEGORY. Workbench shows the
# broken item and complains about it; a console that throws on the first bad
# file shows nothing at all, on exactly the day something is broken.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:workspaceYaml = "schemaVersion: 1`nid: HDT`nname: HDT share`n"

    $script:sevenZip = @'
schemaVersion: 1
id: 7Zip-24.09
name: 7-Zip 24.09 x64
description: The file manager everybody asks for on day one.
folder: Utilities
install: msiexec.exe /i "7z2409-x64.msi" /qn /norestart
uninstall: msiexec.exe /x "{23170F69}" /qn
runIn: FullOS
detect:
  type: msiProduct
  productCode: '{23170F69-40C1-2702-2409-000001000000}'
'@

    $script:suite = @'
schemaVersion: 1
id: Contoso-Suite
name: Contoso Suite
install: setup.exe /quiet
dependencies:
  - 7Zip-24.09
'@

    $script:newFileSystem = {
        New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml'                        = $script:workspaceYaml
            'C:\ws\Applications\7Zip-24.09\app.yaml'      = $script:sevenZip
            'C:\ws\Applications\7Zip-24.09\source\7z.msi' = 'not really an msi'
            'C:\ws\Applications\Contoso-Suite\app.yaml'   = $script:suite
        }
    }

    function Get-HDTTestTree {
        [CmdletBinding()]
        [OutputType([object])]
        param([object] $Workspace)

        return InModuleScope -ModuleName 'Hephaestus' -Parameters @{ W = $Workspace } {
            param($W)
            Get-HDTConsoleShareNode -Workspace $W
        }
    }
}

Describe 'the applications on a share' {

    BeforeAll {
        $script:share = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem (& $script:newFileSystem)
    }

    It 'reads every application in the catalog' {
        @($script:share.Application | ForEach-Object { [string] $_.Id }) |
            Should -Be @('7Zip-24.09', 'Contoso-Suite')
    }

    It 'carries what a properties page shows' {
        $row = @($script:share.Application)[0]

        [string] $row.Name | Should -BeExactly '7-Zip 24.09 x64'
        [string] $row.Description | Should -BeLike '*day one*'
        [string] $row.Install | Should -BeLike 'msiexec.exe /i*'
        [string] $row.Uninstall | Should -BeLike 'msiexec.exe /x*'
        [string] $row.RunIn | Should -BeExactly 'FullOS'
    }

    It 'carries the folder the console draws it under' {
        [string] @($script:share.Application)[0].Folder | Should -BeExactly 'Utilities'
    }

    It 'says how it is detected, in words a technician reads' {
        # AN APPLICATION WITH NO RULE INSTALLS EVERY TIME (DESIGN 8), which is a
        # thing to be able to see on the row rather than infer from a blank.
        [string] @($script:share.Application)[0].Detection | Should -Not -BeNullOrEmpty
        [string] @($script:share.Application)[1].Detection | Should -BeLike '*every time*'
    }

    It 'carries what it depends on' {
        @(@($script:share.Application)[1].Dependency) | Should -Be @('7Zip-24.09')
    }

    It 'names the document, so the row can be edited' {
        [string] @($script:share.Application)[0].Path | Should -BeExactly 'C:\ws\Applications\7Zip-24.09\app.yaml'
    }

    It 'is empty, not absent, on a share with no Applications folder' {
        # Applications are optional; a share that deploys an image and no
        # software is a legitimate share, and the property still has to be there.
        $bare = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem (New-HDTFakeFileSystem -File @{
                'C:\ws\workspace.yaml' = $script:workspaceYaml
            })

        @($bare.Application) | Should -BeNullOrEmpty
    }

    It 'shows a broken one as broken instead of failing the whole share' {
        $fileSystem = New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml'                       = $script:workspaceYaml
            'C:\ws\Applications\7Zip-24.09\app.yaml'     = $script:sevenZip
            'C:\ws\Applications\Broken\app.yaml'         = "schemaVersion: 1`nid: Broken`nnoSuchKey: true`n"
        }

        $share = Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem $fileSystem

        @($share.Application).Count | Should -Be 2
        [string] @($share.Application | Where-Object { $_.Id -eq 'Broken' }).Status | Should -BeExactly 'Error'
        [string] @($share.Application | Where-Object { $_.Id -eq '7Zip-24.09' }).Status | Should -BeExactly 'Ok'
    }

    It 'is not fooled by a folder with no app.yaml in it' {
        $fileSystem = New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml'                 = $script:workspaceYaml
            'C:\ws\Applications\Staging\notes.txt' = 'mine'
        }

        @((Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem $fileSystem).Application) | Should -BeNullOrEmpty
    }
}

Describe 'the Applications category in the tree' {

    BeforeAll {
        $script:node = Get-HDTTestTree -Workspace (Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem (& $script:newFileSystem))
        $script:category = @($script:node | Where-Object { [string] $_.Name -eq 'Applications' })
    }

    It 'is there, named rather than only labelled' {
        # NAMED, so the window can hang New Application off this row without
        # matching on a label somebody may reword.
        @($script:category).Count | Should -Be 1
        [string] @($script:category)[0].Kind | Should -BeExactly 'Category'
    }

    It 'counts what is in it, as the other categories do' {
        [string] @($script:category)[0].Text | Should -BeExactly 'Applications (2)'
    }

    It 'draws one row per application, by the name a technician reads' {
        # NOT 'id - name', which the other two categories use. An application's
        # id is composed FROM its name and version (Get-HDTApplicationName), so
        # a row showing both reads 'Igor-Pavlov-7-Zip-24.09 - Igor Pavlov 7-Zip
        # 24.09' - the same sentence twice, once with hyphens.
        $row = @($script:node | Where-Object { [string] $_.Kind -eq 'Application' })

        @($row | ForEach-Object { [string] $_.Text }) |
            Should -Be @('7-Zip 24.09 x64', 'Contoso Suite')
    }

    It 'puts the version on the row when the name does not already carry it' {
        # A NAME AND A VERSION ARE TWO DOCUMENT KEYS, and an entry whose name is
        # just 'Reader' is exactly the one somebody needs the version of.
        $fileSystem = New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml'                = $script:workspaceYaml
            'C:\ws\Applications\Reader\app.yaml' = "schemaVersion: 1`nid: Reader`nname: Acrobat Reader`nversion: '24.2'`ninstall: setup.exe`n"
        }

        $node = Get-HDTTestTree -Workspace (Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem $fileSystem)
        $row = @($node | Where-Object { [string] $_.Kind -eq 'Application' })[0]

        [string] $row.Text | Should -BeExactly 'Acrobat Reader 24.2'
    }

    It 'says it once when the name already ends with the version' {
        $fileSystem = New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml'                = $script:workspaceYaml
            'C:\ws\Applications\Reader\app.yaml' = "schemaVersion: 1`nid: Reader`nname: Acrobat Reader 24.2`nversion: '24.2'`ninstall: setup.exe`n"
        }

        $node = Get-HDTTestTree -Workspace (Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem $fileSystem)
        $row = @($node | Where-Object { [string] $_.Kind -eq 'Application' })[0]

        [string] $row.Text | Should -BeExactly 'Acrobat Reader 24.2'
    }

    It 'draws the folders an application named' {
        $utilities = @($script:category)[0].Children |
            Where-Object { [string] $_.Kind -eq 'Folder' -and [string] $_.Text -eq 'Utilities' }

        @($utilities).Count | Should -Be 1
        @($utilities[0].Children | ForEach-Object { [string] $_.Text }) | Should -Be @('7-Zip 24.09 x64')
    }

    It 'says so when there is none, and names the command that adds one' {
        $bare = Get-HDTTestTree -Workspace (Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem (New-HDTFakeFileSystem -File @{
                    'C:\ws\workspace.yaml' = $script:workspaceYaml
                }))

        $category = @($bare | Where-Object { [string] $_.Name -eq 'Applications' })[0]
        $empty = @($category.Children)[0]

        [string] $empty.Kind | Should -BeExactly 'Empty'
        (@($empty.Field | ForEach-Object { [string] $_.Value }) -join ' ') | Should -BeLike '*Import-HDTApplication*'
    }

    It 'gives a broken row the command that would read it' {
        # DESIGN 12's "learn the automation surface by clicking around": every
        # row names what would reproduce it, and a broken one most of all.
        $fileSystem = New-HDTFakeFileSystem -File @{
            'C:\ws\workspace.yaml'               = $script:workspaceYaml
            'C:\ws\Applications\Broken\app.yaml' = "schemaVersion: 1`nid: Broken`nnoSuchKey: true`n"
        }

        $node = Get-HDTTestTree -Workspace (Get-HDTConsoleWorkspace -Path 'C:\ws' -FileSystem $fileSystem)
        $row = @($node | Where-Object { [string] $_.Kind -eq 'Application' })[0]

        [string] $row.Status | Should -BeExactly 'Error'
        [string] $row.Command | Should -BeLike '*Get-HDTApplication*'
    }
}
