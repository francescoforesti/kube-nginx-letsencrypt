FROM fedora:32

RUN dnf install tree curl certbot coreutils sed -y && dnf clean all
RUN mkdir -p /etc/letsencrypt /acme-challenge /hooks

COPY ssl-secret-patch-template.json /
COPY challenge-secret-patch-template.json /
COPY entrypoint.sh /
COPY hooks/authenticator.sh /hooks
COPY hooks/.env-template /hooks
COPY index.html /
COPY simple-server.py /

RUN chmod +x /hooks/authenticator.sh

CMD ["/entrypoint.sh"]
