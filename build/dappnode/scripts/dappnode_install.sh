#!/bin/bash

DAPPNODE_DIR="/usr/src/dappnode"
DAPPNODE_CORE_DIR="${DAPPNODE_DIR}/DNCORE"
LOGFILE="${DAPPNODE_DIR}/dappnode_install.log"
MOTD_FILE="/etc/motd"
PKGS=(BIND IPFS VPN WAMP DAPPMANAGER ADMIN WIFI)
CONTENT_HASH_PKGS=(geth openethereum nethermind)
CONTENT_HASH_FILE="${DAPPNODE_CORE_DIR}/packages-content-hash.csv"

if [ "$UPDATE" = true ]; then
    echo "Cleaning for update..."
    rm -rf $LOGFILE
    rm -rf ${DAPPNODE_CORE_DIR}/docker-compose-*.yml
    rm -rf ${DAPPNODE_CORE_DIR}/dappnode_package-*.json
    rm -rf ${DAPPNODE_CORE_DIR}/*.tar.xz
    rm -rf ${DAPPNODE_CORE_DIR}/.dappnode_profile
    rm -rf ${CONTENT_HASH_FILE}
fi

mkdir -p $DAPPNODE_DIR
mkdir -p $DAPPNODE_CORE_DIR
mkdir -p "${DAPPNODE_CORE_DIR}/scripts"
mkdir -p "${DAPPNODE_DIR}/config"

PROFILE_BRANCH="master"
PROFILE_URL="https://raw.githubusercontent.com/dappnode/DAppNode_Installer/${PROFILE_BRANCH}/build/scripts/.dappnode_profile"
PROFILE_FILE="${DAPPNODE_CORE_DIR}/.dappnode_profile"
WGET="wget -q --show-progress --progress=bar:force"
SWGET="wget -q -O-"

function valid_ip() {
    local ip=$1
    local stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && \
        ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

if [[ ! -z $STATIC_IP ]]; then
    if valid_ip $STATIC_IP; then
        echo $STATIC_IP >${DAPPNODE_DIR}/config/static_ip
    else
        echo "The static IP provided: ${STATIC_IP} is not valid."
        exit 1
    fi
fi

[ -f $PROFILE_FILE ] || ${WGET} -O ${PROFILE_FILE} ${PROFILE_URL}

source "${PROFILE_FILE}"

# The indirect variable expansion used in ${!ver##*:} allows us to use versions like 'dev:development'
# If such variable with 'dev:'' suffix is used, then the component is built from specified branch or commit.
for comp in "${PKGS[@]}"; do
    ver="${comp}_VERSION"
    eval "${comp}_URL=\"https://github.com/dappnode/DNP_${comp}/releases/download/v${!ver}/${comp,,}.dnp.dappnode.eth_${!ver}.tar.xz\""
    eval "${comp}_YML=\"https://github.com/dappnode/DNP_${comp}/releases/download/v${!ver}/docker-compose.yml\""
    eval "${comp}_MANIFEST=\"https://github.com/dappnode/DNP_${comp}/releases/download/v${!ver}/dappnode_package.json\""
    eval "${comp}_YML_FILE=\"${DAPPNODE_CORE_DIR}/docker-compose-${comp,,}.yml\""
    eval "${comp}_FILE=\"${DAPPNODE_CORE_DIR}/${comp,,}.dnp.dappnode.eth_${!ver##*:}.tar.xz\""
    eval "${comp}_MANIFEST_FILE=\"${DAPPNODE_CORE_DIR}/dappnode_package-${comp,,}.json\""
done

dappnode_core_build() {
    for comp in "${PKGS[@]}"; do
        ver="${comp}_VERSION"
        file="${comp}_FILE"
        if [[ ${!ver} == dev:* ]]; then
            echo "Cloning & building DNP_${comp}..."
            if ! dpkg -s git >/dev/null 2>&1; then
                apt-get install -y git
            fi
            TMPDIR=$(mktemp -d)
            pushd $TMPDIR
            git clone -b "${!ver##*:}" https://github.com/dappnode/DNP_${comp}
            # Change version in YAML to the custom one
            sed -i "s~^\(\s*image\s*:\s*\).*~\1${comp,,}.dnp.dappnode.eth:${!ver##*:}~" DNP_${comp}/docker-compose.yml
            docker-compose -f ./DNP_${comp}/docker-compose.yml build
            cp ./DNP_${comp}/docker-compose.yml $DAPPNODE_CORE_DIR/docker-compose-${comp,,}.yml
            cp ./DNP_${comp}/dappnode_package.json $DAPPNODE_CORE_DIR/dappnode_package-${comp,,}.json
            rm -r ./DNP_${comp}
            popd
        fi
    done
}

dappnode_core_download() {
    for comp in "${PKGS[@]}"; do
        ver="${comp}_VERSION"
        if [[ ${!ver} != dev:* ]]; then
            # Download DAppNode Core Images if it's needed
            eval "[ -f \$${comp}_FILE ] || $WGET -O \$${comp}_FILE \$${comp}_URL"
            # Download DAppNode Core docker-compose yml files if it's needed
            eval "[ -f \$${comp}_YML_FILE ] || $WGET -O \$${comp}_YML_FILE \$${comp}_YML"
            # Download DAppNode Core manifest files if it's needed
            eval "[ -f \$${comp}_MANIFEST_FILE ] || $WGET -O \$${comp}_MANIFEST_FILE \$${comp}_MANIFEST"
        fi
    done
}

dappnode_core_load() {
    for comp in "${PKGS[@]}"; do
        ver="${comp}_VERSION"
        if [[ ${!ver} != dev:* ]]; then
            eval "[ ! -z \$(docker images -q ${comp,,}.dnp.dappnode.eth:${!ver##*:}) ] || docker load -i \$${comp}_FILE 2>&1 | tee -a \$LOGFILE"
        fi
    done

    # Delete build lines from yml
    sed -i '/build:\|context:\|dockerfile/d' $DAPPNODE_CORE_DIR/*.yml | tee -a $LOGFILE
}

customMotd() {
    if [ -f ${MOTD_FILE} ]; then
        cat <<EOF >${MOTD_FILE}
 ___   _             _  _         _
|   \ /_\  _ __ _ __| \| |___  __| |___
| |) / _ \| '_ \ '_ \ .  / _ \/ _  / -_)
|___/_/ \_\ .__/ .__/_|\_\___/\__,_\___|
          |_|  |_|
EOF
    fi
}

addSwap() {
    # Is swap enabled?
    IS_SWAP=$(swapon --show | wc -l)

    # if not then create it
    if [ $IS_SWAP -eq 0 ]; then
        echo -e '\e[32mSwap not found. Adding swapfile.\e[0m'
        #RAM=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        #SWAP=$(($RAM * 2))
        SWAP=8388608
        fallocate -l ${SWAP}k /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap defaults 0 0' >>/etc/fstab
    else
        echo -e '\e[32mSwap found. No changes made.\e[0m'
    fi
}

dappnode_start() {
    echo -e "\e[32mDAppNode starting...\e[0m" 2>&1 | tee -a $LOGFILE
    source "${PROFILE_FILE}" >/dev/null 2>&1
    docker-compose $DNCORE_YMLS up -d 2>&1 | tee -a $LOGFILE
    echo -e "\e[32mDAppNode started\e[0m" 2>&1 | tee -a $LOGFILE

    # Show credentials to the user on login
    USER=$(cat /etc/passwd | grep 1000 | cut -f 1 -d:)
    [ ! -z $USER ] && PROFILE=/home/$USER/.profile || PROFILE=/root/.profile

    if ! grep -q '.dappnode_profile' "$PROFILE"; then
        echo "########          DAPPNODE PROFILE          ########" >>$PROFILE
        echo -e "source ${DAPPNODE_CORE_DIR}/.dappnode_profile\n" >>$PROFILE
    fi

    sed -i '/return/d' $PROFILE_FILE | tee -a $LOGFILE

    if ! grep -q 'http://my.dappnode/' "$PROFILE_FILE"; then
        echo "echo -e \"\n\e[32mTo get a VPN profile file and connect to your DAppNode, run the following command:\e[0m\"" >>$PROFILE_FILE
        echo "echo -e \"\n\"" >>$PROFILE_FILE
        echo "echo -e \"\n\e[32mdappnode_connect\e[0m\"" >>$PROFILE_FILE
        echo "echo -e \"\n\"" >>$PROFILE_FILE
        echo "echo -e \"\n\e[32mOnce connected through the VPN (OpenVPN) you can access to the administration console by following this link:\e[0m\"" >>$PROFILE_FILE
        echo "echo -e \"\nhttp://my.dappnode/\n\"" >>$PROFILE_FILE
        echo -e "return\n" >>$PROFILE_FILE
    fi
    # Show credentials at shell installation
    [ ! -f "/usr/src/dappnode/iso_install.log" ] && docker run --rm -v dncore_vpndnpdappnodeeth_data:/usr/src/app/secrets $(docker inspect DAppNodeCore-vpn.dnp.dappnode.eth --format '{{.Config.Image}}') getAdminCredentials

    # Delete dappnode_install.sh execution from rc.local if exists, and is not the unattended firstboot
    if [ -f "/etc/rc.local" ] && [ ! -f "/usr/src/dappnode/.firstboot" ]; then
        sed -i '/\/usr\/src\/dappnode\/scripts\/dappnode_install.sh/d' /etc/rc.local 2>&1 | tee -a $LOGFILE
    fi
}

installExtra() {
    if [ -d "/usr/src/dappnode/extra" ]; then
        dpkg -i /usr/src/dappnode/extra/*.deb 2>&1 | tee -a $LOGFILE
    fi
}

grabContentHashes() {
    if [ ! -f "${CONTENT_HASH_FILE}" ]; then
        for comp in "${CONTENT_HASH_PKGS[@]}"; do
            CONTENT_HASH=$(eval ${SWGET} https://github.com/dappnode/DAppNodePackage-${comp}/releases/latest/download/content-hash)
            if [ -z $CONTENT_HASH ]; then
                echo "ERROR! Failed to find content hash of ${comp}." 2>&1 | tee -a $LOGFILE
                exit 1
            fi
            echo "${comp}.dnp.dappnode.eth,${CONTENT_HASH}" >>${CONTENT_HASH_FILE}
        done
    fi
}

##############################################
##############################################
####             SCRIPT START             ####
##############################################
##############################################

echo -e "\e[32m\n##############################################\e[0m" 2>&1 | tee -a $LOGFILE
echo -e "\e[32m##############################################\e[0m" 2>&1 | tee -a $LOGFILE
echo -e "\e[32m####          DAPPNODE INSTALLER          ####\e[0m" 2>&1 | tee -a $LOGFILE
echo -e "\e[32m##############################################\e[0m" 2>&1 | tee -a $LOGFILE
echo -e "\e[32m##############################################\e[0m" 2>&1 | tee -a $LOGFILE

echo -e "\e[32mCreating swap memory...\e[0m" 2>&1 | tee -a $LOGFILE
addSwap

echo -e "\e[32mCustomizing login...\e[0m" 2>&1 | tee -a $LOGFILE
customMotd

echo -e "\e[32mInstalling extra packages...\e[0m" 2>&1 | tee -a $LOGFILE
installExtra

echo -e "\e[32mGrabbing latest content hashes...\e[0m" 2>&1 | tee -a $LOGFILE
grabContentHashes

echo -e "\e[32mBuilding DAppNode Core if needed...\e[0m" 2>&1 | tee -a $LOGFILE
dappnode_core_build

echo -e "\e[32mDownloading DAppNode Core...\e[0m" 2>&1 | tee -a $LOGFILE
dappnode_core_download

echo -e "\e[32mLoading DAppNode Core...\e[0m" 2>&1 | tee -a $LOGFILE
dappnode_core_load

if [ ! -f "/usr/src/dappnode/.firstboot" ]; then
    echo -e "\e[32mDAppNode installed\e[0m" 2>&1 | tee -a $LOGFILE
    dappnode_start
fi

# Run test in interactive terminal
if [ -f "/usr/src/dappnode/.firstboot" ]; then
    openvt -s -w /usr/src/dappnode/scripts/dappnode_test_install.sh
fi

echo -e "\n\e[32mOnce connected through the VPN (OpenVPN) you can access to the administration console by following this link:\e[0m"
echo -e "\nhttp://my.dappnode/\n"

exit 0
