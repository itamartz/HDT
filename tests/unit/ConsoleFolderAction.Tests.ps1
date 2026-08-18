# WHAT RIGHT-CLICK OFFERS, WORKED OUT WITHOUT A WINDOW.
#
# The menu on the tree already decides its items from the row under the pointer -
# New Task Sequence on the category, Remove on a sequence - and folders add three
# more: make one, delete one, and move something into one. Which of those apply
# is a decision about a row, and a decision inside a Click handler is a decision
# nothing can test.
#
# IT READS THE ROW AND NOTHING ELSE. Re-reading the share to answer this costs
# 400ms on the lab share - measured - in front of a menu that is meant to appear
# under the pointer, so the folders the tree draws are stamped on the rows when
# the tree is built.
#
# THE REFUSALS ARE THE POINT. Deleting a folder that still has something in it
# would appear to do nothing: the folder is a label on the documents, so the tree
# draws it again from the sequence that is still in it. The window has to say
# that rather than run a command that quietly changes nothing.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function Get-HDTTestFolderAction {
        [CmdletBinding()]
        [OutputType([object])]
        param([object] $Row)

        return InModuleScope -ModuleName 'Hephaestus' -Parameters @{ R = $Row } {
            param($R)
            Get-HDTConsoleFolderAction -Row $R
        }
    }
}

Describe 'Get-HDTConsoleFolderAction' {

    Context 'the Task Sequences category' {

        BeforeAll {
            $script:onCategory = Get-HDTTestFolderAction -Row ([pscustomobject] @{
                    Kind = 'Category'; Name = 'TaskSequences'; Text = 'Task Sequences'
                })
        }

        It 'is where a folder is made' {
            $script:onCategory.CanCreate | Should -BeTrue
            $script:onCategory.Category | Should -BeExactly 'TaskSequence'
        }

        It 'makes it at the top, not inside anything' {
            $script:onCategory.Parent | Should -BeExactly ''
        }

        It 'offers neither delete nor move, which need a folder and an item' {
            $script:onCategory.CanDelete | Should -BeFalse
            $script:onCategory.CanMove | Should -BeFalse
        }
    }

    Context 'a folder with nothing in it' {

        BeforeAll {
            $script:onEmpty = Get-HDTTestFolderAction -Row ([pscustomobject] @{
                    Kind = 'Folder'; Text = 'Kiosks'; FolderPath = 'Kiosks'
                    FolderCategory = 'TaskSequence'; FolderChoice = [string[]] @('Kiosks')
                    Children = @()
                })
        }

        It 'can be deleted' {
            $script:onEmpty.CanDelete | Should -BeTrue
        }

        It 'is where a folder inside it is made' {
            $script:onEmpty.CanCreate | Should -BeTrue
            $script:onEmpty.Parent | Should -BeExactly 'Kiosks'
        }
    }

    Context 'a folder with something in it' {

        BeforeAll {
            $script:onFull = Get-HDTTestFolderAction -Row ([pscustomobject] @{
                    Kind = 'Folder'; Text = 'Clients'; FolderPath = 'Clients'
                    FolderCategory = 'TaskSequence'; FolderChoice = [string[]] @('Clients')
                    Children = @([pscustomobject] @{ Text = 'DEMO-05' })
                })
        }

        It 'cannot be deleted' {
            # THE DELETE WOULD APPEAR TO DO NOTHING: the sequence still says
            # 'Clients', so the tree draws the folder again from the document.
            $script:onFull.CanDelete | Should -BeFalse
        }

        It 'says why, naming the folder and how much is in it' {
            $script:onFull.DeleteRefusal | Should -BeLike '*Clients*'
            $script:onFull.DeleteRefusal | Should -BeLike '*1 item*'
        }

        It 'counts a folder inside it as something in it' {
            # A NESTED FOLDER IS A CHILD LIKE ANY OTHER, and deleting the parent
            # while it is there would take a folder nobody selected with it.
            $action = Get-HDTTestFolderAction -Row ([pscustomobject] @{
                    Kind = 'Folder'; Text = 'Clients'; FolderPath = 'Clients'
                    FolderCategory = 'TaskSequence'; FolderChoice = [string[]] @('Clients', 'Clients\Laptops')
                    Children = @(
                        [pscustomobject] @{ Kind = 'Folder'; Text = 'Laptops' }
                        [pscustomobject] @{ Kind = 'Folder'; Text = 'Desktops' })
                })

            $action.CanDelete | Should -BeFalse
            $action.DeleteRefusal | Should -BeLike '*2 items*'
        }
    }

    Context 'a task sequence' {

        BeforeAll {
            $script:onItem = Get-HDTTestFolderAction -Row ([pscustomobject] @{
                    Kind = 'TaskSequence'; Name = 'DEMO'; Text = 'DEMO - Demo'; Folder = 'Clients'
                    FolderCategory = 'TaskSequence'; FolderChoice = [string[]] @('Clients', 'Kiosks')
                })
        }

        It 'can be moved' {
            $script:onItem.CanMove | Should -BeTrue
            $script:onItem.Category | Should -BeExactly 'TaskSequence'
        }

        It 'offers every folder the tree draws in its own category' {
            @($script:onItem.Choice) | Should -Be @('Clients', 'Kiosks')
        }

        It 'cannot make or delete a folder' {
            $script:onItem.CanCreate | Should -BeFalse
            $script:onItem.CanDelete | Should -BeFalse
        }

        It 'can still be moved on a share with no folders at all' {
            # THE FIRST FOLDER IS MADE BY MOVING SOMETHING INTO IT, so an empty
            # list of choices is not a reason to hide the item.
            $action = Get-HDTTestFolderAction -Row ([pscustomobject] @{
                    Kind = 'TaskSequence'; Name = 'DEMO'; Text = 'DEMO - Demo'
                    FolderCategory = 'TaskSequence'; FolderChoice = [string[]] @()
                })

            $action.CanMove | Should -BeTrue
            @($action.Choice) | Should -BeNullOrEmpty
        }
    }

    Context 'an operating system' {

        It 'is offered its own folders, never a task sequence folder' {
            $action = Get-HDTTestFolderAction -Row ([pscustomobject] @{
                    Kind = 'OperatingSystem'; Name = 'WIN11'; Text = 'WIN11'
                    FolderCategory = 'OperatingSystem'; FolderChoice = [string[]] @('Windows 11')
                })

            $action.Category | Should -BeExactly 'OperatingSystem'
            @($action.Choice) | Should -Be @('Windows 11')
        }
    }

    Context 'an application' {

        It 'takes the same three actions the other two do' {
            $action = Get-HDTTestFolderAction -Row ([pscustomobject] @{
                    Kind = 'Application'; Name = '7Zip-24.09'; Text = '7Zip-24.09 - 7-Zip'
                    FolderCategory = 'Application'; FolderChoice = [string[]] @('Utilities')
                })

            $action.Category | Should -BeExactly 'Application'
            $action.CanMove | Should -BeTrue
            @($action.Choice) | Should -Be @('Utilities')
        }

        It 'makes a folder from its category' {
            $action = Get-HDTTestFolderAction -Row ([pscustomobject] @{
                    Kind = 'Category'; Name = 'Applications'; Text = 'Applications (2)'
                })

            $action.CanCreate | Should -BeTrue
            $action.Category | Should -BeExactly 'Application'
        }
    }

    Context 'a row folders mean nothing to' {

        It 'offers nothing on <Kind>' -ForEach @(
            @{ Kind = 'BootImage' }
            @{ Kind = 'Driver' }
            @{ Kind = 'Share' }
        ) {
            # AND THE MENU DOES NOT OPEN AT ALL, which is the rule the items
            # already on it follow: a menu that appears everywhere with one live
            # item teaches that right-click does nothing here.
            $action = Get-HDTTestFolderAction -Row ([pscustomobject] @{ Kind = $Kind; Text = 'whatever' })

            $action.CanCreate | Should -BeFalse
            $action.CanDelete | Should -BeFalse
            $action.CanMove | Should -BeFalse
        }

        It 'offers nothing on a category folders do not apply to' {
            $action = Get-HDTTestFolderAction -Row ([pscustomobject] @{
                    Kind = 'Category'; Name = 'Drivers'; Text = 'Drivers'
                })

            $action.CanCreate | Should -BeFalse
        }

        It 'offers nothing when there is no row' {
            $action = Get-HDTTestFolderAction -Row $null

            $action.CanCreate | Should -BeFalse
            $action.CanMove | Should -BeFalse
        }
    }
}
