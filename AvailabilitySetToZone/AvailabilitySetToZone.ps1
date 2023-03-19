<#
.SYNOPSIS
	This script will move Azure VM's from it's Availability Set to Availability Zones
.DESCRIPTION
	This script will get the VM information from the provided Availability Set, remove the VM's keeping the Nic and Disk, then recreate the VM's spread over Availability Zones
.NOTES
	Author: Sjoerd van den Berg

	Currently this script does not support TrustedLaunch enabled VM's
.PARAMETER AvailabilitySetName
	This parameter is used to identify the AvailabilitySet Name
.PARAMETER KeepSourceDisk
	This parameter tell the script to not remove the source disk after copying the disk content to the new disk that supports Availability Groups
.PARAMETER KeepVMStopped
	This parameter will leave the new VM's stopped (deallocated) after recreating them in Availability Zones
.PARAMETER KeepOriginalDisk
	This parameter will leave the original disk remaining after converting to Availability Zone
.EXAMPLE
	AvailabilitySetToZone.ps1 -AvailabilitySetName sbgavailset
.EXAMPLE
	AvailabilitySetToZone.ps1 -AvailabilitySetName sbgavailset -KeepVMStopped
.EXAMPLE
	AvailabilitySetToZone.ps1 -AvailabilitySetName sbgavailset -KeepVMStopped -KeepSourceDisk	
#>

[CmdletBinding()]
param (
	[Parameter(Mandatory)]
	[string]
	$AvailabilitySetName,
	[switch]
	$KeepSourceDisk,
	[switch]
	$KeepVMStopped,
	[string]
	$LogFilePath = (Join-Path $PSscriptRoot "AvailabilitySetToZone-$(Get-Date -Format "yyyyMMddHHmmss").log")
)

function Write-Warn([string] $Message){
	WriteLog -Message $Message -Level Warn
	Write-Warning $Message
}
function Write-Info([string] $Message, [switch] $ToScreen){
	WriteLog -Message $Message -Level Info
	if ($ToScreen) { Write-Host $Message}
}
function Write-Err([string] $Message){
	WriteLog -Message $message -Level Error
	Write-Error $Message
}
function WriteLog{
	param([string] $Message,[ValidateSet("Error","Warn","Info")] $Level)
	$FormattedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	$callstack = Get-PSCallStack
	$scriptname = $callstack[1].Location.Split(":")[0].Trim("ps1").Trim(".")
	"$FormattedDate   $($Level.ToUpper()) [$scriptname] $Message" | Out-File -FilePath $LogFilePath -Append
}

function Login(){
    $context = Get-AzContext
    if (!$context) {
        $azProfile = Connect-AzAccount
		if (!$azProfile) {
			Write-Err "Unable to login to Azure Account"
			Exit
		}
	}
	Write-Host "Connected to Azure [$(Get-AzSubscription)]"
}

Login

# Get the availability set provided by the user

$as = Get-AzAvailabilitySet -Name $AvailabilitySetName
if ($null -eq $as) { Write-Err "Unable to find AvailabilitySet with Name [$AvailabilitySetName]"; Exit }
Write-Info "Found AvailabilitySet [$AvailabilitySetName] with Id [$($as.Id)]"

# Get the Sku used by the VM and verify if this is compatible in at least 2 availability zones

$vm = Get-AzVm -ResourceId $as.VirtualMachinesReferences[0].Id
$location = $vm.Locatation
$vmSize = $vm.HardwareProfile.VmSize
Write-Info "Validating if VM Size [$vmsize] Sku is compatible in at least 2 Availability Zones" -ToScreen
$skus = Get-AzComputeResourceSku | Where-Object { ($_.Locations -contains $location) -and ($_.Name -eq $vmSize) }
$zoneCompatibility = $true
if ($Skus.Restrictions | Where-Object Type -eq "Zone"){
	$zonesRestricted = [array]($Skus.Restrictions[0].RestrictionInfo.Zones)
	if ($zonesRestricted.Count -gt 1){
		Write-Info "VM [$($vm.Name)] with size [$vmSize] is not available in zones [$($zonesRestricted -join ",")]"
		$zoneCompatibility = $false
	}
	else {
		Write-Info "VM [$($vm.Name))] with size [$vmSize] can be deployed in zones [$($zonesRestricted -join ",")]"
	}
}


# If we have enough compatible zones, loop through the VM's part of the availability set and recreate them in zones

$compatibleZones = (1,2,3) | Where-Object {$_ -notin $zonesRestricted} | Sort-Object
$originalVMs = @()
$snapshotNames = @()

if ($zoneCompatibility){
	$i = 1
	foreach ($vmRef in $as.VirtualMachinesReferences){

		# Get existing VM information
		$vm = Get-AzVm -ResourceId $vmRef.Id
		$originalVMs += @([pscustomobject]@{Name=$vm.Name;PowerState=[string]::Empty;Validated=$false})

		# Save all original configurations and write verbose output
		$zone = $compatibleZones[($i % $compatibleZones.Count)-1]
		if ($i -eq $compatibleZones.Count){ $i = 1 }
		else{ $i++ }
		Write-Info "Zone = $zone"
		
		$vmname = $vm.Name
		Write-Info "VM Name = $vmname"

		$tags = $vm.Tags
		Write-Info "VM Tag Names = $($tags.Keys -join ",")"
		Write-Info "VM Tag Values = $($tags.Values -join ",")"

		$location = $vm.Location
		Write-Info "VM Location = $location"

		$vmResourceGroup = $vm.ResourceGroupName
		Write-Info "VM ResourceGroup = $vmResourceGroup"

		$vmSize = $vm.HardwareProfile.VmSize
		Write-Info "VM Size = $vmsize"

		$nicIds = $vm.NetworkProfile.NetworkInterfaces.Id
		Write-Info "Nic Ids = $($nicIds -join ",")"
		
		$osDiskName = $vm.StorageProfile.OsDisk.Name
		Write-Info "OS Disk Name = $osDiskName"

		$sourceDisk = (Get-AZDisk -DiskName $osDiskName -ResourceGroupName $vmResourceGroup)
		if ($sourceDisk.Tags){
			Write-Info "OS Disk Tag Names = $($sourceDisk.Tags.Keys -join ",")"
			Write-Info "OS Disk Tag Values = $($sourceDisk.Tags.Values -join ",")"
		}

		$sourceDataDisks = $vm.StorageProfile.Datadisks | Get-AzDisk	
		foreach ($dataDisk in $sourceDataDisks){

			Write-Info "Data Disks = $($dataDisk.Name)"
			Write-Info "Data Disk Tag Names = $($dataDisk.Tags.Keys -join ",")"
			Write-Info "Data Disk Tag Values = $($dataDisk.Tags.Values -join ",")"

		}

		if ($vm.SecurityProfile){
			$securityType = $vm.SecurityProfile.SecurityType
			Write-Info "SecurityType = $SecurityType"
			$secureboot = $vm.SecurityProfile.UefiSettings.SecureBootEnabled
			Write-Info "SecureBootEnabled = $SecureBoot"
			$vtpm = $vm.SecurityProfile.UefiSettings.VTpmEnabled
			Write-Info "VTpmEnabled = $VTpm"
		}

		if ($vm.DiagnosticsProfile.BootDiagnostics.Enabled){
			$bootdiagEnabled = $true
			Write-Info "bootdiagEnabled = true"
			$StorageUri = $vm.DiagnosticsProfile.BootDiagnostics.StorageUri
			Write-Info "StorageUri = $StorageUri"
		}

		# Stopping the existing VM
		Write-Info "Stopping VM [$($vm.Name)]" -ToScreen
		$result = Stop-AzVM -Name $vm.Name -ResourceGroupName $vmResourceGroup -Force
		Write-Info "Operation [$($result.OperationId)] ended [$($result.EndTime)] with status [$($result.Status)]"
		if ($result.Status -ne "Succeeded") { Write-Err "Stopping the VM [$($vm.Name)] failed"; continue }

		#TODO support remove VM without disk if it is configured to be removed together with VM

		# Remove the VM from the Availability Set
		Write-Info "Removing VM [$($vm.Name)]" -ToScreen
		$result = Remove-AzVM -ResourceGroupName $vmResourceGroup -Name $vm.Name -Force
		Write-Info "Operation [$($result.OperationId)] ended [$($result.EndTime)] with status [$($result.Status)]"
		if ($result.Status -ne "Succeeded") { Write-Err "Removing the VM [$($vm.Name)] failed"; continue }

		$sourceDisk = (Get-AZDisk -DiskName $osDiskName -ResourceGroupName $vmResourceGroup)
		
		#Create the snapshot configuration
		#We recommend you to store your snapshots in Standard storage to reduce cost. Please use Standard_ZRS in regions where zone redundant storage (ZRS) is available, otherwise use Standard_LRS
		#Please check out the availability of ZRS here: https://docs.microsoft.com/en-us/Az.Storage/common/storage-redundancy-zrs#support-coverage-and-regional-availability
		$snapshotConfig =  New-AzSnapshotConfig -SourceUri $sourceDisk.Id -Location $location -CreateOption copy -SkuName "Standard_ZRS"
		
		#Take the snapshot
		$snapshotName = "$vmName-temp-snapshot"
		$snapshotNames += $snapshotName
		Write-Info "Create snapshot snapshot [$snapshotName] based on disk [$($sourceDisk.Name)]" -ToScreen
		$snapshot = New-AzSnapshot -Snapshot $snapshotConfig -SnapshotName $snapshotName -ResourceGroupName $vmResourceGroup
		
		$newDiskName = "$($sourceDisk.Name)-zone"
		Write-Info "Create new disk [$newDiskName] based on snapshot [$snapshotName]" -ToScreen
		$diskConfig = New-AzDiskConfig -SkuName $sourceDisk.Sku.Name -Location $location -CreateOption Copy -SourceResourceId $snapshot.Id -DiskSizeGB ($sourceDisk.DiskSizeGB + 1) -Zone $zone
		$targetDisk = New-AzDisk -Disk $diskConfig -ResourceGroupName $vmResourceGroup -DiskName $newDiskName


		$newDataDiskIDs = @()
		# Create a Snapshot from the Data Disks and the Azure Disks with Zone information
		foreach ($dataDisk in $sourceDataDisks) { 

			$snapshotDataConfig = New-AzSnapshotConfig 	-SourceUri $dataDisk.Id `
														-Location $location `
														-CreateOption copy `
														-SkuName "Standard_ZRS"
			
			# Take the snapshot
			$snapshotName = ("{0}-{1}-temp-snapshot" -f $vmName, $dataDisk.Name)
			$snapshotNames += $snapshotName
			Write-Info "Create snapshot snapshot [$snapshotName] based on disk [$($dataDisk.Name)]" -ToScreen
			$dataSnapshot = New-AzSnapshot 	-Snapshot $snapshotDataConfig `
											-SnapshotName $snapshotName `
											-ResourceGroupName $vmResourceGroup

			# Create the new disk based on the snapshot
			$newDiskName = "$($dataDisk.Name)-zone"
			Write-Info "Create new data disk [$newDiskName] based on snapshot [$snapshotName]" -ToScreen
			$datadiskConfig = New-AzDiskConfig  -SkuName $dataDisk.Sku.Name `
												-Location $dataSnapshot.Location `
												-CreateOption Copy `
												-SourceResourceId $dataSnapshot.Id `
												-DiskSizeGB ($dataDisk.DiskSizeGB + 1) `
												-Zone $zone `
												-Tag $dataDisk.Tags
			$datadisk = New-AzDisk 	-Disk $datadiskConfig `
									-ResourceGroupName $vmResourceGroup `
									-DiskName $newDiskName
			
			$newDataDiskIDs += $dataDisk.Id
			
		}
		
		# Setting up the VM on the Availability Zone
		Write-Info "Setup new VM configuration for VM [$vmname] with Size [$vmSize]" -ToScreen
		$virtualMachine = New-AzVMConfig -VMName $vmname -VMSize $vmSize

		# Add the existing NIC's to the new VM configuration
 		$primary = $true
 		foreach ($nicId in $nicIds){

			$nic = (Get-AzNetworkInterface -ResourceId $nicId)
			$ipconfigs = $nic.IpConfigurations | Where-Object PublicIpAddress -ne $null

			foreach ($ipconfig in $ipconfigs){
				$pip = Get-AzPublicIpAddress | Where-Object id -eq $ipconfig.PublicIpAddress.Id
				Write-Info "Detected Public IP [$($pip.Name)] with Sku Basic. This is not compatible with Availability Zones."
				Write-Info "Reconfiguring NIC [$($nic.Name)] (Disconnecting Public IP reference)"
				Set-AzNetworkInterfaceIpConfig -Name $ipconfig.Name -NetworkInterface $nic -PublicIpAddress $null | Out-Null
				$nic | Set-AzNetworkInterface | Out-Null

			}

			Write-Info "Add NIC with ID [$nicId] to new VM configuration"
			$virtualMachine = Add-AzVMNetworkInterface -VM $virtualMachine -Id $nicId -Primary:($primary)
			$primary = $false
			
		}

		# Add the new OS disk to the new VM configuration
		Write-Info "Configure disk [$($targetDisk.Id)] to new VM configuration"
		if ($sourceDisk.OsType -eq "Windows") {
			$virtualMachine = Set-AzVMOSDisk -VM $virtualMachine -ManagedDiskId $targetDisk.Id -CreateOption Attach -Windows
		}
		else{
			$virtualMachine = Set-AzVMOSDisk -VM $virtualMachine -ManagedDiskId $targetDisk.Id -CreateOption Attach -Linux
		}

		# Add the new data disks to the new VM configuration
		$i = 1 #TODO: Max LUNs
		foreach ($dataDiskId in $newDataDiskIDs){

			Write-Info "Add data disk with ID [$dataDiskId] to new VM configuration"
			$virtualmachine = Add-AzVMDataDisk -VM $virtualmachine -ManagedDiskId $dataDiskId -Lun $i -CreateOption Attach
			$i++

		}

		# If the source VM had secure boot configured, reconfigure this in the new VM configuration
		if ($securityType){
			Write-Info "Configure Security Profile off new VM configuration"
			$virtualMachine = Set-AzVMSecurityProfile -VM $virtualMachine -SecurityType $securityType;
			$virtualMachine = Set-AzVMUefi -VM $virtualMachine -EnableVtpm $vtpm -EnableSecureBoot $secureboot;
		}

		# If the source VM had boot diagnostics configured, reconfigure this in the new VM configuration
		if ($bootdiagEnabled){
			# Get the storage account name from the URI
			$storageAccountName = (Split-path $vm.DiagnosticsProfile.BootDiagnostics.StorageUri -Leaf).Split('.')[0]
			$virtualMachine = Set-AzVMBootDiagnostic -VM $virtualMachine -Enable -ResourceGroupName $vmResourceGroup -StorageAccountName $storageAccountName
		}
		else{
			$virtualMachine = Set-AzVMBootDiagnostic -VM $virtualMachine -Disable
		}
		
		# Start creating the new VM
		Write-Info "Create new VM [$vmname]" -ToScreen
		New-AzVM -ResourceGroupName $vmResourceGroup -Location $location -VM $virtualmachine -Zone $zone -Tag $tags | Out-Null
		#Timer required, otherwise we do not seem to get ProvisioningState
		Start-Sleep -Seconds 10
		$newVM = Get-AzVM -ResourceGroupName $vmResourceGroup -Name $virtualMachine.Name
			
		Write-Info "Provisioning State = $($newVM.ProvisioningState)"
		if ($newVM.ProvisioningState -ne "Succeeded"){
			Write-Err "Provisioning failed"
			continue
		}
		if ($KeepVMStopped){
			Write-Info "Parameter KeepVMStopped detected. Stopping VM [$($vm.Name)]" -ToScreen
			$result = Stop-AzVM -Name $newVm.Name -ResourceGroupName $vmResourceGroup -Force
			Write-Info "Operation [$($result.OperationId)] ended [$($result.EndTime)] with status [$($result.Status)]"
			if ($result.Status -ne "Succeeded") { Write-Err "Stopping the VM [$($vm.Name)] failed"; continue }
		}

	}
}

# Verify if all VM's are created successfully
$originalVMs | Foreach-Object {
	$checkVM = Get-AzVM -Name $_.Name -Status
	if (-not $checkVM) { break }
	if ((($KeepVMStopped -and $checkVM.PowerState -notmatch "running") `
		-or ((-not $KeepVMStopped) -and $checkVM.PowerState -match "running")) `
		-and  ($checkVM.ProvisioningState -eq "Succeeded")){
			$_.PowerState = $checkVm.PowerState
			$_.Validated = $true
	}
}
Write-Info ($originalVMs | Out-String)

Write-Info "Cleaning Up..." -ToScreen
Write-Info "Removing original Availability Set [$AvailabilitySetName]"
$as | Remove-AzAvailabilitySet -Force | Out-Null

Write-Info "Removing temporary Snapshots [$($snapshotNames -Join ",")]"
$snapshotNames | ForEach-Object { Get-AzSnapshot -Name $_ | Remove-AzSnapshot -Force | Out-Null }

# If we don't need to keep the source disks, then remove them
if (-not $KeepSourceDisk){	
	if ($false -in $originalVMs.Validated){
		Write-Warn "Found at least one VM that could not be validated, not removing original disks"
		Exit
	}
	else {
		Write-Info "Remove original disk [$($sourceDisk.Id)]"
		$sourceDisk | Remove-AzDisk -Force | Out-Null
		$sourceDataDisks | Remove-AzDisk -Force | Out-Null
	}
}

$originalVMs