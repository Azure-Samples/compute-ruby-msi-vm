---
services: compute
platforms: ruby
author: vishrutshah
---

# Create Azure virtual machines with Managed Service Identity using Ruby
This sample demonstrates how to create your Azure virtual machines with Managed Service Identity using the Ruby SDK.

**On this page**

- [Run this sample](#run)
- [What is example.rb doing?](#example)
    - [Create a virtual network](#vnet)
    - [Create a public IP address](#ipaddress)
    - [Create a network interface](#nic)
    - [Create a virtual machine with system identity](#vm)
    - [Add MSI extension to the VM](#extension)
    - [Verify MSI extension is running on VM by logging-in via ssh](#msi-extension)
    - [Delete the resources](#delete)


<a id="run"></a>
## Run this sample

1. If you don't already have it, [install Ruby and the Ruby DevKit](https://www.ruby-lang.org/en/documentation/installation/).

2. If you don't have bundler, install it.

    ```
    gem install bundler
    ```
    
3. Clone the repository.

    ```
    git clone https://github.com/Azure-Samples/compute-ruby-msi-vm.git
    ```

4. Install the dependencies using bundle.

    ```
    cd compute-ruby-msi-vm
    bundle install
    ```
    
5. Create an Azure service principal either through

    [Azure CLI](https://azure.microsoft.com/documentation/articles/resource-group-authenticate-service-principal-cli/),
    [PowerShell](https://azure.microsoft.com/documentation/articles/resource-group-authenticate-service-principal/)
    or [the portal](https://azure.microsoft.com/documentation/articles/resource-group-create-service-principal-portal/).

6. Set the following environment variables using the information from the service principle that you created.

    ```
    export AZURE_TENANT_ID={your tenant id}
    export AZURE_CLIENT_ID={your client id}
    export AZURE_CLIENT_SECRET={your client secret}
    export AZURE_SUBSCRIPTION_ID={your subscription id}
    ```

    > [AZURE.NOTE] On Windows, use `set` instead of `export`.

7. Run the sample.

    ```
    bundle exec ruby example.rb
    ```

<a id="example"></a>
## What does example.rb doing?

This sample starts by setting up ResourceManagementClient, the resource provider clients, a resource group, and a storage account using your subscription and credentials.

```ruby
subscription_id = ENV['AZURE_SUBSCRIPTION_ID'] || '11111111-1111-1111-1111-111111111111' # your Azure Subscription Id
  provider = MsRestAzure::ApplicationTokenProvider.new(
      ENV['AZURE_TENANT_ID'],
      ENV['AZURE_CLIENT_ID'],
      ENV['AZURE_CLIENT_SECRET'])
  credentials = MsRest::TokenCredentials.new(provider)
  resource_client = Azure::ARM::Resources::ResourceManagementClient.new(credentials)
  resource_client.subscription_id = subscription_id
  network_client = Azure::ARM::Network::NetworkManagementClient.new(credentials)
  network_client.subscription_id = subscription_id
  storage_client = Azure::ARM::Storage::StorageManagementClient.new(credentials)
  storage_client.subscription_id = subscription_id
  compute_client = Azure::ARM::Compute::ComputeManagementClient.new(credentials)
  compute_client.subscription_id = subscription_id

  #
  # Managing resource groups
  #
  resource_group_params = Azure::ARM::Resources::Models::ResourceGroup.new.tap do |rg|
    rg.location = WEST_US
  end

  # Create Resource group
  puts 'Create Resource Group'
  print_group resource_client.resource_groups.create_or_update(GROUP_NAME, resource_group_params)

  postfix = rand(1000)
  storage_account_name = "rubystor#{postfix}"
  puts "Creating a premium storage account with encryption off named #{storage_account_name} in resource group #{GROUP_NAME}"
  storage_create_params = StorageModels::StorageAccountCreateParameters.new.tap do |account|
    account.location = WEST_US
    account.sku = StorageModels::Sku.new.tap do |sku|
      sku.name = StorageModels::SkuName::PremiumLRS
      sku.tier = StorageModels::SkuTier::Premium
    end
    account.kind = StorageModels::Kind::Storage
    account.encryption = StorageModels::Encryption.new.tap do |encrypt|
      encrypt.services = StorageModels::EncryptionServices.new.tap do |services|
        services.blob = StorageModels::EncryptionService.new.tap do |service|
          service.enabled = false
        end
      end
    end
  end
  print_item storage_account = storage_client.storage_accounts.create(GROUP_NAME, storage_account_name, storage_create_params)
```

<a id="vnet"></a>
### Create a virtual network
Now, we will create a virtual network and configure subnet for the virtual machine.

```ruby
puts 'Creating a virtual network for the VM'
vnet_create_params = NetworkModels::VirtualNetwork.new.tap do |vnet|
  vnet.location = WEST_US
  vnet.address_space = NetworkModels::AddressSpace.new.tap do |addr_space|
    addr_space.address_prefixes = ['10.0.0.0/16']
  end
  vnet.dhcp_options = NetworkModels::DhcpOptions.new.tap do |dhcp|
    dhcp.dns_servers = ['8.8.8.8']
  end
  vnet.subnets = [
      NetworkModels::Subnet.new.tap do |subnet|
        subnet.name = 'rubySampleSubnet'
        subnet.address_prefix = '10.0.0.0/24'
      end
  ]
end
print_item vnet = network_client.virtual_networks.create_or_update(GROUP_NAME, 'sample-ruby-vnet', vnet_create_params)
```

<a id="ipaddress"></a>
### Create a public IP address
Now, we will create a public IP address using dynamic IP allocation method for the Azure VM.

```ruby
puts 'Creating a public IP address for the VM'
public_ip_params = NetworkModels::PublicIPAddress.new.tap do |ip|
    ip.location = WEST_US
    ip.public_ipallocation_method = NetworkModels::IPAllocationMethod::Dynamic
    ip.dns_settings = NetworkModels::PublicIPAddressDnsSettings.new.tap do |dns|
        dns.domain_name_label = 'msi-vm-domain-name-label'
    end
end
print_item public_ip = network_client.public_ipaddresses.create_or_update(GROUP_NAME, 'sample-ruby-pubip', public_ip_params)
```

<a id="nic"></a>
### Create a network interface
Now, we will create a network interface and assign the public ip address created in previous step.
 
```ruby
print_item nic = network_client.network_interfaces.create_or_update(
    GROUP_NAME,
    "sample-ruby-nic-#{vm_name}",
    NetworkModels::NetworkInterface.new.tap do |interface|
        interface.location = WEST_US
        interface.ip_configurations = [
            NetworkModels::NetworkInterfaceIPConfiguration.new.tap do |nic_conf|
                nic_conf.name = "sample-ruby-nic-#{vm_name}"
                nic_conf.private_ipallocation_method = NetworkModels::IPAllocationMethod::Dynamic
                nic_conf.subnet = subnet
                nic_conf.public_ipaddress = public_ip
            end
        ]
    end
)
```

<a id="vm"></a>
### Create a virtual machine with system identity
Now, we will set virtual machine parameters like `OSProfile`, `StorageProfile`, `OSDisk`, `HardwareProfile` & `NetworkProfile` as usual. We will
also set the `VirtualMachineIdentity` to be `SystemAssigned` specifically for creating managed service identity VM and then create the virtual machine.

```ruby
puts 'Creating a Ubuntu 16.04.0-LTS Standard DS2 V2 virtual machine w/ a public IP'
vm_create_params = ComputeModels::VirtualMachine.new.tap do |vm|
  vm.location = location
  vm.os_profile = ComputeModels::OSProfile.new.tap do |os_profile|
    os_profile.computer_name = vm_name
    os_profile.admin_username = 'notAdmin'
    os_profile.admin_password = 'Pa$$w0rd92'
  end

  vm.storage_profile = ComputeModels::StorageProfile.new.tap do |store_profile|
    store_profile.image_reference = ComputeModels::ImageReference.new.tap do |ref|
      ref.publisher = 'canonical'
      ref.offer = 'UbuntuServer'
      ref.sku = '16.04.0-LTS'
      ref.version = 'latest'
    end
    store_profile.os_disk = ComputeModels::OSDisk.new.tap do |os_disk|
      os_disk.name = "sample-os-disk-#{vm_name}"
      os_disk.caching = ComputeModels::CachingTypes::None
      os_disk.create_option = ComputeModels::DiskCreateOptionTypes::FromImage
      os_disk.vhd = ComputeModels::VirtualHardDisk.new.tap do |vhd|
        vhd.uri = "https://#{storage_acct.name}.blob.core.windows.net/rubycontainer/#{vm_name}.vhd"
      end
    end
  end

  vm.hardware_profile = ComputeModels::HardwareProfile.new.tap do |hardware|
    hardware.vm_size = ComputeModels::VirtualMachineSizeTypes::StandardDS2V2
  end

  vm.network_profile = ComputeModels::NetworkProfile.new.tap do |net_profile|
    net_profile.network_interfaces = [
        ComputeModels::NetworkInterfaceReference.new.tap do |ref|
          ref.id = nic.id
          ref.primary = true
        end
    ]
  end

  # Use System Assigned Identity for the VM
  vm.identity = ComputeModels::VirtualMachineIdentity.new.tap do |identity|
    identity.type = ComputeModels::ResourceIdentityType::SystemAssigned
  end
end

ssh_pub_location = File.expand_path('~/.ssh/id_rsa.pub')
if File.exists? ssh_pub_location
  puts "Found SSH public key in #{ssh_pub_location}. Disabling password and enabling SSH authentication."
  key_data = File.read(ssh_pub_location)
  puts "Using public key: #{key_data}"
  vm_create_params.os_profile.linux_configuration = ComputeModels::LinuxConfiguration.new.tap do |linux|
    linux.disable_password_authentication = true
    linux.ssh = ComputeModels::SshConfiguration.new.tap do |ssh_config|
      ssh_config.public_keys = [
          ComputeModels::SshPublicKey.new.tap do |pub_key|
            pub_key.key_data = key_data
            pub_key.path = '/home/notAdmin/.ssh/authorized_keys'
          end
      ]
    end
  end
end

print_item vm = compute_client.virtual_machines.create_or_update(GROUP_NAME, "sample-ruby-vm-#{vm_name}", vm_create_params)
```

<a id="extension"></a>
### Add MSI extension to the VM
Now, we will add an VM extension `ManagedIdentityExtensionForLinux` for Azure VM and configure it to run on port `50342`.

```ruby
puts "Install Managed Service Identity Extension"
ext_name = 'msiextension'
vm_extension = ComputeModels::VirtualMachineExtension.new.tap do |extension|
  extension.publisher = 'Microsoft.ManagedIdentity'
  extension.virtual_machine_extension_type = 'ManagedIdentityExtensionForLinux'
  extension.type_handler_version = '1.0'
  extension.auto_upgrade_minor_version = true
  extension.settings = Hash.new.tap do |settings|
    settings['port'] = '50342'
  end
  extension.location = WEST_US
end

vm_ext = compute_client.virtual_machine_extensions.create_or_update(GROUP_NAME, "sample-ruby-vm-#{vm_name}", ext_name, vm_extension)
```

<a id="msi-extension"></a>
### Verify MSI extension is running on VM by logging-in via ssh
Once the Azure VM has been created, we will verify that MSI extension is running on this VM. Managed Service Identity extension will run on 
`localhost` and configured port, here `50342`. Follow example [here](https://github.com/Azure/azure-sdk-for-ruby/blob/master/runtime/ms_rest_azure/README.md#utilizing-msimanaged-service-identity-token-provider) to
find out the usage.

```
ssh -p 22 notAdmin@msi-vm-domain-name-label.westus.cloudapp.azure.com
```
```
notAdmin@msi-vm:~$ netstat -tlnp
(Not all processes could be identified, non-owned process info
 will not be shown, you would have to be root to see it all.)
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
tcp        0      0 127.0.0.1:50342         0.0.0.0:*               LISTEN      -               
...            

```
```
exit
```

<a id="delete"></a>
### Delete the resources
Now, we will delete all the resources create using this example. Please comment this out to keep the resources alive in you Azure subscription.

```ruby
resource_client.resource_groups.delete(GROUP_NAME)
```