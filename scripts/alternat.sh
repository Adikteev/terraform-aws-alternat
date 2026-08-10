#!/bin/bash

# Send output to a file and to the console
# Credit to the alestic blog for this one-liner
# https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

# Debian 13 (ak-debian-13-base) port of Alternat userdata:
# https://github.com/chime/terraform-aws-alternat/blob/main/scripts/alternat.sh
# Uses nftables + cloud_detect_lib from debian-13-base.

panic() {
  [ -n "$1" ] && echo "$1"
  complete_asg_lifecycle_action ABANDON
  echo "alterNAT setup failed"
  exit 1
}

load_config() {
   if [ -f "$CONFIG_FILE" ]; then
      . "$CONFIG_FILE"
   else
      panic "Config file $CONFIG_FILE not found"
   fi
   validate_var "eip_allocation_ids_csv" "$eip_allocation_ids_csv"
   validate_var "route_table_ids_csv" "$route_table_ids_csv"
   validate_var "enable_nat_restore" "$enable_nat_restore"
   validate_var "enable_ssm" "$enable_ssm"
}

validate_var() {
   var_name="$1"
   var_val="$2"
   if [ ! "$2" ]; then
      echo "Config var \"$var_name\" is unset"
      exit 1
   fi
}

# configure_nat() sets up Linux to act as a NAT device.
# See https://docs.aws.amazon.com/vpc/latest/userguide/VPC_NAT_Instance.html#NATInstance
configure_nat() {
   echo "Installing NAT dependencies if needed"
   export DEBIAN_FRONTEND=noninteractive
   apt-get update -qq
   apt-get install -y -qq nftables procps || panic "Unable to install nftables"
   if ! command -v aws >/dev/null 2>&1; then
      apt-get install -y -qq awscli || panic "Unable to install awscli"
   fi
   command -v aws >/dev/null 2>&1 || panic "aws CLI not found on PATH"

   systemctl enable --now nftables || panic "Unable to enable nftables"

   local nic_mac
   nic_mac="$(get_imds mac)" || panic "Unable to determine primary ENI MAC from IMDS."
   echo "Found MAC ${nic_mac}"

   local nic_name
   nic_name="$(ip -o link | awk -v mac="${nic_mac}" 'BEGIN{IGNORECASE=1} index($0, mac){gsub(/:/,"",$2); print $2; exit}')"
   if [ -z "${nic_name}" ]; then
      nic_name="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
   fi
   [ -n "${nic_name}" ] || panic "Unable to resolve NAT interface name"
   echo "Found interface name ${nic_name}"

   local vpc_cidr_uri="network/interfaces/macs/${nic_mac}/vpc-ipv4-cidr-blocks"
   echo "Metadata location for vpc ipv4 ranges: ${vpc_cidr_uri}"

   local vpc_cidrs=()
   mapfile -t vpc_cidrs < <(get_imds "${vpc_cidr_uri}")
   if [ ${#vpc_cidrs[@]} -lt 1 ] || [ -z "${vpc_cidrs[0]:-}" ]; then
      panic "Unable to obtain VPC CIDR range from metadata."
   fi
   echo "Retrieved VPC CIDR range(s) ${vpc_cidrs[*]} from metadata."

   echo "Enabling NAT..."
   # Read more about these settings here: https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt
   sysctl -q -w "net.ipv4.ip_forward"=1 \
      "net.ipv4.conf.${nic_name}.send_redirects"=0 \
      "net.ipv4.ip_local_port_range"="1024 65535" || panic "sysctl NAT settings failed"

   # Idempotent: flush any previous alterNAT nat table, then recreate.
   nft delete table ip nat 2>/dev/null || true
   nft add table ip nat
   nft add chain ip nat postrouting '{ type nat hook postrouting priority 100 ; }'

   local cidr
   for cidr in "${vpc_cidrs[@]}"; do
      [ -n "$cidr" ] || continue
      nft add rule ip nat postrouting ip saddr "$cidr" oif "$nic_name" masquerade
      if [ $? -ne 0 ]; then
         panic "Unable to add nft rule for cidr $cidr"
      fi
   done

   sysctl "net.ipv4.ip_forward" "net.ipv4.conf.${nic_name}.send_redirects" "net.ipv4.ip_local_port_range"
   nft list ruleset

   echo "NAT configuration complete"
}

# install_ssm_agent() installs amazon-ssm-agent from the official Debian package when enable_ssm=true.
# https://docs.aws.amazon.com/systems-manager/latest/userguide/agent-install-deb.html
install_ssm_agent() {
   if [ "$enable_ssm" != "true" ]; then
      echo "SSM agent install skipped (enable_ssm=${enable_ssm})"
      return 0
   fi

   if systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then
      echo "SSM agent already running"
      return 0
   fi

   echo "Installing Amazon SSM agent"
   export DEBIAN_FRONTEND=noninteractive

   local arch deb_arch
   arch="$(uname -m)"
   case "$arch" in
      aarch64|arm64) deb_arch="debian_arm64" ;;
      x86_64|amd64) deb_arch="debian_amd64" ;;
      *) panic "Unsupported architecture for SSM agent: ${arch}" ;;
   esac

   local tmp_deb="/tmp/amazon-ssm-agent.deb"
   local regional_url="https://s3.${REGION}.amazonaws.com/amazon-ssm-${REGION}/latest/${deb_arch}/amazon-ssm-agent.deb"
   local global_url="https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/${deb_arch}/amazon-ssm-agent.deb"

   if ! curl -fsSL "$regional_url" -o "$tmp_deb"; then
      echo "Regional SSM package download failed, trying global URL"
      curl -fsSL "$global_url" -o "$tmp_deb" || panic "Unable to download amazon-ssm-agent.deb"
   fi

   dpkg -i "$tmp_deb" || apt-get install -y -qq -f || panic "Unable to install amazon-ssm-agent"
   systemctl enable --now amazon-ssm-agent || panic "Unable to enable amazon-ssm-agent"
   rm -f "$tmp_deb"
   echo "SSM agent installed successfully"
}

# Disabling source/dest check is what makes a NAT instance a NAT instance.
# See https://docs.aws.amazon.com/vpc/latest/userguide/VPC_NAT_Instance.html#EIP_Disable_SrcDestCheck
disable_source_dest_check() {
   echo "Disabling source/destination check"
   aws ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" --source-dest-check "{\"Value\": false}"
   if [ $? -ne 0 ]; then
      panic "Unable to disable source/dest check."
   fi
   echo "source/destination check disabled for $INSTANCE_ID"
}

# associate_eip() tries each provided EIP allocation id until it finds one that is not already associated.
function associate_eip() {
   echo "Associating an EIP from the pool of addresses"

   local eip=""
   local num_retries=10
   local sleep_len=60

   IFS=',' read -r -a eip_allocation_ids <<< "${eip_allocation_ids_csv}"

   # Retry the allocation operation $num_retries times with a $sleep_len wait between retries.
   # This is to handle any delays in releasing an EIP allocation during instance termination.
   for n in $(seq 1 "$num_retries"); do
      for eip_allocation_id in "${eip_allocation_ids[@]}"
      do
         eip=$(aws ec2 describe-addresses --allocation-ids "$eip_allocation_id" --query 'Addresses[0].PublicIp' --output text)
         echo "Trying IP $eip"
         aws ec2 associate-address --no-allow-reassociation --allocation-id "$eip_allocation_id" --instance-id "$INSTANCE_ID"
         if [ $? -eq 0 ]; then
            break
         fi
         echo "Failed to associate IP $eip"
         eip=""
      done
      if [ -n "$eip" ]; then
         break
      else
         echo "Unable to associate an EIP ($n of $num_retries attempts)."
         sleep "$sleep_len"
      fi
   done

   if [ -z "$eip" ]; then
      panic "Unable to associate an EIP!"
   fi

   echo "Associated EIP $eip with instance $INSTANCE_ID"
}

# When enable_nat_restore=true: replace then create (upstream Alternat).
# When enable_nat_restore=false: skip if 0.0.0.0/0 already exists; otherwise create.
configure_route_table() {
   echo "Configuring route tables (enable_nat_restore=${enable_nat_restore})"

   IFS=',' read -r -a route_table_ids <<< "${route_table_ids_csv}"

   for route_table_id in "${route_table_ids[@]}"
   do
      echo "Attempting to find route table $route_table_id"
      local rtb_id
      rtb_id=$(aws ec2 describe-route-tables --filters Name=route-table-id,Values="${route_table_id}" --query 'RouteTables[0].RouteTableId' --output text)
      if [ -z "$rtb_id" ] || [ "$rtb_id" = "None" ]; then
         panic "Unable to find route table $route_table_id"
      fi

      echo "Found route table $rtb_id"

      if [ "$enable_nat_restore" = "false" ]; then
         local existing_target
         existing_target=$(aws ec2 describe-route-tables \
           --route-table-ids "$rtb_id" \
           --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[NatGatewayId,InstanceId,GatewayId,NetworkInterfaceId] | [0]' \
           --output text)

         if [ -n "$existing_target" ] && [ "$existing_target" != "None" ]; then
            echo "Default route 0.0.0.0/0 already exists on $rtb_id (target: $existing_target); skipping (enable_nat_restore=false)"
            continue
         fi

         echo "No default route found. Creating route to 0.0.0.0/0 via instance $INSTANCE_ID for $rtb_id"
         aws ec2 create-route --route-table-id "$rtb_id" --instance-id "$INSTANCE_ID" --destination-cidr-block 0.0.0.0/0
         if [ $? -eq 0 ]; then
            echo "Successfully created route to 0.0.0.0/0 via instance $INSTANCE_ID for route table $rtb_id"
         else
            panic "Unable to create the route!"
         fi
         continue
      fi

      echo "Replacing route to 0.0.0.0/0 for $rtb_id"
      aws ec2 replace-route --route-table-id "$rtb_id" --instance-id "$INSTANCE_ID" --destination-cidr-block 0.0.0.0/0
      if [ $? -eq 0 ]; then
         echo "Successfully replaced route to 0.0.0.0/0 via instance $INSTANCE_ID for route table $rtb_id"
         continue
      fi

      echo "Unable to replace route. Attempting to create route"
      aws ec2 create-route --route-table-id "$rtb_id" --instance-id "$INSTANCE_ID" --destination-cidr-block 0.0.0.0/0
      if [ $? -eq 0 ]; then
         echo "Successfully created route to 0.0.0.0/0 via instance $INSTANCE_ID for route table $rtb_id"
      else
         panic "Unable to replace or create the route!"
      fi
   done
}

ASG_LIFECYCLE_HOOK_NAME="NATInstanceLaunchScript"
complete_asg_lifecycle_action() {
  if [[ -z "$1" ]]; then
    echo "No lifecycle action result given"
  fi

  local auto_scaling_group_name
  auto_scaling_group_name="$(get_imds_optional tags/instance/aws:autoscaling:groupName)"
  if [[ -z "${auto_scaling_group_name}" ]]; then
    echo "Could not detect auto scaling group name"
  fi

  local output status
  output="$(aws autoscaling complete-lifecycle-action \
    --lifecycle-hook-name "${ASG_LIFECYCLE_HOOK_NAME}" \
    --auto-scaling-group-name "${auto_scaling_group_name}" \
    --lifecycle-action-result "$1" \
    --instance-id "${INSTANCE_ID}" 2>&1)"
  status=$?
  if [[ $status -ne 0 ]]; then
    if grep -q "No active Lifecycle Action found" <<< "${output}"; then
      echo "Ignoring missing ASG lifecycle action"
    else
      echo "${output}"
      echo "Failed to complete ASG lifecycle action"
    fi
  fi

  echo "Completed ASG lifecycle action with result $1"
}

# debian-13-base: /opt/scripts/cloud_detect_lib.sh
# shellcheck source=/dev/null
source /opt/scripts/cloud_detect_lib.sh
# cloud_detect_lib enables set -euo pipefail; Alternat helpers rely on explicit $? checks.
set +e
set +u

# Older AMI builds may lack helpers added later.
if ! declare -F get_imds >/dev/null 2>&1; then
  get_imds() {
    curl $CURL_OPTS -H "$HEADER" "$URI/latest/meta-data/$1"
  }
fi
if ! declare -F get_imds_optional >/dev/null 2>&1; then
  get_imds_optional() {
    curl $CURL_OPTS -H "$HEADER" "$URI/latest/meta-data/$1" 2>/dev/null || true
  }
fi
if [ -z "${INSTANCE_ID:-}" ]; then
  INSTANCE_ID="$(get_imds instance-id)"
fi

export AWS_DEFAULT_OUTPUT="text"
# https://docs.aws.amazon.com/cli/latest/userguide/cli-usage-pagination.html#cli-usage-pagination-clientside
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${REGION}"

echo "Running on instance ${INSTANCE_ID} az=${AZ} region=${REGION}"

CONFIG_FILE="/etc/alternat.conf"
load_config

echo "Beginning self-managed NAT configuration (ak-debian-13-base / nftables)"
configure_nat
install_ssm_agent
disable_source_dest_check
associate_eip
configure_route_table
complete_asg_lifecycle_action CONTINUE
echo "Configuration completed successfully!"
