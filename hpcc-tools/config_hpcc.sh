#!/bin/bash

SCRIPT_DIR=$(dirname $0)

function create_ips_string()
{
   IPS=
   [ ! -e "$1" ] &&  return
   while read ip
   do
      ip=$(echo $ip | sed 's/[[:space:]]//g') 
      [ -n "$ip" ] && IPS="${IPS}${ip}\\;"
   done < $1
}

function create_envxml()
{
   [ -e ${roxie_ips} ] && roxie_nodes=$(cat ${roxie_ips} | wc -l)
   [ -e ${esp_ips} ] && esp_nodes=$(cat ${esp_ips} | wc -l)
   [ -z "$roxie_nodes" ] && roxie_nodes=0
   [ -z "$esp_nodes" ] && esp_nodes=0

   cmd="$SUDOCMD ${HPCC_HOME}/sbin/envgen -env ${CONFIG_DIR}/${ENV_XML_FILE}   \
       -override roxie,@roxieMulticastEnabled,false -override thor,@replicateOutputs,true \
       -override esp,@method,htpasswd -override thor,@replicateAsync,true                 \
       -thornodes ${thor_nodes} -slavesPerNode ${slaves_per_node} -espnodes ${esp_nodes}  \
       -roxienodes ${roxie_nodes} -supportnodes ${support_nodes} -roxieondemand 1" 

    cmd="$cmd -ip $dali_ip" 
    if [ $thor_nodes -gt 0 ]
    then
       create_ips_string ${thor_ips}
       cmd="$cmd -assign_ips thor ${dali_ip}\;${IPS}"
    fi

    if [ $roxie_nodes -gt 0 ]
    then
       create_ips_string ${roxie_ips}
       cmd="$cmd -assign_ips roxie $IPS"
    fi

    if [ $esp_nodes -gt 0 ]
    then
       create_ips_string ${esp_ips}
       cmd="$cmd -assign_ips esp $IPS"
    fi

    echo "$cmd" 
    eval "$cmd"

}

#------------------------------------------
# Need root or sudo
#
SUDOCMD=
[ $(id -u) -ne 0 ] && SUDOCMD=sudo


#------------------------------------------
# LOG
#
LOG_FILE=/tmp/config_hpcc.log
touch ${LOG_FILE}
exec 2>$LOG_FILE
set -x


#------------------------------------------
# Start sshd
#
ps -efa | grep -v sshd |  grep -q sshd
[ $? -ne 0 ] && $SUDOCMD mkdir -p /var/run/sshd; $SUDOCMD  /usr/sbin/sshd -D &

#------------------------------------------
# Collect conainters' ips
#

if [ -z "$1" ] || [ "$1" != "-x" ]
then
   trials=3
    while [ $trials -gt 0 ]
    do
       ${SCRIPT_DIR}/get_ips.sh
       ${SCRIPT_DIR}/get_ips.py
       [ $? -eq 0 ] && break  
       trials=$(expr $trials \- 1)
       sleep 5
    done
fi

#------------------------------------------
# Create HPCC components file
#
hpcc_config=$(ls /tmp/ips | tr '\n' ',')
echo "cluster_node_types=${hpcc_config%,}" > /tmp/hpcc.conf

#------------------------------------------
# Setup Ansible hosts
#
${SCRIPT_DIR}/ansible/setup.sh -d /tmp/ips -c /tmp/hpcc.conf
export ANSIBLE_HOST_KEY_CHECKING=False


dali_ip=$(cat /etc/ansible/ips/dali)
thor_ips=/etc/ansible/ips/thor

#------------------------------------------
# Restore HPCC configuration files /etc/HPCCSystems
# which is NFS share
#
if [ ! -e /etc/HPCCSystems/environment.conf ]; then
   cp -r /etc/HPCCSystems.bk/* /etc/HPCCSystems/ 
   chown -R hpcc:hpcc /etc/HPCCSystems/
fi

if [ ! -e /etc/HPCCSystems_Roxie/environment.conf ]; then
   cp -r /etc/HPCCSystems.bk/* /etc/HPCCSystems_Roxie/ 
   chown -R hpcc:hpcc /etc/HPCCSystems_Roxie
fi

if [ ! -e /etc/HPCCSystems_Esp/environment.conf ]; then
   cp -r /etc/HPCCSystems.bk/* /etc/HPCCSystems_Esp/ 
   chown -R hpcc:hpcc /etc/HPCCSystems_Esp
fi


#------------------------------------------
# Stop HPCC on all nodes
#
ansible-playbook /opt/hpcc-tools/ansible/stop_hpcc.yaml --extra-vars "hosts=non-dali" 
ansible-playbook /opt/hpcc-tools/ansible/stop_hpcc.yaml --extra-vars "hosts=dali" 


#------------------------------------------
# Parameters to envgen
#
HPCC_HOME=/opt/HPCCSystems
ENV_XML_FILE=environment.xml


[ -e ${thor_ips} ] && thor_nodes=$(cat ${thor_ips} | wc -l)
support_nodes=1
slaves_per_node=1
[ -n "$SLAVES_PER_NODE" ] && slaves_per_node=${SLAVES_PER_NODE}
[ -z "$thor_nodes" ] && thor_nodes=0

#------------------------------------------
# Get load balancer ips for roxie and esp
#
lb_ips=/etc/ansible/lb-ips 
[ ! -d ${lb_ips} ] && cp -r  /etc/ansible/ips $lb_ips 
[ -e ${lb_ips}/roxie ] && [ -n "$ROXIE_SERVICE_HOST" ] && echo  ${ROXIE_SERVICE_HOST} > ${lb_ips}/roxie
[ -e ${lb_ips}/esp ] && [ -n "$ESP_SERVICE_HOST" ] && echo  ${ESP_SERVICE_HOST} > ${lb_ips}/esp

#------------------------------------------
# Generate environment for all nodes with
# roxie and esp load balancer ips
#
CONFIG_DIR=/etc/HPCCSystems
roxie_ips=${lb_ips}/roxie
esp_ips=${lb_ips}/esp
create_envxml
chown -R hpcc:hpcc $CONFIG_DIR

#------------------------------------------
# Generate environment for all real ips
#
esp_ips=/etc/ansible/ips/esp
roxie_ips=/etc/ansible/ips/roxie
CONFIG_DIR=/etc/HPCCSystems/real
[ ! -d $CONFIG_DIR ] && cp -r /etc/HPCCSystems.bk $CONFIG_DIR
create_envxml
chown -R hpcc:hpcc $CONFIG_DIR
CONFIG_DIR=/etc/HPCCSystems

#------------------------------------------
# Createe environment roxie
#
CONFIG_DIR=/etc/HPCCSystems_Roxie
cp -r /etc/HPCCSystems/* ${CONFIG_DIR}/
if [ -n "$ROXIE_SERVICE_HOST" ]; then
  sed  "s/${ROXIE_SERVICE_HOST}/localhost/g"  /etc/HPCCSystems/environment.xml > ${CONFIG_DIR}/environment.xml
fi
chown -R hpcc:hpcc $CONFIG_DIR

#------------------------------------------
# Createe environment esp
#
CONFIG_DIR=/etc/HPCCSystems_Esp
cp -r /etc/HPCCSystems/* ${CONFIG_DIR}/
if [ -n "$ESP_SERVICE_HOST" ]; then
  sed  "s/${ESP_SERVICE_HOST}/localhost/g"  /etc/HPCCSystems/environment.xml > ${CONFIG_DIR}/environment.xml
fi
chown -R hpcc:hpcc $CONFIG_DIR

#------------------------------------------
# Start hpcc 
#
# Need force to use sudo for now since $USER is not defined:
# Should fix it in Platform code to use id instead of $USER
# Need stop first since if add contaners other thor and roxie containers are already up.
# Force them to read environemnt.xml by stop and start
#$SUDOCMD su - hpcc -c  "${HPCC_HOME}/sbin/hpcc-run.sh stop"
#$SUDOCMD su - hpcc -c  "${HPCC_HOME}/sbin/hpcc-run.sh start"

ansible-playbook /opt/hpcc-tools/ansible/start_hpcc.yaml --extra-vars "hosts=dali" 
ansible-playbook /opt/hpcc-tools/ansible/start_hpcc.yaml --extra-vars "hosts=non-dali" 



set +x
$SUDOCMD /opt/HPCCSystems/sbin/configgen -env /etc/HPCCSystems/environment.xml -listall2
echo "HPCC cluster configuration is done."
