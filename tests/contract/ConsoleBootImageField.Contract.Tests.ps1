# EVERY EDITABLE CONTROL ON THE WINDOWS PE WINDOW IS CLASSIFIED, and the set of
# controls is READ OFF THE BUILT WINDOW rather than written down here.
#
# WHAT THIS IS FOR. Nearly every field on that window is consumed by
# Update-HDTBootImage and baked into the .wim - the name, the architecture, the
# language, the background, the scratch space, the answer file, the
# certificates, the components, the drivers, the extra content, the start
# commands, the time zone. Changing one and pressing Save changes the DOCUMENT
# and nothing else; the image goes on carrying what it was built with until
# Update runs. The window said so for none of them.
#
# AND THE MARKER IS ONLY WORTH HAVING IF IT IS RIGHT. rules.yaml is read live
# off the share at deployment, so a rebuild notice raised by editing it would be
# a lie - and a marker that lies once is a marker people stop reading.
# bootstrap-rules.yaml is the opposite trap: it LOOKS like a share document and
# is written INTO the image (Update-HDTBootImage, step 12b), because WinPE reads
# it before the share is reachable.
#
# CLAUDE.md rule 8: a thing is not added until every surface that must know
# about it does, and the proof is a test against the SET. A field added to this
# window tomorrow fails here until somebody has decided which of the two it is.

$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

Describe 'The Windows PE window and what a rebuild is needed for' {

    BeforeAll {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        [System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        $script:viewPath = Join-Path -Path $script:repoRoot `
            -ChildPath 'src\Hephaestus\Private\New-HDTConsoleBootImageView.ps1'

        $script:viewSource = [System.IO.File]::ReadAllText($script:viewPath)

        $script:window = New-HDTConsoleBootImageView `
            -ConsoleHost ([pscustomobject] @{ Answer = ''; Width = 0; Height = 0; Window = $null }) `
            -Xaml ([System.IO.File]::ReadAllText(
                (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\UI\Console\HDTBootImage.xaml'))) `
            -Path 'C:\ws\workspace.yaml' `
            -Line ([string[]] @('schemaVersion: 1', 'id: HDT-LAB', 'name: HDT deployment share')) `
            -Component ([object[]] @()) -SelectionProfile ([object[]] @()) `
            -Theme (Get-HDTConsoleTheme) `
            -Size ([pscustomobject] @{ Width = 1180; Height = 760; Left = 40; Top = 20 })

        $script:field = @(Get-HDTConsoleBootImageField)
        $script:classified = @($script:field | ForEach-Object { [string] $_.Name })

        # WHAT THE VIEW ACTUALLY REACHES FOR. Every FindName in the source, which
        # is how a control gets wired at all - a control the view never names
        # cannot be edited through it.
        $script:named = @(
            [regex]::Matches($script:viewSource, "FindName\('([^']+)'\)") |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        )

        # AND OF THOSE, THE ONES SOMEBODY CAN TYPE IN OR PICK FROM. A TextBlock
        # is output and a Button acts on a field rather than being one; these six
        # types are the input surface, taken off the LIVE window so a control
        # that changes type is caught rather than remembered.
        $script:inputType = @(
            'System.Windows.Controls.TextBox'
            'System.Windows.Controls.ComboBox'
            'System.Windows.Controls.CheckBox'
            'System.Windows.Controls.PasswordBox'
            'System.Windows.Controls.ListBox'
            'System.Windows.Controls.ItemsControl'
        )

        $script:input = @(
            foreach ($name in $script:named) {
                $control = $script:window.FindName($name)
                if ($null -eq $control) { continue }
                if ($script:inputType -notcontains $control.GetType().FullName) { continue }
                [string] $name
            }
        )
    }

    It 'found controls to classify, so the sweep below is not vacuous' {
        @($script:input).Count | Should -BeGreaterThan 10
    }

    It 'classifies every editable control the view names' {
        # A FIELD ADDED WITHOUT A DECISION DEFAULTS TO SILENCE, which is the
        # half-feature this whole file exists to stop. Deciding is cheap; the
        # image quietly carrying last week's time zone is not.
        $unclassified = @($script:input | Where-Object { $script:classified -notcontains $_ })

        $unclassified | Should -BeNullOrEmpty -Because (
            'these are editable on the Windows PE window and nothing says whether a change to them needs the boot image rebuilt: {0}' -f ($unclassified -join ', '))
    }

    It 'classifies nothing that is no longer on the window' {
        $stale = @($script:classified | Where-Object { $null -eq $script:window.FindName($_) })

        $stale | Should -BeNullOrEmpty -Because ('these are classified and no longer exist: {0}' -f ($stale -join ', '))
    }

    It 'gives every classified control one of the three effects' {
        foreach ($one in $script:field) {
            @('Rebuild', 'Share', 'None') | Should -Contain ([string] $one.Effect) `
                -Because ('{0} is classified {1}' -f $one.Name, $one.Effect)
        }
    }

    It 'says why for every control it calls Rebuild' {
        # THE REASON IS THE EVIDENCE. Each of these is a line in
        # Update-HDTBootImage that reads the value and puts it in the image; a
        # row without one is a guess, and a guess is how rules.yaml would end up
        # in this list.
        foreach ($one in @($script:field | Where-Object { $_.Effect -eq 'Rebuild' })) {
            [string] $one.Reason | Should -Not -BeNullOrEmpty -Because ('{0} claims a rebuild' -f $one.Name)
        }
    }

    It 'calls the rules box share-side and the bootstrap box baked' {
        # THE TWO THAT LOOK ALIKE AND ARE NOT. rules.yaml is read off the share
        # at deployment; bootstrap-rules.yaml is written INTO the image, because
        # WinPE reads it before the share is reachable.
        [string] (@($script:field | Where-Object { $_.Name -eq 'HDTRulesBox' })[0]).Effect |
            Should -BeExactly 'Share'

        [string] (@($script:field | Where-Object { $_.Name -eq 'HDTBootstrapRulesBox' })[0]).Effect |
            Should -BeExactly 'Rebuild'
    }

    It 'marks the workspace document dirty in exactly one place' {
        # EVERY LIST EDIT ON THIS WINDOW IS BAKED - a component, a certificate, a
        # line of extra content, a start command - so the flag that says the
        # document changed and the flag that says the image is stale are raised
        # together, by one closure. A tenth handler that set the dirty flag by
        # hand would edit the document and leave the footer silent.
        $raised = @([regex]::Matches($script:viewSource, '\$book\.Dirty\s*=\s*\$true'))

        @($raised).Count | Should -Be 1 -Because 'every other site goes through $markDirty, which also raises the rebuild notice'
    }
}

}
