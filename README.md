# Workspace ONE Prerequisite Validator
This is a validator for the Workspace ONE environment's prerequisites. Customize the prerequisite sheet included in the repository
to suit your environment, then run the validation tool to get an assessment of its readiness.

## Prepare the validation appliance
The validation tool relies on placeholder appliances being deployed at the same network locations as the actual Workspace ONE
components to be deployed. This validation appliance is not provided in the repository but can be created from the provided
source files. If you already have the ova appliance file available, you may skip the remainder of this section.

Start by downloading the Core-current.iso file from [here](http://tinycorelinux.net/downloads.html) and creating a
virtual machine that boots into the ISO file. The first steps will need to be performed on the console of the virtual
machine.

> :warning: **Make sure to change Virtual Device Node setting to IDE 0 for the Virtual Machine's hard disk, as
Tiny Core doesn't recognize the default SCSI device**

Hit **Enter** at the console to boot into Tiny Core, then execute the commands below at the shell prompt
to get ssh access. The last command will change the tc user's password to vmbox.

> tce-load -wi openssh
> sudo cp /usr/local/etc/ssh/sshd\_config.orig /usr/local/etc/ssh/sshd\_config
> sudo /usr/local/etc/init.d/openssh start
> mkdir ~/.ssh
> echo "tc:vmbox" | sudo chpasswd

Now run the preparation bash script as shown below, replacing \<APPLIANCE\_IP\> with the IP address assigned
to the virtual machine. When prompted, enter the password vmbox.

```
./prepare\_appliance.sh APPLIANCE\_IP
```

When appliance preparation is complete, the virtual machine will be shut down to prepare for OVF export.

Before exporting the machine to OVF, you'll need to enable the vApp options that will be used to configure the
appliance during deployment. You can follow the guide [here]() for information on how to create vApp options.
When enabling the vApp Options for the virtual machine, select **IPv4** for **IP protocol**, check **OVF environment**
for the **IP allocation scheme**, and check **VMware Tools** for the **OVF environment transport**.

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

## Running the validation script
When all the needed appliances have been deployed, you can start the environment validation from any Windows machine running
PowerShell v5 or later. In particular, the script can be run from non-Windows devices running PowerShell Core (tested on v7).
The only prerequisites for the validation tool are the Posh-SSH and ImportExcel modules, which can be installed
using the following commands:

```
Install-Module Posh-SSH -Scope CurrentUser
Install-Module ImportExcel -Scope CurrentUser
```

If you wish to utilize PowerCLI functionality (optional), it is assumed that you have the PowerCLI module installed as well:
```
Install-Module VMware.PowerCLI -Scope CurrentUser
```
