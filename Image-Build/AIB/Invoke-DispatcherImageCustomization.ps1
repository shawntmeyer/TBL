param (
        [Parameter(Mandatory=$false)]
        [String]
        $WindowsVersion = '2004',
        [Parameter(Mandatory=$false)]
        [Boolean]
        $Office365Install = $true,
        [Parameter(Mandatory=$false)]
        [String]
        $BuildDir="$env:SystemDrive\BuildArtifacts",
        [Parameter(Mandatatory=$false)]
        [String]
        $CustomizationSourceStorageAccountRG = "BSD-IMAGING-RG",
        [Parameter(Mandatatory=$false)]
        [String]
        $CustomizationSourceStorageAccountName = "bsdimagesources"
)

$ScriptName = $MyInvocation.MyCommand.Name

Function Get-AzStorageFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [String]
        $ResourceGroupName,
        [Parameter(Mandatory=$true)]
        [String]
        $CustomizationSourceStorageName,
        [Parameter(Mandatory=$true)]
        [String]
        $ShareName,
        [Parameter(Mandatory=$true)]
        [String]
        $FilePath,
        [Parameter(Mandatory=$true)]
        [String]
        $DestinationFile
    )

    Write-Output "Download file contents from storage container."    

    ## Get the storage account
    $storageAccount=Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $CustomizationSourceStorageName    

    Get-AzStorageFileContent -Context $storageAccount.Context -ShareName $shareName -Path $FilePath -Destination $DestinationFile
}

Function Update-ServiceConfigurationJSON {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [String]
        $ConfigFile,
        [Parameter(Mandatory=$true)]
        [String]
        $ServiceName,
        [Parameter(Mandatory=$true)]
        [String]
        $VDIState
    )
    Write-Output "Checking for configuration file '$Configfile'."
    If (Test-Path $ConfigFile) {
        Write-Output "Configuration File found. Updating configuration of '$ServiceName' to '$VDIState'."
        $ConfigObj = Get-Content "$ConfigFile" -Raw | ConvertFrom-Json
        $ConfigObj | ForEach-Object {If($_.Name -eq "$ServiceName"){$_.VDIState = $VDIState}}
        $ConfigObj | ConvertTo-Json -depth 32 | Set-Content $ConfigFile
    }
    else {
        Write-Warning "The configuration file not found."
    }
}

Write-Output "Running '$ScriptName'"
If ($CustomizationSourceStorageAccountRG -and $CustomizationSourceStorageAccountName) {
    Write-Log "Verifying availability of Customization Sources storage Account."
    $storageAccount = Get-AzStorageAccount `
        -ResourceGroupName $ResourceGroupName `
        -Name $CustomizationSourceStorageName `
        -ErrorAction SilentlyContinue
    If ($storageAccount) {
        Write-Log "Storage Account Verified."
        $sactx = $storageAccount.Context
    }
}


Write-Output "Creating '$BuildDir'"

If (-not (Get-Module -Name Az -ErrorAction SilentlyContinue)) {
    Install-Module Az -AllowClobber -Force
}
$null = New-Item -Path "$BuildDir" -ItemType Directory -Force -ErrorAction SilentlyContinue
Write-Output "Downloading the WVD Image Prep Script from the 'http://www.github.com/shawntmeyer/wvd' repo."
$PrepWVDImageURL = "https://github.com/shawntmeyer/WVD/archive/master.zip"
$PrepareWVDImageZip= "$BuildDir\WVD-Master.zip"
Write-Output "Downloading '$PrepWVDImageURL' to '$PrepareWVDImageZip'."
Invoke-WebRequest -Uri $PrepWVDImageURL -outfile $PrepareWVDImageZip -UseBasicParsing
Expand-Archive -Path $PrepareWVDImageZip -DestinationPath $BuildDir
Remove-Item -Path $PrepareWVDImageZip -Force -ErrorAction SilentlyContinue
$ScriptPath = "$BuildDir\WVD-Master\Image-Build\Customizations"
Write-Output "Now calling 'Prepare-WVDImage.ps1'"
# & "$ScriptPath\Prepare-WVDImage.ps1" -RemoveApps $False -Office365Install $Office365Install
& "$ScriptPath\Prepare-WVDImage.ps1" -Office365Install $Office365Install
Write-Output "Finished 'Prepare-WVDImage.ps1'."

#region SQL Native Client
$ShareName = "software"
$SqlSourcePath = "hexagon\sqlncli_64.msi"
$sqlCltPath = "$BuildDir\SqlClt\sqlncli_x64.msi"
Get-AzstorageFile `
    -ResourceGroupName $CustomizationSourceStorageAccountRG `
    -StorageAccountName $CustomizationSourceStorageName `
    -ShareName $ShareName `
    -FilePath $SQLSourcePath `
    -DestinationFile $SQLCltPath
Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$SQLCltPath`" /qn IACCEPTSQLNCLILICENSETERMS=YES" -wait
#endregion

#region ICAD Net Install
$Share = "software"
$SourceFile = "hexagon\IPS0042_INetViewer_9.4.50158.zip"
$DestinationFile = "$BuildDir\InetViewer.zip"
Get-AzStorageFileContent `
    -Context $sactx `
    -ShareName $Share `
    -Path $SourceFile `
    -Destination $DestinationFile
$ExtractPath = "$BuildDir\ICADNet"
Expand-Archive -Path $DestinationFile -DestinationPath $ExtractPath
Write-Output "Installing ICAD Net."
Start-Process -FilePath "$ExtractPath\Setup.exe" -ArgumentList "/s ICAD_NET /n ACCEPT_EULA=1 ORASELECTED=0 MSSSELECTED=1" -wait
#end region

#region Dispatcher
$Share = "software"
$SourceFile = "hexagon\IPS0045_INetDispatcher_9.4.50158.zip"
$DestinationFile = "$BuildDir\InetDispatcher.zip"
Get-AzStorageFileContent `
    -Context $sactx `
    -ShareName $Share `
    -Path $SourceFile `
    -Destination $DestinationFile
$ExtractPath = "$BuildDir\ICADDispatcher"
Expand-Archive -Path $DestinationFile -DestinationPath $ExtractPath
Write-Output "Installing ICAD Dispatcher."
Start-Process -FilePath "$ExtractPath\Setup.exe" -ArgumentList "/s Dispatcher /ni ACCEPT_EULA=1" -wait
#end region

#region Informer
$Share = "software"
$SourceFile = "hexagon\IPS0004_Informer__9.4.50075.zip"
$DestinationFile = "$BuildDir\Informer.zip"
Get-AzStorageFileContent `
    -Context $sactx `
    -ShareName $Share `
    -Path $SourceFile `
    -Destination $DestinationFile
$ExtractPath = "$BuildDir\Informer"
Expand-Archive -Path $DestinationFile -DestinationPath $ExtractPath
Write-Output "Installing Informer."
Start-Process -FilePath "$ExtractPath\Setup.exe" -ArgumentList "/s InformerClient /ni ACCEPT_EULA=1" -wait
#end region

# Download Virtual Desktop Optimization Tool from the Virtual Desktop Team GitHub Repo
$WVDOptimizeURL = 'https://github.com/The-Virtual-Desktop-Team/Virtual-Desktop-Optimization-Tool/archive/master.zip'
$WVDOptimizeZIP = "$BuildDir\Windows_10_VDI_Optimize-master.zip"
Write-Output "Downloading the Virtual Desktop Team's Virtual Desktop Optimization Tool from GitHub."
Write-Output "Downloading '$WVDOptimizeURL' to '$WVDOptimizeZIP'."
Invoke-WebRequest -Uri $WVDOptimizeURL -OutFile $WVDOptimizeZIP -UseBasicParsing
Expand-Archive -Path $WVDOptimizeZIP -DestinationPath $BuildDir -force
Remove-Item -Path $WVDOptimizeZIP -Force -ErrorAction SilentlyContinue
$ScriptPath = "$BuildDir\Virtual-Desktop-Optimization-Tool-master"
Write-Output "Staging the Virtual Desktop Optimization Tool at '$ScriptPath'."
Write-Output "Removing AppXPackages.json file to prevent appx removal. Already completed."
$AppxPackagesConfigFileFullName = "$scriptPath\$WindowsVersion\ConfigurationFiles\AppxPackages.json"
Remove-Item -Path $AppxPackagesConfigFileFullName -force
# Update Services Configuration
Write-Output "Updating Services Configuration."
$ServicesConfig = "$ScriptPath\$WindowsVersion\ConfigurationFiles\Services.json"
Write-Output "Setting the 'Store Install Service' in file to 'Default'."
Update-ServiceConfigurationJSON -ServiceName 'InstallService' -ConfigFile $ServicesConfig -VDIState "Default"
Write-Output "Setting the 'System Maintenance Service' in file to 'Default'."
Update-ServiceConfigurationJSON -ServiceName 'SysMain' -ConfigFile $ServicesConfig -VDIState "Default"
Write-Output "Setting the 'Update Orchestration Service' in file to 'Default'."
Update-ServiceConfigurationJSON -ServiceName 'UsoSvc' -ConfigFile $ServicesConfig -VDIState "Default"
Write-Output "Setting the 'Volume Shadow Copy Service' in file to 'Default'."
Update-ServiceConfigurationJSON -ServiceName 'VSS' -ConfigFile $ServicesConfig -VDIState "Default"
# DefaultUserSettings.txt update
$TextFile = "$scriptPath\$WindowsVersion\ConfigurationFiles\DefaultUserSettings.txt"
If (Test-Path $TextFile) {
    # Remove Blank Lines
    (Get-Content $TextFile) | ForEach-Object { if ($_ -ne '') { $_ } } | Set-Content $TextFile
}
# Script Updates
$WVDOptimizeScriptName = (Get-ChildItem $ScriptPath | Where-Object {$_.Name -like '*optimize*.ps1'}).Name
Write-Output "Adding the '-NoRestart' switch to the Set-NetAdapterAdvancedProperty line in '$WVDOptimizeScriptName' to prevent the network adapter restart from killing AIB."
$WVDOptimizeScriptFile = Join-Path -Path $ScriptPath -ChildPath $WVDOptimizeScriptName
(Get-Content $WVDOptimizeScriptFile) | ForEach-Object { if (($_ -like 'Set-NetAdapterAdvancedProperty*') -and ($_ -notlike '*-NoRestart*')) { $_ -replace "$_", "$_ -NoRestart" } else { $_ } } | Set-Content $WVDOptimizeScriptFile
Write-Output "Removing the possibly invasive disk cleanup routine starting at c:\"
(Get-Content $WVDOptimizeScriptFile) | ForEach-Object { if ($_ -like 'Get-ChildItem -Path c:\ -include*') { "# $_" } else { $_ } } | Set-Content $WVDOptimizeScriptFile
Write-Output "Now calling '$WVDOptimizeScriptName'."
& "$WVDOptimizeScriptFile" -WindowsVersion $WindowsVersion -Verbose
Write-Output "Completed $WVDOptimizeScriptName."

#Section Install App Y
Start-Sleep 5
$DeprovisioningScript = "$env:SystemDrive\DeprovisioningScript.ps1"
If (Test-Path $DeprovisioningScript) {
    Write-Output "Adding the /mode:VM switch to the sysprep command line in the deprovisioning script."
    (Get-Content $DeprovisioningScript) | ForEach-Object { if ($_ -like '*System32\Sysprep\Sysprep.exe*') { "$_ /mode:vm" } else { $_ } } | Set-Content $DeprovisioningScript
}
Write-Output 'Cleaning up from customization scripts.'
Write-Output "Removing '$BuildDir'."
Remove-Item -Path $BuildDir\* -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $BuildDir -Recurse -Force -ErrorAction SilentlyContinue