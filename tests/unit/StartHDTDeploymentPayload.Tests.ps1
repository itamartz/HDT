# src/Hephaestus/Payload/Start-HDTDeployment.ps1 - THE WinPE ENTRY POINT, what
# startnet.cmd runs (05-04 puts it in the image).
#
# IT IS TESTED BY PARSING AND INSPECTING IT, exactly as Start-HDTResume.ps1 and
# phase 04's Start-HDTLabDeployment.ps1 are. Running it for real means a booted
# machine to power off, which is what tests/e2e is.
#
# THE ASSERTION THIS FILE EXISTS FOR: the entry point contains NO DEPLOYMENT
# LOGIC. Phase 05's exit criterion is that a machine deploys ITSELF from a boot
# image, and an entry point that partitioned a disk or applied an image itself
# would make that claim a lie while still producing a deployed machine - and
# nobody would notice, because the machine would deploy.
#
# AND A SECOND ONE, WHICH IS THE ONE THAT WOULD HAVE COST 05-05 A WHOLE RUN: it
# assumes exactly one drive letter, and it is the one WinPE guarantees. SPIKES
# S9.1 measured WinPE handing the CONTENT DISK the letter the developer's
# machine calls its system drive, and the RAM disk X:. Anything else this file
# needs is DISCOVERED.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:payloadPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Payload/Start-HDTDeployment.ps1'

    $script:parseError = $null
    $script:token = $null
    $script:ast = $null
    $script:text = ''

    if (Test-Path -LiteralPath $script:payloadPath -PathType Leaf) {
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:payloadPath, [ref] $script:token, [ref] $script:parseError)
        $script:text = Get-Content -LiteralPath $script:payloadPath -Raw
    }

    $script:commandNamed = {
        param([string] $Name)

        if ($null -eq $script:ast) { return @() }

        # Copied into a local before the nested predicate closes over it, or
        # PSScriptAnalyzer reports the parameter unused.
        $wanted = $Name

        return @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq $wanted
                }, $true))
    }

    $script:everyCommandName = @()
    if ($null -ne $script:ast) {
        $script:everyCommandName = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true) | ForEach-Object { [string] $_.GetCommandName() } | Where-Object { $_ })
    }

    $script:elementOf = {
        param([object] $Command)

        return @($Command.CommandElements | ForEach-Object { [string] $_.Extent.Text })
    }

    # The Storage and DISM cmdlets IDiskService and IImageService exist to be the
    # only callers of.
    $script:forbiddenCommand = @(
        'Get-Disk', 'Clear-Disk', 'Initialize-Disk', 'New-Partition', 'Set-Partition',
        'Remove-Partition', 'Get-Partition', 'Format-Volume', 'Get-Volume',
        'Remove-PartitionAccessPath', 'Add-PartitionAccessPath',
        'Get-WindowsImage', 'Expand-WindowsImage', 'Mount-WindowsImage', 'Dismount-WindowsImage',
        'Add-WindowsDriver', 'Add-WindowsPackage'
    )

    # DESIGN 5.1: NONE OF THESE EXISTS IN WinPE. There is no optional component
    # that adds them, and the entry point waits for an address - which is exactly
    # where somebody reaches for one.
    $script:forbiddenNetCommand = @(
        'Get-NetAdapter', 'Get-NetIPAddress', 'New-NetIPAddress',
        'Resolve-DnsName', 'Test-NetConnection', 'Get-NetIPConfiguration'
    )

    $script:forbiddenText = @('bcdboot', 'bcdedit', 'reagentc', 'diskpart', 'dism.exe')

    # THE CODE, WITHOUT THE COMMENTS. The header says in prose that this file
    # calls no bcdboot - and a raw text scan would fail on that sentence, which
    # would teach the next author to delete the sentence rather than keep the
    # property.
    $script:codeOnly = ''
    if ($null -ne $script:token) {
        $script:codeOnly = (@($script:token |
                    Where-Object { $_.Kind -ne 'Comment' } |
                    ForEach-Object { [string] $_.Text }) -join ' ')
    }

    $script:largestTry = $null
    if ($null -ne $script:ast) {
        $script:largestTry = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.TryStatementAst]
                    }, $true) | Sort-Object { $_.Extent.Text.Length } -Descending)[0]
    }
}

Describe 'Start-HDTDeployment.ps1' {

    It 'exists at src/Hephaestus/Payload/Start-HDTDeployment.ps1' {
        Test-Path -LiteralPath $script:payloadPath -PathType Leaf | Should -BeTrue
    }

    It 'parses with no error' {
        @($script:parseError).Count | Should -Be 0 -Because (@($script:parseError | ForEach-Object { $_.Message }) -join "`n")
    }

    It 'passes the PowerShell 5.1 compatibility scanner' {
        # It runs inside WinPE, which has 5.1 and no pwsh at all (SPIKES S1).
        $violation = @(Get-HDTScriptCompatibilityViolation -Path $script:payloadPath)

        $violation.Count | Should -Be 0 -Because (@($violation | ForEach-Object { $_.Reason }) -join "`n")
    }

    It 'defines no unprefixed function' {
        $name = @(Get-HDTSourceFunction -Path $script:payloadPath | ForEach-Object { $_.Name })
        $violation = @(Get-HDTFunctionNameViolation -Name $name)

        $violation.Count | Should -Be 0
    }

    It 'sets StrictMode and ErrorActionPreference' {
        @(& $script:commandNamed 'Set-StrictMode').Count | Should -Be 1
        $script:text | Should -BeLike "*ErrorActionPreference = 'Stop'*"
    }

    Context 'it does no deployment work itself' {

        It 'names no fake' {
            $script:text | Should -Not -BeLike '*New-HDTFake*'
        }

        It 'names no Storage or DISM cmdlet' {
            $hit = @($script:everyCommandName | Where-Object { $script:forbiddenCommand -contains $_ })

            $hit | Should -BeNullOrEmpty -Because ('the entry point called: {0}' -f ($hit -join ', '))
        }

        It 'names no native boot tool' {
            $script:codeOnly | Should -Not -BeNullOrEmpty

            foreach ($tool in $script:forbiddenText) {
                $script:codeOnly | Should -Not -Match ('\b{0}\b' -f [regex]::Escape($tool)) `
                    -Because "$tool belongs to IImageService, not to an entry point"
            }
        }

        It 'calls Invoke-HDTTaskSequence exactly once' {
            # ONE call. Not one per step, not one per group - the loop owns the
            # sequence, and an entry point that drove steps itself would not be
            # proving the engine deployed the machine.
            @(& $script:commandNamed 'Invoke-HDTTaskSequence').Count | Should -Be 1
        }

        It 'invokes no step function directly' {
            $hit = @($script:everyCommandName | Where-Object { $_ -like 'Invoke-HDT*Step' })

            $hit | Should -BeNullOrEmpty -Because ('the entry point called: {0}' -f ($hit -join ', '))
        }

        It 'writes no unattend and stages no image' {
            $script:codeOnly | Should -Not -Match '(?i)unattend'
            $script:codeOnly | Should -Not -Match '(?i)install\.wim'
        }

        It 'loads no UI framework and builds no window of its own' {
            # THIS RULE USED TO FORBID Show-* ENTIRELY, and said so: "DESIGN 11's
            # progress window and wizard are a later milestone. A silent entry
            # point is the honest v1, and this is what stops this file quietly
            # becoming the other thing." That milestone has arrived - the
            # payload now shows DESIGN 11.2's wizard when the share declares one
            # and DESIGN 11.1's progress window while the sequence runs - so the
            # rule is narrowed rather than deleted.
            #
            # WHAT IT STILL FORBIDS IS THE PART THAT MATTERED: this file must
            # not reach for WPF itself. Every window goes through the injected
            # hosts, which are the only things in the engine that name an
            # assembly - so the payload stays testable, and a machine that
            # cannot draw still deploys through the console fallback rather than
            # dying on an Add-Type here.
            $script:codeOnly | Should -Not -Match 'PresentationFramework'
            $script:codeOnly | Should -Not -Match 'System\.Windows\.Forms'
            $script:codeOnly | Should -Not -Match 'XamlReader'
        }

        It 'shows only the three windows DESIGN 11 defines' {
            # ALL THREE REFUSE TO READ A DISMISSED WINDOW AS CONSENT, which is
            # the property that matters: a payload calling a host directly could
            # treat silence as Next.
            #
            # Show-HDTWizard is the WELCOME screen and runs BEFORE the share is
            # reachable - a machine with no address is what it exists for.
            # Show-HDTWizardShell is the multi-page wizard and runs after,
            # against pages that live on the share.
            # Show-HDTDeploymentFailure is the screen a failed machine shows
            # instead of powering off in front of a technician who was told
            # nothing.
            $shown = @($script:everyCommandName | Where-Object { $_ -like 'Show-*' } | Sort-Object -Unique)

            $shown | Should -Be @('Show-HDTDeploymentFailure', 'Show-HDTWizard', 'Show-HDTWizardShell')
        }

        It 'shows the failure screen only when a display was opened' {
            # AN UNATTENDED DEPLOYMENT MUST NOT WAIT FOR A KEYPRESS THAT WILL
            # NEVER COME. A run with no display is a run nobody is standing at,
            # and the zero-keystroke E2E proof depends on it ending by itself.
            $script:codeOnly | Should -Match 'Suppressed'
        }

        It 'asks for a network rather than failing at the share' {
            # THE PROCESS FAULT A LIVE RUN EXPOSED. With no address the payload
            # used to warn and connect anyway, so the failure named a share when
            # the problem was a network. The Welcome screen is what a machine
            # with no address is for (WPF-FIRST W2) - and Set-HDTStaticAddress
            # is how WinPE takes one, since it has no NetTCPIP.
            @(& $script:commandNamed 'Get-HDTWizardSkip').Count | Should -BeGreaterThan 0
            @(& $script:commandNamed 'Show-HDTWizard').Count | Should -BeGreaterThan 0
        }

        It 'decides what counts as an address with Get-HDTUsableAddress' {
            # NEVER INLINE AGAIN. Inline, it cast a [string[]] to a string and
            # split on commas, so a machine holding 192.168.2.39 waited the full
            # timeout for an address it already had - and the payload's own test
            # reads this file's shape, so nothing could catch it.
            @(& $script:commandNamed 'Get-HDTUsableAddress').Count | Should -Be 1
        }

        It 'hides the console only in a pair' {
            # A hidden console plus a wizard that then throws leaves a
            # technician staring at a blank screen with nothing to read and
            # nothing to type into. Hide-HDTShellWindow appears twice: the hide
            # and the restore.
            @($script:everyCommandName | Where-Object { $_ -eq 'Hide-HDTShellWindow' }).Count |
                Should -BeGreaterOrEqual 2
        }

        It 'hides the console before it reads the bootstrap' {
            # WHY THE HIDE IS NOT AT THE WIZARD ANY MORE. WinPE boots into
            # cmd.exe running startnet.cmd, and that full-screen black window
            # covers the desktop - so a BGInfo start command paints the
            # wallpaper BEHIND it and the technician sees nothing until this
            # payload hid the console for the wizard. MDT has no console to hide
            # (winpeshl.ini runs LiteTouch.wsf as the shell), which is why the
            # same BGInfo is on screen there from the first second.
            #
            # AFTER THE LOG CONTEXT, NOT BEFORE IT. The two failures that cannot
            # be logged - powershell-yaml or Hephaestus not importing, and the
            # log directory not being creatable - must still leave their message
            # on a console somebody can read.
            $firstHide = @(& $script:commandNamed 'Hide-HDTShellWindow' |
                    Sort-Object { $_.Extent.StartOffset })[0]
            $bootstrap = @(& $script:commandNamed 'Get-HDTBootstrapConfiguration' |
                    Sort-Object { $_.Extent.StartOffset })[0]

            $firstHide | Should -Not -BeNullOrEmpty
            $bootstrap | Should -Not -BeNullOrEmpty
            $firstHide.Extent.StartOffset | Should -BeLessThan $bootstrap.Extent.StartOffset
        }

        It 'opens the boot status overlay before it hides the console' {
            # THE ORDER IS THE SAFETY. Hiding the console leaves a technician
            # with whatever is on screen instead, and on a boot image built
            # without WinPE-NetFx that is an empty wallpaper - no overlay, and
            # no Welcome screen either. Start-HDTBootStatus reports Console for
            # that machine and the payload leaves the console where it was, so
            # the hide can only ever be a swap of one screen for a better one.
            $overlay = @(& $script:commandNamed 'Start-HDTBootStatus' |
                    Sort-Object { $_.Extent.StartOffset })[0]
            $firstHide = @(& $script:commandNamed 'Hide-HDTShellWindow' |
                    Sort-Object { $_.Extent.StartOffset })[0]

            $overlay | Should -Not -BeNullOrEmpty
            $overlay.Extent.StartOffset | Should -BeLessThan $firstHide.Extent.StartOffset
        }

        It 'closes the overlay in the tail as well as when the engine takes over' {
            # Step 10b closes it on a run that reached the engine. The tail is
            # for the run that did not - a share it could not reach, a wizard
            # somebody cancelled - where a transparent panel left over the
            # failure screen would be one screen explaining another.
            $close = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                        [string] $node.Member.Value -eq 'Close'
                    }, $true) | Where-Object { $_.Extent.Text -match 'StatusHost' })

            @($close).Count | Should -BeGreaterOrEqual 2
            @($close | Where-Object { $_.Extent.StartOffset -gt $script:largestTry.Extent.EndOffset }).Count |
                Should -BeGreaterOrEqual 1
        }

        It 'restores the console in the tail, outside the main try' {
            # THE MACHINE MUST NOT END ON A SCREEN NOBODY CAN READ. The early
            # hide lasts the whole run, so the restore belongs after the catch
            # with the rest of the tail - a FATAL line, the failure screen and a
            # technician left at a command prompt all need the console back.
            $restore = @(& $script:commandNamed 'Hide-HDTShellWindow' | Where-Object {
                    @(& $script:elementOf $_) -contains '-Restore' -and
                    $_.Extent.StartOffset -gt $script:largestTry.Extent.EndOffset
                })

            @($restore).Count | Should -BeGreaterOrEqual 1
        }

        It 'writes nothing with Write-Host' {
            @($script:everyCommandName | Where-Object { $_ -eq 'Write-Host' }) | Should -BeNullOrEmpty
        }
    }

    Context 'the dependency proof' {

        It 'imports powershell-yaml before it imports Hephaestus' {
            # ConvertFrom-HDTYaml imports powershell-yaml lazily and reports
            # HDTDependencyError without it, so the engine cannot read a single
            # YAML document until this has happened (SPIKES S9.1).
            $import = @(& $script:commandNamed 'Import-Module')

            $yaml = @($import | Where-Object { $_.Extent.Text -like '*powershell-yaml*' })
            $engine = @($import | Where-Object { $_.Extent.Text -like '*Hephaestus*' })

            $yaml.Count | Should -BeGreaterOrEqual 1
            $engine.Count | Should -BeGreaterOrEqual 1

            $yaml[0].Extent.StartOffset | Should -BeLessThan $engine[0].Extent.StartOffset
        }

        It 'logs the version of each module it loaded' {
            $script:text | Should -BeLike '*yamlVersion*'
            $script:text | Should -BeLike '*engineVersion*'
        }

        It 'puts the module root on PSModulePath' {
            $script:text | Should -BeLike '*PSModulePath*'
        }

        It 'assumes only X: and no other drive letter' {
            # SPIKES S9.1: WinPE gave the content disk the letter a developer's
            # machine calls its system drive, and the RAM disk X:. X: is the one
            # guarantee; everything else is discovered.
            $script:codeOnly | Should -Not -BeNullOrEmpty
            $script:codeOnly | Should -Not -Match '\b[C-WYZ]:\\'
        }

        It 'enumerates volumes instead of naming them' {
            # Phase 04's launcher scanned a hard-coded run of letters. This one
            # may not, and this assertion is what stops the next author putting
            # it back.
            $script:codeOnly | Should -Match 'GetDrives'

            # TWICE NOW, AND BOTH ARE THE SAME DELEGATION. The first resolves
            # what bootstrap.json carried; the second resolves what a technician
            # typed into the Welcome screen after that share could not be
            # reached. The rule this test defends is that the payload never
            # DECIDES a drive letter - it enumerates and hands the decision to
            # Resolve-HDTDeployRoot - and a corrected share has to go through
            # the same command for the same reason, including the
            # volume-relative form.
            #
            # The count stays exact rather than becoming -BeGreaterThan 0: a
            # third call is a thing to think about, not to wave through.
            @(& $script:commandNamed 'Resolve-HDTDeployRoot').Count | Should -Be 2
        }

        It 'names no Net cmdlet WinPE does not have' {
            $hit = @($script:everyCommandName | Where-Object { $script:forbiddenNetCommand -contains $_ })

            $hit | Should -BeNullOrEmpty -Because ('the entry point called: {0}. DESIGN 5.1: no optional component adds them to WinPE.' -f ($hit -join ', '))
        }
    }

    Context 'what it builds and what it hands the loop' {

        It 'builds the real service adapters' {
            foreach ($name in @('New-HDTFileSystem', 'New-HDTClock', 'New-HDTDiskService',
                    'New-HDTImageService', 'New-HDTRegistryService', 'New-HDTLsaService',
                    'New-HDTEnvironmentProvider', 'New-HDTCimProvider', 'New-HDTProcessService',
                    'New-HDTPowerService', 'New-HDTScriptInvoker', 'New-HDTServiceCatalog')) {

                @(& $script:commandNamed $name).Count | Should -BeGreaterOrEqual 1 -Because "the entry point has to build $name"
            }
        }

        It 'tells the power service it is in WinPE' {
            # THE DEFECT 05-06 FOUND. shutdown.exe is not in the boot image - a
            # read-only mount says so and
            # tests/integration/WinPeContent.Integration.Tests.ps1 keeps saying
            # it - so a Restart step run from here through a power service built
            # for the full OS would call a command that does not exist.
            #
            # This entry point IS the WinPE one; it hardcodes -Phase WinPE
            # everywhere else. There is no detection to do, and -Environment is
            # mandatory so it cannot be left out.
            $power = @(& $script:commandNamed 'New-HDTPowerService')

            $power.Count | Should -Be 1

            $element = & $script:elementOf $power[0]
            $element | Should -Contain '-Environment'
            $element | Should -Contain 'WinPE'
        }

        It 'builds the content provider through New-HDTContentProvider' {
            @(& $script:commandNamed 'New-HDTContentProvider').Count | Should -Be 1
            @(& $script:commandNamed 'New-HDTLocalContentProvider') | Should -BeNullOrEmpty
            @(& $script:commandNamed 'New-HDTSmbContentProvider') | Should -BeNullOrEmpty
        }

        It 'reads the bootstrap through Get-HDTBootstrapConfiguration' {
            @(& $script:commandNamed 'Get-HDTBootstrapConfiguration').Count | Should -Be 1
        }

        It 'gathers facts exactly once' {
            @(& $script:commandNamed 'Get-HDTMachineFact').Count | Should -Be 1
        }

        It 'resolves twice at most, and the second time is the wizard' {
            # IT USED TO BE ONCE, and the wizard is why it is two.
            #
            # The wizard cannot run before the first resolution: it needs the
            # resolved variables to know which pages are skipped and what to
            # prefill the boxes with. And its answers cannot be patched into the
            # result afterwards - that would set values with no provenance and
            # no precedence, which is the whole thing DESIGN 3.1 exists to
            # prevent.
            #
            # SO IT RESOLVES AGAIN WITH -Wizard, and the second pass is how the
            # precedence actually applies: a typed name beats the rule that
            # guessed one, a rule still wins where a box was left empty, and the
            # provenance says which happened. Resolve-HDTVariable is pure, so
            # running it twice costs nothing but the time.
            $resolve = @(& $script:commandNamed 'Resolve-HDTVariable')

            @($resolve).Count | Should -BeLessOrEqual 2
            @($resolve).Count | Should -BeGreaterOrEqual 1
        }

        It 'reads the wizard definition off the share rather than the file system' {
            # DESIGN 11.2's pages live on the share, and standalone media is the
            # same share with the provider swapped - so a payload that reached
            # for the file system here would work on a share and not on media.
            @(& $script:commandNamed 'Import-HDTWizardDocument').Count | Should -Be 1
        }

        It 'decides which pages to ask with Get-HDTWizardPage' {
            # Never by showing every page and letting the technician skip them:
            # a page skipped with no value behind it is an error rather than a
            # prompt (DESIGN 11.2), and only that command knows it.
            @(& $script:commandNamed 'Get-HDTWizardPage').Count | Should -Be 1
        }

        It 'looks for a per-machine override' {
            # DESIGN 3.1's second source. 04-04 proved it is what makes one
            # machine an exception without editing rules.yaml.
            @(& $script:commandNamed 'Get-HDTMachineOverride').Count | Should -Be 1
        }

        It 'builds every workspace path through Get-HDTWorkspacePath' {
            @(& $script:commandNamed 'Get-HDTWorkspacePath').Count | Should -BeGreaterOrEqual 1

            $script:text | Should -Not -Match "'TaskSequences'"
            $script:text | Should -Not -Match "'Logs'"
            $script:text | Should -Not -Match "'Control'"
        }

        It 'passes -State, -StatePath and -LogDestination to the loop' {
            $loop = @(& $script:commandNamed 'Invoke-HDTTaskSequence')[0]
            $element = & $script:elementOf $loop

            $element | Should -Contain '-State'
            $element | Should -Contain '-StatePath'
            $element | Should -Contain '-LogDestination'
        }

        It 'passes the content provider into the service catalog' {
            $catalog = @(& $script:commandNamed 'New-HDTServiceCatalog')[0]

            (& $script:elementOf $catalog) | Should -Contain '-Content'
        }
    }

    Context 'it always leaves evidence and always ends' {

        It 'writes RESULT.json under the deploy root Logs folder' {
            # X:\HDT\RESULT.json ALONE WOULD BE WRITTEN TO A RAM DISK on a
            # machine that is about to power off, and 05-05's whole
            # zero-keystroke proof reads this file back.
            $script:text | Should -BeLike '*RESULT.json*'
            $script:codeOnly | Should -Match 'Get-HDTWorkspacePath'
            $script:codeOnly | Should -Match '-Kind Logs'
        }

        It 'writes the X: copy as a fallback as well' {
            $script:codeOnly | Should -Match 'X:\\HDT'
        }

        It 'writes LAUNCHER.log beside it' {
            $script:text | Should -BeLike '*LAUNCHER.log*'
        }

        It 'writes it as UTF-8 without a BOM' {
            # SPIKES S6's third finding: the default under 5.1 is UTF-16, which
            # half the tooling cannot read.
            $script:text | Should -BeLike '*UTF8Encoding*'
        }

        It 'records launchedBy from HDT_LAUNCHED_BY' {
            # startnet.cmd sets it (05-04) and a human typing the command by hand
            # does not. That single field is what 05-05 asserts to prove the
            # deployment started ITSELF.
            $script:text | Should -BeLike '*launchedBy*'
            $script:text | Should -BeLike '*HDT_LAUNCHED_BY*'
        }

        It 'records resolvedDeployRoot, deployRootSource and candidateRoot' {
            foreach ($field in @('resolvedDeployRoot', 'deployRootSource', 'candidateRoot')) {
                $script:text | Should -BeLike ('*{0}*' -f $field) -Because "a support call needs to know what the resolver saw as well as what it chose"
            }
        }

        It 'assigns every variable its tail reads OUTSIDE the try, so a run that died still gets a tail' {
            # FOUND ON A LIVE MACHINE. The wizard threw, the catch recorded it -
            # and then the tail said
            #
            #     The variable '$display' cannot be retrieved because it has not
            #     been set.
            #
            # because `$display` is assigned at step 10b, INSIDE the try, and the
            # run never reached it. Under Set-StrictMode even `$null -ne $display`
            # throws. So the last thing a technician saw was a second error about
            # the tail, on top of the first one about the wizard - and the tail is
            # the part that writes RESULT.json.
            #
            # THE RULE IS THE WHOLE CLASS, NOT THE ONE VARIABLE. Every future
            # step that puts something in a variable and cleans it up in the tail
            # has the same hole; the guard is that the tail may only read
            # variables the script assigns where a failed run still reaches.

            $script:ast | Should -Not -BeNullOrEmpty

            $body = $script:ast.EndBlock.Statements
            # THE FIRST top-level try - the one the deployment runs in. The
            # payload has a second one further down, in the tail itself; taking
            # the last would leave the whole tail unjudged.
            $tryIndex = -1
            for ($i = 0; $i -lt $body.Count; $i++) {
                if ($tryIndex -lt 0 -and $body[$i] -is [System.Management.Automation.Language.TryStatementAst]) { $tryIndex = $i }
            }
            $tryIndex | Should -BeGreaterThan 0 -Because 'the payload wraps its work in one top-level try'

            # ASSIGNED WHERE A FAILED RUN STILL REACHES: before the try, or in
            # the tail itself. Anything assigned only inside the try is exactly
            # the trap above.
            $safe = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($name in @($script:ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })) {
                [void] $safe.Add($name)
            }

            $outside = @($body[0..($tryIndex - 1)]) + @($body[($tryIndex + 1)..($body.Count - 1)])
            foreach ($statement in $outside) {
                foreach ($assignment in $statement.FindAll({
                            param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {

                    if ($assignment.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
                        [void] $safe.Add($assignment.Left.VariablePath.UserPath)
                    }
                }

                foreach ($loop in $statement.FindAll({
                            param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {

                    [void] $safe.Add($loop.Variable.VariablePath.UserPath)
                }
            }

            # PowerShell's own, plus the ones a scriptblock parameter binds.
            $automatic = @('_', 'PSItem', 'null', 'true', 'false', 'PSScriptRoot', 'PSCommandPath',
                'ErrorActionPreference', 'InformationPreference', 'PSVersionTable', 'Error', 'args', 'this')

            $offender = @()
            foreach ($statement in @($body[($tryIndex + 1)..($body.Count - 1)])) {

                # A scriptblock in the tail brings its own parameters; judging
                # its body here would convict them.
                foreach ($read in $statement.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                            $null -eq ($node.Parent -as [System.Management.Automation.Language.AssignmentStatementAst])
                        }, $true)) {

                    $name = $read.VariablePath.UserPath

                    if ($read.VariablePath.IsGlobal -or $name -like 'env:*') { continue }
                    if ($automatic -contains $name) { continue }
                    if ($safe.Contains($name)) { continue }

                    $offender += '${0} (line {1})' -f $name, $read.Extent.StartLineNumber
                }
            }

            @($offender).Count | Should -Be 0 -Because (
                'the tail runs after a failure and may only read variables a failed run has. Found: {0}' -f
                    (($offender | Select-Object -Unique) -join ', '))
        }

        It 'records endedWith' {
            # ROADMAP M2 left "does WinPE need wpeutil reboot rather than
            # shutdown.exe" open, and this is the first run that can answer it.
            $script:text | Should -BeLike '*endedWith*'
        }

        It 'prompts for a credential only when the bootstrap says to' {
            $prompt = @(& $script:commandNamed 'Get-Credential')

            $prompt.Count | Should -Be 1

            $guard = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.IfStatementAst]
                    }, $true) |
                    Where-Object {
                        $_.Extent.StartOffset -lt $prompt[0].Extent.StartOffset -and
                        $_.Extent.EndOffset -gt $prompt[0].Extent.EndOffset
                    })

            @($guard | Where-Object { $_.Extent.Text -match 'PromptForCredential' }).Count |
                Should -BeGreaterOrEqual 1 -Because 'the one path in this file that stops for a human is reachable only when the image asked for it'

            # And it says so. DESIGN 6.3 offers that build for a shared lab or
            # media going offsite; it must not look like an accident.
            $warning = @(& $script:commandNamed 'Write-Warning' |
                    Where-Object { $_.Extent.StartOffset -gt ($guard | Sort-Object { $_.Extent.StartOffset })[-1].Extent.StartOffset })

            $warning.Count | Should -BeGreaterOrEqual 1
        }

        It 'calls Copy-HDTLog outside the try' {
            # A run that died before the loop never reached the loop's own
            # copy-back, and that run is precisely the one whose log is wanted.
            $copy = @(& $script:commandNamed 'Copy-HDTLog')

            $copy.Count | Should -BeGreaterOrEqual 1
            $script:largestTry | Should -Not -BeNullOrEmpty

            @($copy | Sort-Object { $_.Extent.StartOffset })[-1].Extent.StartOffset |
                Should -BeGreaterThan $script:largestTry.Extent.EndOffset
        }

        It 'disconnects the content provider' {
            $script:codeOnly | Should -Match 'Disconnect'
        }

        It 'ends the machine with wpeutil' {
            $script:text | Should -BeLike '*wpeutil*'
        }

        It 'does not power the machine off when the technician asked for a prompt' {
            # THE DEFECT THIS ASSERTION EXISTS FOR, found on a real VM: pressing
            # Open CMD in the wizard opened a prompt, threw
            # HDTDeploymentCancelled, was reported as a FATAL exception in the
            # parent console, and then wpeutil shut the machine down five
            # seconds later - taking the prompt with it. The one button whose
            # entire purpose is debugging a machine ended the machine.
            #
            # THE POWER LINE MUST THEREFORE BE CONDITIONAL. Asserted on the AST
            # rather than the text, because 'the last line is guarded' is the
            # property, not any particular spelling of the guard.
            $power = @(& $script:commandNamed 'wpeutil.exe') + @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.Extent.Text -like '*wpeutil*'
                    }, $true))

            $power | Should -Not -BeNullOrEmpty

            $guarded = $false
            foreach ($call in $power) {
                $walk = $call.Parent
                while ($null -ne $walk) {
                    if ($walk -is [System.Management.Automation.Language.IfStatementAst]) { $guarded = $true; break }
                    $walk = $walk.Parent
                }
            }

            $guarded | Should -BeTrue -Because 'a machine left at a command prompt must not be powered off under the technician'
        }

        It 'records that it left the technician at a prompt' {
            # RESULT.json is the evidence file, and "why is this machine still
            # on?" is exactly the question it should answer.
            $script:text | Should -BeLike '*leftAtCommandPrompt*'
        }

        It 'reports a cancel as cancelled rather than as a failure' {
            # A technician who pressed Open CMD or Cancel did not suffer a
            # fault, and a red FATAL over a deliberate choice teaches everyone
            # reading the console to ignore red.
            $script:codeOnly | Should -Match 'Cancelled'
        }

        It 'reboots on RebootPending and shuts down otherwise' {
            $script:codeOnly | Should -Match 'reboot'
            $script:codeOnly | Should -Match 'shutdown'
            $script:codeOnly | Should -Match 'RebootPending'
        }

        It 'uses the same two verbs Get-HDTPowerCommand yields for WinPE' {
            # THE ANTI-DRIFT ASSERTION. This last line runs after the catch, on a
            # machine that may have failed before the module imported, so it
            # invokes wpeutil directly rather than through the service - and that
            # is exactly the sort of duplicate that goes stale in silence.
            #
            # It cannot go stale here: the verbs the payload assigns to $ending
            # are compared with the verbs the engine's own decision produces.
            Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

            $engineVerb = @(InModuleScope Hephaestus {
                    foreach ($operation in @('Restart', 'Stop')) {
                        [string] (Get-HDTPowerCommand -Environment WinPE -Operation $operation -DelaySecond 0).Argument[0]
                    }
                }) | Sort-Object

            $payloadVerb = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        ([string] $node.Left.Extent.Text) -eq '$ending'
                    }, $true) |
                    ForEach-Object { ([string] $_.Right.Extent.Text).Trim("'`"") }) | Sort-Object -Unique

            @($payloadVerb).Count | Should -Be 2 -Because 'the payload assigns $ending exactly twice: reboot and shutdown'
            @($payloadVerb) | Should -Be @($engineVerb)
        }

        It 'ends the machine even when the run threw' {
            # A VM left at a WinPE prompt tells nobody anything except that its
            # timeout expired.
            $ended = @($script:ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        ([string] $node.Extent.Text) -like '*wpeutil*'
                    }, $true))

            $ended.Count | Should -BeGreaterOrEqual 1

            @($ended | Sort-Object { $_.Extent.StartOffset })[-1].Extent.StartOffset |
                Should -BeGreaterThan $script:largestTry.Extent.EndOffset
        }
    }
}

Describe 'Start-HDTDeployment.ps1 and the engine s own defaults' {

    # THE ENGINE SUPPLIES FOUR LOCALES AND A TIME ZONE WHEN NOBODY ELSE DID, and
    # for five milestones it supplied them AFTER the wizard had already refused
    # to skip the page that collects them. A zero-touch deployment in this lab
    # died on:
    #
    #   the wizard page 'LocaleTime' is skipped by HDTSkipWizard, but nothing
    #   supplies HDTTimeZone
    #
    # a hundred and fifty lines above the line that supplies HDTTimeZone. The
    # message was true about the moment it was written and false about the run.
    #
    # DEFAULTS BELONG BEFORE ANYTHING READS THEM. That is the whole ordering
    # argument: a default applied after the check that wanted it is not a
    # default, it is a value nobody can use.

    It 'seeds them before the wizard decides which pages to ask' {
        $seed = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $node.Value -eq 'HDTTimeZone'
                }, $true))

        $seed.Count | Should -BeGreaterOrEqual 1

        $check = @(& $script:commandNamed 'Get-HDTWizardPage')

        $check.Count | Should -BeGreaterOrEqual 1

        # The FIRST mention of the time zone is the seed; the check comes after.
        $first = @($seed | Sort-Object { $_.Extent.StartOffset })[0]

        $first.Extent.StartOffset | Should -BeLessThan $check[0].Extent.StartOffset
    }

    It 'keeps applying them only when nothing else spoke' {
        # DESIGN 3.1 precedence: the command line, a machine override and a rule
        # all beat the engine. Seeding earlier must not turn a default into an
        # override.
        $script:text | Should -BeLike '*Contains*'
    }
}

Describe 'Start-HDTDeployment.ps1 and a share it cannot reach' {

    # ZTI HAS NO TECHNICIAN. That is what the letters mean, and it decides this
    # entirely: an image built to run with nobody present must never stop and
    # wait for somebody to press Next. A machine sitting at a screen is not
    # safer than one that failed - it is unreachable AND silent, and it stays
    # that way until a human happens to walk past.
    #
    # THIS FILE ALREADY GOT IT RIGHT ONCE. The no-address path checks the same
    # skip and throws HDTNetworkError rather than asking. The share path did the
    # opposite, on the argument that "a share that cannot be reached has no
    # unattended outcome left to protect" - which is exactly backwards: the
    # outcome to protect is the REPORT, and a machine waiting at a prompt
    # writes none.
    #
    # Measured, in this lab, on 2026-08-20: one transient connect failure left
    # HDT-ZTI-01 at the Welcome screen for two hours and forty-five minutes,
    # correctly prefilled with everything it needed, with nobody to press Next.
    # The host was up, the share was Online, port 445 was open and the
    # credential mapped - the second attempt that never happened would have
    # worked.

    It 'retries the connect before it gives up on the share' {
        # A TRANSIENT IS THE COMMON CASE. WinPE has just brought a network up;
        # the first SMB attempt is the least likely one to succeed, and it was
        # the only one there was.
        $script:text | Should -BeLike '*ConnectAttempt*'
    }

    It 'takes the number of attempts as a parameter rather than burying it' {
        $parameter = @($script:ast.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'ConnectAttempt' })

        $parameter.Count | Should -Be 1
    }

    # AND THEN IT SHOWS THE SCREEN, WHATEVER THE IMAGE SAYS ABOUT WHO IS THERE.
    #
    # THIS IS THE USER'S DECISION, TAKEN ON 2026-08-21, AND IT REVERSES HALF OF
    # THE ONE ABOVE. The retries stay - they were the good half. The refusal
    # does not: a ZTI machine whose share had moved died after five attempts
    # with nothing on screen and nothing in a log, because the log destination
    # IS the share it could not reach. Silence protected no report; there was
    # never going to be one.
    #
    # HDTSkipWelcome DOES NOT HIDE THE PANES BEHIND IT. StaticIp and DeployRoot
    # default to NOT skipped, so the screen this opens has the network pane and
    # the share box on it, prefilled with the share that just failed - which is
    # the one thing a person standing there can fix.
    It 'shows the Welcome screen when the attempts are exhausted' {
        $script:text | Should -BeLike '*$corrected = & $showWelcome*'
    }

    It 'does not refuse on the skip before it has asked' {
        # The refusal was gated on Get-HDTWizardSkip's Welcome. Nothing between
        # the last attempt and the screen may test it again.
        $script:text | Should -Not -BeLike '*HDTShareError:*'
    }

    It 'still ends the deployment when the screen is left without an answer' {
        # The bound is the person, not a timer: closing the screen ends the run
        # rather than looping on the share that already failed.
        $script:text | Should -BeLike '*HDTDeploymentCancelled:*left the Welcome screen*'
    }
}

Describe 'Start-HDTDeployment.ps1 and the finish action' {

    # MDT's FinishAction, on the leg where a WinPE-only sequence ends. DEMO-M3
    # and DEMO-M4 are exactly that: they finish in WinPE and never reach a full
    # OS, so a deployment share that sets HDTFinishAction and saw it ignored
    # here would have a variable that works on some sequences and not others.

    It 'asks Get-HDTFinishAction what the value means' {
        @(& $script:commandNamed 'Get-HDTFinishAction') | Should -Not -BeNullOrEmpty
    }

    It 'tells it this is WinPE' {
        # LOGOFF resolves to no action in WinPE, and only because the
        # environment is passed truthfully. A payload that claimed FullOS here
        # would plan a shutdown.exe /l for a machine with no shutdown.exe.
        $script:text | Should -Match '(?s)Get-HDTFinishAction.*?WinPE'
    }

    It 'applies it only to a run that finished, never to one with a leg to come' {
        # RebootPending MEANS THE DEPLOYMENT IS NOT OVER. The machine is going
        # back into what it just built to run the rest of the sequence, and a
        # finish action honoured here would power it off half way through -
        # leaving an imaged machine that never ran a single full-OS step.
        $script:text | Should -Match "(?s)Get-HDTFinishAction.*?Succeeded"
    }

    It 'still assigns $ending only the two verbs the engine plans' {
        # The finish action moves between the SAME two verbs rather than
        # introducing a third. Get-HDTPowerCommand plans reboot and shutdown for
        # WinPE and nothing else, and the assertion above this one compares the
        # payload's literals against them.
        $assigned = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    ([string] $node.Left.Extent.Text) -eq '$ending'
                }, $true) |
                ForEach-Object { ([string] $_.Right.Extent.Text).Trim("'`"") }) | Sort-Object -Unique

        @($assigned) | Should -Be @('reboot', 'shutdown')
    }

    It 'never lets the finish action change what the run reported' {
        $script:text | Should -Match '(?s)Get-HDTFinishAction.*?catch'
    }
}
