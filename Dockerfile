FROM debian:9.2

RUN apt-get update
RUN apt-get install -y net-tools
RUN apt-get install -y iptables iproute
RUN apt-get install -y strongswan strongswan-swanctl
RUN apt-get install -y wget procps
RUN apt-get install -y dkms
RUN apt-get install -y libstrongswan-standard-plugins libstrongswan-extra-plugins
RUN apt-get install -y libcharon-extra-plugins
RUN mkdir -p /config

RUN ( echo 'vici {';echo 'load = yes';echo 'socket=unix://config/charon.vici';echo '}' )> /etc/strongswan.d/charon/vici.conf

COPY dhcp.conf /etc/strongswan.d/charon/dhcp.conf

COPY ipsec.conf /etc/ipsec.conf
COPY ipsec.secrets /etc/ipsec.secrets
COPY dhcp-server /usr/local/bin/dhcp-server

CMD sed -i "s/@FQDN@/${FQDN}/" /etc/ipsec.conf; \
    cp /key/cert.ca /etc/ipsec.d/cacerts/; \
    /usr/sbin/ipsec start --nofork

EXPOSE 500/udp 4500/udp

