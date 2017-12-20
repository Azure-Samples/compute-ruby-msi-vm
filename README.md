---
services: compute
platforms: ruby
author: vishrutshah
---

# Create Azure virtual machines with Managed Service Identity using Ruby
This sample demonstrates how to create your Azure virtual machines with Managed Service Identity (MSI) using the Ruby SDK. This sample covers the two types of MSI scenarios:

 - System Assigned Identity: the identity is created by ARM on VM creation/update
 - User Assigned Identity: the identity is created and managed by the user, and assigned during VM creation/update

**On this page**

- [Run this sample](#run)
- [What is example.rb doing?](#example)
    - [Create a User Assigned Identity](#ua-msi)
    - [Create a virtual network](#vnet)
    - [Create a public IP address](#ipaddress)
    - [Create a network interface](#nic)
    - [Create a virtual machine with system or user assigned identity](#vm)
    - [Add MSI extension to the VM](#extension)
    - [Create role assignment for the VM](#role-assignment)
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

    [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/create-an-azure-service-principal-azure-cli?toc=%2Fazure%2Fazure-resource-manager%2Ftoc.json&view=azure-cli-latest),
    [PowerShell](https://azure.microsoft.com/documentation/articles/resource-group-authenticate-service-principal/)
    or [the portal](https://azure.microsoft.com/documentation/articles/resource-group-create-service-principal-portal/).

    :exclamation: NOTE :exclamation: Please make sure to create an role assignment with `Owner` role. In case of insufficient permissions, role
    assignment may fail for this sample.  

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

This sample starts by setting up ResourceManagementClient, the resource provider clients, a resource group, a storage account and a user assigned identity if desired, using your subscription and credentials.

```ruby
subscription_id = ENV['AZURE_SUBSCRIPTION_ID'] || '11111111-1111-1111-1111-111111111111' # your Azure Subscription Id
  options = {
      tenant_id: ENV['AZURE_TENANT_ID'],
      client_id: ENV['AZURE_CLIENT_ID'],
      client_secret: ENV['AZURE_CLIENT_SECRET'],
      subscription_id: subscription_id,
  }

  resource_client = Resources::Client.new(options)
  network_client = Network::Client.new(options)
  storage_client = Storage::Client.new(options)
  compute_client = Compute::Client.new(options)
  authorization_client = Authorization::Client.new(options)

  #
  # Managing resource groups
  #
  resource_group_params = resource_client.model_classes.resource_group.new.tap do |rg|
    rg.location = LOCATION
  end

  # Create Resource group
  puts 'Create Resource Group'
  print_group resource_client.resource_groups.create_or_update(GROUP_NAME, resource_group_params)

  # Create storage account
  postfix = rand(1000)
  storage_account_name = "rubystor#{postfix}"
  puts "Creating a premium storage account with encryption off named #{storage_account_name} in resource group #{GROUP_NAME}"
  storage_create_params = StorageModels::StorageAccountCreateParameters.new.tap do |account|
    account.location = LOCATION
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
  <a id="ua-msi"></a>
  ### Create a user assigned identity
  
```ruby
    msi_client = Msi::Client.new(options)
    identity_create_params = MsiModels::Identity.new.tap do |identity|
      identity.location = LOCATION
    end
    print_item user_assigned_identity = msi_client.user_assigned_identities.create_or_update(GROUP_NAME, "myMsiIdentity", identity_create_params)
  end
```

<a id="vnet"></a>
### Create a virtual network
Now, we will create a virtual network and configure subnet for the virtual machine.

```ruby
puts 'Creating a virtual network for the VM'
vnet_create_params = NetworkModels::VirtualNetwork.new.tap do |vnet|
  vnet.location = LOCATION
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
    ip.location = LOCATION
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
        interface.location = LOCATION
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
### Create a virtual machine with system or user assigned identity
Now, we will set virtual machine parameters like `OSProfile`, `StorageProfile`, `OSDisk`, `HardwareProfile` & `NetworkProfile` as usual. We will
also set the `VirtualMachineIdentity` to be `SystemAssigned`, `UserAssigned` or `SystemAssignedUserAssigned` for a creating managed service identity VM and then create the virtual machine.

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

  # Create User Assigned and/or System Assigned identity
    puts 'Create an identity'
    if USER_ASSIGNED_IDENTITY && SYSTEM_ASSIGNED_IDENTITY
      vm.identity = ComputeModels::VirtualMachineIdentity.new.tap do |identity|
        identity.type = ResourceIdentityType::SystemAssignedUserAssigned
        identity.identity_ids = [user_assigned_identity.id]
      end
    elsif USER_ASSIGNED_IDENTITY
      # Use User Assigned Identity for the VM
      vm.identity = ComputeModels::VirtualMachineIdentity.new.tap do |identity|
        identity.type = ResourceIdentityType::UserAssigned
        identity.identity_ids = [user_assigned_identity.id]
      end
    elsif SYSTEM_ASSIGNED_IDENTITY
      # Use System Assigned Identity for the VM
      vm.identity = ComputeModels::VirtualMachineIdentity.new.tap do |identity|
        identity.type = ResourceIdentityType::SystemAssigned
      end
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
  extension.location = LOCATION
end

vm_ext = compute_client.virtual_machine_extensions.create_or_update(GROUP_NAME, "sample-ruby-vm-#{vm_name}", ext_name, vm_extension)
```

<a id="role-assignment"></a>
### Create role assignment for the VM
Now, we will retrieve the default rbac role named as `Contributor`. To know more about the
default roles please visit [built-in-roles](https://docs.microsoft.com/en-us/azure/active-directory/role-based-access-built-in-roles).

```ruby
puts "Getting the Role ID of Contributor of a Resource group: #{GROUP_NAME}"
role_name = 'Contributor'
roles = authorization_client.role_definitions.list(resource_group.id, "roleName eq '#{role_name}'")
contributor_role = roles.first
```

Now, we will assign `Contributor` role at the resource group level to allow managing Azure resources inside
this resource group.

```ruby
msi_accounts_to_assign = []
if SYSTEM_ASSIGNED_IDENTITY
  msi_accounts_to_assign.push(vm.identity.principal_id)
end
if USER_ASSIGNED_IDENTITY
  msi_accounts_to_assign.push(user_assigned_identity.principal_id)
end

puts 'Creating the role assignment for the VM'
role_assignment_params = AuthorizationModels::RoleAssignmentCreateParameters.new.tap do |role_param|
  role_param.properties = AuthorizationModels::RoleAssignmentProperties.new.tap do |property|
    property.principal_id = msi_identity
    property.role_definition_id = contributor_role.id
  end
end
authorization_client.role_assignments.create(resource_group.id, SecureRandom.uuid, role_assignment_params)
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
Now, we will delete all the resources created using this example. Please comment this out to keep the resources alive in you Azure subscription.

```ruby
resource_client.resource_groups.delete(GROUP_NAME)
```