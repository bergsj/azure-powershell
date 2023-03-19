<#
.SYNOPSIS
	This script will move Azure VM's from it's Availability Set to Availability Zones
.DESCRIPTION
	This script will get the VM information from the provided Availability Set, remove the VM's keeping the Nic and Disk, then recreate the VM's spread over Availability Zones
.NOTES
	Author: Sjoerd van den Berg

	This script requires azcopy to be installed and available in the local path environment variable.
	Currently this script does not support TrustedLaunch enabled VM's
.PARAMETER AvailabilitySetName
	This parameter is used to identify the AvailabilitySet Name
.PARAMETER KeepSourceDisk
	This parameter tell the script to not remove the source disk after copying the disk content to the new disk that supports Availability Groups
.EXAMPLE
	AvailabilitySetToZone.ps1 -AvailabilitySetName sbgavailset
#>

[CmdletBinding()]
param (
	[Parameter(Mandatory)]
	[string]
	$AvailabilitySetName,
	[switch]
	$KeepSourceDisk
)

function Login()
{
    $context = Get-AzContext
    if (!$context) {
        $azProfile = Connect-AzAccount
		if (!$azProfile) {
			Write-Error "Unable to login to Azure Account"
			Exit
		}
	}
	Write-Host "Connected to Azure [$(Get-AzSubscription)]"
}

Login
if (-not (Get-Command azcopy -ErrorAction SilentlyContinue)) { Write-Error "Unable to find azcopy, is it installed?"; Exit }

$zoneCompatibility = $true
$as = Get-AzAvailabilitySet -Name $AvailabilitySetName
if ($null -eq $as) { Write-Error "Unable to find AvailabilitySet with Name [$AvailabilitySetName]"; Exit }

$vm = Get-AzVm -ResourceId $as.VirtualMachinesReferences[0].Id
$location = $vm.Locatation
$vmSize = $vm.HardwareProfile.VmSize
Write-Output "Validating if VM Size [$vmsize] Sku is compatible in at least 2 Availability Zones"
$skus = Get-AzComputeResourceSku | Where-Object { ($_.Locations -contains $location) -and ($_.Name -eq $vmSize) }
if ($Skus.Restrictions | Where-Object Type -eq "Zone"){
	$zonesRestricted = [array]($Skus.Restrictions[0].RestrictionInfo.Zones)
	if ($zonesRestricted.Count -gt 1){
		Write-Verbose "VM [$($vm.Name)] with size [$vmSize] is not available in zones [$($zonesRestricted -join ",")]"
		$zoneCompatibility = $false
	}
	else {
		Write-Verbose "VM [$($vm.Name))] with size [$vmSize] can be deployed in zones [$($zonesRestricted -join ",")]"
	}
}

$compatibleZones = (1,2,3) | Where-Object {$_ -notin $zonesRestricted} | Sort-Object

if ($zoneCompatibility){
	$i = 1
	foreach ($vmRef in $as.VirtualMachinesReferences){


		# Get existing VM information
		
		$vm = Get-AzVm -ResourceId $vmRef.Id
		
		$zone = $compatibleZones[($i % $compatibleZones.Count)-1]
		if ($i -eq $compatibleZones.Count){ $i = 1 }
		else{ $i++ }
		Write-Verbose "Zone = $zone"
		
		$vmname = $vm.Name
		Write-Verbose "VM Name = $vmname"

		$location = $vm.Location
		Write-Verbose "VM Location = $location"

		$vmResourceGroup = $vm.ResourceGroupName
		Write-Verbose "VM ResourceGroup = $vmResourceGroup"

		$vmSize = $vm.HardwareProfile.VmSize
		Write-Verbose "VM Size = $vmsize"

		#TODO support multiple NIC's
		$nicId = ($vm.NetworkProfile.NetworkInterfaces)[0].Id
		Write-Verbose "Nic Id = $nicId"
		
		#TODO support remove VM without disk if it is configured to be removed together with VM
		$osDiskName = $vm.StorageProfile.OsDisk.Name
		Write-Verbose "OS Disk Name = $osDiskName"

		$diskSku = (Get-AZDisk -DiskName $osDiskName -ResourceGroupName $vmResourceGroup).Sku.Name
		Write-Verbose "Disk Sku = $diskSku"

		if ($vm.SecurityProfile){
			$securityType = $vm.SecurityProfile.SecurityType
			Write-Verbose "SecurityType = $SecurityType"
			$secureboot = $vm.SecurityProfile.UefiSettings.SecureBootEnabled
			Write-Verbose "SecureBootEnabled = $SecureBootEnabled"
			$vtpm = $vm.SecurityProfile.UefiSettings.VTpmEnabled
			Write-Verbose "VTpmEnabled = $VTpmEnabled"
		}

		if ($vm.DiagnosticsProfile.BootDiagnostics.Enabled){
			$bootdiagEnabled = $true
			Write-Verbose "bootdiagEnabled = true"
			$StorageUri = $vm.DiagnosticsProfile.BootDiagnostics.StorageUri
			Write-Verbose "StorageUri = $StorageUri"
		}

		# Removing the existing VM

		Write-Output "Stopping VM [$($vm.Name)]"
		Stop-AzVM -Name $vm.Name -ResourceGroupName $vmResourceGroup -Force
		
		# Remove the VM from the Availability Set
		Write-Output "Removing VM [$($vm.Name)]"
		Remove-AzVM -ResourceGroupName $vmResourceGroup -Name $vm.Name -Force
		if (Get-AzVM -Name $vm.Name) { Write-Error "Removing the VM [$($vm.Name)] failed"; Exit }

		# Convert the Disk to support Availability Zones
		# TODO : use different approach, this seems to not be working

		# Name of the Managed Disk you are starting with
		$sourceDiskName = $osDiskName
		Write-Verbose "Source Disk Name = $sourceDiskName"
		
		# Name of the resource group the source disk resides in
		$sourceRG = $vm.ResourceGroupName
		Write-Verbose "Source ResourceGroup Name = $sourceRG"

		# Name you want the destination disk to have
		$targetDiskName = "$osDiskName-zone"
		Write-Verbose "Target Disk Name = $targetDiskName"

		# Name of the resource group to create the destination disk in
		$targetRG = $vm.ResourceGroupName
		Write-Verbose "Target ResourceGroup Name = $targetRG"

		# Azure region the target disk will be in
		$targetLocate = $location
		Write-Verbose "Target Locatation = $targetLocate"

		Write-Verbose "Gather properties of the source disk [$sourceDiskName]"
		$sourceDisk = Get-AzDisk -ResourceGroupName $sourceRG -DiskName $sourceDiskName

		Write-Verbose "Create the target disk config with Sku [$diskSku], adding the sizeInBytes with the 512 offset, and the -Upload flag"
		Write-Verbose "If this is an OS disk, add this property: -OsType $sourceDisk.OsType"
		$targetDiskconfig = New-AzDiskConfig -SkuName $diskSku -UploadSizeInBytes $($sourceDisk.DiskSizeBytes+512) `
											 -Location $targetLocate -CreateOption 'Upload' -OsType $sourceDisk.OsType `
											 -Zone $zone

		Write-Verbose "Create the target disk (empty) [$targetDiskName]"
		$targetDisk = New-AzDisk -ResourceGroupName $targetRG -DiskName $targetDiskName -Disk $targetDiskconfig

		Write-Verbose "Get a SAS token for the source disk [$sourceDiskName], so that AzCopy can read it"
		$sourceDiskSas = Grant-AzDiskAccess -ResourceGroupName $sourceRG -DiskName $sourceDiskName -DurationInSecond 86400 -Access 'Read'

		Write-Verbose "Get a SAS token for the target disk [$targetDiskName], so that AzCopy can write to it"
		$targetDiskSas = Grant-AzDiskAccess -ResourceGroupName $targetRG -DiskName $targetDiskName -DurationInSecond 86400 -Access 'Write'
		
		Write-Output "Copy the Disk to be compatible with Availability Zones"
		Write-Verbose "Begin the copy [azcopy copy $($sourceDiskSas.AccessSAS) $($targetDiskSas.AccessSAS) --blob-type PageBlob]"
		azcopy copy $sourceDiskSas.AccessSAS $targetDiskSas.AccessSAS --blob-type PageBlob
		if ($lastexitcode -ne 0){ Write-Error "azcopy returned an error"; Exit }

		Write-Verbose "Revoke the SAS so that the disk [$sourceDiskName] can be used by a VM"
		Revoke-AzDiskAccess -ResourceGroupName $sourceRG -DiskName $sourceDiskName

		Write-Verbose "Revoke the SAS so that the disk [$targetDiskName] can be used by a VM"
		Revoke-AzDiskAccess -ResourceGroupName $targetRG -DiskName $targetDiskName

		if (-not $KeepSourceDisk){
			Write-Verbose "Removing source disk [$sourceDiskName] from resourcegroup [$sourceRG]"
			Remove-AzDisk -ResourceGroupName $sourceRG -DiskName $sourceDiskName -Force
		}
		else{
			Write-Verbose "KeepSourceDisk was set. Source disk [$sourceDiskName] will be kept"
		}


		
		# Setting up the VM on the Availability Zone

		Write-Output "Setup new VM configuration for VM [$vmname] with Size [$vmSize]"
		$virtualMachine = New-AzVMConfig -VMName $vmname -VMSize $vmSize

		Write-Verbose "Add NIC with ID [$nicId] to new VM configuration"
		$virtualMachine = Add-AzVMNetworkInterface -VM $virtualMachine -Id $nicId -Primary
		
		Write-Verbose "Configure disk [$($targetDisk.Id)] to new VM configuration"
		$virtualMachine = Set-AzVMOSDisk -VM $virtualMachine -ManagedDiskId $targetDisk.Id -StorageAccountType $diskSku `
			-DiskSizeInGB 128 -CreateOption Attach -Windows 
	
		if ($securityType){
			
			Write-Verbose "Configure Security Profile off new VM configuration"
			$virtualMachine = Set-AzVMSecurityProfile -VM $virtualMachine -SecurityType $securityType;
			$virtualMachine = Set-AzVMUefi -VM $virtualMachine -EnableVtpm $vtpm -EnableSecureBoot $secureboot;

		}

		if ($bootdiagEnabled){
			#TODO: get StorageAccountName from StorageUri
			$virtualMachine = Set-AzVMBootDiagnostic -VM $virtualMachine -Enable -StorageAccountName 
		}
		
		Write-Output "Create new VM [$vmname]"
		New-AzVM -ResourceGroupName $vmResourceGroup -Location $location -VM $virtualmachine -Zone $zone

		# Setting up the VM on the Availability Zone

		Write-Output "Setup new VM configuration for VM [$vmname] with Size [$vmSize]"
		$virtualMachine = New-AzVMConfig -VMName $vmname -VMSize $vmSize

		Write-Verbose "Add NIC with ID [$nicId] to new VM configuration"
		$virtualMachine = Add-AzVMNetworkInterface -VM $virtualMachine -Id $nicId -Primary
		
		Write-Verbose "Configure disk [$($targetDisk.Id)] to new VM configuration"
		$virtualMachine = Set-AzVMOSDisk -VM $virtualMachine -ManagedDiskId $targetDisk.Id -CreateOption Attach -Windows
	
		if ($securityType){
			
			Write-Verbose "Configure Security Profile off new VM configuration"
			$virtualMachine = Set-AzVMSecurityProfile -VM $virtualMachine -SecurityType $securityType;
			$virtualMachine = Set-AzVMUefi -VM $virtualMachine -EnableVtpm $vtpm -EnableSecureBoot $secureboot;

		}

		if ($bootdiagEnabled){
			#TODO: get StorageAccountName from StorageUri
			$virtualMachine = Set-AzVMBootDiagnostic -VM $virtualMachine -Enable -StorageAccountName 
		}
		
		Write-Output "Create new VM [$vmname]"
		New-AzVM -ResourceGroupName $vmResourceGroup -Location $location -VM $virtualmachine -Zone $zone 

	}
}