#!/bin/sh

set -e

# Find directory in which this script is stored by traversing all symbolic links
SOURCE="${0}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [ ${SOURCE} != /* ] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
SCRIPTDIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

# Setup default config values, search for and load configuration files
load_config() {
  # Check for config in various locations
  if [ -z "${CONFIG:-}" ]; then
    for check_config in "/etc/hpkpinx" "/usr/local/etc/hpkpinx" "${PWD}" "${SCRIPTDIR}"; do
      if [ -f "${check_config}/config.sh" ]; then
        CONFIG="${check_config}/config.sh"
        break
      fi
    done
  fi

  # Default values
  NGINX_ROOT='/etc/nginx'
  HPKP_AGE=10
  STATIC_PIN=
  DEPLOY_HPKP=0

  if [ -z "${CONFIG:-}" ]; then
    echo "#" >&2
    echo "# !! WARNING !! No main config file found, using default config!" >&2
    echo "#" >&2
  elif [ -f "${CONFIG}" ]; then
    echo "# INFO: Using main config file ${CONFIG}"
    BASEDIR="$(dirname "${CONFIG}")"
    # shellcheck disable=SC1090
    . "${CONFIG}"
  else
    _exiterr "Specified config file ${CONFIG} doesn't exist."
  fi
}

# Print error message and exit with error
_exiterr() {
  echo "ERROR: ${1}" >&2
  exit 1
}


generate_pin ()
{
    echo -n "pin-sha256=\""
    set +e
    grep -i "begin ec private key" --quiet ${1}
    USE_RSA=$?
    set -e
    if [ ${USE_RSA} -eq 1 ]
    then
        ALGO='rsa'
    else
        ALGO='ec'
    fi
    PIN=$(openssl ${ALGO} -in ${1} -pubout 2>/dev/null | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)
    if [ ${PIN} = '47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=' ]
    then
        echo -n 'MISSING KEY!'
    else
        echo -n ${PIN}
    fi
    echo -n "\"; "
}

load_config

if [ "$#" -ne 2 ]
then
    echo 'Usage:'
    echo -e '\thpkpinx.sh generate_pin <key.pem>'
    echo -e '\thpkpinx.sh deploy_cert <domain.name>'
    exit 1
fi

if [ ${1} = "generate_pin" ]
then
    generate_pin ${2}
    echo ""
elif [ ${1} = "deploy_cert" ]
then
    if [ -e ${NGINX_ROOT}/hpkp.conf ]
    then
        echo 'Backing up current hpkp.conf'
        \cp -f ${NGINX_ROOT}/hpkp.conf ${HPKPINX_ROOT}/hpkp.conf.bak
    fi
    echo 'Regenerating public key pins using new private keys'
    echo '# THIS FILE IS GENERATED, ANY MODIFICATION WILL BE DISCARDED' > ${NGINX_ROOT}/hpkp.conf
    if [ ${DEPLOY_HPKP} -eq 1 ]
    then
        echo -n "add_header Public-Key-Pins '" >> ${NGINX_ROOT}/hpkp.conf
    else
        echo -n "add_header Public-Key-Pins-Report-Only '" > ${NGINX_ROOT}/hpkp.conf
    fi
    echo -n "pin-sha256=\"${STATIC_PIN}\"; " >> ${NGINX_ROOT}/hpkp.conf
    generate_pin "${NGINX_ROOT}/certs/${2}/privkey.pem" >> ${NGINX_ROOT}/hpkp.conf
    generate_pin "${NGINX_ROOT}/certs/${2}/privkey.roll.pem" >> ${NGINX_ROOT}/hpkp.conf
    echo "max-age=${HPKP_AGE}';" >> ${NGINX_ROOT}/hpkp.conf
fi
