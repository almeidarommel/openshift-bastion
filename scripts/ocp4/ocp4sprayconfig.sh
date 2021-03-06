#!/bin/bash

OCP_LATEST_VERSION=$(curl -s ${OCP_BASEURL}/release.txt | grep 'Version: ' | awk '{print $2}')
OCP_VERSION_RELEASE_UPDATE="${OCP_VERSION}.${OCP_VERSION_RELEASE}.${OCP_RELEASE_UPDATE_NUMBER}"
OCP_API="api api-int"
OCP_APPS='*.apps'

if [ ${OCP_VERSION} -eq 4 ]
then
  nodes="_etcd-server-ssl._tcp ${BOOTSTRAP_NAME} ${OCP_API} ${OCP_APPS} ${MASTERS_DNS_NAMES} ${ETCD_DNS_NAMES} ${APP_NODES_DNS_NAMES} ${INFRA_NODES_DNS_NAMES}"
else
  nodes="_etcd-server-ssl._tcp  ${OCP_API} ${OCP_APPS} ${MASTERS_DNS_NAMES} ${ETCD_DNS_NAMES} ${APP_NODES_DNS_NAMES} ${INFRA_NODES_DNS_NAMES}"
fi

echo "Setting permission to $(whoami) user "
sudo chown $(whoami):$(whoami) ${OCP_USER_PATH} -R

ifFQDNisActive(){
  if [ ${node} == "_etcd-server-ssl._tcp" ]
  then
    fqdn="${node}.${CLUSTER_ID}.${BASE_DOMAIN} SRV"
  else
    fqdn="${node}.${CLUSTER_ID}.${BASE_DOMAIN}"
  fi

  ip=`dig ${fqdn} +short`
  
  [[ -z "$ip" ]] && echo "false" || echo "true"
}

list_cluster_nodes_names(){
  echo "------------------list_cluster_nodes_names-------------------------"
  for node in ${nodes}
  do
    echo "$node.${CLUSTER_ID}.${BASE_DOMAIN}"
  done
  echo "------------------END Listing Cluster DNS Names---------------------"
}

checking_cluster_dns_nodes_names() {
  
  list_cluster_nodes_names

  echo "------------------checking_cluster_dns_nodes_names------------------------"
  for node in ${nodes}
  do
    fqdnActive=$(ifFQDNisActive)
    if [  "$fqdnActive" == "true" ]
    then
      echo "[DNS OK] - ${node}.${CLUSTER_ID}.${BASE_DOMAIN}"
    else
      echo "----------------------------------------------------------------------------"
      echo "[DNS FAIL] - ${node}.${CLUSTER_ID}.${BASE_DOMAIN}"
      echo "!!For proceed the installation you need to configure all DNS listed before!!"
      echo "----------------------------------------------------------------------------"
      exit 1
    fi  
  done
  echo "------------------END checking_cluster_dns_nodes_names---------------------"
}

configuring_webserver_nginx(){
  echo "------------------configuring_webserver_nginx------------------------"

  echo "Creating Ignition and Installers Nginx Paths"
  mkdir -p /var/www/html/ignition
  mkdir -p /var/www/html/installers

  echo "------------------End configuring_webserver_nginx------------------------"
}

downloading_installers(){
  echo "------------------downloading_installers------------------------"

  echo "Creating folder installers"
  mkdir -p ${OCP_SHARED_FOLDER}/installers/

  if [ ! -f ${OCP_SHARED_FOLDER}/installers/openshift-install ]
  then
    echo "Downloading openshift-install cli"
    curl -s ${OCP_BASEURL}/openshift-client-linux-${OCP_VERSION_RELEASE_UPDATE}.tar.gz | tar -xzf - -C ${OCP_SHARED_FOLDER}/installers/ oc kubectl
    curl -s ${OCP_BASEURL}/openshift-install-linux-${OCP_VERSION_RELEASE_UPDATE}.tar.gz | tar -xzf - -C ${OCP_SHARED_FOLDER}/installers/ openshift-install

    echo "Downloading RHCOS = OVA  | ISO | RAW.GZ"
    curl ${RHCOS_PACKAGES}/rhcos-${OCP_VERSION_RELEASE_UPDATE}-x86_64-vmware.x86_64.ova -o ${OCP_SHARED_FOLDER}/installers/rhcos.ova -#
    curl ${RHCOS_PACKAGES}/rhcos-${OCP_VERSION_RELEASE_UPDATE}-x86_64-metal.x86_64.raw.gz -o ${OCP_SHARED_FOLDER}/installers/bios.raw.gz -#
    curl ${RHCOS_PACKAGES}/rhcos-${OCP_VERSION_RELEASE_UPDATE}-x86_64-installer.x86_64.iso -o ${OCP_SHARED_FOLDER}/installers/rhcos.iso -#
  else
    echo "Download error"
    exit 1
  fi

  echo "Copying RHCOS = OVA  | ISO | RAW.GZ to /var/www/html/installers"
  cp -rv ${OCP_SHARED_FOLDER}/installers/rhcos.ova /var/www/html/installers
  cp -rv ${OCP_SHARED_FOLDER}/installers/bios.raw.gz /var/www/html/installers
  cp -rv ${OCP_SHARED_FOLDER}/installers/rhcos.iso /var/www/html/installers
 
  echo "------------------End downloading_installers------------------------"
}

settingSshKeyOnInstallConfigFile(){
  echo "Enable SSH KEYS"

  if [ ! -f ${OCP_SHARED_FOLDER}/auth/id_rsa ]
  then
    ssh-keygen -t rsa -b 4096 -N '' -f ${OCP_USER_PATH}/.ssh/id_rsa

    eval "$(ssh-agent -s)"
    ssh-add  ${OCP_USER_PATH}/.ssh/id_rsa

    echo "Copying ssh keys ${OCP_SHARED_FOLDER}/auth/"
    mkdir -p ${OCP_SHARED_FOLDER}/auth/
    cp -rv ${OCP_USER_PATH}/.ssh/id_rsa* ${OCP_SHARED_FOLDER}/auth/
  else
    mkdir -p ${OCP_USER_PATH}/.ssh/
    cp -rv ${OCP_SHARED_FOLDER}/auth/id_rsa*  ${OCP_USER_PATH}/.ssh/
  fi

  chmod 700  ${OCP_USER_PATH}/.ssh/
  chmod 600  ${OCP_USER_PATH}/.ssh/id_rsa
  chmod 644  ${OCP_USER_PATH}/.ssh/id_rsa.pub
}

add_ssh_key_to_install_config_yaml(){

  echo "Settin SSH Key Pub on ${OCP_USER_PATH}/playbooks/install-config.yaml"
  ssh_key_rsa_pub=`cat ${OCP_USER_PATH}/.ssh/id_rsa.pub`
  sed -i "s|OCP_SSH_KEY|$ssh_key_rsa_pub|" ${OCP_USER_PATH}/playbooks/install-config.yaml
  
  mkdir -p ${OCP_SHARED_FOLDER}/ignitions/
  cp -rv ${OCP_USER_PATH}/playbooks/install-config.yaml ${OCP_SHARED_FOLDER}/ignitions/

}

generate_manisfests_files(){

  echo "------------------generate_manisfests_files------------------------"
  
  ${OCP_SHARED_FOLDER}/installers/openshift-install create manifests --dir=${OCP_SHARED_FOLDER}/ignitions/
  sed -i 's/mastersSchedulable: true/mastersSchedulable: false/g' ${OCP_SHARED_FOLDER}/ignitions/manifests/cluster-scheduler-02-config.yml
  
  echo "------------------END generate_manisfests_files------------------------"
}

generate_ignitions_files(){

  echo "------------------generate_ignitions_files------------------------"

  ${OCP_SHARED_FOLDER}/installers/openshift-install create ignition-configs --dir=${OCP_SHARED_FOLDER}/ignitions/

  echo "Generating secondary Ignition config file for your bootstrap node to your computer"
  cat <<EOF > ${OCP_SHARED_FOLDER}/ignitions/append-bootstrap.ign
  {
    "ignition": {
      "config": {
        "append": [
          {
            "source": "http://${OCP_WEBSERVER_IP}/ignition/bootstrap.ign",
            "verification": {}
          }
        ]
      },
      "timeouts": {},
      "version": "2.1.0"
    },
    "networkd": {},
    "passwd": {},
    "storage": {},
    "systemd": {}
  }
EOF

  echo "Generating files in base64"
  for i in append-bootstrap master worker
  do
      base64 -w0 < ${OCP_SHARED_FOLDER}/ignitions/$i.ign > ${OCP_SHARED_FOLDER}/ignitions/$i.64
  done

  echo "------------------END generate_ignitions_files------------------------"
}


add_ignitions_files_to_www_nginx_path(){
  echo "Copy ${OCP_USER_PATH}/*.ign to WebServer"
  cp -rv ${OCP_SHARED_FOLDER}/ignitions/*.ign /var/www/html/ignition/
  cp -rv ${OCP_SHARED_FOLDER}/ignitions/*.64 /var/www/html/ignition/
}

configurations_generated(){
    
  echo "--------------------------------" >> ${OCP_SHARED_FOLDER}/configurations.txt
  echo "Files configurated on:  ${OCP_USER_PATH}/ocp/sharedfolder/" >> ${OCP_SHARED_FOLDER}/configurations.txt
  echo "URL to access Ignations: http://${OCP_WEBSERVER_IP}/ignition/" >> ${OCP_SHARED_FOLDER}/configurations.txt
  echo "URL to access RHCOS Installers: http://${OCP_WEBSERVER_IP}/installers/" >> ${OCP_SHARED_FOLDER}/configurations.txt
  echo "Openshift Credentials Files:  ${OCP_USER_PATH}/ocp/sharedfolder/ignitions/auth" >> ${OCP_SHARED_FOLDER}/configurations.txt
  list_cluster_nodes_names >> ${OCP_SHARED_FOLDER}/configurations.txt
  echo "--------------------------------" >> ${OCP_SHARED_FOLDER}/configurations.txt
  
  echo "Cluster Openshift Configurations on file: ${OCP_SHARED_FOLDER}/configurations.txt "
  cat ${OCP_SHARED_FOLDER}/configurations.txt
}

setKubeconfigOnEnviroment(){
  mkdir -p ${OCP_USER_PATH}/.kube/
  cp -rv ${OCP_SHARED_FOLDER}/ignitions/auth/kubeconfig  ${OCP_USER_PATH}/.kube/config
  sudo cp ${OCP_SHARED_FOLDER}/installers/oc /usr/bin/
}

checking_cluster_dns_nodes_names

configuring_webserver_nginx

downloading_installers

settingSshKeyOnInstallConfigFile

if [ ! -f ${OCP_SHARED_FOLDER}/configurations.txt ]
then
    add_ssh_key_to_install_config_yaml

    generate_manisfests_files

    generate_ignitions_files
else
  echo "There is configuration files on path: ${OCP_SHARED_FOLDER}/"
  echo "!!You need delete and running again for create the Openshift Enviroment!!"
fi

add_ignitions_files_to_www_nginx_path

configurations_generated

setKubeconfigOnEnviroment