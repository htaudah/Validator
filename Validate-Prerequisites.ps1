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
#>
param(
    [string]$SSH_USERNAME="root",
    [string]$SSH_PASSWORD="vmbox",
    [string]$SheetPath=".\Pre-Install_Requirements.xlsx",
    # Set this to an empty string to open the result as an unsaved temp file
    [string]$OutputPath="",
    [string]$SelfSignedThumbprint="THUMPER",
    [string]$VsphereFQDN="vsphere.haramco.xyz",
    [PSCredential]$VsphereCredentials
)

$SECURE_SSH_PASSWORD = ConvertTo-SecureString -String $SSH_PASSWORD -AsPlainText -Force

# These constants are references to column/section headers; all references in the script should be to these variables
# and not to the Excel string values (which are apt to change)
$C_ENVIRONMENT_HEADER = 'Environment'
$C_COMPONENTS_HEADER = 'Final Workspace ONE Components'
$C_ACCOUNTS_HEADER = 'Service Accounts'
$C_REQUIRED = 'Required'
$C_COMPONENTS = 'Components'
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

# This is a list of URLs with wildcards or other special characters that need to be converted into actual
# URLs for testing. These are only used when for URLs for which the default method of swapping the *
# with www does not result in a valid URL.
$wildcard_urls = @{
    "\*.ggpht.com" = "gp5.ggpht.com"
    "\*.gvt1.com" = "redirector.gvt1.com"
    "\*.gvt2.com" = "beacons.gvt2.com"
    "\*.gvt3.com" = "beacons5.gvt3.com"
}

# This will be used to hold the results excel package
$result_excel = $null

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
$local_components = @($C_DEVICES, $C_BROWSER)
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
    return ($url -match "^([a-zA-Z\d\-]+\.)*[a-zA-Z\d\-]+$")
}
function is_ip($ip_address)
{
    return ($ip_address -match "\b\d{1,3}\.d{1,3}\.d{1,3}\.\d{1,3}\b")
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
            Write-Failure "Parse error for component $($component_name): There was a mismatch in the number of Server"`
                + "IPs and Hostnames ($($server_ip_lines.Count) Server IP lines; $($name_lines.Count) Hostname lines)"
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
            Hostnames = $datarow.$C_HOSTNAMES
            IPs = $datarow.$C_SERVER_IPS
        }
    }
}

# Goes through all worksheets after the first one looking for 'Network Requirements' sections
function Parse-ConnectivityPrereqs
{
    foreach ($worksheet in $worksheets)
    {
        #TODO: remove this when done testing
        if ($worksheet -ne 'Access (On-Premises)' -and $worksheet -ne 'DS-AWCM-API (On-Premises)') {continue}
        Write-Log $worksheet
        
        # Find correct ranges for all the information
        $cells = $excel_pkg.$worksheet.Cells
    
        # Section limits are determined by looking for section headers on column B
        $network_index = -1
        for ($i = 0; $i -lt 200; $i += 1)
        {
            $cell_index = "B" + $i
            $cell = $cells[$cell_index]

            if ($cell.Text -eq $C_NETWORK_REQUIREMENTS)
            {
                $network_index = $i + 2
                break
            }
        }

        if ($network_index -gt 0)
        {
            # Import at the proper starting row
            $real_data = Import-Excel -Path $SheetPath -WorksheetName $worksheet -StartRow $network_index
            # Now we can cycle through the actual network-related rows
            foreach ($line in $real_data)
            {
                # Ignore any rows not applicable
                if ($line.Status -eq "N/A")
                {
                    continue
                }
                # Just get the component names, and rely on the information imported from the first worksheet
                # This is why the names need to match!
                $source = $components[$line.'Source Component']
                if ($source -eq $null)
                {
                    # TODO: are there ever source pseudo-components?
                }
                else
                {
                    # No longer storing component in prereq_table, but relying on standard names everywhere
                    $source = "COMPONENT:$($line.'Source Component')"
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

                # Connectivity tests will differ depending on whether the destination is a component, or just an IP address
                # Whatever it is, though, it gets stored in $destination
                if ($destination -eq $null)
                {
                    $destination = @()
                    $line.'Destination Component'.Split("`n") | ForEach-Object { if (is_url($_.Trim())) {$destination += $_} }
                }
                else
                {
                    # again, we're no longer storing the full components in the prereq_table
                    $destination = "COMPONENT:$($line.'Destination Component')"
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
    $ip = (Resolve-DnsName $record_name -ErrorAction Ignore).IPAddress
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
    foreach ($connection in $prereq_table.CONNECTIVITY)
    {
        # As mentioned, the source must be a component
        $source = $connection[0]
        $destination = $connection[1]
        # If either one refers to a component, get the component
        $source = if ($source -match "^COMPONENT:") { $components[$source.Substring(10)] } else { $source }
        $destination = if ($destination -match "^COMPONENT:") { $components[$destination.Substring(10)] } else { $destination }
        # Connection to the destination VIP must be tested from each source server
        foreach ($source_ip in $source.IPs)
        {
            # Destination is either a component or IP
            if ($destination.GetType() -ne [string])
            {
                # Should the test be to the destination VIP or individual servers (e.g. non-load balanced components,
                # destination with (Servers) appended)?
                if ($destination.DNSIP -eq $null -or $connection[3] -eq $true)
                {
                    foreach ($destination_ip in $destination.SERVERIPs)
                    {
                        $connection[5] = Check-ConnectionBetween $source_ip $destination_ip $connection[2]
                        # As soon as we get one failure, no need to continue with the rest
                        # TODO: fix this, we should check connectivity with all IPs. The result could be an array in this case
                        if ($connection[5] -notmatch "^PASSED")
                        {
                            break
                        }
                    }
                }
                else
                {
                    $connection[5] = Check-ConnectionBetween $source_ip $destination.DNSIP $connection[2]
                    # For load-balanced destinations, also check if the destination SSL handling is accurate
                    if ($connection[5] -match "PASSED")
                    {
                        $result = Get-ServerThumbprint $source_ip $destination.DNSIP $connection[2]
                        if ($destination.SSLHandling -eq "Passthrough")
                        {
                            # We expect the thumbprint to be identical to the one stored in the appliance
                            if ($result -match "^FAILED")
                            {
                                # Do nothing: result contains the error message
                            }
                            elseif ($result -eq $SelfSignedThumbprint)
                            {
                                $result = "PASSED"
                            }
                            else
                            {
                                $result = "FAILED: The thumbprint received by $source_ip while accessing this load balancer on port"`
                                    + "$($connection[2]) does not match the thumbprint on the destination servers. SSL passthrough"`
                                    + "is not correctly configured on this load balancer. (Expected thumbprint: $SelfSignedThumbprint; "`
                                    + "Received thumbprint: $result"
                            }
                        }
                        elseif ($destination.SSLHandling -eq "Bridging")
                        {
                            # We expect the thumbprint to be identical to the one stored in the appliance
                            if ($result -match "^FAILED")
                            {
                                # Do nothing: result contains the error message
                            }
                            # When bridging, we expect the thumbprint to be different from the one configured on the server
                            elseif ($result -ne $SelfSignedThumbprint)
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
                        elseif ($destination.SSLHandling -eq "Offloading")
                        {
                            # as long as any thumbprint is received, that means SSL is being offloaded, since
                            # the destination will not be accepting SSL traffic with offloading configured
                            # TODO: allow the user to specify the expected thumbprint on the loadbalancer
                            if ($result -notmatch "^FAILED")
                            {
                                $result = "PASSED"
                            }
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
            else
            {
                $connection[5] = Check-ConnectionBetween $source_ip $destination $connection[2]
            }
        }
    }
}

# Checks if the $source machine is able to reach the $destination machine
# on port $port, by running the check_connection script built in to the appliance
function Check-ConnectionBetween([string]$source, $destination, [int]$port)
{
    # If $source is 'localhost' the connectivity test needs to be conducted directly from the machine running
    # the validation script (e.g. will be the case for tests for internal devices)
    if ($source -eq 'localhost')
    {
        if (is_url($destination))
        {
            # Some internet URL wildcards must be replaced with a specific known URL for testing
            # These were determined through trial-and-error
            $destination = $destination -replace "\*.notify.live.net","sn.notify.live.net"
            $destination = $destination -replace "\*.phobos.apple.com.edgesuite.net","ax.phobos.apple.com.edgesuite.net"
            # Random number for the Apple URL
            $destination = $destination -replace "#","$(Get-Random -Minimum 0 -Maximum 200)"
            # Any remaining wildcards can just be replace with www
            $destination = $destination -replace "\*","www"
        }
        $result = Test-NetConnection -ComputerName $destination -Port $port
        if ($result.TcpTestSucceeded)
        {
            return "PASSED"
        }
        else
        {
            return "FAILED: A TCP connection could not be established to the specified destination and port. "`
                + "Note that tests labeled for 'Devices on Internet or Wi-Fi' are executed from the device "`
                + "running the validation script."
        }
    }
    $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $SSH_USERNAME, $SECURE_SSH_PASSWORD
    try {
        $session = New-SSHSession -ComputerName $source -AcceptKey -Credential $cred -ErrorAction Stop
    }
    catch {
        return "FAILED: An SSH session could not be established to the source machine `"$source`" to begin the test."`
            + "The error details are printed below:`n"`
            + $_.Exception.Message;
    }
    $result = Invoke-SSHCommand -SSHSession $session -Command "/home/tc/check_connection.sh $destination $port"
    Remove-SSHSession $session
    if ($result.ExitStatus -eq 0)
    {
        return "PASSED"
    }
    else
    {
        return "FAILED: A TCP connection could not be established to the specified destination and port."
    }
}

# Initiates a SSH session with the source to get the thumbprint seen on the destination
function Get-ServerThumbprint([string]$source, [string]$destination, [int]$port)
{
    $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $SSH_USERNAME, $SECURE_SSH_PASSWORD
    try {
        $session = New-SSHSession -ComputerName $source -AcceptKey -Credential $cred -ErrorAction Stop
    }
    catch {
        return "FAILED: An SSH session could not be established to the source machine to begin the test. "`
            + "The error details are printed below:`n"`
            + $_.Exception.Message;
    }
    $result = Invoke-SSHCommand -SSHSession $session -Command "/home/tc/check_thumbprint.sh $destination $port"
    Remove-SSHSession $session
    return $result
}

# Converts connectivity results into an object ready for printing with Export-Excel
function Parse-ConnectivityResults
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
    # if this is the first result, create a new result package
    if ($result_excel -eq $null)
    {
        $result_excel = ($result_objects | Export-Excel -PassThru -WorksheetName "Connectivity")
    }
    # otherwise just add a sheet to the existing one
    else
    {
        $result_objects | Export-Excel -ExcelPackage $result_excel -WorksheetName "Connectivity"
    }
}

function Parse-DNSResults
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
    # if this is the first result, create a new result package
    if ($result_excel -eq $null)
    {
        $result_excel = ($result_objects | Export-Excel -PassThru -WorksheetName "DNS")
    }
    # otherwise just add a sheet to the existing one
    else
    {
        $result_objects | Export-Excel -ExcelPackage $result_excel -WorksheetName "DNS"
    }
}

# Outputs all the results into a Result spreadsheet for easy viewing
function Print-Results
{
    Parse-ConnectivityResults
    Parse-DNSResults
    Export-Excel -ExcelPackage $result_excel -Show
}

# Load Lam's OVF props functions
. $PSScriptRoot\VMOvfProperty.ps1

# Create any appliances needed for validation through PowerCLI
# NOTE: any error here renders the validation useless, so we exit early
function Create-ComponentAppliances
{
    if (-Not ($VsphereFQDN.Length -gt 0))
    {
        Write-Failure "$C_AUTO_PREPARE was specified but VsphereFQDN parameter was blank"
        exit 1
    }
    if ($VsphereCredentials -eq $null)
    {
        $cred = Get-Credential -Message "$C_AUTO_PREPARE was specified but VSphere credentials were not provided. Enter VSphere credentials."
    }
    else
    {
        $cred = $VsphereCredentials
    }
    $vi_server = Connect-VIServer -Server $VsphereFQDN -Credential $cred
    $tc_template = Get-Template -Name 'TinyCore' -Server $vi_server
    # If template was not added yet, components cannot be created
    if ($tc_template -eq $null)
    {
        Write-Failure "Could not locate 'TinyCore' appliance on specified VSphere host $VsphereFQDN"
        Disconnect-VIServer -Confirm:$False
        exit 1
    }
    # Keep track of DNS VIPs created to avoid duplicates for alias components
    $processed_components = @()
    # Create all components parsed from the first sheet
    foreach ($component_name in $components.Keys)
    {
        $component = $components[$component_name]
        # Skip components that don't have auto-prepare fields (these must be aliases)
        # Skip components that were already processed (through an alias) as well as local components
        if ($local_components -contains $component_name -or $component.ComputeNodes -eq $null)
        {
            continue
        }
        # We'll need to create a separate appliance for each server belonging to the component
        foreach ($i in 0..$component.Hostnames.Count)
        {
            $vm = Get-VM -Name ("TinyCore_$($component_name)_$i") -ErrorAction Ignore
            if ($vm -ne $null)
            {
                Write-Failure "$C_AUTO_PREPARE was selected but a previous validation appliance with name `"$("TinyCore_$($component_name)_$i")`" was found."
                Disconnect-VIServer -Confirm:$False
                exit 1
            }
            $vm = New-VM -Template $tc_template -Name ("TinyCore_$($component_name)_$i") -VMHost $component.ComputeNodes[$i]`
                -Datastore $component.Datastores[$i] -PortGroup (Get-VDPortGroup -Name $component.VMNetworks[$i])
            # Set the OVF props according to component properties
            $vm_props = @{
                'guestinfo.hostname' = $component.Hostnames[$i]
                'guestinfo.ipaddress' = $component.IPs[$i]
                'guestinfo.netmask' = $component.SubnetMasks[$i]
                'guestinfo.gateway' = $component.GatewayIPs[$i]
                'guestinfo.dns' = $resources[$C_DNS_SERVER].IPs[0]
            }
            Set-VMOvfProperty -VM $vm $vm_props
            #Start-VM -VM $vm
            # TODO: for now just stop here
            Disconnect-VIServer -Confirm:$False
            exit 1
        }
    }
    Disconnect-VIServer -Confirm:$False
}

# Some settings on the appliance might need to be configured based on the information in the prereq sheet
# These configurations are made here
function Prepare-ComponentAppliances
{
    # Look for destination components that will need to listen for HTTP traffic
    # and compile the lists of port numbers for each host
    $appliance_ports = @{}
    foreach ($connection in $prereq_table.CONNECTIVITY)
    {
        $destination = $connection[1]
        # If it's not a component, there's no appliance for it and we don't care
        if ($destination.GetType() -ne 'PSCustomType')
        {
            continue
        }
        # reminder: connection[2] is the protocol
        if ($connection[2] -match "HTTP")
        {
            foreach ($host_ip in $destination.IPs)
            {
                if ($appliance_ports[$host_ip] -eq $null)
                {
                    $appliance_ports[$host_ip] = @()
                }
                $appliance_ports[$host_ip] += @($connection[2], $connection[3])
            }
        }
    }
    # Now we can start lighttpd on all appliances once the configurations are final
    foreach ($host_ip in $appliance_ports.Keys)
    {
        # all ports for this appliance
        $key_appliance_ports = $appliance_ports[$key]
        # Connect to appliance and edit lighttpd configuration to specified port
        $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $SSH_USERNAME, $SECURE_SSH_PASSWORD
        try {
            $session = New-SSHSession -ComputerName $host_ip -AcceptKey -Credential $cred -ErrorAction Stop
        }
        catch {
            Write-Failure "ERROR: An SSH session could not be established to prepare component `'$component`'. "`
                + "The error details are printed below:`n"`
                + $_.Exception.Message;
        }
        $ssl_state = if ($key_applicance_ports[1] -match "HTTPS") {"enabled"} else {"disabled"}
        # clear out any previous configuration that might be there and kill the process if it's running
        Invoke-SSHCommand -SSHSession $session -Command "sudo sed '/SERVER[/d' /var/www/lighttpd.conf"
        Invoke-SSHCommand -SSHSession $session -Command "sudo kill ``cat /var/www/server.pid-file``"
        # and set the new port/ssl configurations
        Invoke-SSHCommand -SSHSession $session -Command "sudo echo $SERVER[`"socket`"] == `":$key_appliance_ports[0]`" {ssl.engine = `"$ssl_state`"}"
        Invoke-SSHCommand -SSHSession $session -Command "sudo /usr/local/sbin/lighttpd -f /var/www/lighttpd.conf"
        Remove-SSHSession $session
    }
}

Parse-PrereqComponents
Parse-ConnectivityPrereqs
#Check-DNSPrereqs
Create-ComponentAppliances
echo "Done"
