function New-HDTServiceCatalog {
    <#
        .SYNOPSIS
            Builds the injected service catalog a step reaches the outside world
            through.

        .DESCRIPTION
            PROJECT constraint 4 and DESIGN 12.2.1 in one object: "a step
            implementation may not call DISM, CIM, the filesystem or the network
            directly - it receives those through injected service objects". The
            catalog is the single thing a step is handed, and the single thing a
            test replaces to prove the step with no machine attached.

              FileSystem     IFileSystem    (mandatory)
              Clock          IClock         (mandatory)
              Registry       IRegistryService
              Lsa            ILsaService
              Process        IProcessService
              Power          IPowerService
              ScriptInvoker  IScriptInvoker
              Cim            ICimProvider
              Environment    IEnvironmentProvider
              Disk           IDiskService
              Image          IImageService
              Content        IContentProvider

            EVERY PROPERTY IS DEFINED EVEN WHERE IT IS $null. Engine code runs
            under Set-StrictMode -Version Latest, where reading a property that
            was never defined throws "The property 'Process' cannot be found on
            this object" - an error that says nothing about which step wanted
            what.

            GetRequired REPLACES THAT WITH A SENTENCE.

              $Context.Service.GetRequired('Process', 'CommandLine')

            returns the service, or throws naming both the missing service and
            the step type that asked for it. A step author writes one call and
            gets a message an administrator can act on.

            FileSystem and Clock are mandatory and nothing else is, because a
            NoOp sequence must be runnable with two services and no more.

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

        .PARAMETER FileSystem
            An IFileSystem. Mandatory.

        .PARAMETER Clock
            An IClock. Mandatory.

        .PARAMETER Registry
            An IRegistryService, or nothing.

        .PARAMETER Lsa
            An ILsaService, or nothing.

        .PARAMETER Process
            An IProcessService, or nothing.

        .PARAMETER Power
            An IPowerService, or nothing.

        .PARAMETER ScriptInvoker
            An IScriptInvoker, or nothing.

        .PARAMETER Cim
            An ICimProvider, or nothing.

        .PARAMETER Environment
            An IEnvironmentProvider, or nothing.

        .PARAMETER Disk
            An IDiskService, or nothing. DiskPartition asks for it by name.

        .PARAMETER Image
            An IImageService, or nothing. ApplyImage and ConfigureBoot ask for
            it by name.

        .PARAMETER Content
            An IContentProvider, or nothing - New-HDTLocalContentProvider or
            New-HDTSmbContentProvider (DESIGN 6). ApplyImage resolves the
            catalog's image through it when the run was started with one, which
            is the whole of DESIGN 6.2's "a provider swap, not a parallel code
            path" as far as a step is concerned.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with the twelve service
            properties and a GetRequired ScriptMethod.

        .EXAMPLE
            $catalog = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock (New-HDTClock)

            The smallest catalog that runs a NoOp sequence.

        .EXAMPLE
            $catalog = New-HDTServiceCatalog -FileSystem $fs -Clock $clock -Process (New-HDTProcessService)
            $catalog.GetRequired('Process', 'CommandLine')
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless container of service adapters; it changes no state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Clock,

        [Parameter()]
        [AllowNull()]
        [object] $Registry = $null,

        [Parameter()]
        [AllowNull()]
        [object] $Lsa = $null,

        [Parameter()]
        [AllowNull()]
        [object] $Process = $null,

        [Parameter()]
        [AllowNull()]
        [object] $Power = $null,

        [Parameter()]
        [AllowNull()]
        [object] $ScriptInvoker = $null,

        [Parameter()]
        [AllowNull()]
        [object] $Cim = $null,

        [Parameter()]
        [AllowNull()]
        [object] $Environment = $null,

        [Parameter()]
        [AllowNull()]
        [object] $Disk = $null,

        [Parameter()]
        [AllowNull()]
        [object] $Image = $null,

        [Parameter()]
        [AllowNull()]
        [object] $Content = $null
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $catalog = [pscustomobject] @{
        FileSystem    = $FileSystem
        Clock         = $Clock
        Registry      = $Registry
        Lsa           = $Lsa
        Process       = $Process
        Power         = $Power
        ScriptInvoker = $ScriptInvoker
        Cim           = $Cim
        Environment   = $Environment
        Disk          = $Disk
        Image         = $Image
        Content       = $Content
    }

    $catalog | Add-Member -MemberType ScriptMethod -Name GetRequired -Value {
        param([string] $Name, [string] $Caller)

        $asked = 'a step'
        if (-not [string]::IsNullOrWhiteSpace($Caller)) {
            $asked = "the {0} step" -f $Caller
        }

        $known = @($this.PSObject.Properties |
                Where-Object { $_.MemberType -eq 'NoteProperty' } |
                ForEach-Object { $_.Name })

        if ($known -notcontains $Name) {
            throw ("{0} asked the service catalog for '{1}', which is not a service HDT carries. The services are {2}." -f $asked, $Name, ($known -join ', '))
        }

        $service = $this.$Name
        if ($null -eq $service) {
            throw ("{0} needs the {1} service, but the run was started without one. Add it to New-HDTServiceCatalog." -f $asked, $Name)
        }

        return $service
    }

    return $catalog
}
