# A PAYLOAD SCRIPT CAN ONLY CALL WHAT THE MANIFEST EXPORTS.
#
# src/Hephaestus/Payload/*.ps1 are not module files. They are SCRIPTS - the
# thing startnet.cmd runs in WinPE, and the thing the resume agent runs in the
# full OS - and every one of them reaches the engine the same way:
#
#     Import-Module -Name 'Hephaestus'
#
# which imports the MANIFEST. FunctionsToExport is an explicit list (DESIGN
# 15.1), so the 231 functions under Private\ exist inside the module and do not
# exist in the caller's session. A payload line that names one is a
# CommandNotFoundException on a booted machine and nowhere else: it parses, it
# lints, it passes every AST test in the repository, and it fails only on iron.
#
# THIS CONTRACT WAS WRITTEN AFTER THAT HAPPENED. b08bb91 added a call to
# Expand-HDTVariableToken - a private helper - inside the try/catch that starts
# live logging to the share. The call threw, its own catch downgraded the throw
# to a Warning because a share that cannot be written to must never end a
# deployment, and live logging was silently dead on every run for a day. The
# only evidence was one line in LAUNCHER.log on the share it had failed to write
# to.
#
# SO IT IS ASSERTED OVER THE SET, NOT OVER THAT ONE NAME. A test that grepped
# for 'Expand-HDTVariableToken' would pass for this defect and fail for nobody
# after it. This enumerates every command every payload script invokes and
# resolves each one, which is the assertion that catches the next one.
#
# THREE THINGS COUNT AS RESOLVED, and nothing else does:
#
#   1. the script defines the function itself,
#   2. the manifest exports the name, or
#   3. it is a built-in or external command Get-Command can find with the
#      module imported - which, because a module's private functions are not
#      visible to Get-Command from outside, cannot launder a private helper.
#
# A name that fails all three is either a private module function or a name
# that resolves to nothing at all. Both are the same live bug.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:manifestPath = [System.IO.Path]::Combine($script:repoRoot, 'src', 'Hephaestus', 'Hephaestus.psd1')
    $script:payloadRoot = [System.IO.Path]::Combine($script:repoRoot, 'src', 'Hephaestus', 'Payload')

    # The engine must be importable for step 3 to mean anything: Get-Command has
    # to be able to see the exported surface in order to prove that the name it
    # cannot see is private rather than merely unloaded.
    Import-Module -Name $script:manifestPath -Force -ErrorAction Stop

    $script:manifest = Import-PowerShellDataFile -LiteralPath $script:manifestPath

    $script:exported = @(
        @($script:manifest['FunctionsToExport']) +
        @($script:manifest['CmdletsToExport']) +
        @($script:manifest['AliasesToExport'])
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }

    $script:definedFunction = {
        param([string] $Path)

        $parseError = $null
        $token = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $token, [ref] $parseError)

        if (@($parseError).Count -gt 0) {
            throw ("{0} does not parse: {1}" -f $Path, (@($parseError | ForEach-Object { $_.Message }) -join '; '))
        }

        # A class method is a FunctionMemberAst wrapping a FunctionDefinitionAst
        # and is not a command; comparing on GetType().Name rather than a type
        # literal because AST type literals differ in availability between
        # engines (Get-HDTSourceFunction does the same).
        return @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true) |
                Where-Object { -not ($null -ne $_.Parent -and $_.Parent.GetType().Name -eq 'FunctionMemberAst') } |
                ForEach-Object { [string] $_.Name })
    }

    $script:invokedCommand = {
        param([string] $Path)

        $parseError = $null
        $token = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $token, [ref] $parseError)

        # GetCommandName() answers $null for '& $say' and for any other
        # invocation through a variable or an expression. Those are not names
        # and cannot be resolved against an export list; they are dropped, not
        # reported.
        return @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true) |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_.GetCommandName()) } |
                ForEach-Object {
                    [pscustomobject] @{
                        Name = [string] $_.GetCommandName()
                        Line = [int] $_.Extent.StartLineNumber
                    }
                })
    }

    $script:payloadFile = @(Get-ChildItem -LiteralPath $script:payloadRoot -Filter '*.ps1' -File |
            Sort-Object -Property Name)

    # The whole answer is computed once, here, so each It reports its own file
    # and the report names the line a developer can open.
    $script:unresolved = @{}

    foreach ($file in $script:payloadFile) {
        $defined = @(& $script:definedFunction $file.FullName)
        $miss = New-Object -TypeName System.Collections.ArrayList

        foreach ($call in @(& $script:invokedCommand $file.FullName)) {
            if ($defined -contains $call.Name) { continue }
            if ($script:exported -contains $call.Name) { continue }
            if ($null -ne (Get-Command -Name $call.Name -ErrorAction SilentlyContinue)) { continue }

            [void] $miss.Add(('{0}:{1} calls {2}' -f $file.Name, $call.Line, $call.Name))
        }

        $script:unresolved[$file.Name] = @($miss)
    }
}

Describe 'Payload scripts call only exported commands' {

    It 'finds payload scripts to check' {
        # Non-vacuity for the whole file: a Payload\ directory that had been
        # moved or renamed would make every case below pass with nothing in it.
        @($script:payloadFile).Count | Should -BeGreaterThan 0
    }

    It 'has an export list that is a list and not a wildcard' {
        # If FunctionsToExport were '*' every name below would resolve and this
        # contract would assert nothing.
        $script:exported | Should -Not -Contain '*'
        @($script:exported).Count | Should -BeGreaterThan 0
    }

    It 'names no command that only a private module function could satisfy' {
        # THE ASSERTION THIS FILE EXISTS FOR, over the SET of payload scripts.
        $miss = @($script:unresolved.Keys | Sort-Object | ForEach-Object { $script:unresolved[$_] })

        $miss | Should -BeNullOrEmpty -Because (
            "Import-Module Hephaestus gives a payload script the EXPORTED surface only, so each of these is a CommandNotFoundException on a booted machine:`n{0}" -f ($miss -join "`n"))
    }
}
