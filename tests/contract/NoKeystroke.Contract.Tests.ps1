# NOTHING IN tests/e2e TYPES INTO A VIRTUAL MACHINE.
#
# WHY THIS IS A CONTRACT AND NOT A STYLE RULE. A harness that types the command
# it wants to see run proves nothing about whether the product would have run
# it. Phase 04 typed a line at the WinPE prompt because the hand-built boot
# image's startnet.cmd launched nothing; every E2E in this repository now boots
# an image built by Update-HDTBootImage, whose startnet.cmd launches the payload
# named by workspace.yaml's entryCommand. The moment one file starts typing
# again, that difference stops being visible from outside - the VM still does
# the thing, the test still goes green, and what the product does on its own has
# quietly stopped being tested.
#
# WHY IT SCANS FOR THE WRAPPER AND NOT ONLY THE WMI CALLS. tests/helpers has
# Send-HDTLabVmText, which wraps Msvm_Keyboard's TypeText and TypeKey. A search
# for the two WMI method names alone comes back empty on a file that types
# through the wrapper on every line - which is exactly the wrong answer, and was
# exactly the answer this repository got when the question was first asked. The
# wrapper is listed FIRST below for that reason.
#
# WHY BOTH A TOKEN SCAN AND A RAW SCAN. The token scan is the real assertion: it
# ignores comments, so a file's header can explain the property it holds. The
# raw scan then keeps a plain Select-String over tests/e2e honest - the simplest
# check anybody can run without this suite - which means these names may not
# appear in E2E prose either. tests/unit/UnattendedDeploymentE2E.Tests.ps1 makes
# the same argument for one file; this makes it for the folder, and THIS file is
# where the forbidden names are allowed to be written down.
#
# ANTI-VACUITY. Every assertion below is of the form "no file contains X", which
# is trivially true of no files at all. SPIKES S9.15b records the specific way
# that bit this project: @($null).Count is 1, so even a count looked non-empty.
# So the discovery is asserted against a floor before anything is scanned, and
# the floor is on both the number of files and the volume of text.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:e2eRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/e2e'

    # THE NAMES, IN THE ONE FILE ALLOWED TO SPELL THEM. The wrapper first: it is
    # the one a search that "found nothing" had missed.
    $script:forbidden = @('Send-HDTLabVmText', 'TypeText', 'TypeKey', 'Msvm_Keyboard')

    $script:scanned = New-Object -TypeName System.Collections.ArrayList

    foreach ($file in @(Get-ChildItem -LiteralPath $script:e2eRoot -Filter '*.ps1' -File -Recurse)) {
        $text = [System.IO.File]::ReadAllText($file.FullName)

        # The comment-free token stream. Parsing rather than a regex strip,
        # because a regex that removes '#' to end of line also removes half of
        # any string containing one.
        $token = $null
        $parseError = $null
        [void] [System.Management.Automation.Language.Parser]::ParseInput(
            $text, [ref] $token, [ref] $parseError)

        $codeOnly = (@($token |
                    Where-Object { $_.Kind -ne 'Comment' } |
                    ForEach-Object { [string] $_.Text }) -join ' ')

        [void] $script:scanned.Add([pscustomobject] @{
                Name       = [string] $file.Name
                Path       = [string] $file.FullName
                Relative   = $file.FullName.Substring($script:repoRoot.Length).TrimStart('\', '/')
                Text       = $text
                CodeOnly   = $codeOnly
                ParseError = @($parseError)
            })
    }

    $script:totalCodeLength = 0
    foreach ($row in $script:scanned) { $script:totalCodeLength += $row.CodeOnly.Length }

    # -- the whole test tree, for the prompt rule below -----------------------
    #
    # A SECOND, WIDER SCAN, because the rule below is not about virtual machines
    # - it is about this suite stopping to ask a human anything, anywhere.
    #
    # Token stream only. This file has to spell the forbidden name in its own
    # prose to explain the rule, and a raw scan would therefore convict itself.
    $script:testRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests'
    $script:scannedTest = New-Object -TypeName System.Collections.ArrayList

    foreach ($file in @(Get-ChildItem -LiteralPath $script:testRoot -Filter '*.Tests.ps1' -File -Recurse)) {

        # THIS FILE IS EXEMPT FROM ITS OWN RULE, and for the same reason the
        # header is allowed to spell Msvm_Keyboard: the rule has to name the
        # thing it forbids in order to search for it. The name appears here in
        # a search pattern, which is code rather than prose, so the token scan
        # would otherwise convict the only file that may say it.
        if ($file.Name -eq 'NoKeystroke.Contract.Tests.ps1') { continue }

        $text = [System.IO.File]::ReadAllText($file.FullName)

        $token = $null
        $parseError = $null
        [void] [System.Management.Automation.Language.Parser]::ParseInput(
            $text, [ref] $token, [ref] $parseError)

        [void] $script:scannedTest.Add([pscustomobject] @{
                Relative = $file.FullName.Substring($script:repoRoot.Length).TrimStart('\', '/')
                CodeOnly = (@($token |
                            Where-Object { $_.Kind -ne 'Comment' } |
                            ForEach-Object { [string] $_.Text }) -join ' ')
            })
    }
}

Describe 'the no-keystroke contract' {

    Context 'it scanned something' {

        It 'found the E2E folder' {
            Test-Path -LiteralPath $script:e2eRoot -PathType Container | Should -BeTrue
        }

        It 'found at least three E2E scripts' {
            # Deployment, UnattendedDeployment, WinPeSmoke, and the payloads they
            # stage. A floor rather than -gt 0, for the reason in the header.
            @($script:scanned).Count | Should -BeGreaterThan 3 -Because (
                'every "no file types" assertion below is vacuously true of an empty scan')
        }

        It 'read a meaningful volume of code, not empty strings' {
            $script:totalCodeLength | Should -BeGreaterThan 40000 -Because (
                'the E2E suite is thousands of lines; a small total here means the files were found but not read')
        }

        It 'parsed every E2E script it scanned' -ForEach @('Deployment.E2E.Tests.ps1', 'UnattendedDeployment.E2E.Tests.ps1', 'WinPeSmoke.E2E.Tests.ps1') {
            # Named explicitly, so deleting a file cannot quietly shrink the scan
            # to the remaining ones and stay green.
            #
            # CAPTURED BEFORE THE PIPELINE. Inside Where-Object, $_ and $PSItem
            # are the pipeline element, not the -ForEach value: comparing
            # $_.Name to $PSItem there compares a row with itself.
            $wanted = $PSItem

            $match = @($script:scanned | Where-Object { $_.Name -eq $wanted })

            @($match).Count | Should -Be 1 -Because ("{0} is expected in tests/e2e" -f $wanted)
            @($match[0].ParseError).Count | Should -Be 0 -Because (
                (@($match[0].ParseError | ForEach-Object { $_.Message }) -join "`n"))
        }
    }

    Context 'no E2E script sends keyboard input' {

        It 'names no <_> in code' -ForEach @('Send-HDTLabVmText', 'TypeText', 'TypeKey', 'Msvm_Keyboard') {
            $name = $PSItem
            $offender = @($script:scanned |
                    Where-Object { $_.CodeOnly -match [regex]::Escape($name) } |
                    ForEach-Object { $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                "{0} types into a VM. Found in: {1}. A harness that types the command it wants to see run proves nothing about whether the product would have run it - build the image with Update-HDTBootImage and point workspace.yaml's entryCommand at the payload instead" -f
                    $name, (($offender -join ', ')))
        }

        It 'names no <_> in comments either' -ForEach @('Send-HDTLabVmText', 'TypeText', 'TypeKey', 'Msvm_Keyboard') {
            # So that a plain Select-String over tests/e2e comes back empty - the
            # check a human can run without this suite.
            $name = $PSItem
            $offender = @($script:scanned |
                    Where-Object { $_.Text -match [regex]::Escape($name) } |
                    ForEach-Object { $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                "a plain Select-String for '{0}' over tests/e2e must come back empty. Found in: {1}. Discuss the property without naming the call, and point at tests/contract/NoKeystroke.Contract.Tests.ps1" -f
                    $name, (($offender -join ', ')))
        }
    }

    Context 'no test stops to ask a human for a parameter' {

        # THE SAME PROPERTY AS THE RULES ABOVE, ONE LAYER OUT. Those keep a test
        # from typing INTO a machine; this keeps a test from making a machine
        # type back.
        #
        # HOW IT BIT US. A pair of tests proved a parameter was mandatory by
        # calling the command without it and asserting the resulting error id.
        # That works on a non-interactive host - and on an INTERACTIVE one
        # PowerShell does the other thing it is allowed to do: it prompts.
        #
        #     cmdlet New-HDTServiceCatalog at command pipeline position 1
        #     Supply values for the following parameters:
        #     Clock:
        #
        # The suite then sits there, mid-run, waiting on a keystroke, with no
        # failure and no output - which is precisely what this whole contract
        # exists to prevent. It cost a real session's flow before it was found.
        #
        # WHAT TO DO INSTEAD. Assert the declaration rather than the binder:
        #
        #     (Get-Command -Name 'Verb-HDTNoun').Parameters['Clock'].Attributes |
        #         Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        #
        # Whether PowerShell enforces Mandatory is PowerShell's business. That
        # the parameter IS mandatory is ours, and metadata says so without
        # invoking anything.

        It 'scanned the whole test tree' {
            # Anti-vacuity, same as above: "no file contains X" is trivially
            # true of no files.
            @($script:scannedTest).Count | Should -BeGreaterThan 50 -Because (
                'this repository has hundreds of test files; a small count means the scan missed them')
        }

        It 'never proves a mandatory parameter by omitting it' {
            $offender = @($script:scannedTest |
                    Where-Object { $_.CodeOnly -match 'MissingMandatoryParameter' } |
                    ForEach-Object { $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                ("omitting a mandatory parameter PROMPTS on an interactive host and hangs the run with no output. Found in: {0}. Assert the parameter's Mandatory attribute through Get-Command instead - see the comment above this test" -f
                    ($offender -join ', ')))
        }
    }

    Context 'the boot images the E2E suite boots are built, not hand-made' {

        It 'no E2E script boots the hand-built scratch ISO' {
            # THE OTHER HALF OF THE SAME PROPERTY. The typed line existed because
            # the image at this path ran a startnet.cmd that launched nothing. A
            # file that boots it again would have to type again to do anything.
            $offender = @($script:scanned |
                    Where-Object { $_.CodeOnly -match 'HDTPE_x64_uefi\.iso' } |
                    ForEach-Object { $_.Relative })

            @($offender).Count | Should -Be 0 -Because (
                'that ISO was built by hand in SPIKES S1/S3 and launches nothing at boot. Found in: {0}. Build the image with Update-HDTBootImage instead' -f (($offender -join ', ')))
        }
    }
}
