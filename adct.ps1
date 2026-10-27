<#
=====================================================================
  AD CLEANUP TOOL
  Finds stale computers and user accounts in on-prem Active Directory
  and lets you pick which ones to disable. If you choose, it then moves
  them into an organizational unit, or OU, that you select. It writes a
  receipt of everything it does.
=====================================================================

  HOW TO RUN
    The launcher is provided for convenience. Keep Run-ADCleanupTool.bat
    in the same folder as this script and run it as an administrator.
    It handles Windows' script permissions and keeps the window open at
    the end.

    Advanced users can run adct.ps1 directly from PowerShell instead.

  FIRST RUN
    The tool walks you through a short one-time setup of four questions,
    each answered via a selection window. Your answers are saved in a
    small settings file in the same folder as this script:
        ADCleanupTool.settings.json
    After that, your choices are remembered, with an option to modify
    them if needed.

  SHARING
    The script contains nothing specific to your organization. Anything
    specific to your environment lives only in the settings file and the
    log files. To share the tool, point people to the project's GitHub
    page rather than sending files, so no settings or logs travel by
    mistake. The recipient runs their own first-run setup.

  SAFETY
    - This tool contains no delete commands. It only disables and moves
      accounts.
    - Any step that disables or moves accounts requires typing "yes" in
      full.
    - Accounts whose names contain a service or admin keyword are flagged
      in the selection window so they stand out during review. You can add
      your own keywords from the Settings menu.
    - The tool excludes critical built-in accounts from the list: krbtgt
      accounts, the built-in Administrator and Guest, domain controllers,
      managed service accounts, and other critical system accounts. The
      full list is in the Get-StaleAccounts function.
    - The first run creates a Logs folder in the same folder as this
      script. Every run writes its own dated log file there.

  Version 0.1.0  (September 2026)
=====================================================================
#>

# ---------------------------------------------------------------------
#  Basic paths: settings file and log folder live in the same folder as this script
# ---------------------------------------------------------------------
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    try { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { $scriptRoot = (Get-Location).Path }
}

$script:SettingsFile = Join-Path $scriptRoot 'ADCleanupTool.settings.json'
$script:LogDir       = Join-Path $scriptRoot 'Logs'

# Each run gets its own log file (date + time + process id, so two runs
# can never overwrite each other's receipt).
$script:LogFile = Join-Path $script:LogDir ("Run_{0}_{1}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $PID)

# The receipt is a safety feature, so the tool does not run without one.
# Create the Logs folder and write the first line of this run's log file
# now, the same way every later log line is written. If either step fails
# (for example, the tool sits in a folder this account cannot write to),
# stop before anything else happens.
try {
    if (-not (Test-Path -LiteralPath $script:LogDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force -ErrorAction Stop | Out-Null
    }
    Add-Content -Path $script:LogFile -Value ("{0}  Receipt file created." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8 -ErrorAction Stop
}
catch {
    Write-Host ''
    Write-Host 'The tool cannot write its receipt, so it will not run.' -ForegroundColor Red
    Write-Host "Folder it tried to use: $script:LogDir" -ForegroundColor Yellow
    Write-Host "Windows said: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host 'Move the tool to a folder this account can write to, then run it again.' -ForegroundColor Yellow
    return
}

# Filled in once we successfully talk to Active Directory
$script:DC         = $null      # the one AD server this whole run talks to
$script:DomainName = ''
$script:HasGui     = $false     # selection windows are required (checked at startup)
$script:OuCheckUnreachable = $false   # set when a saved OU could not be checked at startup


# ---------------------------------------------------------------------
#  Small helper functions
# ---------------------------------------------------------------------

function Write-Log {
    # Prints a message on screen AND saves it into the run's log file.
    param(
        [string]$Message = '',
        [string]$Color   = 'White',
        [switch]$NoFile
    )
    Write-Host $Message -ForegroundColor $Color
    if (-not $NoFile) {
        Add-Content -Path $script:LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    }
}

function Read-YesNo {
    # Asks a question and only accepts "yes" or "no", typed in full.
    param([string]$Question)
    while ($true) {
        $answer = (Read-Host "$Question [yes/no]").Trim().ToLower()
        if ($answer -eq 'yes') { return $true }
        if ($answer -eq 'no')  { return $false }
        Write-Host '  Please type yes or no in full.' -ForegroundColor Yellow
    }
}

function Wait-Enter {
    param([string]$Message = 'Press Enter to continue')
    $null = Read-Host $Message
}

function Show-ThisWindow {
    # After a selection window closes, ask Windows to bring this window
    # back to the front. Windows sometimes declines (it limits apps from
    # stealing focus), so the on-screen instructions remain the reliable
    # way back. Any failure here is silently ignored.
    try {
        if (-not ('ADCleanupTool.Win32Focus' -as [type])) {
            Add-Type -Namespace ADCleanupTool -Name Win32Focus -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
'@ -ErrorAction Stop
        }
        $handle = [ADCleanupTool.Win32Focus]::GetConsoleWindow()
        if ($handle -eq [IntPtr]::Zero) { $handle = (Get-Process -Id $PID -ErrorAction Stop).MainWindowHandle }
        if ($handle -ne [IntPtr]::Zero) { [void][ADCleanupTool.Win32Focus]::SetForegroundWindow($handle) }
    }
    catch { }
}

function Get-ParentDn {
    # Given a full AD address (a "distinguished name"), returns the address
    # of the OU it lives in. Handles names that contain commas,
    # like "Smith\, John".
    param([string]$DistinguishedName)
    $parts = ([regex]'(?<!\\),').Split($DistinguishedName, 2)
    if ($parts.Count -ge 2) { return $parts[1] }
    return $DistinguishedName
}

function Get-FolderFromCanonical {
    # Turns "domain.com/Folder/Subfolder/Person Name" into "domain.com/Folder/Subfolder"
    param([string]$CanonicalName)
    if ([string]::IsNullOrWhiteSpace($CanonicalName)) { return '' }
    $i = $CanonicalName.LastIndexOf('/')
    if ($i -gt 0) { return $CanonicalName.Substring(0, $i) }
    return $CanonicalName
}


# ---------------------------------------------------------------------
#  Settings: load, save, defaults
# ---------------------------------------------------------------------

function Get-DefaultSettings {
    # The blank starting point. Nothing organization-specific lives here.
    [pscustomobject]@{
        Version   = 1
        Users     = [pscustomobject]@{
            SearchWholeDomain = $true
            SearchBaseDn      = ''
            SearchBaseName    = '(the whole domain)'
            MoveAfterDisable  = $true
            DestinationDn     = ''
            DestinationName   = ''
        }
        Computers = [pscustomobject]@{
            SearchWholeDomain = $true
            SearchBaseDn      = ''
            SearchBaseName    = '(the whole domain)'
            MoveAfterDisable  = $false
            DestinationDn     = ''
            DestinationName   = ''
        }
        # A remembered baseline of the path choices, kept separate from the
        # live Users/Computers settings above. The live settings change every
        # time you Accept an edit; this baseline does not, so "Revert to
        # default paths" always has a fixed home to return to. It is captured
        # from your choices at first-time setup and can be reset by re-running
        # setup.
        Defaults  = [pscustomobject]@{
            Users     = [pscustomobject]@{
                SearchWholeDomain = $true
                SearchBaseDn      = ''
                SearchBaseName    = '(the whole domain)'
                MoveAfterDisable  = $true
                DestinationDn     = ''
                DestinationName   = ''
            }
            Computers = [pscustomobject]@{
                SearchWholeDomain = $true
                SearchBaseDn      = ''
                SearchBaseName    = '(the whole domain)'
                MoveAfterDisable  = $false
                DestinationDn     = ''
                DestinationName   = ''
            }
        }
        # Accounts whose name contains any of these keywords are flagged
        # with a "Keyword Match" in the selection window. These are usually
        # service or admin accounts. The flag makes them stand out during
        # review. Add your own words by editing the settings file from the
        # Settings menu, option 4.
        ProtectedKeywords = @('admin', 'svc', 'service', 'sql', 'backup', 'test', 'system', 'krbtgt', 'guest', 'mailbox', 'azureadssoacc')
    }
}

function Import-Settings {
    if (-not (Test-Path $script:SettingsFile)) { return $null }
    # An unreadable file returns nothing, silently. Each caller prints the
    # message that fits its own situation (startup runs first-time setup;
    # the Notepad edit restores the previous settings).
    try {
        $s = Get-Content -Path $script:SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
    if ($null -eq $s) { return $null }   # an empty file reads as nothing
    # If the keyword list was deleted or emptied by a hand edit, restore the
    # standard list from this script's factory defaults. A customized list
    # (words added or removed) is a deliberate choice and is left alone.
    $keywords = @($s.ProtectedKeywords | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($keywords.Count -eq 0) {
        $s | Add-Member -NotePropertyName ProtectedKeywords -NotePropertyValue (Get-DefaultSettings).ProtectedKeywords -Force
        Export-Settings -Settings $s
        Write-Log 'The keyword list in the settings file was missing, so the standard list was restored.' 'Yellow'
    }
    # Note: a missing "default paths" baseline is left missing on purpose.
    # The tool never silently writes a baseline on load (that once enshrined a
    # bad in-memory save as the default). A baseline is created only by running
    # first-time setup (or re-running it from the Settings menu), and the code
    # that reads the baseline copes with it being absent.
    # By design, hand-edited settings are not shape-checked. Anyone who can edit this file can already edit the script.
    return $s
}

function Export-Settings {
    param($Settings)
    $Settings | ConvertTo-Json -Depth 6 | Set-Content -Path $script:SettingsFile -Encoding UTF8
}

function Set-DefaultsFromCurrent {
    # Captures the current Users/Computers path choices as the remembered
    # default baseline. Called at first-time setup (and when setup is re-run).
    # Uses Add-Member -Force so it works whether or not a Defaults block already
    # exists (older settings files won't have one).
    param($Settings)
    $defaults = [pscustomobject]@{
        Users     = Copy-ModeSettings -Mode $Settings.Users
        Computers = Copy-ModeSettings -Mode $Settings.Computers
    }
    $Settings | Add-Member -NotePropertyName Defaults -NotePropertyValue $defaults -Force
}


# ---------------------------------------------------------------------
#  The OU picker: pulls the live OU structure straight from AD
# ---------------------------------------------------------------------

function Select-OrgUnit {
    # Shows every OU (organizational unit) in Active Directory and lets the user click one.
    # Returns an object with .FullAddress:
    #     an OU's technical address,  or
    #     '@WHOLE'  = search the whole domain (only when offered)
    #     '@SKIP'   = don't move / skip     (only when offered)
    # Returns $null if the user cancels.
    param(
        [string]$Title,
        [switch]$AllowWholeDomain,
        [switch]$AllowSkip,
        [string]$SkipLabel = "Don't move them - just disable"
    )

    try {
        $ous = @(Get-ADOrganizationalUnit -Filter * -Server $script:DC -Properties CanonicalName -ErrorAction Stop |
                 Sort-Object CanonicalName)
    }
    catch {
        Write-Log "Couldn't read the OU list from Active Directory: $($_.Exception.Message)" 'Red'
        return $null
    }
    if ($ous.Count -eq 0) {
        Write-Log 'No OUs were found in Active Directory.' 'Red'
        return $null
    }

    # Build the rows for the selection list. Special choices go at the top.
    $rows = New-Object System.Collections.Generic.List[object]
    if ($AllowWholeDomain) {
        $rows.Add([pscustomobject]@{ OU = '>> Search the WHOLE domain <<'; Location = ''; FullAddress = '@WHOLE' })
    }
    if ($AllowSkip) {
        $rows.Add([pscustomobject]@{ OU = ">> $SkipLabel <<"; Location = ''; FullAddress = '@SKIP' })
    }
    foreach ($ou in $ous) {
        $rows.Add([pscustomobject]@{ OU = $ou.Name; Location = $ou.CanonicalName; FullAddress = $ou.DistinguishedName })
    }

    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host '  A selection window is about to open. Choose ONE row, then select OK.' -ForegroundColor Gray
    Write-Host '  Cancel keeps things as they are. Afterwards, return to this window to continue.' -ForegroundColor Gray
    Wait-Enter 'Press Enter to open the selection window'
    $picked = $rows | Out-GridView -Title $Title -OutputMode Single
    Show-ThisWindow
    return $picked
}


# ---------------------------------------------------------------------
#  First-run setup and settings health check
# ---------------------------------------------------------------------

function Invoke-FirstRunSetup {
    Write-Host ''
    Write-Log '=================  FIRST-TIME SETUP  =================' 'Cyan'
    Write-Log 'Four quick questions. Your answers are saved in the same folder as' 'White'
    Write-Log 'this script and remembered for every run after this one.' 'White'
    Write-Log 'You can change any of them later from the Settings menu.' 'Gray'
    Write-Host ''
    Wait-Enter 'Press Enter to begin'

    $s = Get-DefaultSettings

    # Keep any custom keyword list the user already has. Re-running setup is
    # about paths, not keywords - the two are unrelated - so a customized list
    # must survive it. Without this, the blank starting point above would reset
    # the list to the factory words. (On a genuine first run there is no file,
    # so Import-Settings returns nothing and the factory list stands.)
    $existing = Import-Settings
    if ($null -ne $existing) {
        $existingKeywords = @($existing.ProtectedKeywords | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($existingKeywords.Count -gt 0) { $s.ProtectedKeywords = $existingKeywords }
    }

    # --- Question 1: where to look for USER accounts ---
    $pick = Select-OrgUnit -Title 'STEP 1 of 4  -  Where should the tool LOOK for USER ACCOUNTS?' -AllowWholeDomain
    if ($null -ne $pick -and $pick.FullAddress -ne '@WHOLE') {
        $s.Users.SearchWholeDomain = $false
        $s.Users.SearchBaseDn      = $pick.FullAddress
        $s.Users.SearchBaseName    = $pick.Location
    }
    else {
        $s.Users.SearchWholeDomain = $true
        Write-Log 'Users: the tool will search the whole domain.' 'Gray'
    }

    # --- Question 2: where disabled USERS should be moved ---
    $pick = Select-OrgUnit -Title 'STEP 2 of 4  -  Where should DISABLED USER ACCOUNTS be moved?' -AllowSkip -SkipLabel "Don't move users - just disable them"
    if ($null -ne $pick -and $pick.FullAddress -ne '@SKIP') {
        $s.Users.MoveAfterDisable = $true
        $s.Users.DestinationDn    = $pick.FullAddress
        $s.Users.DestinationName  = $pick.Location
    }
    else {
        $s.Users.MoveAfterDisable = $false
        Write-Log 'Users: disabled accounts will stay where they are.' 'Gray'
    }

    # --- Question 3: where to look for COMPUTERS ---
    $pick = Select-OrgUnit -Title 'STEP 3 of 4  -  Where should the tool LOOK for COMPUTERS?' -AllowWholeDomain
    if ($null -ne $pick -and $pick.FullAddress -ne '@WHOLE') {
        $s.Computers.SearchWholeDomain = $false
        $s.Computers.SearchBaseDn      = $pick.FullAddress
        $s.Computers.SearchBaseName    = $pick.Location
    }
    else {
        $s.Computers.SearchWholeDomain = $true
        Write-Log 'Computers: the tool will search the whole domain.' 'Gray'
    }

    # --- Question 4: where disabled COMPUTERS should be moved ---
    $pick = Select-OrgUnit -Title 'STEP 4 of 4  -  Where should DISABLED COMPUTERS be moved?' -AllowSkip -SkipLabel "Don't move computers - just disable them"
    if ($null -ne $pick -and $pick.FullAddress -ne '@SKIP') {
        $s.Computers.MoveAfterDisable = $true
        $s.Computers.DestinationDn    = $pick.FullAddress
        $s.Computers.DestinationName  = $pick.Location
    }
    else {
        $s.Computers.MoveAfterDisable = $false
        Write-Log 'Computers: disabled machines will stay where they are.' 'Gray'
    }

    # The paths just chosen become the remembered default baseline.
    Set-DefaultsFromCurrent -Settings $s
    Export-Settings -Settings $s
    Write-Host ''
    Write-Log 'Setup complete. Your choices are saved in:' 'Green'
    Write-Log "  $script:SettingsFile" 'Gray'
    Write-Log 'These paths are now your default baseline, used by "Revert to default paths".' 'Gray'
    Write-Host ''
    return $s
}

function Test-OuStatus {
    # Asks AD about one saved OU and reports exactly what happened:
    #   Found       - the OU exists (the live OU object rides along)
    #   Missing     - AD answered clearly: no such OU
    #   Unreachable - AD could not be asked (connection or sign-in problem)
    # The difference matters: only a clear "Missing" should ever trigger
    # the re-pick flow. An unreachable server proves nothing about the OU.
    param([string]$Dn)
    try {
        $ou = Get-ADOrganizationalUnit -Identity $Dn -Server $script:DC -Properties CanonicalName -ErrorAction Stop
        return [pscustomobject]@{ Status = 'Found'; Ou = $ou; Reason = '' }
    }
    catch {
        if ($_.Exception.GetType().Name -eq 'ADIdentityNotFoundException') {
            return [pscustomobject]@{ Status = 'Missing'; Ou = $null; Reason = '' }
        }
        return [pscustomobject]@{ Status = 'Unreachable'; Ou = $null; Reason = $_.Exception.Message }
    }
}

function Write-OuConnectionProblem {
    param([string]$Reason)
    $script:OuCheckUnreachable = $true
    Write-Host ''
    Write-Log 'Could not verify the saved OUs - Active Directory did not accept the connection.' 'Red'
    Write-Log "Windows said: $Reason" 'Yellow'
    Write-Log 'Your saved settings have NOT been changed. This is usually a credential problem.' 'Yellow'
    Write-Log 'Common causes: an expired or recently changed password, a locked account, or the wrong account.' 'Yellow'
    Write-Log 'Please sort that out and run the tool again.' 'Yellow'
}

function Confirm-SettingsHealthy {
    # Checks that every saved OU still exists in AD. If one was renamed,
    # moved, or deleted (hello, OU restructure), we say so plainly and ask
    # the user to pick again. If AD cannot be reached or refuses the
    # sign-in, the saved settings are left COMPLETELY untouched - a
    # connection problem is not evidence that an OU is gone.
    param($Settings)

    $changed = $false

    foreach ($modeName in @('Users', 'Computers')) {
        $m = $Settings.$modeName

        # 1) The OU we search in
        if ((-not $m.SearchWholeDomain) -and (-not [string]::IsNullOrWhiteSpace($m.SearchBaseDn))) {
            $check = Test-OuStatus -Dn $m.SearchBaseDn
            if ($check.Status -eq 'Unreachable') {
                Write-OuConnectionProblem -Reason $check.Reason
                return $Settings
            }
            if ($check.Status -eq 'Found') {
                if ($m.SearchBaseName -ne $check.Ou.CanonicalName) { $m.SearchBaseName = $check.Ou.CanonicalName; $changed = $true }
            }
            else {
                Write-Host ''
                Write-Log "Please note: the OU saved for searching $modeName no longer exists: $($m.SearchBaseName)" 'Yellow'
                Write-Log 'It was probably renamed or moved during an AD reorganization. Please pick it again.' 'Yellow'
                $pick = Select-OrgUnit -Title "Select the OU to SEARCH for $($modeName.ToUpper())" -AllowWholeDomain
                if ($null -ne $pick -and $pick.FullAddress -ne '@WHOLE') {
                    $m.SearchWholeDomain = $false
                    $m.SearchBaseDn      = $pick.FullAddress
                    $m.SearchBaseName    = $pick.Location
                    $changed = $true
                }
                elseif ($null -ne $pick) {
                    $m.SearchWholeDomain = $true
                    $m.SearchBaseDn      = ''
                    $m.SearchBaseName    = '(the whole domain)'
                    Write-Log "Understood - $modeName searches will cover the whole domain for now." 'Gray'
                    $changed = $true
                }
                else {
                    Write-Log 'Left unchanged for now - you can fix it later from the Settings menu.' 'Gray'
                }
            }
        }

        # 2) The OU disabled things get moved to
        if ($m.MoveAfterDisable -and -not [string]::IsNullOrWhiteSpace($m.DestinationDn)) {
            $check = Test-OuStatus -Dn $m.DestinationDn
            if ($check.Status -eq 'Unreachable') {
                Write-OuConnectionProblem -Reason $check.Reason
                return $Settings
            }
            if ($check.Status -eq 'Found') {
                if ($m.DestinationName -ne $check.Ou.CanonicalName) { $m.DestinationName = $check.Ou.CanonicalName; $changed = $true }
            }
            else {
                Write-Host ''
                Write-Log "Please note: the OU where disabled $modeName are moved no longer exists: $($m.DestinationName)" 'Yellow'
                Write-Log 'Please pick an OU again, or choose not to move them.' 'Yellow'
                $pick = Select-OrgUnit -Title "Select where DISABLED $($modeName.ToUpper()) should be moved" -AllowSkip -SkipLabel "Don't move them - just disable"
                if ($null -ne $pick -and $pick.FullAddress -ne '@SKIP') {
                    $m.MoveAfterDisable = $true
                    $m.DestinationDn    = $pick.FullAddress
                    $m.DestinationName  = $pick.Location
                    $changed = $true
                }
                elseif ($null -ne $pick) {
                    $m.MoveAfterDisable = $false
                    $m.DestinationDn    = ''
                    $m.DestinationName  = ''
                    Write-Log "Understood - disabled $modeName will stay where they are for now." 'Gray'
                    $changed = $true
                }
                else {
                    Write-Log 'Left unchanged for now - you can fix it later from the Settings menu.' 'Gray'
                }
            }
        }
    }

    if ($changed) { Export-Settings -Settings $Settings }
    return $Settings
}


# ---------------------------------------------------------------------
#  Showing and changing settings
# ---------------------------------------------------------------------

function Write-ModeSummaryLines {
    # Prints the two "current values" lines used at the top of the settings
    # screens. Screen only (called on every redraw, so it must not spam the log).
    param($M)
    Write-Host "  Searching in   : $($M.SearchBaseName)" -ForegroundColor White
    if ($M.MoveAfterDisable -and -not [string]::IsNullOrWhiteSpace($M.DestinationDn)) {
        Write-Host "  Disabled go to : $($M.DestinationName)" -ForegroundColor White
    }
    else {
        Write-Host '  After disabling: they stay where they are' -ForegroundColor White
    }
}

function Show-ModeSettings {
    param($Settings, [string]$Mode)
    Write-Host ''
    Write-ModeSummaryLines -M $Settings.$Mode
    Write-Host ''
}

function Copy-ModeSettings {
    # Makes an independent copy of one mode's OU settings. Every field is
    # plain text or true/false, so this straight copy is a genuinely separate
    # object - editing the copy never touches the original.
    param($Mode)
    [pscustomobject]@{
        SearchWholeDomain = $Mode.SearchWholeDomain
        SearchBaseDn      = $Mode.SearchBaseDn
        SearchBaseName    = $Mode.SearchBaseName
        MoveAfterDisable  = $Mode.MoveAfterDisable
        DestinationDn     = $Mode.DestinationDn
        DestinationName   = $Mode.DestinationName
    }
}

function Copy-ModeSettingsInto {
    # Copies the values from one mode-settings object INTO another, field by
    # field. Used to commit pending edits back into the live settings object
    # WITHOUT replacing it - so every other part of the tool, which is holding
    # that same live object, sees the update automatically.
    param($From, $Into)
    $Into.SearchWholeDomain = $From.SearchWholeDomain
    $Into.SearchBaseDn      = $From.SearchBaseDn
    $Into.SearchBaseName    = $From.SearchBaseName
    $Into.MoveAfterDisable  = $From.MoveAfterDisable
    $Into.DestinationDn     = $From.DestinationDn
    $Into.DestinationName   = $From.DestinationName
}

function Test-ModeSettingsChanged {
    # True if the pending copy differs from the saved settings. Comparing the
    # addresses and the on/off flags is enough - the display names always ride
    # along with the address they came from.
    param($Pending, $Saved)
    return (
        ($Pending.SearchWholeDomain -ne $Saved.SearchWholeDomain) -or
        ($Pending.SearchBaseDn      -ne $Saved.SearchBaseDn)      -or
        ($Pending.MoveAfterDisable  -ne $Saved.MoveAfterDisable)  -or
        ($Pending.DestinationDn     -ne $Saved.DestinationDn)
    )
}

function Save-PendingInto {
    # Commits a pending copy into the live saved settings and writes the file.
    # On screen it prints a short confirmation ("Saved." unless told otherwise).
    # The resulting values always go into the receipt. -ShowValues also prints
    # them on screen; that is used only when saving on the way out of the edit
    # screen, because no redrawn screen follows to show them.
    param($Pending, $Saved, $Settings, [string]$Mode, [string]$Message = 'Saved.', [switch]$ShowValues)
    Copy-ModeSettingsInto -From $Pending -Into $Saved
    Export-Settings -Settings $Settings

    $lines = @("  Searching in   : $($Saved.SearchBaseName)")
    if ($Saved.MoveAfterDisable -and -not [string]::IsNullOrWhiteSpace($Saved.DestinationDn)) {
        $lines += "  Disabled go to : $($Saved.DestinationName)"
    }
    else {
        $lines += '  After disabling: they stay where they are'
    }

    Write-Log $Message 'Green'
    foreach ($line in $lines) {
        if ($ShowValues) { Write-Log $line 'Gray' }
        else { Add-Content -Path $script:LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $line) -Encoding UTF8 }
    }
}

function Set-PendingSearch {
    # Opens the OU picker for the SEARCH location and records the choice into the
    # pending copy (nothing is saved to disk here).
    param($Pending, [string]$Mode)
    $pick = Select-OrgUnit -Title "Select the OU to SEARCH for $($Mode.ToUpper())" -AllowWholeDomain
    if ($null -ne $pick) {
        if ($pick.FullAddress -eq '@WHOLE') {
            $Pending.SearchWholeDomain = $true;  $Pending.SearchBaseDn = '';                $Pending.SearchBaseName = '(the whole domain)'
        }
        else {
            $Pending.SearchWholeDomain = $false; $Pending.SearchBaseDn = $pick.FullAddress; $Pending.SearchBaseName = $pick.Location
        }
        Write-Host ''
        Write-Log "Pending, not saved yet: $Mode searches will look in $($Pending.SearchBaseName)" 'Yellow'
    }
}

function Set-PendingMove {
    # Opens the OU picker for the MOVE destination and records the choice into
    # the pending copy (nothing is saved to disk here).
    param($Pending, [string]$Mode)
    $pick = Select-OrgUnit -Title "Select where DISABLED $($Mode.ToUpper()) should be moved" -AllowSkip -SkipLabel "Don't move them - just disable"
    if ($null -ne $pick) {
        Write-Host ''
        if ($pick.FullAddress -eq '@SKIP') {
            $Pending.MoveAfterDisable = $false; $Pending.DestinationDn = '';                $Pending.DestinationName = ''
            Write-Log "Pending, not saved yet: disabled $Mode will stay where they are." 'Yellow'
        }
        else {
            $Pending.MoveAfterDisable = $true;  $Pending.DestinationDn = $pick.FullAddress; $Pending.DestinationName = $pick.Location
            Write-Log "Pending, not saved yet: disabled $Mode will move to $($Pending.DestinationName)" 'Yellow'
        }
    }
}

function Test-DefaultPathsExist {
    # Checks that the OUs in one mode's default baseline still exist in AD.
    # Returns $true when they all do. Otherwise explains what is wrong and
    # returns $false, and nothing is changed.
    param($Default, [string]$Mode)
    $checks = @()
    if ((-not $Default.SearchWholeDomain) -and (-not [string]::IsNullOrWhiteSpace($Default.SearchBaseDn))) {
        $checks += [pscustomobject]@{ Dn = $Default.SearchBaseDn; Name = $Default.SearchBaseName; What = "searching $Mode" }
    }
    if ($Default.MoveAfterDisable -and -not [string]::IsNullOrWhiteSpace($Default.DestinationDn)) {
        $checks += [pscustomobject]@{ Dn = $Default.DestinationDn; Name = $Default.DestinationName; What = "moving disabled $Mode" }
    }
    foreach ($c in $checks) {
        $check = Test-OuStatus -Dn $c.Dn
        if ($check.Status -eq 'Found') { continue }
        Write-Host ''
        if ($check.Status -eq 'Missing') {
            Write-Log "Your default OU for $($c.What) no longer exists: $($c.Name)" 'Yellow'
            Write-Log 'Default paths were not applied. Re-run first-time setup to reset them, or pick new paths with options 1 and 2.' 'Yellow'
        }
        else {
            Write-Log 'Could not check your default paths - Active Directory did not respond.' 'Yellow'
            Write-Log "Windows said: $($check.Reason)" 'Yellow'
            Write-Log 'Default paths were not applied.' 'Yellow'
        }
        return $false
    }
    return $true
}

function Edit-ModeSettings {
    # Lets the user change the search OU and/or the destination OU for one
    # mode (Users or Computers).
    #
    # Picks are held as PENDING and are NOT written to disk as they are made.
    # The settings file stays exactly as it was until the user chooses to keep
    # the changes - so the saved file is itself the "last save" to fall back to.
    #
    # Every row keeps the same number for the whole visit, so a number never
    # changes meaning when changes become pending or are saved. A row that
    # would do nothing right now is shown dimmed, and choosing it only says
    # so. Every row except Back keeps the user on this screen, so both paths
    # can be changed in one visit:
    #   Accept these changes    - saves the pending picks, then redraws.
    #                             Dimmed when nothing is pending.
    #   Revert to last save     - drops the pending picks, then redraws.
    #                             Dimmed when nothing is pending.
    #   Revert to default paths - applies and saves the remembered baseline
    #                             straight away, then redraws. Shown only
    #                             mid-cleanup. Dimmed when it would change
    #                             nothing or no baseline is saved.
    #   Back                    - leaves this screen. If picks are still
    #                             pending, asks whether to save them first.
    #
    # -Origin controls only where Back goes, and matches how this screen was
    # reached:
    #   Settings - reached from the Settings menu; Back returns to the main menu.
    #   Cleanup  - reached mid-cleanup; Back returns to the cleanup in progress.
    param($Settings, [string]$Mode, [ValidateSet('Settings', 'Cleanup')][string]$Origin = 'Settings')

    $saved   = $Settings.$Mode                 # the live, saved settings (shared with the rest of the tool)
    $pending = Copy-ModeSettings -Mode $saved  # an independent working copy we edit

    # The remembered baseline for this mode. It is created only by first-time
    # setup, so an older or hand-edited settings file may not have one. When it
    # is missing, "Revert to default paths" is simply not offered.
    $default = $null
    if ($null -ne $Settings.Defaults) { $default = $Settings.Defaults.$Mode }

    $backLabel = 'Back to the main menu'
    if ($Origin -eq 'Cleanup') { $backLabel = 'Back to the cleanup' }

    while ($true) {
        $dirty            = Test-ModeSettingsChanged -Pending $pending -Saved $saved
        $canRevertDefault = ($null -ne $default) -and (Test-ModeSettingsChanged -Pending $pending -Saved $default)

        Write-Host ''
        if ($dirty) { Write-Host "--- Pending Changes for $Mode ---" -ForegroundColor Cyan }
        else        { Write-Host "--- Change settings for $Mode ---" -ForegroundColor Cyan }
        Write-ModeSummaryLines -M $pending
        Write-Host ''

        # Build the menu. Every row is always listed, so its number never
        # changes. The On flag marks whether the row would do anything now.
        $items = New-Object System.Collections.Generic.List[object]
        $items.Add([pscustomobject]@{ Key = 'search';     Label = 'Change where the tool searches';  On = $true })
        $items.Add([pscustomobject]@{ Key = 'move';       Label = 'Change where disabled ones move'; On = $true })
        $items.Add([pscustomobject]@{ Key = 'accept';     Label = 'Accept these changes';            On = $dirty })
        $items.Add([pscustomobject]@{ Key = 'revertsave'; Label = 'Revert to last save';             On = $dirty })
        # "Revert to default paths" is offered only mid-cleanup. The baseline
        # is set when you run (or re-run) first-time setup; during a cleanup,
        # reverting to it is a useful one-step way back to your known-good
        # paths. It is left off the Settings-menu edit screen to keep that
        # screen focused on changing your live saved paths.
        if ($Origin -eq 'Cleanup') {
            $items.Add([pscustomobject]@{ Key = 'revertdefault'; Label = 'Revert to default paths'; On = $canRevertDefault })
        }
        $items.Add([pscustomobject]@{ Key = 'back'; Label = $backLabel; On = $true })

        for ($i = 0; $i -lt $items.Count; $i++) {
            $line = "  {0}. {1}" -f ($i + 1), $items[$i].Label
            if ($items[$i].On) { Write-Host $line }
            else               { Write-Host $line -ForegroundColor DarkGray }
        }

        $choice = (Read-Host ("Choose 1-{0}" -f $items.Count)).Trim()
        if ($choice -notmatch '^\d{1,2}$' -or [int]$choice -lt 1 -or [int]$choice -gt $items.Count) {
            Write-Host ("  Please choose a number from 1 to {0}." -f $items.Count) -ForegroundColor Yellow
            continue
        }
        $selected = $items[[int]$choice - 1]
        if (-not $selected.On) {
            Write-Host '  That option is not available right now.' -ForegroundColor Yellow
            continue
        }
        $action = $selected.Key

        switch ($action) {
            'search' { Set-PendingSearch -Pending $pending -Mode $Mode }
            'move'   { Set-PendingMove   -Pending $pending -Mode $Mode }
            'accept' {
                Write-Host ''
                Save-PendingInto -Pending $pending -Saved $saved -Settings $Settings -Mode $Mode
            }
            'revertsave' {
                $pending = Copy-ModeSettings -Mode $saved
                Write-Host ''
                Write-Log "Reverted to your last saved settings for $Mode." 'Green'
            }
            'revertdefault' {
                # A one-shot action: apply the default paths and save straight
                # away, with no pending/Accept step. The baseline is checked
                # against AD first - after an OU rename or move it could point
                # somewhere that no longer exists, and saving it would break
                # the next search or every move.
                if (-not (Test-DefaultPathsExist -Default $default -Mode $Mode)) { continue }
                Copy-ModeSettingsInto -From $default -Into $pending
                Write-Host ''
                Save-PendingInto -Pending $pending -Saved $saved -Settings $Settings -Mode $Mode -Message 'Reverted to your default paths and saved.'
            }
            'back' {
                if ($dirty) {
                    Write-Host ''
                    if (Read-YesNo 'You have unsaved changes. Save them before leaving?') {
                        Save-PendingInto -Pending $pending -Saved $saved -Settings $Settings -Mode $Mode -ShowValues
                    }
                    else {
                        Write-Log "Cancelled - your settings for $Mode are unchanged." 'Gray'
                    }
                }
                return
            }
        }
    }
}

function Invoke-SettingsMenu {
    param($Settings)
    while ($true) {
        Write-Host ''
        Write-Host '================  SETTINGS  ================' -ForegroundColor Cyan
        Write-Host "  Users     - search in : $($Settings.Users.SearchBaseName)"
        if ($Settings.Users.MoveAfterDisable -and $Settings.Users.DestinationDn) {
            Write-Host "  Users     - move to   : $($Settings.Users.DestinationName)"
        } else {
            Write-Host '  Users     - move to   : (not moved)'
        }
        Write-Host "  Computers - search in : $($Settings.Computers.SearchBaseName)"
        if ($Settings.Computers.MoveAfterDisable -and $Settings.Computers.DestinationDn) {
            Write-Host "  Computers - move to   : $($Settings.Computers.DestinationName)"
        } else {
            Write-Host '  Computers - move to   : (not moved)'
        }
        Write-Host ''
        Write-Host '  1. Change the OUs for Users'
        Write-Host '  2. Change the OUs for Computers'
        Write-Host '  3. Re-run first-time setup - resets saved and default paths, keeps your keyword list'
        Write-Host '  4. Edit the keyword list in Notepad (Advanced)'
        Write-Host '  5. Back to the main menu'
        $choice = (Read-Host 'Choose 1, 2, 3, 4, or 5').Trim().ToUpper()

        if     ($choice -eq '5') { return $Settings }
        elseif ($choice -eq '1') { Edit-ModeSettings -Settings $Settings -Mode 'Users'     -Origin 'Settings'; return $Settings }
        elseif ($choice -eq '2') { Edit-ModeSettings -Settings $Settings -Mode 'Computers' -Origin 'Settings'; return $Settings }
        elseif ($choice -eq '3') {
            # Setup cannot be backed out of partway (cancelling a picker saves
            # whole-domain search or no move), so confirm before starting.
            # After setup, hand control back to the MAIN menu (returning here
            # would drop the user into Settings again, which felt wrong).
            Write-Host ''
            if (Read-YesNo 'This replaces your saved paths and default paths. Your keyword list is kept. Continue?') {
                $Settings = Invoke-FirstRunSetup
                return $Settings
            }
            Write-Log 'Setup was not re-run. Your settings are unchanged.' 'Gray'
        }
        elseif ($choice -eq '4') {
            # The tool does not wait on the Notepad process itself. Windows 11
            # Notepad may open the file as a tab in a window that is already
            # open, and the launched process can then exit right away. Waiting
            # for the user to press Enter works the same with every Notepad.
            try {
                Start-Process notepad.exe -ArgumentList "`"$script:SettingsFile`"" -ErrorAction Stop
            }
            catch {
                Write-Log "Notepad could not be opened: $($_.Exception.Message)" 'Red'
                Write-Log 'Your settings are unchanged.' 'Yellow'
                continue
            }
            Write-Log 'The settings file is open in Notepad.' 'Cyan'
            Write-Host '  Make your edits, save them, and close Notepad.' -ForegroundColor Gray
            Write-Host '  Then return to this window.' -ForegroundColor Gray
            Wait-Enter 'Press Enter here when you are done to reload the settings'
            $reloaded = Import-Settings
            if ($null -eq $reloaded) {
                Write-Log 'Your edit could not be read, so your previous settings were restored.' 'Yellow'
                Write-Log 'Check for a missing comma, quote, or bracket, then try again.' 'Yellow'
                Export-Settings -Settings $Settings
            }
            else {
                $Settings = Confirm-SettingsHealthy -Settings $reloaded
                Write-Log 'Settings reloaded.' 'Green'
            }
        }
        else {
            Write-Host '  Please choose 1, 2, 3, 4, or 5.' -ForegroundColor Yellow
        }
    }
}


# ---------------------------------------------------------------------
#  Finding stale accounts and preparing the pick list
# ---------------------------------------------------------------------

function Get-StaleAccounts {
    # Asks AD for every account of the chosen kind in the chosen OU, then
    # keeps only the stale ones:
    #   - Signed in before : stale if the last sign-in is older than the cutoff.
    #   - Never signed in  : stale only if the account was CREATED before the
    #     cutoff. A brand-new account that simply hasn't been used yet is left
    #     out - it hasn't had the chance to sign in.
    # Already-disabled accounts are included on purpose - they show up marked
    # "Already disabled".
    param(
        $Settings,
        [ValidateSet('Users', 'Computers')][string]$Mode,
        [datetime]$Cutoff,
        [string]$OsFilter = ''
    )
    $m = $Settings.$Mode

    $params = @{
        Filter      = '*'
        Server      = $script:DC
        ErrorAction = 'Stop'
    }
    if ((-not $m.SearchWholeDomain) -and (-not [string]::IsNullOrWhiteSpace($m.SearchBaseDn))) {
        $params.SearchBase = $m.SearchBaseDn
    }

    if ($Mode -eq 'Users') {
        $params.Properties = @('LastLogonDate', 'Created', 'Enabled', 'CanonicalName', 'Description')
        $found = @(Get-ADUser @params)
        # Never offer critical built-in accounts for disabling. This is the
        # user-side equivalent of the domain-controller exclusion below:
        #   - Every krbtgt account. The main one is the Kerberos service
        #     account, and disabling it breaks sign-in across the whole
        #     domain. Read-only domain controllers and Entra Kerberos add
        #     their own (krbtgt_12345, krbtgt_AzureAD).
        #   - Built-in accounts identified by the last number of their SID,
        #     so renaming one cannot hide it from this filter:
        #     500 Administrator, 501 Guest, 502 krbtgt, 503 DefaultAccount.
        # A keyword flag only warns; this removes them from the list entirely.
        $found = @($found | Where-Object {
            $rid = ''
            if ($_.SID) { $rid = $_.SID.Value.Split('-')[-1] }
            ($_.SamAccountName -notlike 'krbtgt*') -and ($rid -notin '500', '501', '502', '503')
        })
    }
    else {
        $params.Properties = @('LastLogonDate', 'Created', 'Enabled', 'CanonicalName', 'OperatingSystem', 'PrimaryGroupID')
        $found = @(Get-ADComputer @params)
        # Never touch domain controllers - disabling one would be catastrophic.
        $found = @($found | Where-Object { $_.DistinguishedName -notlike '*,OU=Domain Controllers,*' })
        # Also exclude them by group, which holds even if one was moved out of
        # that OU: 516 is Domain Controllers, 521 is Read-only Domain Controllers.
        $found = @($found | Where-Object { $_.PrimaryGroupID -notin 516, 521 })
        # Never list managed service accounts. AD stores them as a kind of
        # computer account, but Windows services sign in with them, and
        # disabling one stops the service that uses it. This covers every
        # type (standalone, group, and delegated). If none exist, it does
        # nothing.
        $found = @($found | Where-Object { $_.ObjectClass -notlike 'msDS-*ManagedServiceAccount' })
        # Never list the Microsoft Entra Seamless SSO account. It never signs
        # in, so it always looks stale, and disabling it stops Seamless SSO.
        $found = @($found | Where-Object { $_.SamAccountName -ne 'AZUREADSSOACC$' })
        if (-not [string]::IsNullOrWhiteSpace($OsFilter)) {
            # Treat what was typed as plain text, not as wildcard patterns.
            $osPattern = [System.Management.Automation.WildcardPattern]::Escape($OsFilter)
            $found = @($found | Where-Object { $_.OperatingSystem -like "*$osPattern*" })
        }
    }

    # Keep the stale ones.
    #   - If the account HAS a sign-in date, it is stale when that date is
    #     older than the cutoff.
    #   - If it has NO sign-in date, it has never been used. Treat it as stale
    #     only when it was created before the cutoff - so a freshly made
    #     account that just hasn't been signed into yet does not get swept up.
    #     (Creation dates are exact, so no lag allowance is needed here.)
    $stale = @($found | Where-Object {
        if ($_.LastLogonDate) { $_.LastLogonDate -lt $Cutoff }
        else                  { $_.Created -and ($_.Created -lt $Cutoff) }
    } | Sort-Object Name)
    return $stale
}

function New-DisplayRows {
    # Turns raw AD objects into friendly rows for the selection window, and
    # builds a lookup so we can get back to the real AD object afterwards.
    param($Accounts, $Settings, [string]$Mode)

    $keywords = @($Settings.ProtectedKeywords)
    $rows = New-Object System.Collections.Generic.List[object]
    $map  = @{}

    foreach ($a in $Accounts) {
        $isProtected = $false
        foreach ($k in $keywords) {
            if ([string]::IsNullOrWhiteSpace($k)) { continue }
            # Treat the keyword as plain text, not as a wildcard pattern.
            $kp = [System.Management.Automation.WildcardPattern]::Escape($k)
            if ($a.SamAccountName -like "*$kp*" -or $a.Name -like "*$kp*") { $isProtected = $true; break }
        }

        $lastSeen = 'Never'
        if ($a.LastLogonDate) { $lastSeen = $a.LastLogonDate.ToString('yyyy-MM-dd') }

        $created = ''
        if ($a.Created) { $created = $a.Created.ToString('yyyy-MM-dd') }

        $status = 'Already disabled'
        if ($a.Enabled) { $status = 'Enabled' }

        $protectedText = ''
        if ($isProtected) { $protectedText = 'Yes' }

        $folder = Get-FolderFromCanonical -CanonicalName $a.CanonicalName

        if ($Mode -eq 'Computers') {
            $row = [pscustomobject][ordered]@{
                Name            = [string]$a.Name
                OperatingSystem = [string]$a.OperatingSystem
                Account         = [string]$a.SamAccountName
                LastSeen        = $lastSeen
                Created         = $created
                Status          = $status
                'Keyword Match' = $protectedText
                OU              = $folder
            }
        }
        else {
            $row = [pscustomobject][ordered]@{
                Name      = [string]$a.Name
                Account   = [string]$a.SamAccountName
                LastSeen  = $lastSeen
                Created   = $created
                Status    = $status
                'Keyword Match' = $protectedText
                OU        = $folder
            }
        }

        $rows.Add($row)
        $map[[string]$a.SamAccountName] = @{ Ad = $a; Row = $row; Protected = $isProtected }
    }

    # Hand the results back as a simple two-pocket object with a plain
    # array inside. (Older PowerShell can fumble fancier containers when
    # real AD data is involved - this shape it can never get wrong.)
    return [pscustomobject]@{ Rows = $rows.ToArray(); Map = $map }
}


# ---------------------------------------------------------------------
#  Letting the user pick which accounts to act on
# ---------------------------------------------------------------------

function Select-Accounts {
    param($Rows, [string]$Mode)

    Write-Host ''
    Write-Log 'A selection window is about to open. Highlight the rows you want to DISABLE.' 'Cyan'
    Write-Log 'When you have finished, select OK and return to this window to continue.' 'Gray'
    Wait-Enter 'Press Enter to open the selection window now'
    $picked = @($Rows | Out-GridView -Title "Select the $($Mode.ToUpper()) to DISABLE   (Ctrl+A = all, Ctrl+click = one at a time, Shift+click = range)" -PassThru)
    Show-ThisWindow
    return $picked
}


# ---------------------------------------------------------------------
#  The disable and move steps
# ---------------------------------------------------------------------

function Invoke-DisablePhase {
    # Disables the enabled accounts among the user's selections (after a
    # typed "yes"). The Noun parameter supplies mode-appropriate wording:
    # "computer" or "account". Returns counts for the move step and summary.
    param($Map, $PickedRows, [string]$Noun = 'account')

    $enabledRows = @($PickedRows | Where-Object { $_.Status -eq 'Enabled' })
    $alreadyRows = @($PickedRows | Where-Object { $_.Status -eq 'Already disabled' })

    $result = [pscustomobject]@{
        EnabledCount  = $enabledRows.Count
        AlreadyCount  = $alreadyRows.Count
        DisabledCount = 0
        ErrorCount    = 0
        UserDeclined  = $false
    }

    Write-Host ''
    if ($enabledRows.Count -eq 0) {
        Write-Log 'Everything you selected is already disabled - there is nothing to disable in this step.' 'Green'
        return $result
    }

    Write-Log "$($enabledRows.Count) of the selected ${Noun}s are currently enabled." 'Yellow'
    if ($alreadyRows.Count -gt 0) {
        Write-Log "$($alreadyRows.Count) $Noun(s) already disabled were skipped in this step." 'Gray'
    }

    if (-not (Read-YesNo "Disable these $($enabledRows.Count) $Noun(s) now?")) {
        Write-Log "Understood - no ${Noun}s were disabled." 'Gray'
        $result.UserDeclined = $true
        return $result
    }

    Write-Host ''
    foreach ($row in $enabledRows) {
        $ad = $Map[$row.Account].Ad
        try {
            Disable-ADAccount -Identity $ad.DistinguishedName -Server $script:DC -ErrorAction Stop
            Write-Log "  Disabled: $($row.Name)  ($($row.Account))" 'Green'
            $result.DisabledCount++
            $row.Status = 'Already disabled'   # keep our own records accurate
        }
        catch {
            Write-Log "  FAILED to disable $($row.Name) ($($row.Account)): $($_.Exception.Message)" 'Red'
            $result.ErrorCount++
        }
    }

    Write-Host ''
    Write-Log "Disabled $($result.DisabledCount) of $($enabledRows.Count). Errors: $($result.ErrorCount)." 'Cyan'
    return $result
}

function Invoke-MovePhase {
    # Moves picked accounts into the saved destination OU - but only the
    # ones that really are disabled RIGHT NOW. Each account is re-checked
    # against AD first, so nothing enabled ever gets filed away by mistake.
    param($Map, $PickedRows, $Settings, [string]$Mode, $DisableResult)

    $m = $Settings.$Mode
    $noun = 'account'
    if ($Mode -eq 'Computers') { $noun = 'computer' }
    $result = [pscustomobject]@{
        Ran          = $false
        MovedCount   = 0
        AlreadyThere = 0
        StillEnabled = 0
        Missing      = 0
        ErrorCount   = 0
    }

    if ((-not $m.MoveAfterDisable) -or [string]::IsNullOrWhiteSpace($m.DestinationDn)) {
        Write-Log "This tool is set to leave disabled ${noun}s where they are, so there is no move step." 'Gray'
        return $result
    }

    # Word the question to match what actually just happened.
    Write-Host ''
    if ($DisableResult.DisabledCount -gt 0) {
        $question = "Move the disabled $noun(s) to '$($m.DestinationName)' now?"
    }
    elseif ($DisableResult.AlreadyCount -gt 0) {
        $question = "You selected $($DisableResult.AlreadyCount) $noun(s) that are already disabled. Move them to '$($m.DestinationName)'?"
    }
    else {
        Write-Log "None of the selected ${noun}s are disabled, so there is nothing to move." 'Gray'
        return $result
    }

    if (-not (Read-YesNo $question)) {
        Write-Log "Understood - no ${noun}s were moved." 'Gray'
        return $result
    }

    $result.Ran = $true
    Write-Host ''
    foreach ($row in $PickedRows) {
        $dn = $Map[$row.Account].Ad.DistinguishedName

        # Fresh look at the account as it is RIGHT NOW.
        $fresh = $null
        try {
            if ($Mode -eq 'Users') { $fresh = Get-ADUser     -Identity $dn -Server $script:DC -ErrorAction Stop }
            else                   { $fresh = Get-ADComputer -Identity $dn -Server $script:DC -ErrorAction Stop }
        }
        catch {
            Write-Log "  Skipped $($row.Name): it could no longer be found in AD. It may have been renamed or moved." 'Yellow'
            $result.Missing++
            continue
        }

        if ($fresh.Enabled) {
            Write-Log "  Skipped $($row.Name): it is still ENABLED and will remain in place." 'Yellow'
            $result.StillEnabled++
            continue
        }

        $parent = Get-ParentDn -DistinguishedName $fresh.DistinguishedName
        if ($parent -eq $m.DestinationDn) {
            Write-Log "  Skipped $($row.Name): already in '$($m.DestinationName)'." 'Gray'
            $result.AlreadyThere++
            continue
        }

        try {
            Move-ADObject -Identity $fresh.DistinguishedName -TargetPath $m.DestinationDn -Server $script:DC -ErrorAction Stop
            Write-Log "  Moved: $($row.Name)  ->  $($m.DestinationName)" 'Green'
            $result.MovedCount++
        }
        catch {
            Write-Log "  FAILED to move $($row.Name): $($_.Exception.Message)" 'Red'
            $result.ErrorCount++
        }
    }

    Write-Host ''
    Write-Log "Moved $($result.MovedCount). Already there: $($result.AlreadyThere). Still enabled, left in place: $($result.StillEnabled). Not found: $($result.Missing). Errors: $($result.ErrorCount)." 'Cyan'
    return $result
}


# ---------------------------------------------------------------------
#  One full cleanup run (find -> pick -> disable -> move -> summary)
# ---------------------------------------------------------------------

function Invoke-CleanupRun {
    param($Settings, [ValidateSet('Users', 'Computers')][string]$Mode)

    Write-Host ''
    Write-Log "==============  CLEANING UP: $($Mode.ToUpper())  ==============" 'Cyan'

    # Mode-appropriate wording for every shared message in this run
    $noun = 'account'
    if ($Mode -eq 'Computers') { $noun = 'computer' }

    # --- Confirm (or change) the saved OUs for this run ---
    while ($true) {
        Show-ModeSettings -Settings $Settings -Mode $Mode
        $answer = (Read-Host 'Press Enter to continue, C to change these settings, or X to go back to the main menu').Trim().ToUpper()
        if ($answer -eq '')  { break }
        if ($answer -eq 'X') { return }
        if ($answer -eq 'C') { Edit-ModeSettings -Settings $Settings -Mode $Mode -Origin 'Cleanup'; continue }
        Write-Host '  Please press Enter, C, or X.' -ForegroundColor Yellow
    }

    # --- How old counts as stale? ---
    Write-Host ''
    Write-Host 'How many days without a sign-in should count as stale? (for example: 180)' -ForegroundColor Cyan
    $days = $null
    while ($true) {
        $daysInput = (Read-Host 'Days').Trim()
        if ($daysInput -match '^\d{1,4}$' -and [int]$daysInput -le 5475) {
            $days = [int]$daysInput
            if ($days -lt 30) {
                Write-Host ''
                Write-Log 'A note about small numbers: AD sign-in dates can lag by up to two weeks,' 'Yellow'
                Write-Log 'so a cutoff under 30 days can list accounts that are actively in use.' 'Yellow'
                if (-not (Read-YesNo "Use $days days anyway?")) { Write-Host ''; continue }
            }
            break
        }
        Write-Host '  Please enter a whole number between 0 and 5475.' -ForegroundColor Yellow
    }
    $cutoff = (Get-Date).AddDays(-$days)

    # --- Optional operating-system filter for computers ---
    $osFilter = ''
    if ($Mode -eq 'Computers') {
        Write-Host ''
        Write-Host 'Limit the search to one operating system? Press Enter for ALL computers,' -ForegroundColor Cyan
        Write-Host 'or type part of a name (for example: Windows 11).' -ForegroundColor Cyan
        $osFilter = (Read-Host 'Operating system').Trim()
    }

    Write-Host ''
    Write-Log "Searching $($Settings.$Mode.SearchBaseName) for $Mode with no sign-in since $($cutoff.ToString('yyyy-MM-dd'))." 'Cyan'
    # The wait notice is shown on screen only; the log records just the filter.
    if ($osFilter) {
        Write-Host "Operating system filter: '$osFilter'. This can take a minute, please wait..." -ForegroundColor Gray
        Add-Content -Path $script:LogFile -Value ("{0}  Operating system filter: '{1}'" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $osFilter) -Encoding UTF8
    }
    else {
        Write-Host 'This can take a minute, please wait...' -ForegroundColor Gray
    }

    # --- Ask AD ---
    $stale = $null
    try {
        $stale = @(Get-StaleAccounts -Settings $Settings -Mode $Mode -Cutoff $cutoff -OsFilter $osFilter)
    }
    catch {
        Write-Log "Something went wrong while searching AD: $($_.Exception.Message)" 'Red'
        Write-Log 'Nothing was changed. You may not have permission to read that OU, or the OU may have just changed.' 'Yellow'
        Wait-Enter 'Press Enter to go back to the menu'
        return
    }

    # --- Filed means finished ---
    # Hide accounts that are already disabled AND already inside the
    # destination OU (or one of its sub-OUs) - that work is done.
    # Enabled accounts always appear, wherever they live, so a machine
    # someone re-enabled inside the retired OU still gets noticed.
    # The destination is read from settings fresh each run, so this rule
    # follows any settings change automatically.
    $alreadyFiled = 0
    $destDn = $Settings.$Mode.DestinationDn
    if ($Settings.$Mode.MoveAfterDisable -and -not [string]::IsNullOrWhiteSpace($destDn)) {
        $beforeCount = $stale.Count
        $stale = @($stale | Where-Object {
            $_.Enabled -or -not $_.DistinguishedName.EndsWith(("," + $destDn), [System.StringComparison]::OrdinalIgnoreCase)
        })
        $alreadyFiled = $beforeCount - $stale.Count
    }
    if ($alreadyFiled -gt 0) {
        Write-Log "Skipped $alreadyFiled $noun(s) that are already disabled and filed in '$($Settings.$Mode.DestinationName)'." 'Gray'
    }

    if ($stale.Count -eq 0) {
        if ($osFilter) {
            Write-Log "No stale computers found whose operating system contains '$osFilter'. Check the spelling if you expected results." 'Yellow'
        }
        else {
            Write-Log 'Good news - everything in that location is current. No cleanup is needed.' 'Green'
        }
        Wait-Enter 'Press Enter to go back to the menu'
        return
    }

    # --- Build the friendly rows and show the headline numbers ---
    # (The @(...)[-1] grabs the LAST thing the function hands back, which
    #  is always the results bundle - a guard against stray output.)
    $prep = @(New-DisplayRows -Accounts $stale -Settings $Settings -Mode $Mode)[-1]
    # Keyword matches go to the top of the selection window, then by name.
    # (Clicking a column header in the window still re-sorts it.)
    $rows = @($prep.Rows | Sort-Object @{ Expression = { $_.'Keyword Match' -eq 'Yes' }; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
    $map  = $prep.Map

    $neverCount     = @($rows | Where-Object { $_.LastSeen -eq 'Never' }).Count
    $alreadyCount   = @($rows | Where-Object { $_.Status -eq 'Already disabled' }).Count
    $protectedRows  = @($rows | Where-Object { $_.'Keyword Match' -eq 'Yes' })

    Write-Host ''
    Write-Log "Found $($rows.Count) stale $Mode :" 'Yellow'
    Write-Log "  - Never signed in        : $neverCount" 'Yellow'
    Write-Log "  - Signed in, gone stale  : $($rows.Count - $neverCount)" 'Yellow'
    Write-Log "  - Already disabled       : $alreadyCount" 'Yellow'
    Write-Log "  - Keyword matches        : $($protectedRows.Count)" 'Yellow'

    # (Keyword-matched names stay in the list. The Keyword Match column in
    #  the selection window flags them so they stand out during review.)

    # --- Let the user pick ---
    Write-Host ''
    $picked = @(Select-Accounts -Rows $rows -Mode $Mode)
    if ($picked.Count -eq 0) {
        Write-Host ''
        Write-Log "No ${noun}s were selected, so no changes will be made." 'Yellow'
        Wait-Enter 'Press Enter to go back to the menu'
        return
    }

    # --- Show back what was picked, and write it into the receipt ---
    $pickedEnabled = @($picked | Where-Object { $_.Status -eq 'Enabled' }).Count
    $pickedAlready = @($picked | Where-Object { $_.Status -eq 'Already disabled' }).Count
    Write-Host ''
    Write-Log "You selected $($picked.Count) $noun(s): $pickedEnabled enabled, $pickedAlready already disabled." 'Cyan'
    $pickedKeyword = @($picked | Where-Object { $_.'Keyword Match' -eq 'Yes' }).Count
    if ($pickedKeyword -eq 1) {
        Write-Log '1 of your selections is a keyword match. Review it before continuing.' 'Yellow'
    }
    elseif ($pickedKeyword -gt 1) {
        Write-Log "$pickedKeyword of your selections are keyword matches. Review them before continuing." 'Yellow'
    }
    $preview = $picked | Select-Object -First 20
    ($preview | Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host
    if ($picked.Count -gt 20) { Write-Host "  ...and $($picked.Count - 20) more. All of them are listed in the log file." -ForegroundColor Gray }
    foreach ($p in $picked) {
        Add-Content -Path $script:LogFile -Value ("{0}  SELECTED: {1} ({2}) - {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $p.Name, $p.Account, $p.Status) -Encoding UTF8
    }

    # --- Disable, then move ---
    $disableResult = Invoke-DisablePhase -Map $map -PickedRows $picked -Noun $noun
    $moveResult    = Invoke-MovePhase   -Map $map -PickedRows $picked -Settings $Settings -Mode $Mode -DisableResult $disableResult

    # --- Summary ---
    Write-Host ''
    Write-Log '================  SUMMARY  ================' 'Cyan'
    Write-Log "  Selected              : $($picked.Count)" 'White'
    Write-Log "  Disabled just now     : $($disableResult.DisabledCount)" 'White'
    Write-Log "  Were already disabled : $($disableResult.AlreadyCount)" 'White'
    Write-Log "  Disable errors        : $($disableResult.ErrorCount)" 'White'
    if ($moveResult.Ran) {
        Write-Log "  Moved                 : $($moveResult.MovedCount)" 'White'
        Write-Log "  Already in the OU     : $($moveResult.AlreadyThere)" 'White'
        Write-Log "  Still enabled, left in place : $($moveResult.StillEnabled)" 'White'
        Write-Log "  Move errors           : $($moveResult.ErrorCount)" 'White'
    }
    Write-Log "  Receipt saved to      : $script:LogFile" 'Gray'
    Write-Host ''
    Wait-Enter 'Press Enter to go back to the menu'
}


# ---------------------------------------------------------------------
#  MAIN - this is where the tool actually starts
# ---------------------------------------------------------------------

try { Clear-Host } catch { }

Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '                AD CLEANUP TOOL  v0.1.0              ' -ForegroundColor Cyan
Write-Host '   Find, disable, and file away stale AD accounts    ' -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host ''
Write-Log "Run started. Receipt for this run: $script:LogFile" 'Gray'

# --- Selection windows are required. They are missing on servers installed
#     without a desktop and in text-only remote sessions. ---
$script:HasGui = [bool](Get-Command Out-GridView -ErrorAction SilentlyContinue)
if (-not $script:HasGui) {
    Write-Log 'This tool needs the pop-up selection windows, which are not available here.' 'Red'
    Write-Log 'That usually means a server without a desktop, or a text-only remote session.' 'Yellow'
    Write-Log 'Please run the tool from a regular Windows computer.' 'Yellow'
    return
}

# --- Is the Active Directory toolkit installed? ---
# (Skip creating the "AD:" drive during import - the tool doesn't use it,
#  and a sign-in problem would otherwise surface here as a vague warning.)
$Env:ADPS_LoadDefaultDrive = 0
try {
    Import-Module ActiveDirectory -ErrorAction Stop
}
catch {
    Write-Log 'The Active Directory PowerShell tools are not installed on this computer.' 'Red'
    Write-Log 'This tool requires them to communicate with AD. To install them:' 'Yellow'
    Write-Log '  - On Windows 11: sign in with an administrator account, then go to' 'Yellow'
    Write-Log '    Settings > System > Optional features > Add a feature and install' 'Yellow'
    Write-Log '    "RSAT: Active Directory Domain Services and Lightweight Directory Services Tools"' 'Yellow'
    Write-Log '    Do not choose the "Certificate Services" entry. That is a different toolkit.' 'Yellow'
    Write-Log '    Note: the install option appears grayed out unless you are signed in as an administrator.' 'Yellow'
    Write-Log '  - On a server: Install-WindowsFeature RSAT-AD-PowerShell' 'Yellow'
    Write-Log 'Then run this tool again.' 'Yellow'
    return
}

# --- Find ONE domain controller and use it for everything this run. ---
# (Using a single AD server the whole time keeps the results consistent -
#  otherwise a search, a disable, and a move could each talk to different
#  servers that have not caught up with each other yet.)
try {
    $discovered = Get-ADDomainController -Discover -Writable -ErrorAction Stop
    $script:DC  = ($discovered.HostName | Select-Object -First 1)
}
catch {
    try { $script:DC = (Get-ADDomain -ErrorAction Stop).PDCEmulator } catch { $script:DC = $null }
}

if ([string]::IsNullOrWhiteSpace($script:DC)) {
    Write-Log 'Could not reach Active Directory from this computer.' 'Red'
    Write-Log 'Make sure you are on a domain-joined machine or connected by VPN, and signed in with a domain account, then try again.' 'Yellow'
    return
}

try {
    $script:DomainName = (Get-ADDomain -Server $script:DC -ErrorAction Stop).DNSRoot
}
catch {
    Write-Log "Found an AD server ($script:DC) but could not sign in to it." 'Red'
    Write-Log "Windows said: $($_.Exception.Message)" 'Yellow'
    Write-Log 'This is usually a credential problem - an expired or recently changed password,' 'Yellow'
    Write-Log 'a locked account, or running under an account without AD access.' 'Yellow'
    Write-Log 'Nothing was changed - sort out the sign-in and run the tool again.' 'Yellow'
    return
}
Write-Log "Connected to Active Directory ($script:DomainName) via server: $script:DC" 'Green'

# --- Load saved settings, or run first-time setup ---
$settings = Import-Settings
if ($null -eq $settings) {
    if (Test-Path $script:SettingsFile) {
        Write-Log 'The settings file could not be read. It may be damaged. Running first-time setup again.' 'Yellow'
    }
    $settings = Invoke-FirstRunSetup
}
$settings = Confirm-SettingsHealthy -Settings $settings
if ($script:OuCheckUnreachable) {
    Write-Log "Receipt for this run: $script:LogFile" 'Gray'
    return
}

# Record in the receipt which keyword list this run is using (receipt only,
# not shown on screen) - a dated record of any customizations.
Add-Content -Path $script:LogFile -Value ("{0}  Keyword list in use: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (@($settings.ProtectedKeywords) -join ', ')) -Encoding UTF8

# --- Main menu ---
while ($true) {
    Write-Host ''
    Write-Host '----------------  MAIN MENU  ----------------' -ForegroundColor Cyan
    Write-Host '  1. Clean up COMPUTERS'
    Write-Host '  2. Clean up USER ACCOUNTS'
    Write-Host '  3. Settings'
    Write-Host '  4. Quit'
    $choice = (Read-Host 'Choose 1, 2, 3, or 4').Trim().ToUpper()

    if     ($choice -eq '1') { Invoke-CleanupRun -Settings $settings -Mode 'Computers' }
    elseif ($choice -eq '2') { Invoke-CleanupRun -Settings $settings -Mode 'Users' }
    elseif ($choice -eq '3') { $settings = Invoke-SettingsMenu -Settings $settings }
    elseif ($choice -eq '4') { break }
    else   { Write-Host '  Please choose 1, 2, 3, or 4.' -ForegroundColor Yellow }
}

Write-Host ''
Write-Log 'All done. It is safe to close this window.' 'Green'
Write-Log "Receipt for this run: $script:LogFile" 'Gray'

