# THE INSTALL OPERATING SYSTEM PAGE - MDT's, where an administrator PICKS an
# operating system out of the share rather than typing its id.
#
# THE LIST IS THE SHARE'S OWN. Get-HDTConsoleWorkspace already reads
# OperatingSystems\<id>\os.yaml for the browser; this reuses it, so a window can
# never offer an image the engine cannot resolve, and importing one makes it
# appear here without anything being edited.
#
# WHAT THE DOCUMENT SAYS WINS, EVEN IF THE SHARE DOES NOT HAVE IT. A sequence
# naming an image somebody has since deleted must still open, still show the
# name it carries, and say that it is missing - a dropdown that silently
# selected the first row instead would rewrite the deployment on the next save.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:path = 'C:\ws\TaskSequences\DEMO\sequence.yaml'

    $script:line = [string[]] @(@'
schemaVersion: 1
id: DEMO
name: image choice
steps:
  - group: Install
    steps:
      - name: Install Operating System
        type: ApplyImage
        os: Win11-LTSC-2024
        index: 1
        target: primary
        timeoutMinutes: 60
      - name: Validate
        type: Validate
'@ -split "`r?`n")

    $script:fileSystem = New-HDTFakeFileSystem -File @{
        'C:\ws\workspace.yaml' = "schemaVersion: 1`nid: LAB`nname: lab`ndeployRoot: \\host\share"
        'C:\ws\TaskSequences\DEMO\sequence.yaml' = ($script:line -join "`n")
        'C:\ws\OperatingSystems\Win11-LTSC-2024\os.yaml' = @'
schemaVersion: 1
id: Win11-LTSC-2024
name: Windows 11 Enterprise LTSC 2024
type: wim
sourcePath: sources\install.wim
defaultIndex: 1
images:
  - index: 1
    name: Windows 11 Enterprise LTSC
'@
        'C:\ws\OperatingSystems\WS2025-Std\os.yaml' = @'
schemaVersion: 1
id: WS2025-Std
name: Windows Server 2025 Standard
type: wim
sourcePath: sources\install.wim
defaultIndex: 2
images:
  - index: 2
    name: Windows Server 2025 Standard (Desktop Experience)
'@
    }
}

Describe 'Get-HDTConsoleImageChoice' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTConsoleImageChoice' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'an ApplyImage step' {

        BeforeAll {
            $script:view = Get-HDTConsoleImageChoice -Line $script:line -Path $script:path `
                -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem
        }

        It 'belongs on screen' {
            $script:view.IsImageStep | Should -BeTrue
        }

        It 'offers every operating system the share holds' {
            # SORTED BY WHAT IS ON SCREEN, which is the order somebody scans.
            @($script:view.Image | ForEach-Object { $_.Id }) |
                Should -Be @('Win11-LTSC-2024', 'WS2025-Std')
        }

        It 'shows the name an administrator gave it, not only its folder' {
            $win11 = @($script:view.Image | Where-Object { $_.Id -eq 'Win11-LTSC-2024' })[0]

            $win11.Display | Should -BeLike '*Windows 11 Enterprise LTSC 2024*'
        }

        It 'selects the one the document names' {
            $script:view.Selected | Should -BeExactly 'Win11-LTSC-2024'
        }

        It 'carries the rest of what the step declares' {
            $script:view.Index | Should -BeExactly '1'
            $script:view.Target | Should -BeExactly 'primary'
            $script:view.TimeoutMinutes | Should -BeExactly '60'
        }

        It 'names the command each control would run' {
            $script:view.OsCommandFormat | Should -BeLike "*Set-HDTStepProperty*-Property 'os'*"
            $script:view.IndexCommandFormat | Should -BeLike "*-Property 'index'*"
        }
    }

    Context 'a step naming an image the share no longer has' {

        BeforeAll {
            $gone = [string[]] @(@($script:line) | ForEach-Object {
                    if ($_ -eq '        os: Win11-LTSC-2024') { '        os: Win10-Deleted' } else { $_ }
                })

            $script:missing = Get-HDTConsoleImageChoice -Line $gone -Path $script:path `
                -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem
        }

        It 'still shows what the document says' {
            # A DROPDOWN THAT SILENTLY SELECTED THE FIRST ROW would rewrite the
            # deployment the next time anybody pressed save.
            $script:missing.Selected | Should -BeExactly 'Win10-Deleted'
        }

        It 'offers it as a row of its own, marked missing' {
            $row = @($script:missing.Image | Where-Object { $_.Id -eq 'Win10-Deleted' })

            @($row).Count | Should -Be 1
            $row[0].Missing | Should -BeTrue
            $row[0].Display | Should -BeLike '*not in this share*'
        }
    }

    Context 'a step of any other type' {

        It 'says the page does not belong to it' {
            $view = Get-HDTConsoleImageChoice -Line $script:line -Path $script:path `
                -Name 'Validate' -Workspace 'C:\ws' -FileSystem $script:fileSystem

            $view.IsImageStep | Should -BeFalse
        }
    }

    Context 'a share that cannot be read' {

        It 'opens anyway, with the document''s own value' {
            # THE EDITOR MUST OPEN. A share that is offline, renamed or not yet
            # created is the moment somebody most needs to look at the sequence.
            $view = Get-HDTConsoleImageChoice -Line $script:line -Path $script:path `
                -Name 'Install Operating System' -Workspace 'C:\nowhere' `
                -FileSystem (New-HDTFakeFileSystem)

            $view.IsImageStep | Should -BeTrue
            $view.Selected | Should -BeExactly 'Win11-LTSC-2024'
        }
    }
}

Describe 'what the window shows and what the file keeps' {

    # THE UI SHOWS THE NAME; THE YAML KEEPS THE ID. An id is what the engine
    # resolves and what a share is keyed on; a name is what a person recognises.
    # The dropdown binds Display and writes Id, so neither has to compromise.

    It 'shows the name alone, not the name with its folder bolted on' {
        $view = Get-HDTConsoleImageChoice -Line $script:line -Path $script:path `
            -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem

        $win11 = @($view.Image | Where-Object { $_.Id -eq 'Win11-LTSC-2024' })[0]

        $win11.Display | Should -BeExactly 'Windows 11 Enterprise LTSC 2024'
    }

    It 'falls back to the id for an image whose os.yaml names it nothing else' {
        $view = Get-HDTConsoleImageChoice -Line $script:line -Path $script:path `
            -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem

        # There is always something in the box: a share whose os.yaml carries no
        # name is a share whose folder name is the only thing anybody has.
        foreach ($row in @($view.Image)) { $row.Display | Should -Not -BeNullOrEmpty }
    }

    Context 'a step whose image is a variable' {

        BeforeAll {
            $script:byVariable = [string[]] @(@'
schemaVersion: 1
id: DEMO
name: image by variable
variables:
  HDTOSImage: Win11-LTSC-2024
steps:
  - group: Install
    steps:
      - name: Install Operating System
        type: ApplyImage
        os: "%HDTOSImage%"
        target: primary
'@ -split "`r?`n")

            $script:resolved = Get-HDTConsoleImageChoice -Line $script:byVariable -Path $script:path `
                -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem
        }

        It 'follows the variable to the image it names' {
            # A VARIABLE THERE IS LEGITIMATE - rules.yaml choosing an image per
            # model is a real pattern - so the page reads it rather than
            # reporting the reference as an image nobody has.
            $script:resolved.Selected | Should -BeExactly 'Win11-LTSC-2024'
        }

        It 'says the choice came through a variable, so nobody edits past it' {
            $script:resolved.Note | Should -BeLike '*%HDTOSImage%*'
        }

        It 'still writes the variable back, not the image it resolved to' {
            # THE FILE KEEPS WHAT THE AUTHOR WROTE. Resolving for display and
            # then saving the resolution would quietly delete the indirection
            # the sequence was built on.
            $script:resolved.Written | Should -BeExactly '%HDTOSImage%'
        }
    }
}

Describe 'the image index' {

    # AN INDEX IS A NUMBER INSIDE A WIM, and nobody remembers which. os.yaml
    # already carries the editions - index and name - because
    # Import-HDTOperatingSystem read them off the media, so the page offers them
    # instead of a box to type 1 into and hope.

    BeforeAll {
        $script:view = Get-HDTConsoleImageChoice -Line $script:line -Path $script:path `
            -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem
    }

    It 'offers the editions the selected image holds' {
        @($script:view.Edition | ForEach-Object { $_.Index }) | Should -Be @(1)
    }

    It 'shows the edition name beside its number' {
        @($script:view.Edition)[0].Display | Should -BeLike '*Windows 11 Enterprise LTSC*'
        @($script:view.Edition)[0].Display | Should -BeLike '*1*'
    }

    It 'selects the one the document names' {
        $script:view.Index | Should -BeExactly '1'
    }

    Context 'an index written as a variable' {

        BeforeAll {
            $script:byVariable = [string[]] @(@'
schemaVersion: 1
id: DEMO
name: index by variable
variables:
  HDTOSImage: Win11-LTSC-2024
  HDTOSImageIndex: 1
steps:
  - group: Install
    steps:
      - name: Install Operating System
        type: ApplyImage
        os: "%HDTOSImage%"
        index: "%HDTOSImageIndex%"
        target: primary
'@ -split "`r?`n")

            $script:resolved = Get-HDTConsoleImageChoice -Line $script:byVariable -Path $script:path `
                -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem
        }

        It 'follows it, so the box shows an edition rather than a token' {
            $script:resolved.Index | Should -BeExactly '1'
        }

        It 'still writes the variable back' {
            $script:resolved.IndexWritten | Should -BeExactly '%HDTOSImageIndex%'
        }
    }

    Context 'an image the share does not have' {

        It 'offers no editions rather than the wrong ones' {
            # THE EDITIONS BELONG TO AN IMAGE. Listing another image's would put
            # a number in the file that names something else entirely.
            $gone = [string[]] @(@($script:line) | ForEach-Object {
                    if ($_ -eq '        os: Win11-LTSC-2024') { '        os: Win10-Deleted' } else { $_ }
                })

            $view = Get-HDTConsoleImageChoice -Line $gone -Path $script:path `
                -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem

            @($view.Edition).Count | Should -Be 0
        }
    }
}

Describe 'an index the step does not declare' {

    It 'is 1, which is what the engine applies' {
        # A BLANK BOX BESIDE A LIST OF EDITIONS reads as "nothing chosen" rather
        # than "the usual one", and 1 is the first image in every WIM.
        $bare = [string[]] @(@'
schemaVersion: 1
id: DEMO
name: no index
steps:
  - group: Install
    steps:
      - name: Install Operating System
        type: ApplyImage
        os: Win11-LTSC-2024
        target: primary
'@ -split "`r?`n")

        $view = Get-HDTConsoleImageChoice -Line $bare -Path $script:path `
            -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem

        $view.Index | Should -BeExactly '1'
    }
}

Describe 'the destination' {

    # MDT CALLS IT Destination, and it is the step's target: which volume the
    # image is written to. 'primary' is the volume the partition step published
    # and is what nearly every sequence wants - it is never a guess at C:, which
    # in WinPE is frequently the content disk.
    #
    # THE ALTERNATIVES ARE VARIABLES, AND THEY ARE OFFERED WITH THEIR %% ON.
    # A box that only ever accepted 'primary' or a letter would make the useful
    # case - a sequence that publishes its own volume variable - something you
    # have to know the syntax for.

    It 'leads with the variable the OS volume actually is' {
        # 'primary' IS %HDTOSVolume% - Invoke-HDTApplyImageStep resolves it to
        # exactly that and refuses when it is unset. A magic word that means a
        # variable teaches nobody which variable, so the variable leads.
        $view = Get-HDTConsoleImageChoice -Line $script:line -Path $script:path `
            -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem

        @($view.Destination)[0] | Should -BeExactly '%HDTOSVolume%'
    }

    It 'still offers primary, because documents are full of the word' {
        $view = Get-HDTConsoleImageChoice -Line $script:line -Path $script:path `
            -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem

        @($view.Destination) | Should -Contain 'primary'
        @($view.Destination)[-1] | Should -BeExactly 'primary'
    }

    It "offers the engine's own published volume variables, with their percent signs" {
        $view = Get-HDTConsoleImageChoice -Line $script:line -Path $script:path `
            -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem

        @($view.Destination) | Should -Contain '%HDTOSVolume%'
        @($view.Destination) | Should -Contain '%HDTSystemVolume%'
    }

    It 'offers a variable the sequence publishes itself' {
        # A PARTITION TABLE THAT NAMES A VARIABLE has published one, and that is
        # exactly the volume somebody would want to apply an image to.
        $own = [string[]] @(@'
schemaVersion: 1
id: DEMO
name: own variable
steps:
  - group: Preinstall
    steps:
      - name: Format and Partition
        type: DiskPartition
        wipe: true
        partition:
          - name: Windows
            type: Primary
            size: remainder
            variable: HDTBuildVolume
  - group: Install
    steps:
      - name: Install Operating System
        type: ApplyImage
        os: Win11-LTSC-2024
        target: primary
'@ -split "`r?`n")

        $view = Get-HDTConsoleImageChoice -Line $own -Path $script:path `
            -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem

        @($view.Destination) | Should -Contain '%HDTBuildVolume%'
    }

    It 'lists each one once, however many steps publish it' {
        $view = Get-HDTConsoleImageChoice -Line $script:line -Path $script:path `
            -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem

        @($view.Destination).Count | Should -Be @($view.Destination | Sort-Object -Unique).Count
    }
}

Describe 'the editions follow the image, not the document' {

    # PICKING Server 2025 AND STILL BEING OFFERED WINDOWS 11'S EDITIONS is an
    # index that names something else entirely - and it is written to the file
    # by the same Apply. The list has to belong to the row, so the window can
    # repopulate it the moment the selection changes, without asking anything.

    It 'carries its own editions on every image row' {
        $view = Get-HDTConsoleImageChoice -Line $script:line -Path $script:path `
            -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem

        $server = @($view.Image | Where-Object { $_.Id -eq 'WS2025-Std' })[0]
        $win11 = @($view.Image | Where-Object { $_.Id -eq 'Win11-LTSC-2024' })[0]

        @($server.Edition | ForEach-Object { $_.Index }) | Should -Be @(2)
        @($win11.Edition | ForEach-Object { $_.Index }) | Should -Be @(1)
    }

    It 'names the edition on the row it belongs to' {
        $view = Get-HDTConsoleImageChoice -Line $script:line -Path $script:path `
            -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem

        $server = @($view.Image | Where-Object { $_.Id -eq 'WS2025-Std' })[0]

        @($server.Edition)[0].Display | Should -BeLike '*Windows Server 2025 Standard*'
    }

    It 'gives an image the share does not have no editions to offer' {
        $view = Get-HDTConsoleImageChoice -Line $script:line -Path $script:path `
            -Name 'Install Operating System' -Workspace 'C:\ws' -FileSystem $script:fileSystem

        # The missing row is a placeholder for what the document says; there is
        # no catalog behind it to read editions out of.
        foreach ($row in @($view.Image | Where-Object { $_.Missing })) {
            @($row.Edition).Count | Should -Be 0
        }
    }
}
