function New-HDTRegistryService {
    <#
        .SYNOPSIS
            Creates the real IRegistryService adapter over the registry provider.

        .DESCRIPTION
            The one place in HDT that reads the registry. PROJECT constraint 4
            forbids engine logic from touching it directly, so
            Get-HDTMachineFact receives this object and can be swapped for
            New-HDTFakeRegistryService in a test.

            Six IRegistryService methods, plus EnsureKey. TestPath and GetValue are the read subset the fact
            gatherer needs, which today is the SecureBoot state key.
            NewKey, SetValue, RemoveValue and RemoveKey are the write half
            the autologon lifecycle runs on.

            REMOVING SOMETHING THAT IS NOT THERE IS NOT AN ERROR. The
            teardown runs on machines in unknown states - an image that already
            carried a DefaultPassword, a run that died between two writes - and a
            teardown that throws on the first absent value is a teardown that
            does not finish, leaving a machine armed with six of nine artifacts
            cleared.

            SetValue creates the key first because New-ItemProperty fails on a
            key that does not exist - through EnsureKey, which builds the path a
            level at a time. It does NOT use `New-Item -Force`: on the registry
            provider that means "delete this key tree and make an empty one", and
            using it here wiped a live Winlogon key mid-deployment. The comment
            above EnsureKey has the run and the failure.

            RemoveKey goes through Get-Item so that an absent key is a no-op, and
            counts children first so that a key with children and no Recurse is
            refused rather than PROMPTED FOR - which is what Remove-Item does
            there, and what hung. That count is the only branch in this adapter,
            and it is here because a prompt cannot be expressed as a pipeline.

            GetValue returns $null for a missing key and for a missing value
            name, and never throws. That is the contract, not a branch on data:
            on a BIOS machine
            HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State genuinely
            does not exist, and a gatherer that had to catch would swallow real
            errors too.

            Paths are PowerShell provider paths (HKLM:\...). The long hive names
            - HKEY_LOCAL_MACHINE\ and friends - are accepted as synonyms, because
            that is how a runbook or a rules file tends to write them.

            Every call is recorded in $Operations, before it can throw, exactly
            as the fakes record (tests/helpers/README.md section 4), so
            provenance and query-order assertions work against either
            implementation.

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with the six
            IRegistryService ScriptMethods. Note that Get-Member -MemberType
            Method does NOT list a ScriptMethod - use -MemberType Method,
            ScriptMethod.

        .EXAMPLE
            $registry = New-HDTRegistryService
            $registry.GetValue('HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State', 'UEFISecureBootEnabled')

            Returns 1 on a Secure Boot machine and $null on a BIOS machine, which
            is what HDTSecureBootEnabled is derived from.

        .EXAMPLE
            $registry = New-HDTRegistryService
            $registry.SetValue('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon', 'AutoLogonCount', 3, 'DWord')

            Three more autologons, as the reboot ceremony arms them. A lab test
            observed the count reading 2, 1, 0 across those three legs.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'RegistryService'

        # SET BY THE PAYLOAD ONCE THERE IS A LOG TO SET IT TO. The adapters are
        # built before the log context exists - see Start-HDTDeployment and
        # Start-HDTResume - so this is assigned afterwards rather than passed to
        # the factory. $null until then, and Note writes nothing while it is.
        LogContext  = $null
    }

    # WHAT IT TOLERATED, SAID OUT LOUD. This adapter's whole contract is that
    # absence is not an error: a key that is already there, a value that is
    # already gone. Every one of those used to be a silent no-op, and a silently
    # tolerated condition is the next mystery - the run that failed on
    # 2026-08-30 spent its last minute in exactly these calls and the log has not
    # one line about what any of them found.
    #
    # Info, not Debug: an administrator reading this a week later needs it to
    # explain the outcome, and Debug is for volume rather than for importance.
    $service | Add-Member -MemberType ScriptMethod -Name Note -Value {
        param([string] $Message, [System.Collections.IDictionary] $Data)

        if ($null -eq $this.LogContext) {
            return
        }

        Write-HDTLog -Context $this.LogContext -Component 'Registry' -Message $Message -Data $Data
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return , ([string[]] @($this.Operations | ForEach-Object { $_.Operation }))
    }

    $service | Add-Member -MemberType ScriptMethod -Name NormalizePath -Value {
        param([string] $Path)

        $normalized = $Path
        $normalized = $normalized -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM:\'
        $normalized = $normalized -replace '^HKEY_CURRENT_USER\\', 'HKCU:\'
        $normalized = $normalized -replace '^HKEY_CLASSES_ROOT\\', 'HKCR:\'
        $normalized = $normalized -replace '^HKEY_USERS\\', 'HKU:\'

        return $normalized.TrimEnd('\')
    }

    $service | Add-Member -MemberType ScriptMethod -Name TestPath -Value {
        param([string] $Path)

        $this.Record('TestPath', @($Path))

        return [bool] (Test-Path -LiteralPath $this.NormalizePath($Path))
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetValue -Value {
        param([string] $Path, [string] $Name)

        $this.Record('GetValue', @($Path, $Name))

        $item = Get-ItemProperty -LiteralPath $this.NormalizePath($Path) -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            return $null
        }

        $property = $item.PSObject.Properties[$Name]
        if ($null -eq $property) {
            return $null
        }

        return $property.Value
    }

    # NOT PART OF IRegistryService. It is the create-if-missing primitive that
    # NewKey and SetValue both need, and it is one method so the two cannot drift
    # apart again.
    #
    # `New-Item -Force` ON THE REGISTRY PROVIDER MEANS DELETE, NOT CREATE.
    # On the file system -Force means "and don't complain if it is already
    # there". On the registry provider it means "DELETE THIS KEY TREE AND MAKE AN
    # EMPTY ONE": the provider sees the key, sees Force, and calls
    # RegistryKey.DeleteSubKeyTree before recreating it. Every value and every
    # subkey under it is gone.
    #
    # BOTH WRITERS USED IT, so every SetValue silently emptied the key it was
    # writing to. Nothing noticed while the only keys involved were HDT's own
    # empty ones - and then run-20260830-204613 armed autologon a second time,
    # in the full OS, and aimed it at a live
    # HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon: Shell,
    # Userinit, Notify, GPExtensions, the lot. It did not even finish, throwing
    # ArgumentException "Cannot delete a subkey tree because the subkey does not
    # exist" part-way down a tree it had no business walking - which reached the
    # log as "Exception calling SetValue with 4 argument(s)", a set that was
    # really a delete. The WinPE leg had survived the same call minutes earlier
    # because WinPE's Winlogon is a shallow RAM-hive copy that deletes cleanly.
    #
    # SO IT IS BUILT ANCESTOR BY ANCESTOR INSTEAD. New-Item WITHOUT -Force never
    # deletes, but it also refuses a path whose parent is missing and does not
    # create the chain - which is the one thing -Force was genuinely wanted for.
    # Walking the path creates each level that is absent and no-ops on each level
    # that is present.
    $service | Add-Member -MemberType ScriptMethod -Name EnsureKey -Value {
        param([string] $Path)

        $full = $this.NormalizePath($Path)
        $part = $full.Split('\')

        $level = [System.Collections.ArrayList]::new()
        for ($depth = 1; $depth -lt $part.Count; $depth++) {
            [void] $level.Add((($part[0..$depth]) -join '\'))
        }

        # READ BEFORE WRITING, so the log can say which levels this call actually
        # created and which were already there. That is the difference between
        # "HDT made this key" and "HDT found it", and it is the question asked of
        # a machine that came back wrong.
        $absent = @($level | Where-Object { -not (Test-Path -LiteralPath $_) })

        # SilentlyContinue COVERS EXACTLY ONE CONDITION - "this level is already
        # there", which New-Item reports as a non-terminating error and which is
        # the normal case for every level but the last.
        foreach ($each in $level) {
            New-Item -Path $each -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }

        # AND IT IS NOT ALLOWED TO HIDE ANYTHING ELSE. A denied write or a hive
        # that is not mounted is swallowed by the line above, so the key is read
        # back: the failure then reaches the caller here, naming the key, rather
        # than as a confusing New-ItemProperty error one line later.
        Get-Item -LiteralPath $full -ErrorAction Stop | Out-Null

        $this.Note(
            ("registry key '{0}' is present; {1} of its {2} level(s) had to be created ({3})" -f
                $full, $absent.Count, $level.Count,
                (@($absent) -join ', ')),
            ([ordered] @{
                    path         = $full
                    levelCount   = [int] $level.Count
                    createdCount = [int] $absent.Count
                    created      = [string[]] @($absent)
                    alreadyThere = [string[]] @($level | Where-Object { $absent -notcontains $_ })
                }))
    }

    $service | Add-Member -MemberType ScriptMethod -Name NewKey -Value {
        param([string] $Path)

        $this.Record('NewKey', @($Path))

        $this.EnsureKey($Path)
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetValue -Value {
        param([string] $Path, [string] $Name, [object] $Value, [string] $Type)

        $this.Record('SetValue', @($Path, $Name, $Value, $Type))

        $full = $this.NormalizePath($Path)
        $this.EnsureKey($full)

        # READ BEFORE THE WRITE, so the log can say whether this was a new value
        # or an overwrite - which is the difference between HDT configuring a
        # machine and HDT changing something that was already set.
        $before = $null -ne (Get-ItemProperty -LiteralPath $full -Name $Name -ErrorAction SilentlyContinue)

        # -Force HERE IS THE FILE-SYSTEM MEANING AND IS CORRECT: on a VALUE it
        # overwrites, and it deletes no key.
        New-ItemProperty -LiteralPath $full -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null

        # THE NAME, THE TYPE AND THE LENGTH - NEVER THE VALUE. Everything else
        # this adapter logs is said in full, and this one thing is not: any
        # caller may put a secret through SetValue, and DESIGN 4.5.2's guarantee
        # that the deployment password reaches no log must not depend on every
        # future caller remembering. The type is what actually goes wrong here
        # anyway - Winlogon ignores AutoLogonCount written as a String.
        $this.Note(
            ("registry value '{0}' under '{1}' was written as {2} ({3} character(s)), {4}" -f
                $Name, $full, $Type, ([string] $Value).Length,
                @('which is a new value', 'overwriting a value that was already there')[[int] $before]),
            ([ordered] @{
                    path        = $full
                    name        = $Name
                    type        = $Type
                    valueLength = ([string] $Value).Length
                    overwrote   = [bool] $before
                }))
    }

    $service | Add-Member -MemberType ScriptMethod -Name RemoveValue -Value {
        param([string] $Path, [string] $Name)

        $this.Record('RemoveValue', @($Path, $Name))

        $full = $this.NormalizePath($Path)

        # READ FIRST, SO THE TOLERATED CASE IS VISIBLE. Absent is not an error -
        # teardown runs on machines in unknown states - but "there was nothing to
        # remove" and "it was removed" are different facts about the machine, and
        # a teardown that reports six cleared artifacts should be able to say
        # which of them were already gone before it started.
        $keyThere = [bool] (Test-Path -LiteralPath $full)
        $valueThere = [bool] ($null -ne (Get-ItemProperty -LiteralPath $full -Name $Name -ErrorAction SilentlyContinue))

        Remove-ItemProperty -LiteralPath $full -Name $Name -Force -ErrorAction SilentlyContinue

        $this.Note(
            ("registry value '{0}' under '{1}': the key was {2} and the value was {3}" -f
                $Name, $full,
                @('not there', 'there')[[int] $keyThere],
                @('already absent, so the remove was a no-op', 'present, and has been removed')[[int] $valueThere]),
            ([ordered] @{
                    path       = $full
                    name       = $Name
                    keyExisted = $keyThere
                    existed    = $valueThere
                    removed    = $valueThere
                }))
    }

    $service | Add-Member -MemberType ScriptMethod -Name RemoveKey -Value {
        param([string] $Path, [bool] $Recurse)

        $this.Record('RemoveKey', @($Path, $Recurse))

        $full = $this.NormalizePath($Path)

        # A KEY WITH CHILDREN AND NO Recurse DID NOT THROW - IT ASKED, AND WAITED.
        # This line used to read "still reaches Remove-Item and still throws",
        # which is what the file system does and not what the registry provider
        # does. `Remove-Item -Recurse:$false` on a key that has subkeys calls
        # ShouldContinue, and NEITHER -Force NOR -Confirm:$false answers it. In
        # WinPE's interactive host that is a teardown stopped dead on a question
        # nobody is standing there to answer; under -NonInteractive it is a
        # PSInvalidOperationException naming the HOST rather than the key.
        #
        # Counting first makes the refusal deterministic and names the key, which
        # is the behaviour the fake has always had and the contract now pins.
        # THE ONE BRANCH IN THIS ADAPTER, and it is here because a prompt cannot
        # be expressed as a pipeline - see the note on branch-free adapters in
        # the description.
        $child = @(Get-ChildItem -LiteralPath $full -ErrorAction SilentlyContinue)

        if ($child.Count -gt 0 -and -not $Recurse) {
            throw [System.InvalidOperationException]::new(
                ("The registry key '{0}' has {1} child key(s) and Recurse was not requested." -f $Path, $child.Count))
        }

        $existed = [bool] (Test-Path -LiteralPath $full)

        # Get-Item yields nothing for an absent key, so the pipeline is a no-op
        # there - removing something that is not there is not an error.
        Get-Item -LiteralPath $full -ErrorAction SilentlyContinue |
            Remove-Item -Recurse:$Recurse -Force -Confirm:$false -ErrorAction Stop

        $this.Note(
            ("registry key '{0}' was {1}; it had {2} child key(s) and recurse was {3}" -f
                $full,
                @('already absent, so the remove was a no-op', 'present, and has been removed')[[int] $existed],
                $child.Count,
                @('not asked for', 'asked for')[[int] $Recurse]),
            ([ordered] @{
                    path       = $full
                    existed    = $existed
                    removed    = $existed
                    childCount = [int] $child.Count
                    recurse    = $Recurse
                }))
    }

    return $service
}
