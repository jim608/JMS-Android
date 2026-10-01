FROM nginx:alpine

EXPOSE 80

ENV BASE_URL=""
ENV SEERR_BASE_URL=""
ENV SEERR_HEADER="null"
ENV FLADDER_WEBPATH="/"
ENV JMS_DIAGNOSTICS_ENDPOINT=""
ENV JMS_DIAGNOSTICS_UPSTREAM=""

COPY build/web /usr/share/nginx/html
COPY docker-entrypoint.sh /docker-entrypoint.sh

RUN mkdir -p /usr/share/nginx/html/assets/config /etc/nginx/jms && \
    chown -R nginx:nginx /usr/share/nginx/html && \
    chmod +x /docker-entrypoint.sh && \
    chown -R nginx:nginx /etc/nginx/conf.d /etc/nginx/jms

CMD ["/docker-entrypoint.sh"]
