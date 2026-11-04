# Shared runtime for every Next.js app on the platform.
#
# App images are this base plus three reproducible layers (dependencies,
# public assets, app code) appended by crane in CI. Because all apps share
# this base, the server downloads it once per Node major and each deploy only
# moves the layers that changed.
#
# Rebuilt weekly by .github/workflows/runtime-image.yml to pick up OS and
# Node.js security patches.
ARG NODE_MAJOR=24

FROM busybox:1.38-musl AS busybox

FROM node:${NODE_MAJOR}-slim
# Static wget (~1 MB) used by health checks, so there's no curl/apt layer.
COPY --from=busybox /bin/busybox /usr/local/bin/wget
RUN install -d -o node -g node /srv
ENV NODE_ENV=production \
    PORT=3000 \
    HOSTNAME=0.0.0.0 \
    NEXT_TELEMETRY_DISABLED=1
WORKDIR /srv
USER node
EXPOSE 3000
HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:3000/"]
CMD ["node", "server.js"]
