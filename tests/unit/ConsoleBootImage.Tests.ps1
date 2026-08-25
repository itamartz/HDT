# The WinPE window's state, worked out without a window.
#
# HDTBootImage.xaml is four tabs over one YAML block, and every control on it is
# the face of a command that already exists. What this file asserts is the
# QUESTION those tabs ask - what is ticked, what is listed, what each row would
# run - so that New-HDTConsoleHost's ShowBootImage stays what an adapter is
# allowed to be: load the markup, apply this by name, wire the buttons, show it.
#
# THE ADK IS INJECTED, NOT READ. Get-HDTAdkComponent needs an installed ADK and
# a registry; this command takes its output as a parameter, so the whole of the
# Features tab is testable on a machine with neither.

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

    $script:workspaceText = @'
schemaVersion: 1
id: HDT-LAB
name: HDT lab deployment share
deployRoot: \\HDT-HOST\HdtShare
bootImage:
  name: HDTPE_x64
  architecture: amd64
  language: en-us
  scratchSpaceMB: 512
  drivers: winpe-nic
  unattend: Unattend-PE.xml
  optionalComponents:
    - WinPE-WMI
    - WinPE-SecureStartup
  extraContent:
    - source: Tools\BGInfo
      destination: \Tools\BGInfo
    - source: Tools\TightVNC
      destination: \Tools\VNC
  startCommand:
    - X:\Tools\run.cmd
    - X:\Tools\BGInfo\bginfo64.exe /timer:0
'@

    $script:line = [string[]] @($script:workspaceText -split "`r?`n")

    # The shape Get-HDTAdkComponent returns, hand-built so no ADK is needed -
    # Description included, because that is the shape as of the description
    # table. A fixture missing it would pass here and throw under StrictMode
    # against the real command.
    $script:component = @(
        [pscustomobject] @{ Name = 'WinPE-WMI'; CabPath = 'X:\WinPE-WMI.cab'; SizeBytes = [long] 2097152
            LanguagePack = [string[]] @('en-us'); Requires = [string[]] @(); Required = $true; Declared = $true
            Description = 'WMI providers for system diagnostics - the query surface most gather scripts use.'
        }
        [pscustomobject] @{ Name = 'WinPE-PowerShell'; CabPath = 'X:\WinPE-PowerShell.cab'; SizeBytes = [long] 31457280
            LanguagePack = [string[]] @('en-us'); Requires = [string[]] @('WinPE-WMI', 'WinPE-NetFx'); Required = $true; Declared = $true
            Description = 'Windows PowerShell. No remoting and no ISE, and PowerShell 2.0 is not supported.'
        }
        [pscustomobject] @{ Name = 'WinPE-SecureStartup'; CabPath = 'X:\WinPE-SecureStartup.cab'; SizeBytes = [long] 1048576
            LanguagePack = [string[]] @('en-us'); Requires = [string[]] @('WinPE-WMI'); Required = $false; Declared = $true
            Description = 'BitLocker and the TPM - the tools, the WMI classes and the TPM driver.'
        }
        [pscustomobject] @{ Name = 'WinPE-HTA'; CabPath = 'X:\WinPE-HTA.cab'; SizeBytes = [long] 37449728
            LanguagePack = [string[]] @('en-us'); Requires = [string[]] @(); Required = $false; Declared = $false
            Description = 'HTML Applications - GUI tools written in HTML and script.'
        }
    )

    # What Get-HDTSelectionProfile returns for the share, injected for the same
    # reason the ADK list is: reading it needs folders on disk.
    $script:selectionProfile = @(
        [pscustomobject] @{
            Id = 'boot-critical'; Name = 'Boot critical - Dell and HP'
            Include = [string[]] @('Drivers\WinPE\Dell WinPE 11 x64', 'Drivers\WinPE\HP WinPE 11 x64')
            IsBuiltIn = $false; Path = 'C:\HDTLab\Share\Control\selection-profiles.yaml'
        }
        [pscustomobject] @{
            Id = 'nothing'; Name = 'Nothing'; Include = [string[]] @()
            IsBuiltIn = $true; Path = ''
        }
    )

    $script:view = Get-HDTConsoleBootImageSetting -Line $script:line `
        -Path 'C:\HDTLab\Share\workspace.yaml' -Component $script:component `
        -SelectionProfile $script:selectionProfile
}

Describe 'Get-HDTConsoleBootImageSetting' {

    It 'is exported by Hephaestus' {
        Get-Command -Name 'Get-HDTConsoleBootImageSetting' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    Context 'the banner' {

        It 'names the image and the document it is configured in' {
            # BOTH SHARES IN THIS LAB HOLD AN HDTPE_x64. Two windows open at once
            # would otherwise be identical over different files, and the
            # difference only shows at the moment one of them saves.
            $script:view.Title | Should -BeLike '*HDTPE_x64*'
            $script:view.DocumentPath | Should -BeExactly 'C:\HDTLab\Share\workspace.yaml'
        }
    }

    Context 'the General tab' {

        It 'reads <Property> as <Expected>' -ForEach @(
            @{ Property = 'Name'; Expected = 'HDTPE_x64' }
            @{ Property = 'Architecture'; Expected = 'amd64' }
            @{ Property = 'Language'; Expected = 'en-us' }
            @{ Property = 'Unattend'; Expected = 'Unattend-PE.xml' }
        ) {
            [string] $script:view.General.$Property | Should -BeExactly $Expected
        }

        It 'gives the scratch space as text, because the combo matches on its Tag' {
            # SelectedValuePath="Tag" compares strings. An int here selects
            # nothing and the box comes up blank on a document that set it.
            $script:view.General.ScratchSpaceMB | Should -BeOfType [string]
            $script:view.General.ScratchSpaceMB | Should -BeExactly '512'
        }

        It 'gives the boot prompt as a boolean, because the control is a tick box' {
            # Every other value on this tab is a string, because the controls
            # showing them are text and combo boxes. CheckBox.IsChecked takes a
            # boolean, and a string here would tick the box for 'false'.
            $script:view.General.PromptForKey | Should -BeOfType [bool]
        }

        It 'defaults the boot prompt off, which is what every image was built with' {
            # "Press any key to boot from CD or DVD" is efisys.bin's doing and
            # HDT has always written efisys_noprompt.bin: a machine nobody is
            # standing at cannot answer a keypress.
            $script:view.General.PromptForKey | Should -BeFalse
        }

        It 'has a control on the page for it' {
            # THE VIEW MODEL AND THE MARKUP HAVE TO AGREE ON THE NAME, and this
            # is the file that would otherwise go stale in silence: the host
            # finds the control by name, and a rename here is a tick box that
            # quietly stops loading and saving.
            $xamlPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/Console/HDTBootImage.xaml'
            $xaml = [xml] (Get-Content -LiteralPath $xamlPath -Raw)

            @($xaml.SelectNodes('//*[@*[local-name()="Name"]="HDTBootImagePromptForKeyCheck"]')).Count |
                Should -Be 1
        }

        It 'carries the Set-HDTWorkspaceProperty call Apply would run' {
            $script:view.General.Command | Should -BeLike 'Set-HDTWorkspaceProperty*'
            $script:view.General.Command | Should -BeLike '*-BootImageName*'
        }

        It 'carries the Set-HDTBootImageUnattend call the answer file box would run' {
            $script:view.General.UnattendCommandFormat |
                Should -BeLike 'Set-HDTBootImageUnattend*-Path ''{0}''*'
        }

        It 'carries the New-HDTBootImageUnattend call the template button would run' {
            # A SHARE WITH NO ANSWER FILE IS THE ORDINARY CASE, and the box next
            # to it takes a path to a file that has to already exist. The
            # template button is where the file comes from.
            $script:view.General.UnattendTemplateCommandFormat |
                Should -BeLike 'New-HDTBootImageUnattend*-Workspace ''{0}''*'
        }

        It 'names the share the answer file is written to and read from' {
            # THE DOCUMENT'S FOLDER IS THE SHARE. Both the template button and
            # the Open button need it: unattend is stored relative to the root,
            # and neither a file picker nor a text box hands back a root.
            $script:view.WorkspaceRoot | Should -BeExactly 'C:\HDTLab\Share'
        }
    }

    Context 'the Features tab' {

        It 'lists every component the ADK offers, not only the declared ones' {
            @($script:view.Component).Count | Should -Be 4
        }

        It 'ticks a component the document declares' {
            @($script:view.Component | Where-Object { $_.Name -eq 'WinPE-SecureStartup' })[0].Declared |
                Should -BeTrue
        }

        It 'leaves an undeclared component unticked' {
            @($script:view.Component | Where-Object { $_.Name -eq 'WinPE-HTA' })[0].Declared |
                Should -BeFalse
        }

        It 'ticks a required component and refuses to let it be unticked' {
            # WinPE-PowerShell is not in this document's optionalComponents list
            # and is applied to every image anyway. Shown ticked and disabled
            # rather than hidden: an administrator looking for PowerShell has to
            # find it and see that it is already there.
            $row = @($script:view.Component | Where-Object { $_.Name -eq 'WinPE-PowerShell' })[0]

            $row.Declared | Should -BeTrue
            $row.CanChange | Should -BeFalse
        }

        It 'lets an optional component be unticked' {
            @($script:view.Component | Where-Object { $_.Name -eq 'WinPE-HTA' })[0].CanChange |
                Should -BeTrue
        }

        It 'gives each row a size a person reads rather than a byte count' {
            @($script:view.Component | Where-Object { $_.Name -eq 'WinPE-HTA' })[0].SizeText |
                Should -BeLike '*35.7 MB*'
        }

        It 'says what the component is for, which the ADK does not' {
            # WinPE_OCs\ is cabs and nothing else. Without the table HDT ships,
            # this column is blank and the row reads 'WinPE-Dot3Svc  1.3 MB'.
            @($script:view.Component | Where-Object { $_.Name -eq 'WinPE-WMI' })[0].Description |
                Should -BeLike '*WMI*'
        }

        It 'reads as what it does, then what comes with it' {
            # ONE COLUMN, IN THAT ORDER. The description answers "what is this";
            # the suffix answers "and what else does ticking it drag in". They
            # are read together by somebody deciding, and a second column would
            # put the second answer off the edge of a narrow window.
            $row = @($script:view.Component | Where-Object { $_.Name -eq 'WinPE-PowerShell' })[0]

            $row.DetailText | Should -BeLike '*PowerShell*'
            $row.DetailText | Should -BeLike '*(*WinPE-WMI*)'
        }

        It 'gives a component with nothing to require the description alone' {
            $row = @($script:view.Component | Where-Object { $_.Name -eq 'WinPE-HTA' })[0]

            $row.DetailText | Should -BeExactly $row.Description
        }

        It 'says on the row what a component needs beside it' {
            # WinPE-PowerShell without WinPE-WMI is a build that fails after two
            # and a half minutes. Saying so on the row costs nothing.
            @($script:view.Component | Where-Object { $_.Name -eq 'WinPE-PowerShell' })[0].RequiresText |
                Should -BeLike '*WinPE-WMI*'
        }

        It 'totals only what is ticked, because the cost of this tab is the WIM' {
            # WMI 2 MB + PowerShell 30 MB + SecureStartup 1 MB = 33 MB. HTA is
            # not ticked and must not be counted.
            $script:view.SelectedSizeText | Should -BeLike '*33.0 MB*'
            $script:view.SelectedSizeText | Should -BeLike '*3 of 4*'
        }

        It 'says what the document itself declares, apart from what is ticked' {
            # A WINDOW CANNOT TELL A REAL TICK FROM WPF BUILDING A ROW. A
            # TabControl does not realise an unselected tab, so every checkbox
            # on the Features tab is created - and raises Checked - the first
            # time somebody clicks it, which would re-add every component that
            # was already there. Add-HDTBootImageComponent refuses a duplicate,
            # so that is not a silent bug: it is the window dying.
            $script:view.DeclaredName | Should -Contain 'WinPE-SecureStartup'
            $script:view.DeclaredName | Should -Not -Contain 'WinPE-HTA'

            # WinPE-PowerShell is applied to every image but is NOT in this
            # document, and that difference is the whole point of this property:
            # Declared says what the tick shows, this says what a Remove would
            # actually have to remove.
            $script:view.DeclaredName | Should -Not -Contain 'WinPE-PowerShell'
        }

        It 'carries the call each row would run when it is ticked or unticked' {
            $row = @($script:view.Component | Where-Object { $_.Name -eq 'WinPE-HTA' })[0]

            $row.AddCommand | Should -BeLike 'Add-HDTBootImageComponent*WinPE-HTA*'
            $row.RemoveCommand | Should -BeLike 'Remove-HDTBootImageComponent*WinPE-HTA*'
        }
    }

    Context 'the Drivers tab' {

        It 'reads the driver group' {
            $script:view.Driver.Group | Should -BeExactly 'winpe-nic'
        }

        It 'offers the groups the share has, with "no drivers" first' {
            # A LIST, NOT A BOX YOU TYPE INTO: a group is a folder under
            # Drivers\, so the legal answers are knowable, and a typo builds an
            # image with no drivers in it that nobody notices until the bench.
            #
            # AND THE EMPTY ANSWER IS AN ENTRY. "No drivers" is a real choice,
            # and a list whose only way to say it is to clear the selection is a
            # list you cannot say it in.
            @($script:view.Driver.Choice)[0].Name | Should -BeExactly ''
            @($script:view.Driver.Choice)[0].Display | Should -BeLike '*none*'

            @($script:view.Driver.Choice | ForEach-Object { $_.Name }) | Should -Contain 'winpe-nic'
            @($script:view.Driver.Choice | ForEach-Object { $_.Name }) | Should -Contain 'boot-critical'
        }

        It 'keeps a declared profile the share no longer has, and says so' {
            # A RENAMED PROFILE MUST NOT READ AS "no drivers". The document still
            # says winpe-nic; a list that quietly dropped it would show the
            # empty row selected, and the next Save would make that true.
            #
            # IT SAYS "not a selection profile", NOT "not on the share": this key
            # used to name a folder under Drivers\ and an old share still does,
            # which the build still honours. Calling that missing would be the
            # window telling somebody their working share is broken.
            $view = Get-HDTConsoleBootImageSetting -Line $script:line `
                -Path 'C:\HDTLab\Share\workspace.yaml' -Component $script:component `
                -SelectionProfile @([pscustomobject] @{
                        Id = 'boot-critical'; Name = 'Boot critical'; Include = [string[]] @('Drivers')
                        IsBuiltIn = $false; Path = 'C:\S\Control\selection-profiles.yaml'
                    })

            $row = @($view.Driver.Choice | Where-Object { $_.Name -eq 'winpe-nic' })

            @($row).Count | Should -Be 1
            $row[0].Display | Should -BeLike '*not a selection profile*'
        }

        # THE VALUE IS THE ID AND THE LABEL IS THE NAME. A picker showing
        # 'boot-critical' where 'Boot critical - Dell and HP' was available is a
        # picker that made an administrator read a slug.
        It 'offers the profile by name and answers with its id' {
            $row = @($script:view.Driver.Choice | Where-Object { $_.Name -eq 'boot-critical' })

            @($row).Count | Should -Be 1
            $row[0].Display | Should -BeExactly 'Boot critical - Dell and HP'
        }

        It 'marks a built-in as one, because the editor cannot rename it' {
            $row = @($script:view.Driver.Choice | Where-Object { $_.Name -eq 'nothing' })

            $row[0].Display | Should -BeLike '*built in*'
        }

        It 'offers only "no drivers" on a share with none imported' {
            $view = Get-HDTConsoleBootImageSetting -Line ([string[]] @(
                    'schemaVersion: 1'; 'id: X'; 'name: Y'; 'deployRoot: \\a\b')) `
                -Path 'C:\HDTLab\Share\workspace.yaml' -Component @() -SelectionProfile @()

            @($view.Driver.Choice).Count | Should -Be 1
            @($view.Driver.Choice)[0].Name | Should -BeExactly ''
        }

        It 'carries the Apply and the Clear calls' {
            $script:view.Driver.ApplyCommandFormat | Should -BeLike 'Set-HDTBootImageDriver*-Name ''{0}''*'
            $script:view.Driver.ClearCommand | Should -BeLike 'Set-HDTBootImageDriver*-Clear*'
        }
    }

    Context 'the Customisations tab' {

        It 'lists the extra content in the order the document declares it' {
            @($script:view.Content).Count | Should -Be 2
            $script:view.Content[0].Source | Should -BeExactly 'Tools\BGInfo'
            $script:view.Content[0].Destination | Should -BeExactly '\Tools\BGInfo'
            $script:view.Content[1].Destination | Should -BeExactly '\Tools\VNC'
        }

        It 'carries the Remove call for a content row, keyed on the destination' {
            # Remove-HDTBootImageContent takes the DESTINATION - it is what makes
            # a row unique inside the image, and two sources can land in one
            # place.
            $script:view.Content[1].RemoveCommand |
                Should -BeLike 'Remove-HDTBootImageContent*-Destination ''\Tools\VNC''*'
        }

        It 'carries the Add format the two boxes fill in' {
            $script:view.AddContentCommandFormat |
                Should -BeLike 'Add-HDTBootImageContent*-Source ''{0}''*-Destination ''{1}''*'
        }

        It 'lists the start commands in the order startnet.cmd will run them' {
            @($script:view.StartCommand).Count | Should -Be 2
            $script:view.StartCommand[0].Text | Should -BeExactly 'X:\Tools\run.cmd'
            $script:view.StartCommand[1].Text | Should -BeLike '*bginfo64.exe*'
        }

        It 'holds the line the document holds, and does not project startnet.cmd' {
            # TWO FILES, AND THIS ONE DESCRIBES workspace.yaml. startnet.cmd is
            # generated from it at build time and carries `call` in front of a
            # batch file so cmd.exe returns - a rule that belongs to
            # Get-HDTStartnetScript, not to a view of the authored document.
            # Publishing it here put text on the window that appears in no file
            # the window can save.
            $script:view.StartCommand[0].Text | Should -BeExactly 'X:\Tools\run.cmd'
            $script:view.StartCommand[0].PSObject.Properties['Effective'] | Should -BeNullOrEmpty
        }

        It 'carries the Remove call for a start command row' {
            $script:view.StartCommand[0].RemoveCommand |
                Should -BeLike 'Remove-HDTBootImageStartCommand*-Command ''X:\Tools\run.cmd''*'
        }

        It 'carries the Add format, and the one that puts it first' {
            $script:view.AddStartCommandFormat |
                Should -BeLike 'Add-HDTBootImageStartCommand*-Command ''{0}''*'
            $script:view.AddStartCommandFirstFormat | Should -BeLike '*-First*'
        }
    }

    Context 'a workspace.yaml with no bootImage block at all' {

        BeforeAll {
            # What New-HDTWorkspace writes: no bootImage block, because an
            # omitted setting takes the engine default and a copied-out default
            # goes stale. The window still has to open on it.
            $script:bare = Get-HDTConsoleBootImageSetting -Line ([string[]] @(
                    'schemaVersion: 1'
                    'id: HDT-LAB'
                    'name: HDT lab deployment share'
                    'deployRoot: \\HDT-HOST\HdtShare'
                )) -Path 'C:\HDTLab\Share\workspace.yaml' -Component $script:component
        }

        It 'opens, and shows the engine defaults rather than empty boxes' {
            $script:bare.General.Architecture | Should -Not -BeNullOrEmpty
            $script:bare.General.Language | Should -Not -BeNullOrEmpty
        }

        It 'has no content, no start commands and no answer file' {
            @($script:bare.Content).Count | Should -Be 0
            @($script:bare.StartCommand).Count | Should -Be 0
            $script:bare.General.Unattend | Should -BeExactly ''
        }

        It 'still ticks the components the engine applies to every image' {
            @($script:bare.Component | Where-Object { $_.Declared }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'a document that will not parse' {

        It 'throws rather than showing a window over a file it did not understand' {
            # The browser's row already says the document is broken. A window
            # that opened anyway would offer to Save over it.
            { Get-HDTConsoleBootImageSetting -Line ([string[]] @('bootImage:', '  name: [unclosed')) `
                    -Path 'C:\ws\workspace.yaml' -Component @() } | Should -Throw
        }
    }
}

Describe 'the Certificates tab' {

    # A ROOT CA AND A MACHINE CERTIFICATE ARE DIFFERENT ANIMALS and the tab
    # keeps them apart: a list you add to and remove from, and one file with one
    # password. What each row would run is on the row, as everywhere else.

    BeforeAll {
        $script:certText = @'
schemaVersion: 1
id: HDT-LAB
name: lab share
deployRoot: \HDT-HOST\HdtShare
bootImage:
  name: HDTPE_x64
  architecture: amd64
  rootCertificates:
    - Certs\contoso-root.cer
    - Certs\contoso-issuing.cer
  clientCertificate: Certs\winpe-802.1x.pfx
'@

        $script:certLine = [string[]] @($script:certText -split "`r?`n")

        $script:certView = Get-HDTConsoleBootImageSetting -Line $script:certLine `
            -Path 'C:\HDTLab\Share\workspace.yaml' -Component @() -SelectionProfile @() `
            -HasCertificatePassword $true
    }

    It 'lists the certificate authorities the document trusts' {
        @($script:certView.Certificate).Count | Should -Be 2
        [string] @($script:certView.Certificate)[0].Path | Should -BeExactly 'Certs\contoso-root.cer'
    }

    It 'says which store each row lands in' {
        # THE TWO ROWS ON THE GENERAL TAB DIFFER BY STORE AND BY NOTHING ELSE
        # AN EYE CAN SEE - two path boxes, one above the other. The window says
        # so in its hint; this is the same fact, on the data, so a caller that
        # is not a window can tell them apart too.
        [string] @($script:certView.Certificate)[0].Store | Should -BeExactly 'Root'
    }

    It 'carries the Remove call on the row' {
        [string] @($script:certView.Certificate)[0].RemoveCommand |
            Should -BeLike 'Remove-HDTBootImageCertificate*Certs\contoso-root.cer*'
    }

    It 'counts what is trusted, in one line under the box' {
        # THE BOX SHOWS ONE ROW AT A TIME. A chain is a root AND the subordinate
        # that issued the certificate, and an administrator has to be able to
        # see that both are there without opening the drop-down.
        [string] $script:certView.CertificateSummaryText | Should -BeLike '*2*'
    }

    It 'says so plainly when none is trusted' {
        $bare = Get-HDTConsoleBootImageSetting -Line $script:line `
            -Path 'C:\HDTLab\Share\workspace.yaml' -Component @() -SelectionProfile @()

        [string] $bare.CertificateSummaryText | Should -BeLike '*no certificate authorities*'
    }

    It 'carries the Add format' {
        $script:certView.AddCertificateCommandFormat | Should -BeLike 'Add-HDTBootImageCertificate*-Path ''{0}''*'
    }

    It 'reads the machine certificate and the calls that change it' {
        [string] $script:certView.ClientCertificate.Path | Should -BeExactly 'Certs\winpe-802.1x.pfx'
        $script:certView.ClientCertificate.ApplyCommandFormat |
            Should -BeLike 'Set-HDTBootImageClientCertificate*-Path ''{0}''*'
        $script:certView.ClientCertificate.ClearCommand |
            Should -BeLike 'Set-HDTBootImageClientCertificate*-Clear*'
    }

    It 'says whether a password has been stored for it' {
        # A .pfx NAMED WITH NO PASSWORD IS A BUILD Update-HDTBootImage REFUSES,
        # so the window has to be able to say so before anybody presses Update.
        $script:certView.ClientCertificate.HasPassword | Should -BeTrue

        $without = Get-HDTConsoleBootImageSetting -Line $script:certLine `
            -Path 'C:\HDTLab\Share\workspace.yaml' -Component @() -SelectionProfile @() `
            -HasCertificatePassword $false

        $without.ClientCertificate.HasPassword | Should -BeFalse
        [string] $without.ClientCertificate.Warning | Should -Not -BeNullOrEmpty
    }

    It 'says nothing is wrong when no certificate is named at all' {
        $bare = Get-HDTConsoleBootImageSetting -Line $script:line `
            -Path 'C:\HDTLab\Share\workspace.yaml' -Component @() -SelectionProfile @()

        @($bare.Certificate).Count | Should -Be 0
        [string] $bare.ClientCertificate.Path | Should -BeExactly ''
        [string] $bare.ClientCertificate.Warning | Should -BeExactly ''
    }

    It 'carries the password call, which names the share and not the password' {
        $script:certView.ClientCertificate.PasswordCommandFormat |
            Should -BeLike 'Set-HDTBootImageCertificatePassword*-WorkspaceRoot ''{0}''*'

        $script:certView.ClientCertificate.PasswordCommandFormat | Should -Not -BeLike '*{1}*'
    }
}

Describe 'the time zone row' {

    # WinPE'S ANSWER FILE CANNOT SET A TIME ZONE, so this row is not a duplicate
    # of anything on the answer file line above it: it is what puts tzutil into
    # startnet.cmd, and what the deployed machine's unattend inherits.

    BeforeAll {
        # INJECTED, like the ADK list and the driver groups. Windows adds time
        # zones, so reading them here would make this suite's result depend on
        # how recently the machine running it was patched.
        $script:zone = @(
            [pscustomobject] @{ Id = 'UTC'; Display = '(UTC) Coordinated Universal Time'; BaseUtcOffset = '00:00:00' }
            [pscustomobject] @{ Id = 'Israel Standard Time'; Display = '(UTC+02:00) Jerusalem'; BaseUtcOffset = '02:00:00' }
        )

        $script:zoneLine = [string[]] @(($script:workspaceText + "`n  timeZone: Israel Standard Time") -split "`r?`n")

        $script:zoneView = Get-HDTConsoleBootImageSetting -Line $script:zoneLine `
            -Path 'C:\HDTLab\Share\workspace.yaml' -Component @() -SelectionProfile @() -TimeZone $script:zone
    }

    It 'reads what the document names' {
        [string] $script:zoneView.TimeZone.Id | Should -BeExactly 'Israel Standard Time'
    }

    It 'offers every zone it was given, with the hardware clock first' {
        # "Leave it alone" IS A REAL CHOICE and it is what every image built
        # before this did, so it is a row rather than an empty selection.
        @($script:zoneView.TimeZone.Choice).Count | Should -Be 3
        [string] @($script:zoneView.TimeZone.Choice)[0].Id | Should -BeExactly ''
    }

    It 'keeps a zone the document names that this machine has never heard of' {
        # A share edited on one machine and built on another. Dropping it would
        # make the window read as 'no time zone' and a Save would make that true.
        $strange = [string[]] @(($script:workspaceText + "`n  timeZone: Mars Standard Time") -split "`r?`n")

        $view = Get-HDTConsoleBootImageSetting -Line $strange -Path 'C:\HDTLab\Share\workspace.yaml' `
            -Component @() -SelectionProfile @() -TimeZone $script:zone

        [string] $view.TimeZone.Id | Should -BeExactly 'Mars Standard Time'
        @($view.TimeZone.Choice | Where-Object { $_.Id -eq 'Mars Standard Time' }).Count | Should -Be 1
    }

    It 'carries the calls Save would run' {
        $script:zoneView.TimeZone.ApplyCommandFormat | Should -BeLike 'Set-HDTBootImageTimeZone*-Name ''{0}''*'
        $script:zoneView.TimeZone.ClearCommand | Should -BeLike 'Set-HDTBootImageTimeZone*-Clear*'
    }

    It 'says what it costs to leave it alone' {
        # THE ROW HAS TO SAY WHY IT MATTERS. WinPE on the hardware clock stamps
        # its logs hours away from the machine it just built.
        [string] $script:zoneView.TimeZone.Hint | Should -Not -BeNullOrEmpty
    }
}

Describe 'the Bootstrap tab' {

    # MDT'S Bootstrap.ini IS THE FILE WinPE READS BEFORE IT HAS A SHARE: where
    # the share is, who to sign in as, and whether to ask. HDT's equivalent is
    # bootstrap.json, written into X:\HDT\ by Update-HDTBootImage - so unlike
    # MDT's it is GENERATED, and editing it as text would be editing something
    # the next build overwrites.
    #
    # THIS TAB IS THEREFORE THE FACTS IT IS BUILT FROM, not the file. Same
    # information, same place on the window, edited through the commands that
    # own those keys - which is the only shape that survives a rebuild.

    BeforeAll {
        $script:bootstrapSetting = Get-HDTConsoleBootImageSetting -Line $script:line -Path 'C:\HDTLab\Share\workspace.yaml' `
            -Component $script:component -SelectionProfile $script:selectionProfile
    }

    It 'carries the share name and where clients reach it' {
        $script:bootstrapSetting.Bootstrap.ShareName | Should -BeExactly 'HDT lab deployment share'
        $script:bootstrapSetting.Bootstrap.DeployRoot | Should -BeExactly '\\HDT-HOST\HdtShare'
    }

    It 'shows the workspace id, which no command here may change' {
        # It is carried into every boot image and written into log and artifact
        # names. Changing it after a share has produced anything leaves
        # artifacts that no longer agree with the share that made them, which is
        # why Set-HDTWorkspaceProperty has no -Id.
        $script:bootstrapSetting.Bootstrap.WorkspaceId | Should -BeExactly 'HDT-LAB'
    }

    It 'names the provider the deployRoot implies, rather than asking' {
        # Update-HDTBootImage decides it exactly this way: a UNC deployRoot is
        # Smb, anything else is Local. A second question on the window would be
        # a second place for the two to disagree.
        $script:bootstrapSetting.Bootstrap.Provider | Should -BeExactly 'Smb'
    }

    It 'says the technician will be asked when no credential is stored' {
        # A UNC share with no embedded credential turns promptForCredential on
        # at build time and the payload asks - LiteTouch's behaviour, and worth
        # saying out loud because the two images behave very differently in
        # front of somebody.
        $script:bootstrapSetting.Bootstrap.HasCredential | Should -BeFalse
        $script:bootstrapSetting.Bootstrap.PromptForCredential | Should -BeTrue
    }

    It 'writes the sentences the window shows, so the host composes no prose' {
        # "THE QUERY, AND ONLY ASSIGNMENT AFTER IT" is the rule ShowBootImage
        # states about itself. A host that built 'Provider: Smb' out of a
        # property would be computing something, and the next window to want the
        # same sentence would build it slightly differently.
        $script:bootstrapSetting.Bootstrap.ProviderText | Should -Not -BeNullOrEmpty
        $script:bootstrapSetting.Bootstrap.PromptText | Should -Not -BeNullOrEmpty
        $script:bootstrapSetting.Bootstrap.CredentialText | Should -Not -BeNullOrEmpty
    }

    It 'says nobody is stored rather than showing an empty box' {
        # An empty field beside "Sign in as" reads as a window that failed to
        # load, not as a share that has no credential.
        $script:bootstrapSetting.Bootstrap.CredentialText | Should -BeLike '*not set*'
    }

    It 'runs the command that owns those keys' {
        $script:bootstrapSetting.Bootstrap.Command |
            Should -BeLike 'Set-HDTWorkspaceProperty -Line $line*'
    }

    It 'asks for the password rather than carrying one' {
        # The same rule the certificate password follows: nothing on a window
        # and nothing in an echoed command is ever a secret in clear text.
        $script:bootstrapSetting.Bootstrap.CredentialCommandFormat | Should -BeLike '*Get-Credential*'
        $script:bootstrapSetting.Bootstrap.CredentialCommandFormat | Should -Not -BeLike '*-Password *'
    }

    Context 'a share that states a credential and a log level' {

        BeforeAll {
            $script:statedLine = [string[]] @(
                'schemaVersion: 1'
                'id: HDT-LOCAL'
                'name: Build host share'
                'deployRoot: C:\HDTLab\Share'
                'logLevel: Debug'
                'credential:'
                '  username: LAB\svc-hdt'
                'bootImage:'
                '  name: HDTPE_x64'
            )

            $script:stated = Get-HDTConsoleBootImageSetting -Line $script:statedLine -Path 'C:\HDTLab\Share\workspace.yaml' `
                -Component $script:component -SelectionProfile $script:selectionProfile
        }

        It 'shows the user it will sign in as' {
            $script:stated.Bootstrap.CredentialUser | Should -BeExactly 'LAB\svc-hdt'
            $script:stated.Bootstrap.HasCredential | Should -BeTrue
        }

        It 'does not claim it will prompt when it has somebody to be' {
            $script:stated.Bootstrap.PromptForCredential | Should -BeFalse
        }

        It 'shows the user it will sign in as in the sentence too' {
            $script:stated.Bootstrap.CredentialText | Should -BeExactly 'LAB\svc-hdt'
        }

        It 'shows the log level the document states' {
            $script:stated.Bootstrap.LogLevel | Should -BeExactly 'Debug'
        }

        It 'calls a local deployRoot Local' {
            $script:stated.Bootstrap.Provider | Should -BeExactly 'Local'
        }
    }
}

Describe 'the Windows PE window, as something to type into' {

    # WHITE MEANS TYPE HERE, on every window in this console. The detail pane
    # paints its typeable boxes with the panel brush and washes the rest out
    # with HDTFieldBrush, and the sequence editor does the same - but this
    # window's TextBox style painted EVERY box with the wash, so the image name
    # and the language read as facts about the image rather than as the two
    # things an administrator most often changes.
    #
    # THE WASH GOT DARKER AND THAT IS WHAT EXPOSED IT. HDTFieldBrush was #FAFAFA
    # - invisible against white - so nobody could see which rule this window was
    # following. It is #EDEDED now, and this window was following the wrong one.

    BeforeAll {
        $script:pePath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/Console/HDTBootImage.xaml'
        $script:peXaml = [System.IO.File]::ReadAllText($script:pePath)
        $script:peDocument = [xml] $script:peXaml
    }

    It 'paints a box that takes typing with the panel brush, not the read-only wash' {
        $style = @($script:peDocument.SelectNodes("//*[local-name()='Style']") |
                Where-Object { $_.GetAttribute('TargetType') -eq 'TextBox' })

        @($style).Count | Should -BeGreaterThan 0

        foreach ($current in $style) {
            $background = @($current.SelectNodes("*[local-name()='Setter']") |
                    Where-Object { $_.GetAttribute('Property') -eq 'Background' })

            foreach ($setter in $background) {
                [string] $setter.GetAttribute('Value') | Should -BeExactly '{DynamicResource HDTPanelBrush}'
            }
        }
    }

    It 'never sets a drop-down Background without making it take effect' {
        # TRIED AND MEASURED, NOT ASSUMED: a Setter on its own left the box
        # exactly as grey as before, because WPF's NON-EDITABLE ComboBox draws
        # its own chrome and ignores Background. A test that asserted the Setter
        # would have passed while the screen disagreed - which is the one kind
        # of test this repository must not have.
        #
        # AND "THE ARROW SAYS IT IS A CHOOSER" TURNED OUT NOT TO BE ENOUGH. The
        # dropdown measured #EAEAEA against a #EDEDED read-only wash and a
        # #FFFFFF editable box beside it, and it was reported as looking
        # disabled by somebody using the window.
        #
        # IsEditable IS WHAT MAKES THE BACKGROUND REAL: it puts a text box in
        # the closed control, which paints it - #FFFFFF, measured the same way -
        # and IsReadOnly keeps it from being typed into, so it still behaves
        # exactly like a chooser. So the rule is no longer "never set it": it is
        # "never set it and leave it doing nothing".
        $style = @($script:peDocument.SelectNodes("//*[local-name()='Style']") |
                Where-Object { $_.GetAttribute('TargetType') -eq 'ComboBox' })

        @($style).Count | Should -BeGreaterThan 0

        foreach ($current in $style) {
            $setter = @($current.SelectNodes("*[local-name()='Setter']"))

            $background = @($setter | Where-Object { $_.GetAttribute('Property') -eq 'Background' })
            if (@($background).Count -eq 0) { continue }

            @($setter | Where-Object {
                    $_.GetAttribute('Property') -eq 'IsEditable' -and $_.GetAttribute('Value') -eq 'True'
                }) | Should -Not -BeNullOrEmpty -Because 'a Background on a stock ComboBox template does nothing'

            @($setter | Where-Object {
                    $_.GetAttribute('Property') -eq 'IsReadOnly' -and $_.GetAttribute('Value') -eq 'True'
                }) | Should -Not -BeNullOrEmpty -Because 'an editable chooser must not become a box somebody types into'
        }
    }

    It 'still declares the wash, because something read-only may want it' {
        $script:peXaml | Should -Match 'x:Key="HDTFieldBrush"'
    }
}


}
