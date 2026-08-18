# WHAT AN APPLICATION IS CALLED, AND WHAT ITS FOLDER IS CALLED, from the three
# things MDT asks for.
#
# Deployment Workbench's New Application wizard asks for Publisher, Application
# Name and Version, and composes both the display name and the folder from them
# - '7-Zip' on its own is not an application, it is three of them a year apart,
# and a share where the difference between the version everyone runs and the
# version being piloted is somebody's memory of which folder is which is a share
# that installs the wrong one.
#
# THE ID IS NOT THE DISPLAY NAME. HDT's id is a folder name and what a task
# sequence names to install it, so it cannot hold spaces - the display name can
# and should. One composes from the other rather than being typed twice, which
# is the whole reason this is a function and not two boxes somebody fills in.
#
# AND AN ID SOMEBODY TYPED IS LEFT ALONE. Composing is what happens when nobody
# has decided; a share that renames an entry because the publisher was edited is
# a share that breaks every sequence naming it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTApplicationName' {

    Context 'all three answered' {

        BeforeAll {
            $script:full = Get-HDTApplicationName -Publisher 'Igor Pavlov' -Name '7-Zip' -Version '24.09'
        }

        It 'reads as Workbench reads it: publisher, name, version' {
            [string] $script:full.Display | Should -BeExactly 'Igor Pavlov 7-Zip 24.09'
        }

        It 'makes an id a folder can be called' {
            [string] $script:full.Id | Should -BeExactly 'Igor-Pavlov-7-Zip-24.09'
        }

        It 'makes an id the engine accepts' {
            # THE SAME PATTERN Import-HDTApplication ENFORCES. An id this
            # function composed and the importer refused would be a dialog that
            # fills a box in and then will not use it.
            [string] $script:full.Id | Should -Match '^[A-Za-z0-9][A-Za-z0-9_.-]*$'
        }
    }

    Context 'the parts that were left out' {

        It 'skips a missing publisher rather than leaving a gap' {
            $answer = Get-HDTApplicationName -Name '7-Zip' -Version '24.09'

            [string] $answer.Display | Should -BeExactly '7-Zip 24.09'
            [string] $answer.Id | Should -BeExactly '7-Zip-24.09'
        }

        It 'is the name alone when that is all there is' {
            $answer = Get-HDTApplicationName -Name 'Contoso Suite'

            [string] $answer.Display | Should -BeExactly 'Contoso Suite'
            [string] $answer.Id | Should -BeExactly 'Contoso-Suite'
        }

        It 'answers empty when nothing was given, rather than a stray separator' {
            $answer = Get-HDTApplicationName

            [string] $answer.Display | Should -BeExactly ''
            [string] $answer.Id | Should -BeExactly ''
        }
    }

    Context 'text a folder name cannot hold' {

        It 'turns <Bad> into an id anyway' -ForEach @(
            @{ Bad = 'Contoso (Europe)'; Id = 'Contoso-Europe' }
            @{ Bad = 'Adobe: Reader'; Id = 'Adobe-Reader' }
            @{ Bad = 'Node.js'; Id = 'Node.js' }
            @{ Bad = 'C++ Redistributable'; Id = 'C-Redistributable' }
            @{ Bad = '  Spaced  Out  '; Id = 'Spaced-Out' }
        ) {
            # A PUBLISHER IS WHATEVER IS ON THE VENDOR'S PAGE, brackets and all,
            # and a dialog that refuses the name of the thing being installed is
            # a dialog somebody works around by typing something else.
            [string] (Get-HDTApplicationName -Name $Bad).Id | Should -BeExactly $Id
        }

        It 'never composes an id that starts with a character the engine refuses' {
            [string] (Get-HDTApplicationName -Name '.NET Desktop Runtime').Id | Should -Match '^[A-Za-z0-9]'
        }

        It 'gives up rather than inventing an id from punctuation alone' {
            # '+++' has nothing in it a folder name can keep, and a folder
            # called '-' helps nobody. Empty says "you name it".
            [string] (Get-HDTApplicationName -Name '+++').Id | Should -BeExactly ''
        }
    }
}
