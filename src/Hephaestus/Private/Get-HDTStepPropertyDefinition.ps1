function Get-HDTStepPropertyDefinition {
    <#
        .SYNOPSIS
            What a step type can be asked, as a table - so the Properties sheet
            offers every setting the engine reads rather than only the ones the
            document happens to mention.

        .DESCRIPTION
            THE SHEET USED TO BUILD ONE ROW PER KEY ALREADY IN THE FILE, and a
            step's template writes only the keys it cannot start without. So
            every other setting the engine reads had no row, could not be typed
            into, and could be reached only by opening the YAML somewhere else.
            The same defect sixteen times over:

              ConfigureBoot    recovery and setBootOrder - both switches its own
                               header calls load-bearing, both defaulting to
                               true, neither turn-off-able from the console
              EnableBitLocker  pin and startupKey - while the protector list
                               OFFERED tpmPin and tpmStartupKey, which require
                               them. The console offered a choice it then made
                               impossible to satisfy
              NoOp             all five of its keys. The sheet was empty
              Tattoo           both of its keys. The sheet was empty
              Restart          message, the sentence a technician reads while
                               the machine goes down
              InstallRoles     source, the payload path for a removed feature
              ApplyUnattend    target, named in the engine's own refusal
              InstallCertificate  bootstrap

            VALIDATE NEVER HAD THE PROBLEM, and that is where this idea comes
            from: Get-HDTValidateCheckDefinition already offers every check
            whether or not the document declares one. This is that, for the rest.

            THE DOCUMENT STILL WINS. This supplies the ROW and the DEFAULT; the
            file supplies the VALUE wherever it has one. A row nobody touches is
            identical to what it was filled with, so Get-HDTConsoleStepChange
            writes nothing - which is what stops a sheet full of defaults from
            adding twelve keys to a step the first time anybody edits one of
            them (DESIGN 12).

            THE DEFAULTS HERE ARE THE ENGINE'S, quoted from the step that reads
            them. A default this table got wrong would be worse than an empty
            box: it would say, in a box that looks authoritative, that the step
            will do something it will not.

            CLOSED SETS COME FROM Get-HDTStepPropertyChoice, which is the table
            Invoke-HDTEnableBitLockerStep refuses by. Spelling them again here
            would be two lists to drift apart, and the way that goes wrong is a
            drop-down offering a value the step rejects at the machine.

            List AND Table ARE BOTH SEQUENCES AND ONLY ONE IS EDITABLE. A flat
            list of strings - features - becomes a comma line, which is what
            Get-HDTConsoleValidateCheck already does for requireVariable and the
            Command page does for its exit codes. A MAPPING - Tattoo's values,
            name to value - stays read-only, because flattening it to a line
            loses which half was which.

            A TYPE WITH A DEDICATED PAGE IS NOT HERE. ApplyImage, DiskPartition,
            Validate, InstallApplications and CommandLine own their settings on
            a page of their own and the generic sheet is collapsed for them
            entirely - a key listed in both places is a key that can disagree
            with itself while both boxes look right.

            NEITHER ARE THE COMMON KEYS. name, type, condition, continueOnError,
            disabled, runIn, timeoutMinutes, retry, resumable and log never
            reach Property at all (Import-HDTSequenceDocument), and the ones that
            are editable are edited above the tabs or on Options.

        .PARAMETER Type
            The step's type, as the document spells it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] in the order they
            should be shown, each with:

              Key      the YAML key
              Label    the caption
              Kind     Text, Check, Choice, List or Table
              Choice   the closed set, for a Choice
              Default  what the engine does when the key is absent
              Hint     one sentence behind the ?, or empty

            An empty array for a type this table says nothing about - which is
            every third-party type out of Modules\ (CLAUDE.md rule 3), and they
            go on getting their rows from the document.

        .EXAMPLE
            Get-HDTStepPropertyDefinition -Type 'ConfigureBoot'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Type
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $new = {
        param([string] $Key, [string] $Label, [string] $Kind, [string] $Default, [string] $Hint)

        return [pscustomobject] @{
            Key     = $Key
            Label   = $Label
            Kind    = $Kind
            Choice  = [string[]] @(Get-HDTStepPropertyChoice -Type $Type -Key $Key)
            Default = $Default
            Hint    = $Hint
        }
    }

    # THE ORDER IS THE ORDER TO SHOW THEM IN: what the step does first, how it
    # reports second. MDT's dialogs read that way and so does the file, because
    # every Get-HDT*StepTemplate writes its keys in this order.
    $row = switch ($Type) {

        # THE HINT UNDER 'Driver group' IS THE ONLY DOCUMENTATION MOST PEOPLE
        # WILL READ, and it has one job: teach that the path takes variables.
        # An administrator who has not met MDT's Total Control method will type
        # a literal folder name, get drivers on the one model they tested, and
        # find out on somebody else's desk that the step does nothing for every
        # other machine in the fleet. The pattern in the hint is the fix, and it
        # fits in the space the neighbouring hints use.
        #
        # WHAT IS DELIBERATELY NOT IN THE HINT: that the store's shape is the
        # administrator's own - any names, any depth - and that group match
        # skips the PnP ranking entirely. Both are true, neither changes what
        # they type into this box, and four lines under one field is a screen
        # explaining itself at the cost of the controls around it.
        'ApplyDrivers' {
            & $new 'group' 'Driver group' 'Text' 'Win11\%HDTMake%\%HDTModel%' 'A folder under Drivers\, resolved per machine - %HDTMake% and %HDTModel% are filled in as the deployment runs. Empty matches by hardware id instead.'
            & $new 'mode' 'Install' 'Choice' 'all' 'All installs every driver in the group. Matching installs only the ones this machine reports hardware for.'
            & $new 'profile' 'Selection profile' 'Text' '' 'Limits which folders are considered when matching by hardware id. Empty considers the whole driver store.'
            & $new 'target' 'Target volume' 'Text' '%HDTOSVolume%' 'The volume the drivers are injected into. Empty uses the volume the partition step published.'
        }

        'ApplyUnattend' {
            & $new 'template' 'Answer file' 'Text' '' 'The unattend.xml this step stages, relative to the sequence folder or rooted. It is copied into the image, not applied to the running machine.'
            & $new 'expand' 'Expand variables' 'Check' 'true' 'Replace %HDTComputerName% and the rest inside the answer file as it is copied. Off writes the file through untouched.'
            & $new 'target' 'Target volume' 'Text' '%HDTOSVolume%' 'The volume the answer file is written to. Empty uses the volume the partition step published, which is what nearly every sequence wants.'
        }

        # ROW ORDER IS THE TEMPLATE'S KEY ORDER: image then compress, which is
        # what Get-HDTCaptureImageStepTemplate writes out, then the three the
        # template deliberately leaves out because they have working defaults.
        'CaptureImage' {
            & $new 'image' 'Capture to' 'Text' '%HDTTaskSequenceID%.wim' 'The WIM this writes, under Captures\ on the share. A rooted path is taken as written; a name with no extension gets .wim.'
            & $new 'compress' 'Compression' 'Choice' 'max' 'max is right for an image kept for years. fast halves the capture time and costs disk; none is for a lab.'
            & $new 'name' 'Image name' 'Text' '' 'The name stored inside the WIM, which is what an Apply step asks for. Empty uses the file''s own name.'
            & $new 'description' 'Description' 'Text' '' 'Stored inside the WIM beside the name. This is what tells somebody in six months what this build was.'
            & $new 'source' 'Capture from' 'Text' '%HDTOSVolume%' 'The volume to read. Empty uses the volume the partition step published; HDT will not guess a drive letter to read an operating system out of.'
            & $new 'configFile' 'Exclusion list' 'Text' '' 'What to leave out of the image. Empty uses the share''s Control\wimscript.ini if it has one, otherwise the list HDT ships - never nothing.'
        }

        # ROW ORDER IS THE TEMPLATE'S KEY ORDER: action, then the boot image
        # the template deliberately leaves out because one name serves almost
        # every share.
        'BootToWinPE' {
            & $new 'action' 'Action' 'Choice' 'stage' 'stage copies a WinPE onto this disk, arm makes the next restart boot it, remove takes both away. stage and arm run before Sysprep; remove runs in WinPE.'
            & $new 'bootImage' 'Boot image' 'Text' 'HDTPE_x64' 'Which Boot\<name>.wim on the share to stage. Empty uses the one Update-HDTBootImage builds by default.'
        }

        'ConfigureBoot' {
            & $new 'firmware' 'Firmware' 'Choice' 'auto' 'auto reads the machine rather than trusting what the sequence assumed, and is right unless a lab is deliberately testing the other path.'
            & $new 'recovery' 'Register recovery' 'Check' 'true' 'Points the recovery environment at the WinRE image on the recovery partition. Off leaves a machine with no recovery entry.'
            & $new 'setBootOrder' 'Set firmware boot order' 'Check' 'true' 'Moves this installation to the front of the firmware boot order. Off leaves a machine that boots the network or the old installation first.'
        }

        'EnableBitLocker' {
            & $new 'drive' 'Drive' 'Text' '%HDTOSVolume%' 'The volume to encrypt. Empty uses the volume the partition step published; HDT will not guess.'
            & $new 'scope' 'Encrypt' 'Choice' 'usedSpaceOnly' 'usedSpaceOnly encrypts the blocks in use, which is right for a volume HDT has just created. full encrypts the free space too and takes far longer.'
            & $new 'method' 'Method' 'Choice' 'XtsAes256' 'The cipher. XTS is for fixed drives; use an AES-CBC method only for a volume that has to be read by an older Windows.'
            & $new 'protector' 'Protector' 'Choice' 'tpm' 'What unlocks the drive at boot. tpmPin and tpmStartupKey need the box below filled in as well.'
            & $new 'pin' 'PIN' 'Text' '' 'Required by the tpmPin protector and ignored by the others. A step that picks tpmPin without one fails at the machine.'
            & $new 'startupKey' 'Startup key path' 'Text' '' 'Required by the tpmStartupKey protector and ignored by the others.'
            & $new 'recoveryPassword' 'Recovery password' 'Check' 'true' 'Create a numerical recovery password. Off leaves a drive nobody can rescue.'
            & $new 'escrow' 'Back the key up to' 'Choice' 'ad' 'Where the recovery password is stored before encryption starts. none is for a lab; a machine whose key is nowhere is a machine that can be lost.'
            & $new 'wait' 'Wait for encryption' 'Check' 'false' 'Hold the sequence until the volume finishes encrypting. Off lets the deployment carry on while it runs in the background.'
        }

        'InstallCertificate' {
            & $new 'target' 'Target volume' 'Text' '%HDTOSVolume%' 'The volume whose certificate store is written to. Empty uses the volume the partition step published.'
            & $new 'bootstrap' 'Bootstrap document' 'Text' 'X:\HDT\bootstrap.json' 'Where the certificates are read from. A missing file is not an error - the step completes having staged nothing - so a wrong path here is silent.'
        }

        # THE ROW ORDER IS THE TEMPLATE'S KEY ORDER, and every row is a variable
        # the wizard's Computer Details page already collects - so the sheet
        # reads as "here is where each box on that page goes" rather than as
        # five things to invent.
        #
        # THERE IS NO PASSWORD ROW, AND THERE MUST NOT BE. A box here writes a
        # domain admin credential into sequence.yaml, which lives on a share
        # every machine being deployed can read and which this very console
        # prints back into a text box. The password comes from
        # HDTDomainAdminPassword in the variable bag, where every log, checkpoint
        # and report redacts it.
        'JoinDomain' {
            & $new 'domain' 'Domain' 'Text' '%HDTJoinDomain%' 'The domain to join, as the wizard collected it. Empty and with no workgroup either, the step fails rather than guessing.'
            & $new 'ou' 'Computer account OU' 'Text' '%HDTMachineObjectOU%' 'Where the computer object is created, as a distinguished name. Empty uses the domain''s default container. A refused OU is retried once without it, because the account may already exist somewhere else.'
            & $new 'workgroup' 'Workgroup' 'Text' '%HDTJoinWorkgroup%' 'The workgroup to join when no domain is set. A share seeds WORKGROUP here, so a machine nobody gave a domain to still gets a decision; the domain wins when both are set.'
            & $new 'userName' 'Join account' 'Text' '%HDTDomainAdmin%' 'The account that joins the machine. The wizard splits CORP\svc-hdt-join into this and the box below.'
            & $new 'userDomain' 'Join account domain' 'Text' '%HDTDomainAdminDomain%' 'The domain that account belongs to, when it is not the one being joined. Empty joins as a bare account name.'
        }

        'InstallRoles' {
            & $new 'features' 'Features' 'List' '' 'The Windows features to install, by name, separated by commas. The step refuses a name the target image does not have before it installs anything.'
            & $new 'includeManagementTools' 'Include management tools' 'Check' 'false' 'Install each feature''s management console and cmdlets alongside it.'
            & $new 'source' 'Payload source' 'Text' '' 'A side-by-side store for a feature whose payload was removed from the image - .NET 3.5 is the usual case. Empty lets Windows look where it normally would.'
        }

        'NoOp' {
            & $new 'message' 'Message' 'Text' '' 'What the step logs. Empty logs the step''s own name.'
            & $new 'exitCode' 'Exit code' 'Text' '0' 'The code the step reports. Anything but 0 with Fail off is still a pass; this is for rehearsing what a real step''s code would do.'
            & $new 'fail' 'Fail' 'Check' 'false' 'Make the step fail. This is how a sequence''s error handling is rehearsed without breaking a real step.'
            & $new 'failAttempt' 'Fail until attempt' 'Text' '0' 'Fail while the attempt number is at or below this, then pass - which is how a retry is rehearsed.'
            & $new 'requestReboot' 'Request a reboot' 'Check' 'false' 'Report that a restart is wanted, so the sequence''s reboot and resume can be rehearsed.'
        }

        'PowerShell' {
            & $new 'script' 'Script' 'Text' '' 'The .ps1 to run, relative to the workspace or rooted. It runs in the engine''s own session, so it can see the task sequence variables.'
        }

        'Restart' {
            & $new 'delaySeconds' 'Delay' 'Text' '0' 'Seconds between the step finishing and the machine going down, so somebody standing at it can read the message.'
            & $new 'message' 'Message' 'Text' 'a restart was requested' 'What is shown while the machine restarts.'
        }

        'SetVariable' {
            & $new 'variable' 'Variable name' 'Text' '' 'The name to set. It has to begin with HDT - the engine reserves everything else, and refuses a name starting with an underscore outright.'
            & $new 'value' 'Value' 'Text' '' 'What to set it to. %Other% tokens in here are expanded when the step runs, not when it is saved.'
        }

        # ONE ROW, AND IT IS THE ONE THE TEMPLATE LEAVES OUT. The template writes
        # runIn and timeoutMinutes, both of which are common keys edited on the
        # Options tab rather than here.
        'Sysprep' {
            & $new 'unattend' 'Answer file' 'Text' '' 'The GENERALIZE-pass answer file, which is not the deployment''s unattend.xml. It is staged where sysprep looks and deleted afterwards, so it does not travel inside the image. Empty runs sysprep without one.'
        }

        'Tattoo' {
            & $new 'path' 'Registry key' 'Text' 'HKLM:\SOFTWARE\Hephaestus\Deployment' 'Where the deployment record is stamped. This is what an audit reads months later to find out what built the machine.'
            & $new 'values' 'Extra values' 'Table' '' 'Values of your own, stamped beside the standard ones. A name that collides with a standard stamp replaces it.'
        }

        default { }
    }

    return [pscustomobject[]] @($row)
}
