<#
.SYNOPSIS
Ensures that environment of the machine running the script is ready for a Workspace ONE deployment.
.DESCRIPTION
The Validate-Prerequisites script runs a series of tests for all network requirements listed in the Workspace
ONE prerequisite sheet.
.PARAMETER VsphereCredentials
The PSCredential used to connect to VSphere (ESXi or VCenter) for running PowerCLI commands
.PARAMETER SSH_USERNAME
The username used to connect to the validation appliances through SSH
.PARAMETER SSH_PASSWORD
The password used to connect to the validation appliances through SSH
.PARAMETER SheetPath
The full path of the prerequisite excel sheet
.PARAMETER SelfSignedThumbprint
The thumbprint of the SSL certificate embedded into the validation appliances
.PARAMETER ConnectionTimeout
The number of seconds to wait for a connection to be established when testing for connectivity
between components.
#>
param(
    [string]$SSH_USERNAME="root",
    [string]$SSH_PASSWORD="vmbox",
    [string]$SheetPath=".\Pre-Install_Requirements.xlsx",
    # Set this to an empty string to open the result as an unsaved temp file
    [string]$OutputPath="",
    [string]$SelfSignedThumbprint="D6:7D:11:B0:97:B9:86:48:CB:16:9B:4F:2E:40:EE:1F:59:C7:4C:0B",
    [string]$VsphereFQDN="vsphere.haramco.xyz",
    [int]$ConnectionTimeout=5,
    [PSCredential]$VsphereCredentials,
    [switch]$ClearOnExit=$false,
    [int]$ConnectionAttempts=4
)

$SECURE_SSH_PASSWORD = ConvertTo-SecureString -String $SSH_PASSWORD -AsPlainText -Force

# These constants are references to column/section headers; all references in the script should be to these variables
# and not to the Excel string values (which are apt to change)
$C_ENVIRONMENT_HEADER = 'Environment'
$C_COMPONENTS_HEADER = 'Final Workspace ONE Components'
$C_ACCOUNTS_HEADER = 'Service Accounts'
$C_REQUIRED = 'Required'
$C_COMPONENTS = 'Components'
$C_SOURCE_COMPONENT = 'Source Component'
$C_DESTINATION_COMPONENT = 'Destination Component'
$C_HOSTNAMES = 'Server Hostname(s)'
$C_SERVER_IPS = 'Server IP(s)'
$C_DNS_RECORD = 'DNS (VIP) Record'
$C_DNS_IP = 'IP of DNS (VIP) Record'
$C_SSL_HANDLING = 'SSL Handling'
$C_RESOURCES_HEADER = 'Internal Resources'
$C_SERVER_SHEET = 'Servers & Environment'
$C_NETWORK_REQUIREMENTS = 'Network Requirements'
$C_ADDITIONAL_COMPONENTS = 'Additional Components'
$C_PRESENT = 'Present'
$C_PORTS = 'Port(s)'
$C_DESTINATION_COMPONENT = 'Destination Component'
$C_DEVICES = 'Devices on Internet or Wi-Fi'
$C_BROWSER = 'Browser'
$C_BROWSER_ADMIN = 'Browser (for admin access)'
$C_APPLIANCE_AUTO_PREPARATION = 'Appliance Auto-Preparation'
$C_VCENTER_SERVER = 'vCenter FQDN'
$C_QUESTIONNAIRE = 'Questionnaire'
$C_COMPUTE_NODE = 'Compute Node'
$C_GATEWAY_IP = 'Gateway IP Address'
$C_SUBNET_MASK = 'Subnet Mask'
$C_QUESTION = 'Question'
$C_ANSWER = 'Answer'
$C_AUTO_PREPARE = 'Appliance Auto-Preparation'
$C_VM_NETWORK = 'VM Network'
$C_DATASTORE = 'Datastore'
$C_DNS_SERVER = 'DNS Server'
$C_SSL_PASSTHROUGH = 'Passthrough'
$C_SSL_BRIDGING = 'Bridging'
$C_SSL_OFFLOADING = 'Offloading'
$C_NA = 'N/A'

# For compatibility reasons, check if running under PowerShell Core
if (Get-Command Test-NetConnection -ErrorAction Ignore)
{
    $powershell_core = $False
}
else
{
    $powershell_core = $True
}

# This is a list of URLs with wildcards or other special characters that need to be converted into actual
# URLs for testing. These are only used when for URLs for which the default method of swapping the *
# with www does not result in a valid URL.
$wildcard_urls = @{
    "\*.ggpht.com" = "gp5.ggpht.com"
    "\*.gvt1.com" = "redirector.gvt1.com"
    "\*.gvt2.com" = "beacons.gvt2.com"
    "\*.gvt3.com" = "beacons5.gvt3.com"
    "\*.notify.live.net" = "sn.notify.live.net"
    "\*.phobos.apple.com.edgesuite.net" = "ax.phobos.apple.com.edgesuite.net"
    "\*.phobos.apple.com" = "a1865.phobos.apple.com"
    "\*.googleapis.com" = "gcm.googleapis.com"
}

# Questionnaire answers that are relevant to the script
$auto_prepare = $null

# This table will be used to store the results of all prereq checks for the final report
# The table is represented as follows:
$prereq_table = @{
    # Connectivity is represented as a matrix from each source to each destination as follows:
    # [ [source, destination, port, protocol, bypass_vip, pass/fail],
    #   [source, destination, port, protocol, bypass_vip, pass/fail],
    #   [source, destination, port, protocol, bypass_vip, pass/fail] ]
    CONNECTIVITY = @()
    # DNS Records are represented by a hashtable from the required name to the pass/fail result
    DNSRECORDS = @{}
    # Load balancing prereqs are represented by a hashtable from the VIP to the pass/fail result
    LOADBALANCING = @{}
}

# Get workbook information
$excel_pkg = Open-ExcelPackage -Path $SheetPath
if ($excel_pkg -eq $null)
{
    exit 1
}
$worksheets = $excel_pkg.Workbook.Worksheets | ForEach-Object {$_.Name}


# This hashtable contains all relevant components in the Workspace ONE architecture
# It is pre-loaded with some pseudo-components that are not associated with any particular
# physical device (e.g. 'Devices on Wi-Fi or Internet')
$components = @{}
# These are the components that are actually represented by the machine running the test.
$local_components = @($C_DEVICES, $C_BROWSER_ADMIN)
foreach ($local_component in $local_components)
{
    $components[$local_component] = [PSCustomObject]@{
        IPs = 'localhost'
    }
}

# These are the resources that are present in the Internal Resources section
$resources = @{}

function Write-Failure($message)
{
    Write-Host -ForegroundColor Red $message
}
function Write-Success($message)
{
    Write-Host -ForegroundColor Green $message
}
function Write-Log($message)
{
    Write-Host -ForegroundColor Yellow $message
}
# TODO: is this regex good enough?
function is_url($url)
{
    return ($url -match "^(\*\.)?([a-zA-Z\d\-]+\.)*[a-zA-Z\d\-]+$")
}
function is_ip($ip_address)
{
    return ($ip_address -match "\b\d{1,3}\.d{1,3}\.d{1,3}\.\d{1,3}\b")
}

# This SSH pool is used to avoid multiple costly SSH connections to the same host
$ssh_session_pool = @{}
# Helper function to either initiate an SSH session to the specified host, or fetch one from the SSH pool
# if one already exists for this host
function Get-PoolSSHSession
{
    param(
        [string]$Destination,
        [PSCredential]$Credential
    )
    if (-Not $ssh_session_pool.ContainsKey($Destination) -or $ssh_session_pool[$Destination] -eq $null)
    {
        $ssh_session_pool[$Destination] = New-SSHSession -ComputerName $Destination -Force -Credential $Credential `
            -ErrorAction Stop -WarningAction SilentlyContinue
    }
    return $ssh_session_pool[$Destination]
}
function Remove-SSHPool
{
    foreach ($key in $ssh_session_pool.Keys)
    {
        $session = $ssh_session_pool[$key]
        if ($session -ne $null)
        {
            Remove-SSHSession $session | Out-Null
        }
    }
}

# Parses all component information from the Server tab. This function assumes the sections are laid out in the
# order (Deployment, Environment, Resources, Final WS1 Components)
function Parse-PrereqComponents
{
    # Find correct ranges for all the information
    $cells = $excel_pkg.$C_SERVER_SHEET.Cells
    
    # Section limits are determined by looking for section headers on column B
    $components_index = -1
    $resources_index = -1
    $accounts_index = -1
    $questionnaire_index = -1
    # the environment index is only needed for the Auto-Prepare fields
    $environment_index = -1
    for ($i = 0; $i -lt 1000; $i += 1)
    {
        $cell_index = "B" + $i
        $cell = $cells[$cell_index]

        if ($cell.Text -eq $C_ENVIRONMENT_HEADER)
        {
            $environment_index = $i + 1
        }
        elseif ($cell.Text -eq $C_COMPONENTS_HEADER)
        {
            $components_index = $i + 1
        }
        elseif ($cell.Text -eq $C_RESOURCES_HEADER)
        {
            $resources_index = $i + 1
        }
        elseif ($cell.Text -eq $C_ACCOUNTS_HEADER)
        {
            $accounts_index = $i + 1
        }
        elseif ($cell.Text -eq $C_QUESTIONNAIRE)
        {
            $questionnaire_index = $i + 1
        }
        # if started reading the questionnaire, parsing stops at the first blank cell
        elseif ($questionnaire_index -gt 0)
        {
            if ($cell.Text.Length -eq 0)
            {
                $questionnaire_index_end = $i
            }
        }

        if ($questionnaire_index_end -gt 0)
        {
            # questionnaire section should be the last one
            break
        }
    }

    # First read the questionnaire answers
    $data = Import-Excel -Path $SheetPath -WorkSheetname $C_SERVER_SHEET -StartRow $questionnaire_index -EndRow $questionnaire_index_end

    foreach ($datarow in $data)
    {
        if ($datarow.$C_QUESTION -eq $C_AUTO_PREPARE)
        {
            $auto_prepare = $datarow.$C_ANSWER
        }
    }

    # Now read the components
    $data = Import-Excel -Path $SheetPath -WorkSheetname $C_SERVER_SHEET -StartRow $components_index -EndRow ($accounts_index - 3)

    $i = 0
    foreach ($datarow in $data)
    {
        $component_name = $datarow.$C_COMPONENTS
        # There is no longer a Required column since we're using the Final Components table. Instead, we skip components
        # that have neither a hostname nor a DNS entry
        if ($datarow.$C_HOSTNAMES -eq "N/A" -and $datarow.$C_DNS_RECORD -eq "N/A")
        {
            continue
        }
        # Check if DNS record exists for host
        $name_lines = $datarow.$C_HOSTNAMES.Split("`n")
        $server_ip_lines = $datarow.$C_SERVER_IPS.Split("`n")
        if ($name_lines.Count -ne $server_ip_lines.Count)
        {
            Write-Failure $("Parse error for component $($component_name): There was a mismatch in the number of Server"`
                + "IPs and Hostnames ($($server_ip_lines.Count) Server IP lines; $($name_lines.Count) Hostname lines)")
        }
        # Not all components have a VIP
        if ($datarow.$C_DNS_RECORD -ne $null)
        {
            $vip_lines = $datarow.$C_DNS_RECORD.Split("`n")
            $vip_ip_lines = $datarow.$C_DNS_IP.Split("`n")
        }
        if ($vip_lines.Count -gt 1)
        {
            Write-Failure "Parse error for component $($component_name): More than one DNS record listed"
        }
        if ($vip_ip_lines.Count -gt 1)
        {
            Write-Failure "Parse error for component $($component_name): More than one DNS IP listed"
        }
        # if a component has the same DNS record as a previous component, it is simply an alias to that component
        if ($vip_lines -ne $null)
        {
            foreach ($old_component_name in $components.Keys)
            {
                $old_component = $components[$old_component_name]
                if ($vip_lines[0].Trim() -eq $component.DNSRecord)
                {
                    $components[$component_name] = $old_component
                }
            }
        }

        $components[$component_name] = [PSCustomObject]@{
            DNSRecord = if ($vip_lines -ne $null) {$vip_lines[0].Trim()} else {$null}
            DNSIP = if ($vip_ip_lines -ne $null) {$vip_ip_lines[0].Trim()} else {$null}
            Hostnames = @($name_lines | ForEach-Object {$_.Trim()})
            IPs = @($server_ip_lines | ForEach-Object {$_.Trim()})
            SSLHandling = $datarow.$C_SSL_HANDLING
            ### Remaining fields only needed if using auto-prepare
            ComputeNodes = $null
            GatewayIPs = $null
            SubnetMasks = $null
            VMNetworks = $null
            Datastores = $null
        }

        $i+=1
    }

    # Now read the environments section if using auto-prepare
    if ($auto_prepare)
    {
        $data = Import-Excel -Path $SheetPath -WorkSheetname $C_SERVER_SHEET -StartRow $environment_index -EndRow ($resources_index - 3)
        foreach ($datarow in $data)
        {
            $component = $components[$datarow.$C_COMPONENTS]
            # We only care about components that were seen in the resources table
            # We also don't care about alias components (a single validation appliance will suffice)
            if ($component -eq $null -or $component.$C_HOSTNAMES -eq "N/A" -or $datarow.$C_REQUIRED -match "Same as")
            {
                continue
            }
            $component_name = $datarow.$C_COMPONENTS
            # If using auto-create, check if additional columns have been included
            $required_params = @($C_COMPUTE_NODE, $C_GATEWAY_IP, $C_SUBNET_MASK, $C_VM_NETWORK, $C_DATASTORE)
            foreach ($required_param in $required_params)
            {
                if ($datarow.$required_param -eq $null)
                {
                    Write-Failure $("Parse error for component $($component_name): $C_AUTO_PREPARE was selected but no "`
                        + "value for `"$required_param`" was provided")
                    exit 1
                }
            }
            $subnets = $datarow.$C_SUBNET_MASK.Split("`n")
            $gateway_ips = $datarow.$C_GATEWAY_IP.Split("`n")
            $compute_nodes = $datarow.$C_COMPUTE_NODE.Split("`n")
            $vm_networks = $datarow.$C_VM_NETWORK.Split("`n")
            $datastores = $datarow.$C_DATASTORE.Split("`n")

            if ($subnets.Count -ne $component.Hostnames.Count)
            {
                Write-Failure $("Parse error for component $($component_name): There was a mismatch in the number of Hostname"`
                    + "and $C_SUBNET_MASK lines ($($subnets.Count) $C_SUBNET_MASK lines; $($component.Hostnames.Count) Hostname lines)")
            }
            if ($compute_nodes.Count -ne $component.Hostnames.Count)
            {
                Write-Failure $("Parse error for component $($component_name): There was a mismatch in the number of Hostname"`
                    + "and $C_COMPUTE_NODE lines ($($compute_nodes.Count) $C_COMPUTE_NODE lines; $($component.Hostnames.Count) Hostname lines)")
            }
            if ($gateway_ips.Count -ne $component.Hostnames.Count)
            {
                Write-Failure $("Parse error for component $($component_name): There was a mismatch in the number of Hostname"`
                    + "and $C_GATEWAY_IP lines ($($gateway_ips.Count) $C_GATEWAY_IP lines; $($component.Hostnames.Count) Hostname lines)")
            }
            $component.ComputeNodes = $compute_nodes
            $component.GatewayIPs = $gateway_ips
            $component.SubnetMasks = $subnets
            $component.VMNetworks = $vm_networks
            $component.Datastores = $datastores
        }
    }
        

    # Now read the resources section
    $data = Import-Excel -Path $SheetPath -WorkSheetname $C_SERVER_SHEET -StartRow $resources_index -EndRow ($components_index - 3)

    $i = 0
    foreach ($datarow in $data)
    {
        if ($datarow.$C_PRESENT -ne 'Yes')
        {
            continue
        }

        $resource_name = $datarow.$C_COMPONENTS

        $name_lines = $datarow.$C_HOSTNAMES.Split("`n")
        $server_ip_lines = $datarow.$C_SERVER_IPS.Split("`n")
        # TODO: for now only the DNS server can have multiple hostnames
        if ($name_lines.Count -ne 1 -and $resource_name -ne $C_DNS_SERVER)
        {
            Write-Error "Parse error for resource $($resource_name): expected one Hostname line"
        }
        if ($vip_ip_lines.Count -ne 1 -and $resource_name -ne $C_DNS_SERVER)
        {
            Write-Error "Parse error for resource $($resource_name): expected one Server IP line"
        }

        $resources[$resource_name] = [PSCustomObject]@{
            Hostnames = $name_lines
            IPs = $server_ip_lines
        }
    }
}

# Goes through all worksheets after the first one looking for 'Network Requirements' sections
function Parse-ConnectivityPrereqs
{
    foreach ($worksheet in $worksheets)
    {
        #TODO: remove this when done testing
        #if ($worksheet -ne 'DS-AWCM-API (On-Premises)') {continue}
        #if ($worksheet -ne 'Access (On-Premises)') {continue}
        #if ($worksheet -ne 'Tunnel & Content Gateway') {continue}
        
        Write-Log "Parsing sheet `"$worksheet`" for network rules"
        
        # Find correct ranges for all the information
        $cells = $excel_pkg.$worksheet.Cells
    
        # Section limits are determined by looking for section headers on column B
        $network_index = -1
        for ($i = 0; $i -lt 200; $i += 1)
        {
            $cell_index = "B" + $i
            $cell = $cells[$cell_index]

            # Still searching for starting index
            if ($network_index -eq -1)
            {
                if ($cell.Text -eq $C_NETWORK_REQUIREMENTS)
                {
                    $network_index = $i + 2
                }
            }
            # Searching for ending index
            else
            {
                # the section ends with the first empty cell in column B that comes after the start index
                if ($i -gt $network_index -and $cell.Text.Length -eq 0)
                {
                    $network_index_end = $i - 1
                    break
                }
            }
        }

        if ($network_index -gt 0)
        {
            # Import at the proper starting row
            $real_data = Import-Excel -Path $SheetPath -WorksheetName $worksheet -StartRow $network_index -EndRow $network_index_end
            # Now we can cycle through the actual network-related rows
            foreach ($line in $real_data)
            {
                # Ignore any rows with status not set to "Pending"
                if ($line.Status -ne "Pending")
                {
                    continue
                }
                # Just get the component names, and rely on the information imported from the first worksheet
                # This is why the names need to match!
                $source = $components[$line.$C_SOURCE_COMPONENT]
                if ($source -eq $null)
                {
                    # TODO: are there ever source pseudo-components?
                    # TODO: are there ever source resources?
                }
                else
                {
                    # No longer storing component in prereq_table, but relying on standard names everywhere
                    $source = "COMPONENT:$($line.$C_SOURCE_COMPONENT)"
                }
                # NOTE: Unlike the destination, the source can never be an IP address; it will always relate to a component

                # Destinations with (Servers) appended must reference the destination servers instead of the VIP
                $bypass_vip = $false
                $destination = $components[$line.$C_DESTINATION_COMPONENT]
                if ($destination -eq $null -and $line.$C_DESTINATION_COMPONENT -cmatch '(Servers)$')
                {
                    $len = $line.$C_DESTINATION_COMPONENT.Length
                    # Remove " (Servers)" to get the real component name
                    $trimmed = $line.$C_DESTINATION_COMPONENT.Substring(0, $len - 10)
                    $destination = $components[$trimmed]
                    if ($destination -ne $null)
                    {
                        $bypass_vip = $true
                    }
                }
                # If destination is still $null, it might be a resource (see Worksheet to understand disctinction)
                if ($destination -eq $null)
                {
                    $destination = $resources[$line.$C_DESTINATION_COMPONENT]
                    if ($destination -ne $null)
                    {
                        $destination = "RESOURCE:$($line.$C_DESTINATION_COMPONENT)"
                    }
                }

                # Connectivity tests will differ depending on whether the destination is a component, or just an IP address
                # Whatever it is, though, it gets stored in $destination
                if ($destination -eq $null)
                {
                    $destination = @()
                    $line.$C_DESTINATION_COMPONENT.Split("`n") | ForEach-Object { if (is_url($_.Trim())) {$destination += $_} }
                }
                elseif ($destination -notmatch "^RESOURCE:")
                {
                    # again, we're no longer storing the full components in the prereq_table
                    $destination = "COMPONENT:$($line.$C_DESTINATION_COMPONENT)"
                }
                # there will be a connection entry for each port/protocol. Be sure to include separate ports/protocols
                # on separate lines. The number of protocol and port lines must always match
                # NOTE: for port ranges above 5 ports, a random port will be selected from the range
                if ($line.Port.GetType() -eq [Double])
                {
                    $ports = @($line.Port)
                }
                else
                {
                    $ports = $line.Port.Split("`n")
                }
                $protocols = $line.Protocol.Split("`n")
                $individual_ports = @()
                $individual_protocols = @()
                # There should now not be any case of unequal Port/Protcol line numbers
                if ($ports.Length -ne $protocols.Length)
                {
                    Write-Error "Parse error for connection between $source and $($destination): The number of port and protocol "`
                        + "lines do not match. This row will be skipped."
                    continue
                }
                # Entries with commas are split out into individual port numbers
                $i = 0
                $comma_ports = @()
                $comma_protocols = @()
                for ($i = 0; $i -lt $ports.Length; $i += 1)
                {
                    # Skip doubles
                    if ($ports[$i].GetType()  -eq [Double])
                    {
                        continue
                    }
                    $comma_entries = @($ports[$i].Split(",").Trim())
                    $comma_entries | ForEach-Object { $comma_ports += $_ }
                    $comma_protocols += (1..$comma_entries.Length) | ForEach-Object { $protocols[$i] }
                }
                if ($comma_ports.Length -gt 0)
                {
                    $ports = $comma_ports
                    $protocols = $comma_protocols
                } 
                # If it's a range, split it out further
                $i = 0
                for ($i = 0; $i -lt $ports.Length; $i += 1)
                {
                    $port = $ports[$i]
                    if ($port -match "-")
                    {
                        $sub_ports = ($port.Split("-")[0]..$port.Split("-")[1])
                    }
                    else
                    {
                        $individual_ports += $port
                        $individual_protocols += $protocols[$i]
                        continue
                    }
                    if ($sub_ports.Length -gt 5)
                    {
                        $individual_ports += $sub_ports[(Get-Random -Minimum 0 -Maximum $sub_ports.Length)]
                        $individual_protocols += $individual_protocols[$i]
                    }
                    else
                    {
                        $individual_ports += $sub_ports
                        # it will be the same protocol for each port
                        $individual_protocols += (1..$sub_ports.Length) | ForEach-Object { $protocols[$i] }
                    }
                }

                # Now fill in the necessary entries in the prereq table
                # See comments in prereq table to understand how this is being filled in
                if ($destination -is [array])
                {
                    foreach ($destination_ip in $destination)
                    {
                        for ($i = 0; $i -lt $individual_ports.Length; $i += 1)
                        {
                            $connection = @($source, $destination_ip, $individual_ports[$i], $individual_protocols[$i], $bypass_vip, '')
                            $prereq_table.CONNECTIVITY += ,$connection
                        }
                    }
                }
                elseif ($destination -ne $null)
                {
                    for ($i = 0; $i -lt $individual_ports.Length; $i += 1)
                    {
                        $connection = @($source, $destination, $individual_ports[$i], $individual_protocols[$i], $bypass_vip, '')
                        $prereq_table.CONNECTIVITY += ,$connection
                    }
                }
            }
        }
        # if not found, then this sheet has no info pertaining to connectivity requirements
    }
}

# Goes through all expected DNS records and checks for their existence
function Check-DNSPrereqs
{
    foreach ($component_name in $components.Keys)
    {
        $component = $components[$component_name]

        $vip_ip = $component.DNSIP
        # Not all components have VIPs
        if ($vip_ip -ne $null)
        {
            $vip_name = $component.DNSRecord
            Check-DNSRecord $vip_name $vip_ip $component_name
        }

        # For the database component, the hostname can be ignored
        if ($component_name -match "DB Server \(SQL\)")
        {
            continue
        }
        $server_hostnames = $component.Hostnames
        $server_ips = $component.IPs
        for ($i = 0; $i -lt $server_hostnames.Length; $i+=1)
        {
            Check-DNSRecord $server_hostnames[$i] $server_ips[$i] $component_name
        }
    }
}

# Helper function to check for existence of single record (called from above function)
function Check-DNSRecord([string]$record_name, [string]$record_ip, [string]$component_name)
{
    # Resolve-DnsName is not cross-platform
    if (Get-Command Resolve-DnsName -ErrorAction Ignore)
    {
        $ip = (Resolve-DnsName $record_name -ErrorAction Ignore).IPAddress
    }
    else
    {
        try
        {
            $ip = [System.Net.Dns]::GetHostEntry($record_name)[0].AddressList.IPAddressToString
        }
        catch
        {
            # $ip will remain $null
        }
    }
    if ($ip -eq $null)
    {
        $result = "FAILED: The DNS Record for `'$component_name`' has not been created. "`
            + "Expected record for $record_name pointing to $record_ip but name could not be resolved."
    }
    elseif ($ip -ne $record_ip)
    {
        $result = "FAILED: The DNS Record for `'$component_name`' is incorrectly configured. "`
            + "Expected record for $record_name to resolve to $record_ip but resolved to $ip instead."
    }
    else
    {
        $result = "PASSED"
    }

    $prereq_table['DNSRECORDS'][$record_name] = $result
}

function Check-InstalledFeatures([string]$server_ip, [string[]]$feature_names)
{
    $cred = Get-Credential
    $session = New-PSSession -ComputerName $server_ip -Credential $cred
    $installed_features = Invoke-Command -ScriptBlock { Get-WindowsFeature | Where-Object {$_.installstate -eq "installed"} | Select-Object -Property Name } -Session $session
    # return a list of features not installed
    foreach ($feature_name in $feature_names)
    {
        if ($installed_features -notcontains $feature_name)
        {
            $missing_features += $feature_name
        }
    }

    if ($missing_features.Length -gt 0)
    {
        # TODO: check output format
        return "FAILED: Some required features are not installed on this server. A list of the missing features is shown below:`n"`
            + "$missing_features"
    }
    else
    {
        return "PASSED"
    }
}

# Checks if the necessary connectivity between all the components exists
function Check-ComponentConnectivity
{
    # Go through the parsed connectivity requirements and test them
    $rule_number = 1
    $total_rules = $prereq_table.CONNECTIVITY.Count
    Write-Log "$total_rules network rules to check..."
    foreach ($connection in $prereq_table.CONNECTIVITY)
    {
        Write-Progress -Id 1 -Activity "Checking network rule $rule_number of $total_rules" -PercentComplete ($rule_number / $total_rules * 100)
        $rule_number += 1
        # As mentioned, the source must be a component
        $source = $connection[0]
        $destination = $connection[1]
        # If port is not a number, connection is untestable
        if (-Not [Int32]::TryParse($connection[2], [ref]$null))
        {
            continue
        }
        # If either one refers to a component, get the component
        $source = if ($source -match "^COMPONENT:") { $components[$source.Substring(10)] } else { $source }
        # Connection to the destination VIP must be tested from each source server
        foreach ($source_ip in $source.IPs)
        {
            # Destination can be a component, resource, or web URL
            if ($destination -match '^COMPONENT:')
            {
                $destination = $components[$destination.Substring(10)]
                # Should the test be to the destination VIP or individual servers (e.g. non-load balanced components,
                # destination with (Servers) appended)?
                if ($destination.DNSIP -eq $null -or $connection[3] -eq $true)
                {
                    foreach ($destination_ip in $destination.SERVERIPs)
                    {
                        $connection[5] = Check-ConnectionBetween $source_ip $destination_ip $connection[2] $connection[3] $False
                        # NOTE: there will be one result for each row in the network requirements. So we stop
                        # at the first failure, but report the exact source IP and destination IP (since each row
                        # may contain multiple source and/or destination IPs)
                        if ($connection[5] -notmatch "^PASSED")
                        {
                            break
                        }
                    }
                }
                else
                {
                    $connection[5] = Check-ConnectionBetween $source_ip $destination.DNSIP $connection[2] $connection[3] $False
                    # For load-balanced destinations, also check if the destination SSL handling is accurate
                    if ($connection[5] -match "PASSED")
                    {
                        $result = Get-ServerThumbprint $source_ip $destination.DNSIP $connection[2]
                        if ($result -match "^FAILED")
                        {
                            # Do nothing: result contains the error message
                        }
                        # N/A SSL Handling is treated as Passthrough since in both cases there is no SSL handling taking place
                        elseif ($destination.SSLHandling -eq $C_SSL_PASSTHROUGH -or $destination.SSLHandling -eq $C_NA)
                        {
                            # We expect the thumbprint to be identical to the one stored in the appliance
                            if ($result -eq $SelfSignedThumbprint)
                            {
                                $result = "PASSED"
                            }
                            else
                            {
                                $result = "FAILED: The thumbprint received by $source_ip while accessing this load balancer on port"`
                                    + " $($connection[2]) does not match the thumbprint on destination server $($destination.DNSRecord)."`
                                    + " SSL passthrough is not correctly configured on this load balancer. (Expected thumbprint:"`
                                    + " $SelfSignedThumbprint; Received thumbprint: $result)"
                            }
                        }
                        elseif ($destination.SSLHandling -eq $C_SSL_BRIDGING)
                        {
                            # When bridging, we expect the thumbprint to be different from the one configured on the server
                            if ($result -ne $SelfSignedThumbprint)
                            {
                                $result = "PASSED"
                            }
                            else
                            {
                                $result = "FAILED: The thumbprint received by $source_ip while accessing this load balancer on port"`
                                    + "$($connection[2]) matches the thumbprint configured on the server. SSL bridging"`
                                    + "is not correctly configured on this load balancer. (Server thumbprint: $SelfSignedThumbprint; "`
                                    + "Received thumbprint: $result)"
                            }
                        }
                        elseif ($destination.SSLHandling -eq $C_SSL_OFFLOADING)
                        {
                            # as long as any thumbprint is received, that means SSL is being offloaded, since
                            # the destination will not be accepting SSL traffic with offloading configured
                            # TODO: allow the user to specify the expected thumbprint on the loadbalancer
                            $result = "PASSED"
                        }
                        # Store the result in the prereq_table, but note that a single failed result for LOADBALANCING
                        # for a destination must stick
                        $current_value = $prereq_table['LOADBALANCING'][$destination.DNSIP]
                        if ($current_value -eq $null -or $current_value -eq "PASSED")
                        {
                            $prereq_table['LOADBALANCING'][$destination.DNSIP] = $result
                        }
                    }
                }
            }
            elseif ($destination -match '^RESOURCE:')
            {
                # TODO: is first IP good enough for all resources?
                $destination = $resources[$destination.Substring(9)].IPs[0]
                $connection[5] = Check-ConnectionBetween $source_ip $destination $connection[2] $connection[3] $False
            }
            else
            {
                $connection[5] = Check-ConnectionBetween $source_ip $destination $connection[2] $connection[3] $True
            }

            # If a failure was reported for any source IPs, no need to carry on with the rest since, as we said,
            # there is only a single result reported for each row in the network requirements
            if ($connection[5] -notmatch "PASSED")
            {
                break
            }
        }
    }
    # The SSH Pool should no longer be needed
    Remove-SSHPool
}

# Checks if the $source machine is able to reach the $destination machine
# If the $source machine is 'localhost', the test is run directly from the running PowerShell instance
# If the $destination is a Web URL, and a $Proxy parameter is defined, the test is done by attempting
# to pull the web content from the destination and checking for the $ProxyDenialString, which is
# a string in the proxy response indicating the request was blocked
function Check-ConnectionBetween([string]$source, $destination, [int]$port, [string]$protocol, [bool]$is_web_url)
{
    if ($is_web_url)
    {
        # Some internet URL wildcards must be replaced with a specific known URL for testing
        # These were determined through trial-and-error
        foreach ($key in $wildcard_urls.Keys)
        {
            $replacement = $wildcard_urls[$key]
            $destination = $destination -replace $key,$replacement
        }
        $destination = $destination -replace "\*.notify.live.net","sn.notify.live.net"
        $destination = $destination -replace "\*.phobos.apple.com.edgesuite.net","ax.phobos.apple.com.edgesuite.net"
        # Random number for the Apple URL
        $destination = $destination -replace "#","$(Get-Random -Minimum 0 -Maximum 200)"
        # Any remaining wildcards can just be replace with www
        $destination = $destination -replace "\*","www"
    }
    # If $source is 'localhost' the connectivity test needs to be conducted directly from the machine running
    # the validation script (e.g. will be the case for tests for internal devices)
    if ($source -eq 'localhost')
    {
        if ($is_web_url -and $ProxyServer.Length -gt 0)
        {
            try
            {
                # The SkipHttpErrorCheck parameter avoids much grief
                if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey("SkipHttpErrorCheck"))
                {
                    $response = Invoke-WebRequest -Uri "$($destination):$($port)" -Proxy $ProxyServer -SkipHttpErrorCheck
                }
                else
                {
                    $response = Invoke-WebRequest -Uri "$($destination):$($port)" -Proxy $ProxyServer
                }
                if ($response.Content -match "$ProxyDenialString")
                {
                    return $("FAILED: Proxy response contains the specified `$ProxyDenialString, indicating "`
                        + "that a response was not correctly received from the destination.")
                }
            }
            catch
            {
                if ($_.Exception.Response -eq $null)
                {
                    return "FAILED: A response could not be retrieved from the destination."
                }
                # As a response was received, it might still be ok as long as the error response came
                # from the intended destination (e.g. some URLs return 404 when tested directly)
                if ($powershell_core)
                {
                    # Running PowerShell Core but without the SkipHttpErrorCheck, so this mangled output
                    # is the best we can do (but it should still capture Proxy Denial String if chosen wisely)
                    if ($_.ErrorDetails.Message -match $ProxyDenialMessage)
                    {
                        return $("FAILED: Proxy response contains the specified `$ProxyDenialString, indicating "`
                            + "that a response was not correctly received from the destination.")
                    }
                }
                else
                {
                    # With legacy PowerShell, this is how you get the HTTP response with an error response code
                    $stream = $_.Exception.Response.GetResponseStream()
                    $stream.Position = 0
                    $reader = [System.IO.StreamReader]::new($stream)
                    $response = $reader.ReadToEnd()

                    if ($response -match "$ProxyDenialString")
                    {
                        return $("FAILED: Proxy response contains the specified `$ProxyDenialString, indicating "`
                            + "that a response was not correctly received from the destination.")
                    }
                }
                # If we reached here, then a response was received that doesn't contain the proxy denial string
                # so we are ok
                return "PASSED"
            }
        }
        else
        {
            # Test-NetConnection was removed in PowerShell Core
            if (-Not $powershell_core)
            {
                $result = (Test-NetConnection -ComputerName $destination -Port $port).TcpTestSucceeded
            }
            else
            {
                $result = Test-Connection -ComputerName $destination -TCPPort $port
            }
            if ($result)
            {
                return "PASSED"
            }
            else
            {
                return $("FAILED: A TCP connection could not be established to the specified destination and port. "`
                    + "Note that tests labeled for 'Devices on Internet or Wi-Fi' are executed from the device "`
                    + "running the validation script.")
            }
        }
    }
    $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $SSH_USERNAME, $SECURE_SSH_PASSWORD
    try {
        #$session = New-SSHSession -ComputerName $source -Force -Credential $cred -ErrorAction Stop -WarningAction SilentlyContinue
        $session = Get-PoolSSHSession -Destination $source -Credential $cred
    }
    catch {
        return $("FAILED: An SSH session could not be established to the source machine `"$source`" to begin the test."`
            + "The error details are printed below:`n"`
            + $_.Exception.Message)
    }
    # Just as was done above, we use the telnet test unless it's a Web URL and a $Proxy is specified
    if ($is_web_url -and $ProxyServer.Length -gt 0)
    {
        # TODO: handle the protocol prefix
        $prefix = if ($protocol -match "HTTPS") { "https://" } else { "http://" }
        $result = Invoke-SSHCommand -SSHSession $session -Command "curl $($prefix)$($destination):$($port) --proxy $ProxyServer"
        #Remove-SSHSession $session | Out-Null
        # curl is more well-behaved; an error response code does not trigger an exit code
        if ($result.ExitStatus -eq 0)
        {
            if ($result.Output -notmatch "$ProxyDenialString")
            {
                return "PASSED"
            }
            else
            {
                return $("FAILED: Proxy response contains the specified `$ProxyDenialString, indicating "`
                        + "that a response was not correctly received from the destination.")
            }
        }
        else
        {
            return "FAILED: A TCP connection could not be established to the specified destination and port."
        }
    }
    else
    {
        $result = Invoke-SSHCommand -SSHSession $session -Command "nc -w $ConnectionTimeout -z $destination $port"
        #Remove-SSHSession $session | Out-Null
        if ($result.ExitStatus -eq 0)
        {
            return "PASSED"
        }
        else
        {
            return "FAILED: A TCP connection could not be established to the specified destination and port."
        }
    }
}

# Initiates a SSH session with the source to get the thumbprint seen on the destination
function Get-ServerThumbprint([string]$source, [string]$destination, [int]$port)
{
    # We'll need to handle getting the thumbprint from both PowerShell and from validation appliances
    if ($source -eq 'localhost')
    {
        # This part adapted from https://tech.zsoldier.com/2018/10/powershell-get-sha256-thumbprint-from.html
        $Certificate = $null
        $TcpClient = New-Object -TypeName System.Net.Sockets.TcpClient
        try
        {
            $TcpClient.Connect($destination, $port)
            $TcpStream = $TcpClient.GetStream()
        
            $Callback = { param($sender, $cert, $chain, $errors) return $true }
        
            $SslStream = New-Object -TypeName System.Net.Security.SslStream -ArgumentList @($TcpStream, $true, $Callback)
            try
            {
                $SslStream.AuthenticateAsClient($URI)
                $Certificate = $SslStream.RemoteCertificate
            }
            finally {
                $SslStream.Dispose()
            }
        
        }
        finally
        {
            $TcpClient.Dispose()
        }
        
        if ($Certificate) {
            if ($Certificate -isnot [System.Security.Cryptography.X509Certificates.X509Certificate2])
            {
                $Certificate = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $Certificate
            }
            $SHA256 = [Security.Cryptography.SHA256]::Create()
            $Bytes = $Certificate.GetRawCertData()
            $HASH = $SHA256.ComputeHash($Bytes)
            $thumbprint = [BitConverter]::ToString($HASH).Replace('-',':')
            Switch ($SHA256Thumbprint)
            {
                $false 
                {
                    Write-Output $Certificate
                }
                $true 
                {
                    Write-Output $thumbprint
                }
            }
        }
    }
    else
    {
        $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $SSH_USERNAME, $SECURE_SSH_PASSWORD
        try {
            #$session = New-SSHSession -ComputerName $source -Force -Credential $cred -ErrorAction Stop -WarningAction SilentlyContinue
            $session = Get-PoolSSHSession -Destination $source -Credential $cred
        }
        catch {
            return $("FAILED: An SSH session could not be established to the source machine to begin the test. "`
                + "The error details are printed below:`n"`
                + $_.Exception.Message)
        }
        $command = "openssl s_client -connect $($destination):$port < /dev/null 2>/dev/null | openssl x509 -fingerprint -noout -in /dev/stdin"
        $result = Invoke-SSHCommand -SSHSession $session -Command $command
        #Remove-SSHSession $session | Out-Null
        if ($result.ExitStatus -ne 0)
        {
            return "FAILED: attempting to retreive the certificate thumbprint returned exit code $($result.ExitStatus)"
        }
        $thumbprint = $result.Output[0].Substring($result.Output[0].IndexOf('=') + 1)
    }
    return $thumbprint
}

# Converts connectivity results into an object ready for printing with Export-Excel
# If a previous $result_excel is passed in, the returned excel file will include its worksheets
function Parse-ConnectivityResults($input_excel)
{
    $result_objects = @()
    foreach ($result in $prereq_table.CONNECTIVITY)
    {
        $result_object = [PSCustomObject]@{
            Source = if ($result[0] -match "^COMPONENT:") { $result[0].Substring(10) } else { $result[0] }
            Destination = if ($result[1] -match "^COMPONENT:") { $result[1].Substring(10) } else { $result[1] }
            Port = $result[2].ToString()
            Protocol = $result[3]
            Result = $result[5]
        }
        $result_objects += $result_object
    }
    if ($result_objects.Count -eq 0)
    {
        return $input_excel
    }
    # if this is the first result, create a new result package
    if ($input_excel -eq $null)
    {
        $result_excel = ($result_objects | Export-Excel -PassThru -WorksheetName "Connectivity")
        return $result_excel
    }
    # otherwise just add a sheet to the existing one
    else
    {
        return ($result_objects | Export-Excel -ExcelPackage $input_excel -Autosize -PassThru -WorksheetName "Connectivity")
    }
}

function Parse-DNSResults($input_excel)
{
    $result_objects = @()
    foreach ($key in $prereq_table.DNSRECORDS.Keys)
    {
        $result_object = [PSCustomObject]@{
            "DNS Name" = $key
            "Result" = $prereq_table.DNSRECORDS[$key]
        }
        $result_objects += $result_object
    }
    if ($result_objects.Count -eq 0)
    {
        return $input_excel
    }
    # if this is the first result, create a new result package
    if ($input_excel -eq $null)
    {
        $result_excel = ($result_objects | Export-Excel -PassThru -WorksheetName "DNS")
        return $result_excel
    }
    # otherwise just add a sheet to the existing one
    else
    {
        return ($result_objects | Export-Excel -ExcelPackage $input_excel -Autosize -PassThru -WorksheetName "DNS")
    }
}

# Outputs all the results into a Result spreadsheet for easy viewing
function Print-Results
{
    $results = Parse-ConnectivityResults
    $results = Parse-DNSResults $results
    Export-Excel -ExcelPackage $results -Show
}

# Load Lam's OVF props functions
. $PSScriptRoot\VMOvfProperty.ps1

# Create any appliances needed for validation through PowerCLI and returns a list of the created appliances
# NOTE: any error here renders the validation useless, so we exit early
function Create-ComponentAppliances
{
    $deployed_appliances = @()
    if (-Not ($VsphereFQDN.Length -gt 0))
    {
        Write-Failure "$C_AUTO_PREPARE was specified but VsphereFQDN parameter was blank"
        exit 1
    }
    if ($VsphereCredentials -eq $null)
    {
        Write-Failure "$C_AUTO_PREPARE was specified but VSphere credentials were not provided."
        exit 1
    }
    $vi_server = Connect-VIServer -Server $VsphereFQDN -Credential $VsphereCredentials
    $tc_template = Get-Template -Name 'TinyCore' -Server $vi_server
    # If template was not added yet, components cannot be created
    if ($tc_template -eq $null)
    {
        Write-Failure "Could not locate 'TinyCore' template on specified VSphere host $VsphereFQDN"
        Disconnect-VIServer -Confirm:$False -Server $vi_server
        exit 1
    }
    # Create all components parsed from the first sheet
    foreach ($component_name in $components.Keys)
    {
        $component = $components[$component_name]
        # Skip component if one of the following is true:
        # (i) it doesn't have auto-prepare fields (must be an alias to another component)
        # (ii) it doesn't have a hostname (e.g. Database components)
        # (iii) it's a localhost component (e.g. user browser, end user device, etc...)
        # (iv) Database components, as they are part of the prerequisites
        if ($local_components -contains $component_name`
            -or $component.ComputeNodes -eq $null`
            -or $component.Hostnames[0] -eq "N/A"`
            -or $component_name -match '\[DB\]')
        {
            continue
        }
        # We'll need to create a separate appliance for each server belonging to the component
        foreach ($i in 0..($component.Hostnames.Count - 1))
        {
            $vm = Get-VM -Name ("TinyCore_$($component_name)_$i") -Server $vi_server -ErrorAction Ignore
            if ($vm -ne $null)
            {
                Write-Failure "$C_AUTO_PREPARE was selected but a previous validation appliance with name `"$("TinyCore_$($component_name)_$i")`" was found."
                Disconnect-VIServer -Confirm:$False -Server $vi_server
                exit 1
            }
            $vm = New-VM -Template $tc_template -Name ("TinyCore_$($component_name)_$i") -VMHost $component.ComputeNodes[$i]`
                -Datastore $component.Datastores[$i] -PortGroup (Get-VDPortGroup -Name $component.VMNetworks[$i]) -Server $vi_server
            if ($vm -eq $null)
            {
                Write-Failure "Failed to create validation appliance for component `"$component_name`""
                exit 1
            }
            # Set the OVF props according to component properties
            $vm_props = @{
                'guestinfo.hostname' = $component.Hostnames[$i]
                'guestinfo.ipaddress' = $component.IPs[$i]
                'guestinfo.netmask' = $component.SubnetMasks[$i]
                'guestinfo.gateway' = $component.GatewayIPs[$i]
                'guestinfo.dns' = $resources[$C_DNS_SERVER].IPs[0]
            }
            Set-VMOvfProperty -VM $vm $vm_props | Out-Null
            Start-VM -VM $vm -Server $vi_server | Out-Null
            # Keep a record of the appliances for ClearOnExit
            $deployed_appliances += $vm
        }
    }
    # Wait 5 seconds for appliances to boot up
    Write-Log "Waiting 20 seconds for appliances to boot..."
    Start-Sleep -s 20
    Disconnect-VIServer -Confirm:$False -Server $vi_server
    return $deployed_appliances
}

# Some settings on the appliance might need to be configured based on the information in the prereq sheet
# This function applies the configuration idempotently to all appliances
function Prepare-ComponentAppliances
{
    # Look for destination components that will need to listen for HTTP traffic
    # and compile the lists of port numbers for each host
    $appliance_ports = @{}
    foreach ($connection in $prereq_table.CONNECTIVITY)
    {
        $destination = $connection[1]
        # If it's not a component, there's no appliance for it and we don't care
        if ($destination -notmatch '^COMPONENT:')
        {
            continue
        }
        $destination_component = $components[$destination.Substring(10)]
        # reminder: connection[3] is the protocol
        if ($connection[3] -match "HTTP")
        {
            foreach ($host_ip in $destination_component.IPs)
            {
                if ($appliance_ports[$host_ip] -eq $null)
                {
                    $appliance_ports[$host_ip] = @()
                }
                $appliance_ports[$host_ip] += ,@($connection[2], $connection[3])
            }
        }
    }
    # Now we can start lighttpd on all appliances once the configurations are final
    $appliance_number = 1
    $total_appliances = $appliance_ports.Keys.Count
    Write-Log "Configuring $total_appliances validation appliances..."
    foreach ($host_ip in $appliance_ports.Keys)
    {
        Write-Progress -Id 2 -Activity "Configuring appliance $appliance_number of $total_appliances" `
            -PercentComplete ($appliance_number / $total_appliances * 100)
        $appliance_number += 1
        # all ports for this appliance
        $host_appliance_ports = $appliance_ports[$host_ip]
        # Connect to appliance and edit lighttpd configuration to specified port
        $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $SSH_USERNAME, $SECURE_SSH_PASSWORD
        $connection_attempts = 0
        $session = $null
        while ($session -eq $null -and $connection_attempts -lt $ConnectionAttempts)
        {
            try {
                $session = New-SSHSession -ComputerName $host_ip -Force -Credential $cred -ErrorAction Stop -ConnectionTimeout 5 `
                    -WarningAction SilentlyContinue
            }
            catch {
                $error_message = $_.Exception.Message
            }
        }
        if ($session -eq $null)
        {
            Write-Failure $("ERROR: An SSH session could not be established to prepare component with IP address `'$host_ip`'. "`
                + "The error details for the last attempt are printed below:`n"`
                + $error_message);
            
            continue
        }
        # copy the read-only template lighttpd config so we can customize it
        $ret = $(Invoke-SSHCommand -SSHSession $session -Command "sudo cp /var/www/lighttpd_template.conf /var/www/lighttpd.conf")
        $ret = $(Invoke-SSHCommand -SSHSession $session -Command "sudo kill ``cat /var/www/server.pid-file``")
        # and set the new port/ssl configurations. We use this list to ensure each port number is added only once
        $processed_ports = @()
        if ($host_appliance_ports.Count -eq 0)
        {
            Write-Log "WARNING: Configuring appliance with IP address `'$host_ip`' without any listening ports!"
        }
        # The following needs explaining: lighttpd forces using a top-level server.port and top-level ssl settings
        # in addition to the per-port lines to listen to specific ports, so the approach is as follows:
        # If there is any HTTPS port for this appliance, keep the top-level ssl settings and have server.port point
        # to any one of the HTTPS port. If there are only HTTP ports, comment out the top-level ssl settings, and have
        # server.port point to any of them.
        $found_ssl = ""
        foreach ($host_appliance_port in $host_appliance_ports)
        {
            # skip if port number was already processed
            if ($processed_ports -contains $host_appliance_port[0])
            {
                continue
            }
            $ssl_state = "disable"
            if ($host_appliance_port[1] -match "HTTPS")
            {
                $ssl_state = "enable"
                $found_ssl = $host_appliance_port[0]
            }
            $ret = $(Invoke-SSHCommand -SSHSession $session `
                -Command "sudo echo \`$SERVER[\`"socket\`"] == \`":$($host_appliance_port[0])\`" {ssl.engine = \`"$ssl_state\`"} >> /var/www/lighttpd.conf")
            $processed_ports += $host_appliance_port[0]
        }
        if ($found_ssl.Length -gt 0)
        {
            # just add the port line
            $ret = $(Invoke-SSHCommand -SSHSession $session `
                -Command "sudo echo server.port = \`"$found_ssl\`" >> /var/www/lighttpd.conf")
        }
        else
        {
            # comment out all top-level ssl line and have server.port point to any port in use
            $ret = $(Invoke-SSHCommand -SSHSession $session `
                -Command "sudo sed -i 's/^ssl/#ssl/g' /var/www/lighttpd.conf")
            $ret = $(Invoke-SSHCommand -SSHSession $session `
                -Command "sudo echo server.port = \`"$($host_appliance_ports[0][0])\`" >> /var/www/lighttpd.conf")
        }
        $ret = $(Invoke-SSHCommand -SSHSession $session -Command "sudo /usr/local/sbin/lighttpd -f /var/www/lighttpd.conf")
        Remove-SSHSession $session | Out-Null
    }
}

Parse-PrereqComponents
Parse-ConnectivityPrereqs
Check-DNSPrereqs
#$vms = Create-ComponentAppliances
#Prepare-ComponentAppliances
#Check-ComponentConnectivity
#Print-Results
if ($vms.Count -gt 0 -and $ClearOnExit)
{
    $vi_server = Connect-VIServer -Server $VsphereFQDN -Credential $VsphereCredentials
    foreach ($vm in $vms)
    {
        # As an added security measure, confirm that 'TinyCore' appears in the vm name
        if ($vm.Name -notmatch "^TinyCore")
        {
            continue
        }
        Stop-VM -VM $vm -Confirm:$False -Server $vi_server
        Remove-VM -VM $vm -DeletePermanently -Confirm:$False -Server $vi_server
    }
}
echo "Done"
