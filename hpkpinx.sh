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
  CERT_ROOT="${NGINX_ROOT}/certs"
  MULTIPLE_HPKP_CONF=0
  STATIC_PIN_FILE=""

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
    CERT_NAME=${2} # The second argument is the name of the cert
    if [ ${MULTIPLE_HPKP_CONF} -eq 1 ] # if we want multiple conf files we have to prefix the config file with the name
    then
        HPKP_CONF=${NGINX_ROOT}/${CERT_NAME}-hpkp.conf
    else
        HPKP_CONF=${NGINX_ROOT}/hpkp.conf
    fi
    if [ ${STATIC_PIN_FILE} != "" ] # if an path to an STATIC_PIN_FILE is set use it
    then
        # get the pin
        STATIC_PIN=$(cat "${STATIC_PIN_FILE}" | grep "${CERT_NAME}" | cut -d ' ' -f 2)
    fi
    if [ -e ${HPKP_CONF} ]
    then
        echo 'Backing up current hpkp.conf'
        \cp -f ${HPKP_CONF} ${HPKP_CONF}.bak
    fi
    echo 'Regenerating public key pins using new private keys'
    echo '# THIS FILE IS GENERATED, ANY MODIFICATION WILL BE DISCARDED' > ${HPKP_CONF}
    if [ ${DEPLOY_HPKP} -eq 1 ]
    then
        echo -n "add_header Public-Key-Pins '" >> ${HPKP_CONF}
    else
        echo -n "add_header Public-Key-Pins-Report-Only '" > ${HPKP_CONF}
    fi

    echo -n "pin-sha256=\"${STATIC_PIN}\"; " >> ${HPKP_CONF}
    generate_pin "${CERT_ROOT}/${CERT_NAME}/privkey.pem" >> ${HPKP_CONF}
    generate_pin "${CERT_ROOT}/${CERT_NAME}/privkey.roll.pem" >> ${HPKP_CONF}
    echo "max-age=${HPKP_AGE}';" >> ${HPKP_CONF}
fi
