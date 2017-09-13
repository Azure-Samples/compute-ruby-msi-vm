#!/usr/bin/env ruby

require 'azure_mgmt_resources'
require 'azure_mgmt_network'
require 'azure_mgmt_storage'
require 'azure_mgmt_compute'
require 'azure_mgmt_authorization'

WEST_US = 'westus'
GROUP_NAME = 'azure-sample-compute-msi'

StorageModels = Azure::ARM::Storage::Models
NetworkModels = Azure::ARM::Network::Models
ComputeModels = Azure::ARM::Compute::Models
ResourceModels = Azure::ARM::Resources::Models
AuthorizationModels = Azure::ARM::Authorization::Models

# This sample shows how to create a Azure virtual machines with Managed Service Identity using the Azure Resource Manager APIs for Ruby.
#
# This script expects that the following environment vars are set:
#
# AZURE_TENANT_ID: with your Azure Active Directory tenant id or domain
# AZURE_CLIENT_ID: with your Azure Active Directory Application Client ID
# AZURE_CLIENT_SECRET: with your Azure Active Directory Application Secret
# AZURE_SUBSCRIPTION_ID: with your Azure Subscription Id
#
def run_example
  #
  # Create the Resource Manager Client with an Application (service principal) token provider
  #
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
  authorization_client = Azure::ARM::Authorization::AuthorizationManagementClient.new(credentials)
  authorization_client.subscription_id = subscription_id

  #
  # Managing resource groups
  #
  resource_group_params = Azure::ARM::Resources::Models::ResourceGroup.new.tap do |rg|
    rg.location = WEST_US
  end

  # Create Resource group
  puts 'Create Resource Group'
  print_group resource_group = resource_client.resource_groups.create_or_update(GROUP_NAME, resource_group_params)

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

  puts 'Creating a public IP address for the VM'
  public_ip_params = NetworkModels::PublicIPAddress.new.tap do |ip|
    ip.location = WEST_US
    ip.public_ipallocation_method = NetworkModels::IPAllocationMethod::Dynamic
    ip.dns_settings = NetworkModels::PublicIPAddressDnsSettings.new.tap do |dns|
      dns.domain_name_label = 'msi-vm-domain-name-label'
    end
  end
  print_item public_ip = network_client.public_ipaddresses.create_or_update(GROUP_NAME, 'sample-ruby-pubip', public_ip_params)

  vm = create_vm(compute_client, network_client, WEST_US, 'msi-vm', storage_account, vnet.subnets[0], public_ip)

  puts "Getting the Role ID of Contributor of a Resource group: #{GROUP_NAME}"
  role_name = 'Contributor'
  roles = authorization_client.role_definitions.list(resource_group.id, "roleName eq '#{role_name}'")
  contributor_role = roles.first
  puts contributor_role

  puts 'Creating the role assignment for the VM'
  role_assignment_params = AuthorizationModels::RoleAssignmentCreateParameters.new.tap do |role_param|
    role_param.properties = AuthorizationModels::RoleAssignmentProperties.new.tap do |property|
      property.principal_id = vm.identity.principal_id
      property.role_definition_id = contributor_role.id
    end
  end
  authorization_client.role_assignments.create(resource_group.id, SecureRandom.uuid, role_assignment_params)

  puts 'Listing all of the resources within the group'
  resource_client.resources.list_by_resource_group(GROUP_NAME).each do |res|
    print_item res
  end
  puts ''

  export_template(resource_client)

  puts "Thank you for creating managed service identity Azure VM."
  puts "Use `netstat -tlnp` command verify that MSI service is running at 127.0.0.1:50342 address."
  puts "Connect to your new virtual machine via: 'ssh -p 22 #{vm.os_profile.admin_username}@#{public_ip.dns_settings.fqdn}'. Admin Password is: Pa$$w0rd92"

  puts 'Press any key to continue and delete the sample resources'
  gets

  # Delete Resource group and everything in it
  puts 'Delete Resource Group'
  resource_client.resource_groups.delete(GROUP_NAME)
  puts "\nDeleted: #{GROUP_NAME}"

end

def print_group(resource)
  puts "\tname: #{resource.name}"
  puts "\tid: #{resource.id}"
  puts "\tlocation: #{resource.location}"
  puts "\ttags: #{resource.tags}"
  puts "\tproperties:"
  print_item(resource.properties)
end

def print_item(resource)
  resource.instance_variables.sort.each do |ivar|
    str = ivar.to_s.gsub /^@/, ''
    if resource.respond_to? str.to_sym
      puts "\t\t#{str}: #{resource.send(str.to_sym)}"
    end
  end
  puts "\n\n"
end

def export_template(resource_client)
  puts "Exporting the resource group template for #{GROUP_NAME}"
  export_result = resource_client.resource_groups.export_template(
      GROUP_NAME,
      ResourceModels::ExportTemplateRequest.new.tap{ |req| req.resources = ['*'] }
  )
  puts export_result.template
  puts ''
end

# Create a Virtual Machine, Install MSI extension and return it
def create_vm(compute_client, network_client, location, vm_name, storage_acct, subnet, public_ip)
  puts "Creating a network interface for the VM #{vm_name}"
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

  compute_client.virtual_machine_extensions.create_or_update(GROUP_NAME, "sample-ruby-vm-#{vm_name}", ext_name, vm_extension)

  compute_client.virtual_machines.get(GROUP_NAME, "sample-ruby-vm-#{vm_name}")
end

if $0 == __FILE__
  run_example
end
