FROM nginx:alpine
LABEL demo3.tier="web" demo3.immutable="true"

RUN apk add --no-cache curl

COPY html/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

HEALTHCHECK --interval=2s --timeout=2s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
