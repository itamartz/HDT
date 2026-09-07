# AN EXPORTED COMMAND IS A PROMISE TO SOMEBODY OUTSIDE THE MODULE.
#
# FunctionsToExport is what a payload script, a share-side launcher, a step type
# in a workspace's Modules\ and an administrator at a prompt can name. Nothing
# else needs to be there: a command whose every caller is another file in
# Public\ or Private\ works exactly as well private, because the module's own
# files see each other either way.
#
# THE ABSENCE OF THIS RULE IS WHY IT HAPPENED. Six public commands went in on
# one day and three of them - Save-HDTSecretBag, Restore-HDTSecretBag and
# Clear-HDTSecretBag - had no caller anywhere but Invoke-HDTTaskSequence and
# Clear-HDTAutoLogon. Nothing was broken by it and nothing would have caught it:
# every contract in this directory was green, because none of them had an
# opinion about where a function lives. The exported surface went 314 -> 320 and
# three of those six were the module talking to itself in public.
#
# SO THE RULE IS WRITTEN DOWN HERE, WHERE IT FAILS RATHER THAN AGES.
#
#   An exported command that requires an INJECTED SERVICE or an EXECUTION
#   CONTEXT must be reachable from outside Public\ and Private\, or be declared
#   below with a reason.
#
# WHY THE INJECTED-SERVICE QUALIFIER, AND WHAT IT COSTS. The unqualified rule -
# "every export needs an outside caller" - was measured against this module and
# flags 171 of 320 names. That is a census, not a contract: most of the 171 are
# Get-HDTApplication, Import-HDTDriver, Remove-HDTTaskSequence, Install-HDTAdk -
# commands an administrator types, whose only in-repository caller is a console
# handler under Private\. A rule that needs 160 declarations to go green is a
# rubber stamp with extra steps.
#
# The qualifier is the property that actually separated the secret bag from
# those: SAVE-HDTSECRETBAG CANNOT BE CALLED WITHOUT FIRST BUILDING AN ILsaService
# AND A VARIABLE BAG. A command shaped like that is the engine talking to itself;
# a command an administrator can drive with strings and paths is a tool, and the
# console proves that every day by driving it. The cost of the qualifier is
# stated plainly: a future private-shaped command whose parameters are all
# strings will pass this test. It buys a contract that is 13 lines of
# declaration instead of 160, and a red line for the exact shape that has
# already gone wrong once.
#
# THE STEP-TYPE REGISTRY IS EXEMPT, AND MECHANICALLY SO. Get-HDTStepType builds
# the registry from each module's ExportedFunctions table - a step type that is
# not exported does not exist, for HDT's own types and a third party's alike -
# so Invoke-HDT<Type>Step, Test-HDT<Type>StepApplicable, Get-HDT<Type>StepDescription
# and Get-HDT<Type>StepTemplate are load-bearing on the exported surface by
# construction. The exemption is the registry's own four name shapes, not a list
# of the types that happen to ship today.
#
# THE DECLARATION LIST CANNOT BE PADDED. Three assertions hold it shut: an entry
# naming a command the module does not export fails, an entry naming a command
# that DOES have an outside caller fails, and an entry whose reason is not a
# sentence fails. So it can only ever hold names this contract actually flags,
# and each one has to say what an administrator or an extension author does with
# it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:manifestPath = [System.IO.Path]::Combine($script:repoRoot, 'src', 'Hephaestus', 'Hephaestus.psd1')

    # Get-Command has to see the exported surface for the signature scan below,
    # and Get-HDTServiceCatalog's own parameter list is where the service names
    # come from - see $script:serviceName.
    Import-Module -Name $script:manifestPath -Force -ErrorAction Stop

    $script:manifest = Import-PowerShellDataFile -LiteralPath $script:manifestPath
    $script:exported = @(@($script:manifest['FunctionsToExport']) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })

    # THE OPERATOR ENTRY POINTS: exported for somebody outside the module even
    # though no file outside Public\ and Private\ names them. Each reason says
    # who that somebody is. A command listed here that stops being flagged must
    # be removed from the list; the tests below make that mandatory rather than
    # tidy.
    $script:operatorEntryPoint = [ordered] @{
        'Clear-HDTAutoLogon'        = 'The autologon teardown checklist, and what an administrator runs by hand on a machine left logging itself in after a deployment died. The engine reaches it through Invoke-HDTBootReconciliation, which is why no payload script names it directly.'
        'Get-HDTAutoLogonState'     = 'The read half of the same pair: what a machine is asked before anybody decides to clear it, and the answer a support case quotes. Reporting a state is not something the engine needs a public name for; being asked by hand is.'
        'Invoke-HDTStep'            = 'The step dispatcher. A step type shipped in a workspace Modules\ folder runs a nested step through it, and that folder is imported into the caller session where only exported names exist.'
        'Resolve-HDTImageIndex'     = 'Chooses the one image to apply, or refuses. An administrator runs it against an imported operating system to find out which index an edition resolves to before authoring an ApplyImage step - Get-HDTOperatingSystem''s help gives that call as an example.'
        'Save-HDTRunState'          = 'The checkpoint writer. Repairing a half-finished deployment means reading a state.json, correcting it and writing it back through the same command that wrote it, rather than hand-editing the file the engine will read.'
        'Select-HDTTargetDisk'      = 'Answers which disk a deployment would wipe on this machine, without wiping it. Hard rule 6 refuses ambiguous targets at run time; this is how an administrator finds out before the run instead of during it.'
        'Set-HDTLogPath'            = 'Moves the live log to the target volume and mirrors what was already written. A step type in Modules\ that relocates content needs the same move the engine performs, and it can only name an exported command.'
        'Test-HDTRunStateAbandoned' = 'Says whether a state document describes a live deployment or a dead one. That is the question asked before deleting a state.json by hand, and it must be answerable without starting a run.'
        'Test-HDTStepApplicable'    = 'Asks a step type whether a step applies to this machine. A third-party step type calls it to honour the same condition rules the engine does, and an administrator calls it to find out why a step was skipped.'
        'Write-HDTStatus'           = 'Writes the status.json heartbeat the monitor reads. A long-running step type in Modules\ writes its own heartbeat through it, or a machine that is working is reported as hung.'
    }

    # THE INJECTED SERVICES, FROM THE COMMAND THAT ASSEMBLES THEM. New-HDTServiceCatalog
    # takes one parameter per service, so its parameter list is the set - a
    # service added tomorrow is covered without anybody editing this file.
    # Context and Service are the two names an execution context travels under.
    $script:serviceName = @(
        @((Get-Command -Name 'New-HDTServiceCatalog' -ErrorAction Stop).Parameters.Keys |
            Where-Object { [System.Management.Automation.PSCmdlet]::CommonParameters -notcontains $_ }) +
        @('Context', 'Service')
    ) | Sort-Object -Unique

    # THE REGISTRY'S FOUR NAME SHAPES, as Get-HDTStepType matches them.
    $script:stepTypeShape = '^(Invoke-HDT[A-Za-z0-9]+Step|Test-HDT[A-Za-z0-9]+StepApplicable|Get-HDT[A-Za-z0-9]+StepDescription|Get-HDT[A-Za-z0-9]+StepTemplate)$'

    # EVERYTHING IN THE REPOSITORY THAT IS NOT Public\ OR Private\ AND CAN CALL A
    # COMMAND. Payload scripts and the launcher template run on a booted machine
    # off the share; tools\ and build.ps1 run here; samples\ is what a workspace
    # looks like. docs\ is deliberately absent: command-reference.html names
    # every export by construction, so counting it would make this test pass for
    # everything.
    $script:callerRoot = @(
        [System.IO.Path]::Combine($script:repoRoot, 'src', 'Hephaestus', 'Payload')
        [System.IO.Path]::Combine($script:repoRoot, 'src', 'Hephaestus', 'Templates')
        [System.IO.Path]::Combine($script:repoRoot, 'src', 'Hephaestus', 'UI')
        [System.IO.Path]::Combine($script:repoRoot, 'tools')
        [System.IO.Path]::Combine($script:repoRoot, 'samples')
    )

    $script:callerFile = New-Object -TypeName System.Collections.ArrayList

    foreach ($root in $script:callerRoot) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File)) {
            [void] $script:callerFile.Add($file.FullName)
        }
    }

    foreach ($single in @(
            [System.IO.Path]::Combine($script:repoRoot, 'build.ps1')
            [System.IO.Path]::Combine($script:repoRoot, 'src', 'Hephaestus', 'Start-HDTConsole.ps1')
            [System.IO.Path]::Combine($script:repoRoot, 'src', 'Hephaestus', 'Hephaestus.psm1'))) {
        if (Test-Path -LiteralPath $single -PathType Leaf) { [void] $script:callerFile.Add($single) }
    }

    # A CALL, NOT A MENTION. PayloadExportedCommand.Contract.Tests.ps1 already
    # resolves invocations through the AST for the same reason: a command named
    # in a comment - and this repository's comments name commands constantly -
    # is documentation, and counting it would launder every one of these.
    #
    # String literals DO count, because a launcher builds a powershell.exe
    # command line and a console handler table holds command names as text; a
    # name inside quotes in a script that runs outside the module is a call that
    # the AST cannot see as one.
    $script:called = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($path in @($script:callerFile)) {
        if ($path -like '*.bundle.ps1') { continue }

        if (@('.ps1', '.psm1', '.psd1') -contains [System.IO.Path]::GetExtension($path)) {
            $parseError = $null
            $token = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $token, [ref] $parseError)

            foreach ($command in @($ast.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.CommandAst]
                        }, $true))) {
                $name = [string] $command.GetCommandName()
                if (-not [string]::IsNullOrWhiteSpace($name)) { [void] $script:called.Add($name) }
            }

            foreach ($item in @($token)) {
                if (@('StringLiteral', 'StringExpandable') -notcontains [string] $item.Kind) { continue }
                foreach ($match in [regex]::Matches([string] $item.Text, '\b[A-Z][a-zA-Z]*-HDT[A-Za-z0-9]+\b')) {
                    [void] $script:called.Add($match.Value)
                }
            }
        } else {
            # A .cmd launcher, a .xaml with a command name in it, a YAML sample
            # that names a command for a PowerShell step. No AST for these.
            foreach ($match in [regex]::Matches([System.IO.File]::ReadAllText($path), '\b[A-Z][a-zA-Z]*-HDT[A-Za-z0-9]+\b')) {
                [void] $script:called.Add($match.Value)
            }
        }
    }

    # THE ANSWER, COMPUTED ONCE. Name -> the mandatory service parameters that
    # make it engine-shaped, for every export with no caller outside the module.
    $script:flagged = [ordered] @{}

    foreach ($name in @($script:exported | Sort-Object)) {
        if ($script:called.Contains($name)) { continue }
        if ($name -match $script:stepTypeShape) { continue }

        $command = Get-Command -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $command) { continue }

        $mandatory = New-Object -TypeName System.Collections.ArrayList
        foreach ($set in @($command.ParameterSets)) {
            foreach ($parameter in @($set.Parameters)) {
                if (-not $parameter.IsMandatory) { continue }
                if ($script:serviceName -notcontains $parameter.Name) { continue }
                if ($mandatory -notcontains $parameter.Name) { [void] $mandatory.Add([string] $parameter.Name) }
            }
        }

        if (@($mandatory).Count -eq 0) { continue }

        $script:flagged[$name] = @($mandatory | Sort-Object)
    }
}

Describe 'Exported commands are reachable from outside the module' {

    Context 'the scan itself' {

        It 'has an export list that is a list and not a wildcard' {
            $script:exported | Should -Not -Contain '*'
            @($script:exported).Count | Should -BeGreaterThan 0
        }

        It 'knows what an injected service is called' {
            # New-HDTServiceCatalog renamed or unexported would empty this set
            # and every command below would look operator-callable.
            @($script:serviceName).Count | Should -BeGreaterThan 5
            $script:serviceName | Should -Contain 'Lsa'
            $script:serviceName | Should -Contain 'Context'
        }

        It 'found scripts outside the module that call it' {
            # A caller root that had been moved or renamed would make the whole
            # module look unreachable and the list below unmanageable.
            @($script:callerFile).Count | Should -BeGreaterThan 0
            @($script:called | Where-Object { $script:exported -contains $_ }).Count |
                Should -BeGreaterThan 20 -Because 'the payload scripts alone drive the engine through dozens of exported commands'
        }
    }

    Context 'the rule' {

        It 'exports no engine-only command that nothing outside the module reaches' {
            # THE ASSERTION THIS FILE EXISTS FOR, over the SET of exports. A
            # command that needs an ILsaService or an execution context, that no
            # payload, launcher, tool or sample calls, and that nobody has
            # declared an operator entry point, is the module exporting a
            # conversation it has with itself.
            $miss = @($script:flagged.Keys |
                    Where-Object { -not $script:operatorEntryPoint.Contains($_) } |
                    ForEach-Object { '{0} (mandatory {1})' -f $_, (@($script:flagged[$_]) -join ', ') })

            $miss | Should -BeNullOrEmpty -Because (
                "each of these takes an injected service or an execution context and is called only from Public\ or Private\, so it belongs in Private\ - move it, drop it from FunctionsToExport and from docs/command-categories.psd1, or declare it an operator entry point with a reason in this file:`n{0}" -f ($miss -join "`n"))
        }
    }

    Context 'the operator entry point declarations' {

        It 'declares nothing the module does not export' {
            $extra = @($script:operatorEntryPoint.Keys | Where-Object { $script:exported -notcontains $_ })
            $extra | Should -BeNullOrEmpty -Because (
                'a declaration for a name that is not exported is a leftover and would hide the next one: {0}' -f ($extra -join ', '))
        }

        It 'declares nothing this contract does not flag' {
            # THE LOCK ON THE LIST. Without this a developer could declare a
            # command pre-emptively - or declare all 320 - and the rule above
            # would assert nothing ever again. An entry survives only while the
            # command really is engine-shaped and really has no outside caller,
            # so gaining a payload caller makes removing the entry mandatory.
            $stale = @($script:operatorEntryPoint.Keys | Where-Object { -not $script:flagged.Contains($_) })
            $stale | Should -BeNullOrEmpty -Because (
                'these are reachable without a declaration, so declaring them only blunts the rule: {0}' -f ($stale -join ', '))
        }

        It 'gives every declaration a reason somebody wrote' {
            foreach ($name in @($script:operatorEntryPoint.Keys)) {
                $reason = [string] $script:operatorEntryPoint[$name]

                $reason | Should -Not -BeNullOrEmpty -Because ('{0} is declared with no reason at all' -f $name)
                $reason.Length | Should -BeGreaterThan 80 -Because (
                    "{0}'s reason has to say who outside the module runs it and why - 'operator command' is the rubber stamp this list exists to refuse" -f $name)
                $reason | Should -Match '\.\s*$' -Because ('{0}''s reason should read as a sentence' -f $name)
            }
        }
    }
}
