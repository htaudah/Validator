# Workspace ONE Prerequisite Validator
This is a validation tool for the Workspace ONE environment's prerequisites. Customize the prerequisite sheet included
in the repository to suit your environment, then run the validation tool to get an assessment of its readiness.

## Prepare the validation appliance
The validation tool relies on placeholder appliances being deployed at the same network locations as the actual Workspace ONE
components to be deployed. This validation appliance is provided as an OVA file under the project's
[releases](https://github.com/htaudah/Validator/releases). This section is only useful if you will be creating the
appliance from source.

Start by downloading the Core-current.iso file from [here](http://tinycorelinux.net/downloads.html) and creating a
virtual machine that boots into the ISO file. The first steps will need to be performed on the console of the virtual
machine itself.

> :warning: **Make sure to change the Virtual Device Node setting to IDE 0 for the Virtual Machine's hard disk, as
Tiny Core doesn't recognize SCSI hard drives.**

Hit **Enter** at the console to boot into Tiny Core, then execute the commands below at the shell prompt
to get ssh access. The last command will change the tc user's password to vmbox.

```
tce-load -wi openssh
sudo cp /usr/local/etc/ssh/sshd\_config.orig /usr/local/etc/ssh/sshd\_config
sudo /usr/local/etc/init.d/openssh start
mkdir ~/.ssh
echo "tc:vmbox" | sudo chpasswd
```

Now run the preparation bash script as shown below, replacing *APPLIANCE\_IP* with the IP address assigned
to the virtual machine. When prompted, enter the password **vmbox**.

```
./prepare\_appliance.sh APPLIANCE_IP
```

When appliance preparation is complete, the virtual machine will be shut down to prepare for OVF export. Disconnect
the TinyCore ISO so prevent the machine from booting into the ISO next time.

Before exporting the machine to OVF, you'll need to enable the vApp options that will be used to configure the
appliance during deployment. You can follow the guide
[here](https://docs.vmware.com/en/VMware-vSphere/7.0/com.vmware.vsphere.vm_admin.doc/GUID-33840994-E5D4-4746-AC7C-359411239FD3.html)
for information on how to create vApp options. When enabling the vApp Options for the virtual machine, select
**IPv4** for **IP protocol**, check **OVF environment** for the **IP allocation scheme**, and check **VMware Tools**
for the **OVF environment transport**.

The options utilized by the appliance are shown in the table below. Their meaning is self-explanatory. Be sure to
leave their values and default values blank.

| Key | Label | Category |
| ----------- | ----------- | --- |
| guestinfo.hostname | Hostname | Networking |
| guestinfo.ipaddress | IP Address | Networking |
| guestinfo.netmask | Netmask | Networking |
| guestinfo.gateway | Gateway | Networking |
| guestinfo.dns | DNS Server | Networking |

After the options are created, you can export the machine to OVF/OVA format from the vSphere console.

## Import the validation appliance
When importing a ready-made validation appliance from the releases page, you need only import the OVA file as a virtual machine
and convert the created machine to a template. The name of the template has special significance as the validation
script will assume a name of *TinyCore*. The template should have all vApp options left blank, as those are configured
during appliance deployment. If you will be deploying the appliances manually, do so before running the validation script
below.

## Running the validation script
When all the needed appliances have been deployed, or if using auto-prepare to deploy appliances automatically, you can start the
environment validation from any Windows machine running PowerShell v5 or lateror  non-Windows devices running PowerShell Core
(tested on Linux PowerShell v7; requires customization of the Posh-SSH module). The only prerequisites for the validation tool
are the Posh-SSH and ImportExcel modules, which can be installed using the following commands:

```
Install-Module Posh-SSH -Scope CurrentUser
Install-Module ImportExcel -Scope CurrentUser
```

If you wish to utilize PowerCLI functionality (optional), it is assumed that you have the PowerCLI module installed as well:
```
Install-Module VMware.PowerCLI -Scope CurrentUser
```

> :warning: **If installing PowerCLI on a Windows machine that has Hyper-V features enabled, it is possible that you will need
to also include the `AllowClobber` parameter in the installation command above. This will cause any PowerCLI commands to
override those provided by Hyper-V modules. This is both safe and reversible.**

The parameters might need to be customized to suit your environment. The best reference for determining the parameters to use
is the PowerShell script itself; run the command below to show information on each of the available parameters. The output
snippet shows information on the ProxyServer parameter.

```
Get-Help ./Validate-Prerequisites.ps1 -Full
    ...

    -ProxyServer <String>
        The URL (e.g. 'https://192.168.1.100:9090') of the Proxy server used by components to reach the internet
        
        Required?                    false
        Position?                    10
        Default value                
        Accept pipeline input?       false
        Accept wildcard characters?  false
    ...
```

The command below is typical for environments without a proxy server that leaves all defaults:
```
./Validate-Prerequisites.ps1 -VsphereCredentials $vsphere_creds -ClearOnExit
```
