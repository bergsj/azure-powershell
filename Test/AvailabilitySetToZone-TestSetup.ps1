$nameprefix = "testas2zone"

$rgname = "$nameprefix-rg-prod"
Remove-AzResourceGroup -Name $rgname -Force -ErrorAction SilentlyContinue
$rgname = "$nameprefix-rg-network"
Remove-AzResourceGroup -Name $rgname -Force -ErrorAction SilentlyContinue

$location = "westeurope"
$numberOfVMs = 2

$vmsize = "Standard_D2_v4"
$storageaccounttype = "Standard_LRS"
$ImagePublisher="MicrosoftWindowsServer"
$ImageOffer="WindowsServer"
$ImageVersion="2016-Datacenter-gensecond"

$secureVM = $true
if ($secureVM){
	$securityType = "TrustedLaunch"; #Must be Gen2; https://learn.microsoft.com/en-us/azure/virtual-machines/trusted-launch
	$secureboot = $true;
	$vtpm = $true;
}

$tag = @{
	environment  = "test"
	appowner = "sjoerd"
}

[string]$userName = 'myazureadmin'
[string]$userPassword = 'Testing123abc!'
[securestring]$secStringPassword = ConvertTo-SecureString $userPassword -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($userName, $secStringPassword); 

$vnetAddressPrefix = "10.40.0.0/20"
$subnetAddressPrefix =  "10.40.0.0/24"
$subnet2AddressPrefix =  "10.40.1.0/24"
$privateIPAddress = "10.40.0.4","10.40.0.5"
$privateIPAddress2 = "10.40.1.4","10.40.1.5"

$vnetname = "$nameprefix-vnet1"
$subnetname = "$nameprefix-subnet"
$subnet2name = "$nameprefix-subnet2"
$asname = "$nameprefix-availset"
$storageAccountName = "$($nameprefix)bootdiag"

$rgname = "$nameprefix-rg-network"
if (-not (Get-AzResourceGroup -Name $rgname -Location $location -ErrorAction SilentlyContinue)){
	New-AzResourceGroup -Name $rgname -Location $location -Tags $tag
}

$subnet  = New-AzVirtualNetworkSubnetConfig -Name $subnetname -AddressPrefix $subnetAddressPrefix
$subnet2  = New-AzVirtualNetworkSubnetConfig -Name $subnet2name -AddressPrefix $subnet2AddressPrefix
if (-not (Get-AzVirtualNetwork -ResourceGroupName $rgname -Name $vnetname -ErrorAction SilentlyContinue)){
	New-AzVirtualNetwork -ResourceGroupName $rgname -Name $vnetname -AddressPrefix $vnetAddressPrefix -Subnet $subnet,$subnet2 -Location $location -Tag $tag
}

$rgname = "$nameprefix-rg-prod"
if (-not (Get-AzResourceGroup -Name $rgname -Location $location -ErrorAction SilentlyContinue)){
	New-AzResourceGroup -Name $rgname -Location $location -Tags $tag
}

$as = Get-AzAvailabilitySet -ResourceGroupName $rgname -Name $asname -ErrorAction SilentlyContinue
if (-not ($as)){
	$as = New-AzAvailabilitySet -ResourceGroupName $rgname -Name $asname -Location $location -Sku Aligned -Tag $tag -PlatformFaultDomainCount 2 -PlatformUpdateDomainCount 5
}
New-AzStorageAccount -ResourceGroupName $rgname -Name $storageAccountName -SkuName Standard_LRS -Location $location

for ($i = 0; $i -lt $numberOfVMs; $i++){

	$vmName = "$nameprefix-vm$($i+1)"
	$osDiskName = "$vmname-osdisk"
	$nicName = "$vmname-nic"
	$nic2Name = "$vmname-nic2"
	$nsgname = "$vmname-nsg"
	$pipName = "$vmname-pip"
	$dataDiskName = "$vmname-datadisk"

	if (-not (Get-AzVM -Name $vmName -ErrorAction SilentlyContinue)){

		Write-Host "$vmName not found, creating..."

		$virtualMachine = New-AzVMConfig -VMName $vmname -VMSize $vmsize -AvailabilitySetId $as.Id
		$virtualMachine = Set-AzVMOperatingSystem -VM $virtualMachine -Windows -computerName $vmname -Credential $Credential
		$sku = (Get-AzVMImageSku -Location $location -Offer $ImageOffer -PublisherName $ImagePublisher | Where-Object Skus -eq $ImageVersion).Skus
		$virtualMachine = Set-AzVMSourceImage -VM $virtualMachine -PublisherName $ImagePublisher -Offer $ImageOffer -Skus $sku -Version "latest"
		
		$virtualMachine = Set-AzVMBootDiagnostic -VM $virtualMachine -Enable -StorageAccountName $storageAccountName -ResourceGroupName $rgname
		
		$subnet = Get-AzVirtualNetwork -Name $vnetname | Get-AzVirtualNetworkSubnetConfig -Name $subnetname
		$subnet2 = Get-AzVirtualNetwork -Name $vnetname | Get-AzVirtualNetworkSubnetConfig -Name $subnet2name

		$nsgRuleRDP = New-AzNetworkSecurityRuleConfig -Name RDP -Protocol Tcp -Direction Inbound -Priority 1001 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Access Allow
		$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $rgname -Name $nsgname -ErrorAction SilentlyContinue
		if (-not $nsg){
			$nsg = New-AzNetworkSecurityGroup -ResourceGroupName $rgname -Location $location -Name $nsgname -SecurityRules $nsgRuleRDP
		}

		$nic = Get-AzNetworkInterface -ResourceGroupName $rgname -Name $nicName -ErrorAction SilentlyContinue
		if (-not $nic){
			$pip = New-AzPublicIpAddress -Name $pipName -ResourceGroupName $rgname -Location $location -Sku Basic -AllocationMethod Static
			$nic = New-AzNetworkInterface 	-ResourceGroupName $rgname `
											-Location $location `
											-Name $nicName `
											-Subnet $subnet `
											-PrivateIpAddress $privateIPAddress[$i] `
											-NetworkSecurityGroup $nsg `
											-EnableAcceleratedNetworking `
											-Tag $tag `
											-PublicIpAddress $pip
		}
		$nic2 = Get-AzNetworkInterface -ResourceGroupName $rgname -Name $nic2Name -ErrorAction SilentlyContinue
		if (-not $nic2){
			$nic2 = New-AzNetworkInterface 	-ResourceGroupName $rgname `
											-Location $location `
											-Name $nic2Name `
											-Subnet $subnet2 `
											-PrivateIpAddress $privateIPAddress2[$i] `
											-NetworkSecurityGroup $nsg `
											-Tag $tag	
		}

		$virtualMachine = Add-AzVMNetworkInterface -VM $virtualMachine -Id $nic.Id -Primary
		$virtualMachine = Add-AzVMNetworkInterface -VM $virtualMachine -Id $nic2.Id

		$virtualMachine = Set-AzVMOSDisk -Name $osDiskName -DiskSizeInGB 127 -StorageAccountType $storageaccounttype -CreateOption "fromImage" -VM $virtualMachine

		$diskConfig = New-AzDiskConfig -SkuName $storageaccounttype -Location $location -CreateOption Empty -DiskSizeGB 127
		$dataDisk = Get-AzDisk -DiskName $dataDiskName -ErrorAction SilentlyContinue
		if (-not $dataDisk){
			$dataDisk = New-AzDisk -DiskName $dataDiskName -Disk $diskConfig -ResourceGroupName $rgname
		}
		$virtualMachine = Add-AzVMDataDisk -VM $virtualMachine -Name $dataDiskName -CreateOption Attach -ManagedDiskId $dataDisk.Id -Lun 1

		if ($secureVM){
			$virtualMachine = Set-AzVMSecurityProfile -VM $virtualMachine -SecurityType $securityType;
			$virtualMachine = Set-AzVMUefi -VM $virtualMachine -EnableVtpm $vtpm -EnableSecureBoot $secureboot;
		}

		New-AzVm `
			-ResourceGroupName $rgname `
			-VM $virtualMachine `
			-Location $location `
			-Tag $tag
	}
	
}

<#
$zonesRestricted = [array](3)
$compatibleZones = (1,2,3) | Where-Object {$_ -notin $zonesRestricted} | Sort-Object
$compatibleZones
$vms = "vm1","vm2"
$i = 1
foreach ($vmRef in $vms){

	$i
	$zone = $compatibleZones[($i % $compatibleZones.Count)-1]
	
	if ($i -eq $compatibleZones.Count){ $i = 1 }
	else{ $i++ }
	write-host "deploy $vmRef in zone $zone"
}
#>
