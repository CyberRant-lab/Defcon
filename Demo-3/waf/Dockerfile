FROM owasp/modsecurity-crs:nginx-alpine
LABEL demo3.tier="waf"

# This image uses envsubst to generate conf.d/default.conf at runtime
# from templates. We must put our config in the template location.
COPY nginx-waf.conf /etc/nginx/templates/conf.d/default.conf.template

EXPOSE 80

HEALTHCHECK --interval=2s --timeout=2s --retries=5 \
    CMD curl -f http://localhost/health || exit 1
