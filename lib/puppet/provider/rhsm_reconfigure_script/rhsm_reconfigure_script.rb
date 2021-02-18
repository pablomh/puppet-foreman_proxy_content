Puppet::Type.type(:rhsm_reconfigure_script).provide(:rhsm_reconfigure_script) do

  def create
    template = render_template
    File.open(resource[:path], 'w', 0o755) do |file|
      file.write(template)
    end
  end

  def exists?
    File.exist?(resource[:path]) && (File.read(resource[:path]) == render_template)
  end

  private

  def render_template
    ::ERB.new(script_template).result(binding)
  end

  def server_ca_cert
    # Reads the server CA certificate from
    # disk on the client
    File.read(resource[:server_ca_cert])
  end

  def default_ca_cert
    # Reads the default CA certificate from
    # disk on the client
    File.read(resource[:default_ca_cert])
  end

  def script_template
    <<~'HEREDOC'
      #!/bin/bash

      set -e

      KATELLO_SERVER=<%= resource[:rhsm_hostname] %>
      PORT=<%= resource[:rhsm_port] %>

      KATELLO_SERVER_CA_CERT=<%= resource[:server_ca_name] %>.pem
      KATELLO_DEFAULT_CA_CERT=<%= resource[:default_ca_name] %>.pem

      CERT_DIR=/etc/rhsm/ca
      PREFIX=/rhsm
      CFG=/etc/rhsm/rhsm.conf
      CFG_BACKUP=$CFG.kat-backup
      CA_TRUST_ANCHORS=/etc/pki/ca-trust/source/anchors

      read -r -d '' KATELLO_DEFAULT_CA_DATA << EOM || true
      <%= default_ca_cert %>
      EOM

      read -r -d '' KATELLO_SERVER_CA_DATA << EOM || true
      <%= server_ca_cert %>
      EOM

      is_debian()
      {
        if [ -r "/etc/os-release" ]
        then
          ID="$(sed -n -e "s/^ID\s*=\s*\(.*\)/\1/p" /etc/os-release)"
          ID_LIKE="$(sed -n -e "s/^ID_LIKE\s*=\s*\(.*\)/\1/p" /etc/os-release)"

          if [ "$ID" = "debian" ] ||       # Debian
             [ "$ID_LIKE" = "debian" ] ||  # e.g Ubuntu
             [ "$ID_LIKE" = "ubuntu" ]     # e.g. Linux Mint
          then
            return 0
          fi
        fi
        return 1
      }

      # exit on non-RHEL systems or when rhsm.conf is not found
      test -f $CFG || exit
      type -P subscription-manager >/dev/null || type -P subscription-manager-cli >/dev/null || exit

      # backup configuration during the first run
      test -f $CFG_BACKUP || cp $CFG $CFG_BACKUP

      # create the cert
      echo "$KATELLO_SERVER_CA_DATA" > $CERT_DIR/$KATELLO_SERVER_CA_CERT
      chmod 644 $CERT_DIR/$KATELLO_SERVER_CA_CERT

      echo "$KATELLO_DEFAULT_CA_DATA" > $CERT_DIR/$KATELLO_DEFAULT_CA_CERT
      chmod 644 $CERT_DIR/$KATELLO_DEFAULT_CA_CERT

      if is_debian
      then
        # Debian setup
        BASEURL=https://$KATELLO_SERVER/pulp/deb

        subscription-manager config \
          --server.hostname="$KATELLO_SERVER" \
          --server.prefix="$PREFIX" \
          --server.port="$PORT" \
          --rhsm.repo_ca_cert="%(ca_cert_dir)s$KATELLO_SERVER_CA_CERT" \
          --rhsm.baseurl="$BASEURL"
      else
        # rhel setup
        BASEURL=https://$KATELLO_SERVER/pulp/content/

        # Get version of RHSM
        RHSM_V="$((rpm -q --queryformat='%{VERSION}' subscription-manager 2> /dev/null || echo 0.0.0) | tail -n1 | tr . ' ')"
        declare -a RHSM_VERSION=($RHSM_V)

        # configure rhsm
        # the config command was introduced in rhsm 0.96.6
        # fallback left for older versions
        if test ${RHSM_VERSION[0]:-0} -gt 0 -o ${RHSM_VERSION[1]:-0} -gt 96 -o \( ${RHSM_VERSION[1]:-0} -eq 96 -a ${RHSM_VERSION[2]:-0} -gt 6 \); then
          subscription-manager config \
            --server.hostname="$KATELLO_SERVER" \
            --server.prefix="$PREFIX" \
            --server.port="$PORT" \
            --rhsm.repo_ca_cert="%(ca_cert_dir)s$KATELLO_SERVER_CA_CERT" \
            --rhsm.baseurl="$BASEURL"

          # Older versions of subscription manager may not recognize
          # report_package_profile and package_profile_on_trans options.
          # So set them separately and redirect out & error to /dev/null
          # to fail silently.
          subscription-manager config --rhsm.package_profile_on_trans=1 > /dev/null 2>&1 || true
          subscription-manager config --rhsm.report_package_profile=1 > /dev/null 2>&1 || true
        else
          sed -i "s/^hostname\s*=.*/hostname = $KATELLO_SERVER/g" $CFG
          sed -i "s/^port\s*=.*/port = $PORT/g" $CFG
          sed -i "s|^prefix\s*=.*|prefix = $PREFIX|g" $CFG
          sed -i "s|^repo_ca_cert\s*=.*|repo_ca_cert = %(ca_cert_dir)s$KATELLO_SERVER_CA_CERT|g" $CFG
          sed -i "s|^baseurl\s*=.*|baseurl=$BASEURL|g" $CFG
        fi

        if grep --quiet full_refresh_on_yum $CFG; then
          sed -i "s/full_refresh_on_yum\s*=.*$/full_refresh_on_yum = 1/g" $CFG
        else
          full_refresh_config="#config for on-premise management\nfull_refresh_on_yum = 1"
          sed -i "/baseurl/a $full_refresh_config" $CFG
        fi
      fi

      # also add the katello ca cert to the system wide ca cert store
      if [ -d $CA_TRUST_ANCHORS ]; then
        update-ca-trust enable
        cp $CERT_DIR/$KATELLO_SERVER_CA_CERT $CA_TRUST_ANCHORS
        update-ca-trust
      fi

      # EL5 systems and subscription-manager versions before 1.18.1-1 don't have the network.fqdn fact.
      # For these cases, we have to update the "hostname-override" fact
      if (test -f /etc/redhat-release && grep -q -i "Red Hat Enterprise Linux Server release 5" /etc/redhat-release) || \
         (test -f /etc/centos-release && grep -q -i "CentOS Linux release 5" /etc/centos-release) || \
         test ${RHSM_VERSION[0]:-0} -lt 1 -o ${RHSM_VERSION[1]:-0} -lt 18 -o \( ${RHSM_VERSION[1]:-0} -eq 18 -a ${RHSM_VERSION[2]:-0} -lt 2 \); then
        FQDN="$(hostname -f 2>/dev/null || echo localhost)"
        if [ "$FQDN" != "localhost" ] && [ -d /etc/rhsm/facts/ ]; then
          echo "{\"network.hostname-override\":\"$FQDN\"}" > /etc/rhsm/facts/katello.facts
        fi
      fi

      exit 0
    HEREDOC
  end

end
