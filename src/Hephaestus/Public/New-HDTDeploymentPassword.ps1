function New-HDTDeploymentPassword {
    <#
        .SYNOPSIS
            Generates the per-deployment local Administrator password.

        .DESCRIPTION
            DESIGN 4.5.2: "The Administrator password used during deployment is
            generated at run start (high entropy, stored only in the state
            document on the machine being built), not a fixed corporate password
            reused across the fleet. If it leaks it is worth one machine,
            mid-build."

            The value is returned and nothing else. It reaches exactly two
            places: the DefaultPassword LSA secret, and state.json's
            deploymentPassword - until Clear-HDTAutoLogon nulls it. It is never
            put in a record, a message, a report or the registry, and a test
            asserts that by reading this file's own text.

            THE ALPHABET, and why each excluded character is excluded:

                A-Z  a-z  0-9  ! # $ * + - = ? @ _              72 characters

            Everything else is deliberately absent. & < > " ' break unattend.xml
            (or force escaping that some consumers get wrong); % breaks %Var%
            expansion in a rules file or a command line; ^ | \ / and space break
            a command line. A password that cannot survive being handled is worse
            than a shorter one, and the entropy cost is small: 72 characters over
            24 positions is about 148 bits.

            COMPLEXITY WITHOUT A RETRY LOOP. Windows complexity wants three of
            four character classes; this takes one character from each of the
            four by construction, fills the rest from the whole alphabet, and
            then shuffles. Generating and re-rolling until a password happened to
            satisfy the rule would work too, but it biases the distribution in a
            way that is hard to reason about and impossible to test.

            REJECTION SAMPLING, not modulo. Bytes come from the injected
            generator one at a time. A byte at or above the largest multiple of
            the target size is discarded and redrawn, so every character is
            equally likely. Folding a byte with a modulo would make the first
            256 mod n characters of the alphabet more likely than the rest.
            RandomNumberGenerator's own integer helper is .NET Core only and does
            not exist under Windows PowerShell 5.1, which is the engine's floor,
            so the mapping is written out here.

            PowerShell's own random cmdlet is not used and must not be: it is not
            a CSPRNG. A test asserts its absence by reading this file, which is
            also why it is not named here.

        .PARAMETER Length
            How many characters. 16 to 127, defaulting to 24.

        .PARAMETER RandomNumberGenerator
            The source of randomness - anything exposing GetBytes([byte[]]).
            Defaults to
            [System.Security.Cryptography.RandomNumberGenerator]::Create().
            Injectable so the byte-to-character mapping is testable: the same
            stream twice must give the same password.

        .OUTPUTS
            System.String

        .EXAMPLE
            $password = New-HDTDeploymentPassword

            A 24 character password, different on every call.

        .EXAMPLE
            $password = New-HDTDeploymentPassword -Length 32
            Set-HDTAutoLogon -Registry $registry -Lsa $lsa -UserName 'Administrator' -Password $password -RemainingLeg 3

            The only two things that are ever done with it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Generates a value and returns it; it changes no state.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [ValidateRange(16, 127)]
        [int] $Length = 24,

        [Parameter()]
        [object] $RandomNumberGenerator
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $generator = $RandomNumberGenerator
    $owned = $false
    if (-not $PSBoundParameters.ContainsKey('RandomNumberGenerator')) {
        $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $owned = $true
    }

    try {
        # One uniformly distributed index in 0..($Size - 1), by rejection
        # sampling over single bytes. A scriptblock rather than a nested
        # function so the file holds exactly one command (DESIGN 15.1).
        $drawIndex = {
            param([int] $Size)

            $ceiling = [int] ([math]::Floor(256 / $Size)) * $Size
            $buffer = New-Object -TypeName 'System.Byte[]' -ArgumentList 1

            do {
                $generator.GetBytes($buffer)
            } while ([int] $buffer[0] -ge $ceiling)

            return ([int] $buffer[0]) % $Size
        }

        $upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        $lower = 'abcdefghijklmnopqrstuvwxyz'
        $digit = '0123456789'
        $symbol = '!#$*+-=?@_'
        $every = $upper + $lower + $digit + $symbol

        $character = New-Object -TypeName System.Collections.ArrayList

        # One from each class first, so complexity is guaranteed rather than
        # likely, then the rest from the whole alphabet.
        foreach ($class in @($upper, $lower, $digit, $symbol)) {
            [void] $character.Add($class[(& $drawIndex $class.Length)])
        }

        for ($index = $character.Count; $index -lt $Length; $index++) {
            [void] $character.Add($every[(& $drawIndex $every.Length)])
        }

        # Fisher-Yates, so the four guaranteed characters are not always in the
        # first four positions - which would leak the alphabet's shape.
        for ($index = $character.Count - 1; $index -gt 0; $index--) {
            $swap = & $drawIndex ($index + 1)
            $held = $character[$index]
            $character[$index] = $character[$swap]
            $character[$swap] = $held
        }

        return (-join $character)
    } finally {
        if ($owned) {
            $generator.Dispose()
        }
    }
}
