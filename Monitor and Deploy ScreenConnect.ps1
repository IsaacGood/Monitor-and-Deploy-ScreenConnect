<# Monitor and Deploy ScreenConnect - Isaac Good

1.2 / 2025-06-23
    Changed - Write-Host to Write-Information or Write-Verbose and added preference variables for each
    Changed - Combined some if statements
    Changed - Moved Company Name and Friendly Name code to Install-SC function
1.1 / 2025-06-16
    Added - Reinstall versions older than 25.4.16.9293 (broken by 25.4 binary signing changes)
    Added - Reenable service if disabled
    Added - If install fails, remove installer registry entries & service, then try again
    Added - Support for Datto RMM
    Changed - Code clean up: better variable names, logic flow, etc
    Changed - Functioned redundant code: Exit-NoError, Exit-WithError, Test-InstallTooOld, Test-Service
    Changed - Switched to EscapeDataString instead of just replacing '&'
    Changed - 25.4 changed filename in URL from ConnectWise.ClientSetup.msi to ScreenConnect.ClientSetup.msi
    Fixed - Age threshold wasn't actually being used

Notes:
    To get proper naming in SC, create two Syncro platform variables for the script:
Name: $CompanyName / Variable Type: platform / Value: customer_business_name_or_customer_full_name
Name: $FriendlyName / Variable Type: platform / Value: asset_custom_field_device_name

    The Friendly Name will only apply on initial install. Changing the name later in Syncro
does not sync, it must be changed in SC manually or delete it and let it reinstall.
If a Syncro asset has ever had a Friendly Name it will still have that name even if you have
turned it off in Syncro. The script can't check if it's on or off, so if you want to avoid
this, don't add the script variable.

    If an agent already exists in ScreenConnect with a company name or you change its company
name, the script can't detect this, you'll have to change in SC manually or delete/reinstall.

Future Development Ideas:
    - Bring in and set other fields like Site, Department, Device Type from RMM
    - Integrate with SC API to sync changed Company and Friendly Names into SC

#>

# Your ScreenConnect service name
# Example: 'ScreenConnect Client (923541cbadlc3b34f)'
$ServiceName = 'ScreenConnect Client ()'

# Your full ScreenConnect domain with NO trailing slash
# Example: 'https://my.screenconnect.com'
$Domain = 'https://'

# Write ScreenConnect join URL to an RMM field
$RMMField = $true
# Name of Custom Asset Field you created in Syncro
$RMMFieldSyncro = 'SC'
# Number of User Defined Field to use in Datto
$RMMFieldDatto = '14'

# Check the agent installation age
# If you update your ScreenConnect server manually make sure you set a calendar reminder,
# recurring ticket or similar to keep it updated or you risk getting a flood of alerts!
$InstallTooOldCheck = $true
# Number of days since installation to consider an agent 'too old'
$InstallTooOldThreshold = '180'

# Force reinstall regardless of age/service status
$ForceReinstall = $false

# Download path and filename
$FilePath = "$env:temp\sc.msi"

# Set Write-Information & Write-Verbose console output preferences
$InformationPreference = 'Continue'
$VerbosePreference = 'SilentlyContinue'

##### END OF VARIABLES #####

# Determine if running in Datto RMM or Syncro
$Datto = Get-Service | Where-Object { $_.DisplayName -match 'Datto RMM' }
$Syncro = Get-Module | Where-Object { $_.ModuleBase -match 'Syncro' }
if ($Syncro) { Import-Module $env:SyncroModule -DisableNameChecking }

function Exit-WithError {
    param ($Text)
    if ($Datto) {
        Write-Information '<-Start Result->'; Write-Information "Alert=$Text"; Write-Information '<-End Result->'
    } elseif ($Syncro) {
        Write-Information $Text
        Rmm-Alert -Category "Monitor ScreenConnect" -Body $Text
    } else {
        Write-Information $Text
    }
    Start-Sleep 10 # Give us a chance to view output when running interactively
    exit 1
}

function Exit-NoError {
    param ($Text)
    if ($Datto) {
        Write-Information '<-Start Result->'; Write-Information "Status=$Text"; Write-Information '<-End Result->'
    } elseif ($Syncro) {
        Write-Information $Text
        Rmm-Alert -Category "Monitor ScreenConnect" -Body $Text
        Close-Rmm-Alert -Category "Monitor ScreenConnect"
    } else {
        Write-Information $Text
    }
    Start-Sleep 10 # Give us a chance to view output when running interactively
    exit 0
}

function Remove-ExistingInstall {
    Get-ChildItem "HKLM:\SOFTWARE\Classes\Installer\Products\*\" | Get-ItemProperty | Where-Object ProductName -Like "$ServiceName" | Remove-Item -Recurse -Force
    Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\" | Get-ItemProperty | Where-Object DisplayName -Like "$ServiceName" | Remove-Item -Recurse -Force
    Get-ChildItem "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\" | Get-ItemProperty | Where-Object DisplayName -Like "$ServiceName" | Remove-Item -Recurse -Force
    sc.exe delete $ServiceName # not using Remove-Service to maintain PS5 compatibility
    Stop-Process -Name msiexec -Force -ErrorAction SilentlyContinue
}

function Install-SC {
    # Get Company Name
    if ($Datto) { $CompanyName = $env:CS_PROFILE_NAME }
    if ($CompanyName.length -lt 1 ) {
        Write-Information "Unable to get Company Name, it will be left blank"
    } else {
        Write-Verbose "Company Name found to use for install: $CompanyName"
    }
    # Escape characters like '&' so names doesn't get improperly abbreviated
    $CompanyName = [uri]::EscapeDataString($CompanyName)
    $FriendlyName = [uri]::EscapeDataString($FriendlyName)
    $MSIURL = "$Domain/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest&t=$FriendlyName&c=$CompanyName&c=&c=&c=&c=&c=&c=&c="
    Write-Verbose "Downloading installer: $MSIURL"
    Invoke-WebRequest -Uri $MSIURL -OutFile $FilePath
    Write-Verbose "Installing MSI from: $FilePath"
    Start-Process "msiexec.exe" -ArgumentList "/i `"$FilePath`" /quiet" -Wait
    Remove-Item $FilePath -Force
    if ((Test-Service) -ne 'Running') {
        Exit-WithError "Service not running, install failed"
    } else { Write-Information "Install successful" }
}

function Test-InstallTooOld {
    $InstallKey = Get-ChildItem "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall", "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall" | Where-Object { $_.GetValue( "DisplayName" ) -like $ServiceName }
    $InstallVersion = Get-ItemProperty -Path "Registry::$InstallKey" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DisplayVersion
    $global:InstallDate = Get-ItemProperty -Path "Registry::$InstallKey" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InstallDate
    if ($InstallDate -lt ((Get-Date).AddDays(-$InstallTooOldThreshold).ToString("yyyyMMdd")) -or $InstallVersion -lt "25.4.16.9293") { return $true }
}

function Test-Service {
    $ServiceStatus = (Get-Service $ServiceName -ErrorAction SilentlyContinue).Status
    Start-Sleep 4 # Wait to ensure service isn't flipping between states
    $ServiceStatus2 = (Get-Service $ServiceName -ErrorAction SilentlyContinue).Status
    if ($ServiceStatus -eq 'Running' -and $ServiceStatus2 -eq 'Running') {
        return 'Running'
    } elseif ($null -eq $ServiceStatus) {
        return 'Not Found'
    } else {
        return 'Stopped'
    }
}

if ($ForceReinstall -eq $true) { Install-SC }

# Test the service
switch (Test-Service) {
    'Running' {
        Write-Information "$ServiceName service is running"
    }
    'Not Found' {
        Write-Information "$ServiceName service not found, installing"
        Install-SC
    }
    'Stopped' {
        Write-Information "$ServiceName service is not running or disabled, attempting to start it"
        Set-Service $ServiceName -StartupType Automatic # Enable service if it is disabled/manual
        Start-Service $ServiceName
        if ((Test-Service) -eq 'Running') {
            Exit-NoError "Service was not running or disabled, it has been started"
        } else {
            Write-Information "Service could not be started, forcing removal & attempting reinstall"
            Remove-ExistingInstall
            Install-SC
        }
    }
}

if ((Test-Service) -ne 'Running') {
    Exit-WithError "Service is not running, reinstall failed"
}

# Test the install age
if ($InstallTooOldCheck -and (Test-InstallTooOld)) {
    Write-Verbose "$ServiceName installed on: $InstallDate"
    Write-Information "Install is old, attempting update"
    Install-SC
    if (Test-InstallTooOld) {
        Write-Information "Update failed, forcing removal & reattempting install"
        Remove-ExistingInstall
        Install-SC
        if (Test-InstallTooOld) {
            Exit-WithError "Version is old, reinstall failed"
        }
    }
}

if ($Datto) {
    Write-Information '<-Start Result->'; Write-Information "Status=OK"; Write-Information '<-End Result->'
} elseif ($Syncro) {
    Close-Rmm-Alert -Category "Monitor ScreenConnect"
}

# Get the ScreenConnect GUID and build the URL to insert into the custom field
if ($RMMField -eq $true) {
    $ServiceCommandLine = (Get-ItemProperty "HKLM:\SYSTEM\ControlSet001\Services\$ServiceName").ImagePath
    $GUID = ($ServiceCommandLine -split '(?<=\&s=)(.*)(?=\&k)')[1] # Extract between &s= and &k
    $ScreenConnectUrl = "$Domain/Host#Access/All%20Machines//$GUID/Join" # Yes, there is supposed to be two slashes
    Write-Verbose "ScreenConnect URL: $ScreenConnectUrl"
    if ($Datto -and $RMMFieldDatto -ge 1) {
        New-ItemProperty "HKLM:\Software\CentraStage" -Name "custom$RMMFieldDatto" -Value $ScreenConnectUrl | Out-Null
    }
    if ($Syncro -and $null -ne $RMMFieldSyncro) {
        Set-Asset-Field -Name "$RMMFieldSyncro" -Value $ScreenConnectUrl
    }
}
