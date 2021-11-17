#!/bin/bash

# Copyright 2019 Marko Kohtala <marko.kohtala@okoko.fi>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Based on work by Jakub Scholz <www@scholzj.com> in
# https://github.com/scholzj/docker-qpid-cpp

set -e

# if command starts with an option, prepend qpidd
if [ "${1:0:1}" = '-' ]; then
    set -- qpidd "$@"
fi

if [ "$1" = "qpidd" ]; then
    sasl_external=0
    sasl_plain=0
    have_ssl=0
    have_acl=0
    have_sasl=0
    have_store=0
    have_paging=0
    have_sslnodict=0
    have_auth=0

    have_config=0

    # Home dir
    if [ -z "$QPIDD_HOME" ]; then
        QPIDD_HOME="/var/lib/qpidd"
    fi

    if [ ! -d "$QPIDD_HOME" ]; then
        mkdir -p "$QPIDD_HOME"
        chown -R qpidd:qpidd "$QPIDD_HOME"
    fi

    # Data dir (and also PID dir)
    if [ -z "$QPIDD_DATA_DIR" ]; then
        QPIDD_DATA_DIR="$QPIDD_HOME/work"
    fi

    if [ ! -d "$QPIDD_DATA_DIR" ]; then
        mkdir -p "$QPIDD_DATA_DIR"
        chown -R qpidd:qpidd "$QPIDD_DATA_DIR"
    fi

    #####
    # If SASL database already exists, change the password only when it was provided from outside.
    # If it doesn't exist, create it either with password from env or with default password
    #####
    : "${QPIDD_SASL_DB:=$QPIDD_HOME/etc/sasl/qpidd.sasldb}"
    mkdir -p "$(dirname "$QPIDD_SASL_DB")"

    if [ -r "${QPIDD_ADMIN_USERNAME_FILE:=/run/secrets/admin_username}" ] ;then
        QPIDD_ADMIN_USERNAME="$(cat "$QPIDD_ADMIN_USERNAME_FILE")"
    fi
    if [ -r "${QPIDD_ADMIN_PASSWORD_FILE:=/run/secrets/admin_password}" ]; then
        QPIDD_ADMIN_PASSWORD="$(cat "$QPIDD_ADMIN_PASSWORD_FILE")"
    fi
    if [ "$QPIDD_ADMIN_USERNAME" ] && [ "$QPIDD_ADMIN_PASSWORD" ]; then
        echo "$QPIDD_ADMIN_PASSWORD" | saslpasswd2 -f "$QPIDD_SASL_DB" -u QPID -p "$QPIDD_ADMIN_USERNAME"
        sasl_plain=1
        have_auth=1
    fi

    #####
    # SSL
    #####
    if [ "$QPIDD_SSL_SERVER_PUBLIC_KEY" -a "$QPIDD_SSL_SERVER_PRIVATE_KEY" ]; then
        tempDir="$(mktemp -d)"

        if [ -z "$QPIDD_SSL_DB_DIR" ]; then
            QPIDD_SSL_DB_DIR="$QPIDD_HOME/etc/ssl"
        fi

        mkdir -p "$QPIDD_SSL_DB_DIR"


        # Password file
        if [ -r "${QPIDD_SSL_DB_PASSWORD_FILE:=$QPIDD_SSL_DB_DIR/pwdfile}" ]; then
            QPIDD_SSL_DB_PASSWORD="$(cat "$QPIDD_SSL_DB_PASSWORD_FILE")"
        else
            if [ -z "$QPIDD_SSL_DB_PASSWORD" ]; then
                QPIDD_SSL_DB_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"
            fi
            echo "$QPIDD_SSL_DB_PASSWORD" > "$QPIDD_SSL_DB_PASSWORD_FILE"
        fi

        # Server key
        echo "DEBUG: Server key"
        echo "$QPIDD_SSL_SERVER_PUBLIC_KEY" > $tempDir/serverKey.crt
        echo "$QPIDD_SSL_SERVER_PRIVATE_KEY" > $tempDir/serverKey.pem
        openssl pkcs12 -export -in $tempDir/serverKey.crt -inkey $tempDir/serverKey.pem -out $tempDir/serverKey.p12 -passout pass:$(cat $QPIDD_SSL_DB_PASSWORD_FILE)

        # Does the database already exist?
        echo "DEBUG: NSS DB"
        #certutil -L -d sql:$QPIDD_SSL_DB_DIR >> /dev/null
        if [ ! -f $QPIDD_SSL_DB_DIR/cert9.db -o ! -f $QPIDD_SSL_DB_DIR/key4.db ] ; then
            certutil -N -d sql:$QPIDD_SSL_DB_DIR -f $QPIDD_SSL_DB_PASSWORD_FILE
        fi

        # Delete old server keys
        exists=$(certutil -L -d sql:$QPIDD_SSL_DB_DIR | grep serverKey | wc -l)
        while [ "$exists" -gt 0 ]; do
            certutil -D -d sql:$QPIDD_SSL_DB_DIR -n serverKey
            res=$?
        done

        # Load server certificate
        echo "DEBUG: Loading keys"
        certutil -A -d sql:$QPIDD_SSL_DB_DIR -n serverKey -t ",," -i $tempDir/serverKey.crt -f $QPIDD_SSL_DB_PASSWORD_FILE
        pk12util -i $tempDir/serverKey.p12 -d sql:$QPIDD_SSL_DB_DIR -w $QPIDD_SSL_DB_PASSWORD_FILE -k $QPIDD_SSL_DB_PASSWORD_FILE

        if [ "$QPIDD_SSL_TRUSTED_CA" ]; then
             pushd $tempDir
             echo "$QPIDD_SSL_TRUSTED_CA" > db.ca
             csplit db.ca '/^-----END CERTIFICATE-----$/1' '{*}' --elide-empty-files --silent --prefix=ca_

             counter=1
             for cert in $(ls ca_*); do
                 certutil -A -d sql:$QPIDD_SSL_DB_DIR -f $QPIDD_SSL_DB_PASSWORD_FILE -t "T,," -i $cert -n ca_$counter
                 let counter=$counter+1
             done

             rm ca_*
             rm db.ca
             popd

             sasl_external=1
             have_auth=1
        fi

        if [ "$QPIDD_SSL_TRUSTED_PEER" ]; then
             pushd $tempDir
             echo "$QPIDD_SSL_TRUSTED_PEER" > db.peer
             csplit db.peer '/^-----END CERTIFICATE-----$/1' '{*}' --elide-empty-files --silent --prefix=peer_

             counter=1
             for cert in $(ls peer_*); do
                 certutil -A -d sql:$QPIDD_SSL_DB_DIR -f $QPIDD_SSL_DB_PASSWORD_FILE -t "P,," -i $cert -n peer_$counter
                 let counter=$counter+1
             done

             if [ -z "$QPIDD_SSL_TRUSTED_CA" ]; then
                  openssl req -subj '/CN=dummy_CA' -new -newkey rsa:2048 -days 365 -nodes -x509 -keyout server.key -out server.crt
                  certutil -A -d sql:$QPIDD_SSL_DB_DIR -f $QPIDD_SSL_DB_PASSWORD_FILE -t "T,," -i server.crt -n dummy_CA
             fi

             rm peer_*
             rm db.peer
             popd

             sasl_external=1
             have_auth=1
        fi

        if [ "$QPIDD_SSL_NO_DICT" ]; then
            have_sslnodict=1
        fi

        have_ssl=1
    fi

    #####
    # Create SASL config if it doesn't exist, create it
    #]####
    if [ -z "$QPIDD_SASL_CONFIG_DIR" ]; then
        QPIDD_SASL_CONFIG_DIR="$QPIDD_HOME/etc/sasl/"
    fi

    if [ ! -f "$QPIDD_SASL_CONFIG_DIR/qpidd.conf" ]; then
        if [ $sasl_plain -eq 1 -o $sasl_external -eq 1 ]; then
            mkdir -p "$(dirname $QPIDD_SASL_CONFIG_DIR)"

            mechs=""

            if [ $sasl_plain -eq 1 ]; then
                mechs="PLAIN DIGEST-MD5 CRAM-MD5 $mechs"
            fi

            if [ $sasl_external -eq 1 ]; then
                mechs="EXTERNAL $mechs"
            fi

            cat > $QPIDD_SASL_CONFIG_DIR/qpidd.conf <<-EOS
mech_list: $mechs
pwcheck_method: auxprop
auxprop_plugin: sasldb
sasldb_path: $QPIDD_SASL_DB
sql_select: dummy select
EOS
            have_sasl=1
        fi
    fi

    #####
    # Create ACL file - if user was set and the ACL env var not, generate it.
    #####
    if [ -z "$QPIDD_ACL_FILE" ]; then
        QPIDD_ACL_FILE="$QPIDD_HOME/etc/qpidd.acl"
    fi

    if [ "$QPIDD_ACL_RULES" ]; then
        echo $QPIDD_ACL_RULES > $QPIDD_ACL_FILE
        have_acl=1
    elif [ $QPIDD_ADMIN_USERNAME ]; then
        if [ ! -f "$QPIDD_ACL_FILE" ]; then
            cat > $QPIDD_ACL_FILE <<-EOS
acl allow $QPIDD_ADMIN_USERNAME@QPID all
acl deny-log all all
EOS
            have_acl=1
        fi
    fi

    #####
    # Store dir configuration
    #####
    if [ -z $QPIDD_STORE_DIR ]; then
        QPIDD_STORE_DIR="$QPIDD_HOME/store"
    fi

    mkdir -p "$QPIDD_STORE_DIR"
    have_store=1

    #####
    # Paging dir configuration
    #####
    if [ -z $QPIDD_PAGING_DIR ]; then
        QPIDD_PAGING_DIR="$QPIDD_HOME/paging"
    fi

    mkdir -p "$QPIDD_PAGING_DIR"
    have_paging=1

    #####
    # Generate broker config file if it doesn`t exist
    #####
    if [ -z "$QPIDD_CONFIG_FILE" ]; then
        QPIDD_CONFIG_FILE="$QPIDD_HOME/etc/qpidd.conf"
    fi

    if [ "$QPIDD_CONFIG_OPTIONS" ]; then
        cat >> $QPIDD_CONFIG_FILE <<-EOS
$QPIDD_CONFIG_OPTIONS
EOS
	      have_config=1
    else
        if [ ! -f "$QPIDD_CONFIG_FILE" ]; then
            cat >> $QPIDD_CONFIG_FILE <<-EOS
data-dir=$QPIDD_DATA_DIR
pid-dir=$QPIDD_DATA_DIR
EOS

            if [ $have_sasl -eq "1" ]; then
                cat >> $QPIDD_CONFIG_FILE <<-EOS
sasl-config=$QPIDD_SASL_CONFIG_DIR
EOS
                have_config=1
            fi

            if [ $have_auth -eq "1" ]; then
                cat >> $QPIDD_CONFIG_FILE <<-EOS
auth=yes
EOS
                have_config=1
            fi

            if [ $have_acl -eq "1" ]; then
                cat >> $QPIDD_CONFIG_FILE <<-EOS
acl-file=$QPIDD_ACL_FILE
EOS
                have_config=1
            fi

            if [ $have_store -eq "1" ]; then
                cat >> $QPIDD_CONFIG_FILE <<-EOS
store-dir=$QPIDD_STORE_DIR
EOS
                have_config=1
            fi

            if [ $have_paging -eq "1" ]; then
                cat >> $QPIDD_CONFIG_FILE <<-EOS
paging-dir=$QPIDD_PAGING_DIR
EOS
                have_config=1
            fi

            if [ $have_ssl -eq "1" ]; then
                cat >> $QPIDD_CONFIG_FILE <<-EOS
ssl-cert-password-file=$QPIDD_SSL_DB_PASSWORD_FILE
ssl-cert-name=serverKey
ssl-cert-db=sql:$QPIDD_SSL_DB_DIR
EOS
                have_config=1

                if [ $sasl_external -eq "1" ]; then
                    cat >> $QPIDD_CONFIG_FILE <<-EOS
ssl-require-client-authentication=yes
EOS
                fi

                if [ $sasl_sslnodict -eq "1" ]; then
                    cat >> $QPIDD_CONFIG_FILE <<-EOS
ssl-sasl-no-dict=yes
EOS
                fi
            fi
        else
            have_config=1
        fi
    fi

    if [ $have_config -eq "1" ]; then
        set -- "$@" "--config" "$QPIDD_CONFIG_FILE"
    fi

    #chown -R qpidd:qpidd "$QPIDD_HOME"
fi

# else default to run whatever the user wanted like "bash"
exec "$@"
