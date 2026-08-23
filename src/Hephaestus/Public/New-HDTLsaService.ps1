function New-HDTLsaService {
    <#
        .SYNOPSIS
            Creates the real ILsaService adapter over LSA private data.

        .DESCRIPTION
            The one place in HDT that touches LSA private data. The
            deployment password is stored as an LSA secret named DefaultPassword,
            not as registry cleartext, because Winlogon reads it from there and a
            registry hive can be lifted by any local read, a registry backup or a
            captured image. This is the mechanism Sysinternals' Autologon.exe
            uses, and SPIKES.md S8 observed three real autologons driven by that
            secret alone, with no registry DefaultPassword anywhere.

            The secret name is DefaultPassword with no L$ or M$ prefix. HDT
            writes only that one.

            THIS IS AN UNTESTED ADAPTER, and deliberately so:
            there is no way to unit test it that does not write an LSA secret on
            the machine running the suite. Its contract row is opt-in - elevated
            AND $env:HDT_ALLOW_LSA_TEST -eq '1' - and even then only reads. The
            price of not testing it is that it must stay dumb: the only branches
            below are the Add-Type guard and the status checks, and every
            decision about WHAT to store lives in Set-HDTAutoLogon and
            Clear-HDTAutoLogon, which are tested against New-HDTFakeLsaService.
            Do not add logic here.

            A null data pointer passed to LsaStorePrivateData deletes the secret,
            which is why RemoveSecret is a store of nothing rather than a
            separate API. STATUS_OBJECT_NAME_NOT_FOUND (0xC0000034) from
            LsaRetrievePrivateData means the secret is not there, which is a fact
            rather than a failure, so GetSecret returns $null for it.

            Storing or reading LSA private data requires elevation. A
            non-elevated caller gets a Win32Exception from LsaOpenPolicy saying
            access is denied, which is the truth and is more useful than a
            swallowed $null.

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with SetSecret, GetSecret
            and RemoveSecret ScriptMethods. Note that Get-Member -MemberType
            Method does NOT list a ScriptMethod - use -MemberType Method,
            ScriptMethod.

        .EXAMPLE
            $lsa = New-HDTLsaService
            $lsa.GetSecret('DefaultPassword')

            Reads the autologon password Windows itself stores there. $null when
            there is none, which is the normal state of a machine nobody has
            deployed to.

        .EXAMPLE
            @($lsa.GetOperationName())

            What has been asked of it this run. The engine never writes an LSA secret
            without recording that it did - a password that exists and cannot be
            accounted for is the thing DESIGN 4.5.2 is careful about.
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

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Compiled once per session. The guard is one of the two branches this
    # adapter is allowed to have.
    if (-not ('HDTLsaInterop' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class HDTLsaInterop
{
    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_UNICODE_STRING
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_OBJECT_ATTRIBUTES
    {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern uint LsaOpenPolicy(IntPtr SystemName, ref LSA_OBJECT_ATTRIBUTES ObjectAttributes, uint DesiredAccess, out IntPtr PolicyHandle);

    [DllImport("advapi32.dll")]
    public static extern uint LsaClose(IntPtr ObjectHandle);

    [DllImport("advapi32.dll")]
    public static extern uint LsaFreeMemory(IntPtr Buffer);

    [DllImport("advapi32.dll")]
    public static extern int LsaNtStatusToWinError(uint Status);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern uint LsaStorePrivateData(IntPtr PolicyHandle, ref LSA_UNICODE_STRING KeyName, ref LSA_UNICODE_STRING PrivateData);

    [DllImport("advapi32.dll", EntryPoint = "LsaStorePrivateData", SetLastError = true)]
    public static extern uint LsaDeletePrivateData(IntPtr PolicyHandle, ref LSA_UNICODE_STRING KeyName, IntPtr PrivateData);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern uint LsaRetrievePrivateData(IntPtr PolicyHandle, ref LSA_UNICODE_STRING KeyName, out IntPtr PrivateData);
}
'@
    }

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'LsaService'

        # POLICY_ALL_ACCESS for the 2000/XP-era policy object. Storing private
        # data needs POLICY_CREATE_SECRET and reading needs
        # POLICY_GET_PRIVATE_INFORMATION; asking for the lot keeps the adapter
        # from having to decide which.
        PolicyAccess = 0x00000FFF

        # STATUS_OBJECT_NAME_NOT_FOUND (0xC0000034). The secret is not there,
        # which is a fact rather than a failure.
        #
        # WRITTEN IN DECIMAL DELIBERATELY. PowerShell parses a hex literal that
        # fits in 32 bits as an Int32, so 0xC0000034 is -1073741772, and
        # comparing it against the [uint32] an LSA call returns is silently
        # false. Verified on both engines: the first cut of this adapter used the
        # hex form and every "secret does not exist" turned into a Win32Exception
        # instead of $null.
        NotFound     = [uint32] 3221225524
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

    $service | Add-Member -MemberType ScriptMethod -Name NewUnicodeString -Value {
        param([string] $Value)

        $string = New-Object -TypeName 'HDTLsaInterop+LSA_UNICODE_STRING'
        $string.Buffer = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($Value)
        $string.Length = [uint16] ($Value.Length * 2)
        $string.MaximumLength = [uint16] (($Value.Length + 1) * 2)

        return $string
    }

    $service | Add-Member -MemberType ScriptMethod -Name OpenPolicy -Value {
        $attributes = New-Object -TypeName 'HDTLsaInterop+LSA_OBJECT_ATTRIBUTES'
        $attributes.Length = [System.Runtime.InteropServices.Marshal]::SizeOf($attributes)

        $policy = [IntPtr]::Zero
        $status = [HDTLsaInterop]::LsaOpenPolicy([IntPtr]::Zero, [ref] $attributes, $this.PolicyAccess, [ref] $policy)
        $this.AssertStatus($status, 'LsaOpenPolicy')

        return $policy
    }

    $service | Add-Member -MemberType ScriptMethod -Name AssertStatus -Value {
        param([uint32] $Status, [string] $Api)

        if ($Status -ne 0) {
            $code = [HDTLsaInterop]::LsaNtStatusToWinError($Status)
            throw (New-Object -TypeName System.ComponentModel.Win32Exception -ArgumentList $code,
                ("{0} failed with NTSTATUS 0x{1:X8} (Win32 error {2})." -f $Api, $Status, $code))
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetSecret -Value {
        param([string] $Name, [string] $Value)

        # The name is recorded; the value never is.
        $this.Record('SetSecret', @($Name, '<redacted>'))

        $policy = $this.OpenPolicy()
        try {
            $key = $this.NewUnicodeString($Name)
            $data = $this.NewUnicodeString($Value)
            try {
                $status = [HDTLsaInterop]::LsaStorePrivateData($policy, [ref] $key, [ref] $data)
                $this.AssertStatus($status, 'LsaStorePrivateData')
            } finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($data.Buffer)
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($key.Buffer)
            }
        } finally {
            [void] [HDTLsaInterop]::LsaClose($policy)
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetSecret -Value {
        param([string] $Name)

        $this.Record('GetSecret', @($Name))

        $policy = $this.OpenPolicy()
        try {
            $key = $this.NewUnicodeString($Name)
            try {
                $buffer = [IntPtr]::Zero
                $status = [HDTLsaInterop]::LsaRetrievePrivateData($policy, [ref] $key, [ref] $buffer)

                if ($status -eq $this.NotFound) {
                    return $null
                }
                $this.AssertStatus($status, 'LsaRetrievePrivateData')

                try {
                    $data = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
                        $buffer, [type] 'HDTLsaInterop+LSA_UNICODE_STRING')

                    return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($data.Buffer, [int] ($data.Length / 2))
                } finally {
                    [void] [HDTLsaInterop]::LsaFreeMemory($buffer)
                }
            } finally {
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($key.Buffer)
            }
        } finally {
            [void] [HDTLsaInterop]::LsaClose($policy)
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name RemoveSecret -Value {
        param([string] $Name)

        $this.Record('RemoveSecret', @($Name))

        $policy = $this.OpenPolicy()
        try {
            $key = $this.NewUnicodeString($Name)
            try {
                # A null data pointer deletes. STATUS_OBJECT_NAME_NOT_FOUND means
                # it was already gone, which teardown treats as success.
                $status = [HDTLsaInterop]::LsaDeletePrivateData($policy, [ref] $key, [IntPtr]::Zero)

                if ($status -eq $this.NotFound) {
                    return
                }
                $this.AssertStatus($status, 'LsaStorePrivateData (delete)')
            } finally {
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($key.Buffer)
            }
        } finally {
            [void] [HDTLsaInterop]::LsaClose($policy)
        }
    }

    return $service
}
