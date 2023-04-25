#!/bin/bash

####################################
### Script Name: trojan-go-docker.sh
### Author: Bitwild
### Date: 2023/04/25
####################################

# set -x
set -e
set -u
set -o pipefail

INSTALL_DIR="/data/Trojan-Go-Docker"

if [ ${EUID} -ne 0 ]; then
    echo "You should execute this script as root."
    exit 1
fi

function get_args {
    read -r -p "Input your domain:" DOMAIN
    if [ -z "${DOMAIN}" ]; then
        echo "Domain not specified, please specify."
        get_args
    fi

    read -r -p "Input your password:" PASSWORD
    if [ -z "${PASSWORD}" ]; then
        echo "Password not specified, please specify."
        get_args
    fi
}

function prepare_dirs {
    mkdir -p ${INSTALL_DIR}/acme.sh/data/cert
    mkdir -p ${INSTALL_DIR}/nginx/data/html
    mkdir -p ${INSTALL_DIR}/nginx/data/logs
    mkdir -p ${INSTALL_DIR}/trojan-go/data
    cd ${INSTALL_DIR}
}

function install_pre_reqs {
    local pre_reqs="curl wget unzip"
    if [ "$(command -v apt)" ]; then
        apt-get install -y ${pre_reqs}
    elif [ "$(command -v yum )" ]; then
        yum install -y ${pre_reqs}
    fi

    if [ ! "$(command -v docker )" ]; then
        curl -Lso- https://get.docker.com | bash
        systemctl enable docker
        systemctl start docker
    fi
}

function config_docker_compose {

echo "DOMAIN=${DOMAIN}" > ${INSTALL_DIR}/.env

cat > ${INSTALL_DIR}/docker-compose.yml <<-EOF
version: '3.9'

services:

  acme.sh:
    container_name: acme.sh
    image: neilpang/acme.sh
    restart: always
    network_mode: host
    volumes:
      - ./acme.sh/data:/acme.sh
    command:
      - daemon

  nginx:
    container_name: nginx 
    image: nginx
    restart: always
    network_mode: host
    volumes:
      - ./nginx/data/html:/usr/share/nginx/html
      - ./nginx/data/logs:/var/log/nginx

  trojan-go:
    container_name: trojan-go
    image: p4gefau1t/trojan-go
    restart: always
    network_mode: host
    volumes:
      - ./trojan-go/data:/etc/trojan-go
      - ./trojan-go/data/update_geoip.sh:/etc/periodic/daily/update_geoip.sh
      - ./acme.sh/data/cert:/etc/cert
    depends_on:
      - nginx
EOF
}

function config_acme {
    docker run --rm -it -v ./acme.sh/data:/acme.sh --net=host neilpang/acme.sh --register-account -m my@example.com
    docker run --rm -it -v ./acme.sh/data:/acme.sh --net=host neilpang/acme.sh --issue -d "${DOMAIN}" --standalone
    docker run --rm -it -v ./acme.sh/data:/acme.sh --net=host neilpang/acme.sh --install-cert --ecc -d "${DOMAIN} " --key-file /acme.sh/cert/"${DOMAIN}".key --fullchain-file /acme.sh/cert/${DOMAIN}.cert
}

function config_nginx {
    local template_urls="https://www.free-css.com/assets/files/free-css-templates/download/page284/dorang.zip
                         https://www.free-css.com/assets/files/free-css-templates/download/page289/4uhost.zip
                         https://www.free-css.com/assets/files/free-css-templates/download/page284/rhino.zip
                         https://www.free-css.com/assets/files/free-css-templates/download/page286/safecam.zip
                         https://www.free-css.com/assets/files/free-css-templates/download/page2/touch-of-purple.zip
                         https://www.free-css.com/assets/files/free-css-templates/download/page1/photoprowess.zip"
    template_url=$(shuf -n 1 -e ${template_urls})
    template_zip_name=$(basename "${template_url}")
    wget -q "${template_url}"
    tmp_dir=$(mktemp -d)
    unzip -d "${tmp_dir}" "${template_zip_name}"> /dev/null
    template_dir=$(dirname "$(find ${tmp_dir} -maxdepth 2 -type f -name index.html)")
    rm -rf ${INSTALL_DIR}/nginx/data/html
    mv "${template_dir}" ${INSTALL_DIR}/nginx/data/html
    rm -rf "${template_zip_name}"
    rm -rf "${tmp_dir}"
}

function config_trojan_go {
cat > ${INSTALL_DIR}/trojan-go/data/config.json <<-EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 443,
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "log_level": 1,
  "log_file": "/etc/trojan-go/trojan-go.log",
  "password": [
	  "${PASSWORD}"
  ],
  "disable_http_check": false,
  "udp_timeout": 60,
  "ssl": {
    "verify": true,
    "verify_hostname": true,
    "cert": "/etc/cert/${DOMAIN}.cert",
    "key": "/etc/cert/${DOMAIN}.key",
    "key_password": "",
    "cipher": "",
    "curves": "",
    "prefer_server_cipher": false,
    "sni": "",
    "alpn": [
      "http/1.1"
    ],
    "session_ticket": true,
    "reuse_session": true,
    "plain_http_response": "",
    "fallback_addr": "127.0.0.1",
    "fallback_port": 80,
    "fingerprint": ""
  },
  "tcp": {
    "no_delay": true,
    "keep_alive": true,
    "prefer_ipv4": false
  },
  "mux": {
    "enabled": true,
    "concurrency": 8,
    "idle_timeout": 60
  },
  "router": {
    "enabled": true,
    "bypass": [],
    "proxy": [],
    "block": [
	    "geoip:private"
    ],
    "default_policy": "proxy",
    "domain_strategy": "as_is",
    "geoip": "/etc/trojan-go/geoip.dat",
    "geosite": "/etc/trojan-go/geosite.dat"
  },
  "websocket": {
    "enabled": true,
    "path": "/${DOMAIN}",
    "host": "${DOMAIN}"
  },
  "shadowsocks": {
    "enabled": true,
    "method": "AES-128-GCM",
    "password": "${PASSWORD}"
  }
}
EOF

cat > ${INSTALL_DIR}/trojan-go/data/update.sh <<-EOF
#/bin/env sh

wget -q https://github.com/v2fly/domain-list-community/raw/release/dlc.dat -O /etc/trojan-go/geosite.dat
wget -q https://github.com/v2fly/geoip/raw/release/geoip.dat -O /etc/trojan-go/geoip.dat
wget -q https://github.com/v2fly/geoip/raw/release/geoip-only-cn-private.dat -O /etc/trojan-go/geoip-only-cn-private.dat

exit 0
EOF

chmod a+x ${INSTALL_DIR}/trojan-go/data/update.sh

}

function show_client_config {
    echo "=====Client Configuration====="
    echo "server: ${DOMAIN}"
    echo "port: 443"
    echo "password: ${PASSWORD}"
    echo "tcp_no_delay: True"
    echo "mux: true"
    echo "websocket: True"
    echo "websocket server: ${DOMAIN}"
    echo "websocket path: /${DOMAIN}"
    echo "shadowsocks: true"
    echo "shadowsocks password: ${PASSWORD}"
    echo "=====Client Configuration====="
}

function pull_compose {
    cd ${INSTALL_DIR}
    docker compose pull
}

function start_compose {
    cd ${INSTALL_DIR}
    docker compose up -d
}

function stop_compose {
    cd ${INSTALL_DIR}
    docker compose down
}

function do_install {
    get_args
    prepare_dirs
    install_pre_reqs
    config_docker_compose
    pull_compose
    config_acme
    config_nginx
    config_trojan_go
    show_client_config
}

function main {
    local task=$1
    case ${task} in
    install)
    do_install
    start_compose
    ;;
    start)
    start_compose
    ;;
    stop)
    stop_compose
    ;;
    restart)
    stop_compose
    start_compose
    ;;
    *)
    exit 1
    esac
}

main "$1"

exit 0