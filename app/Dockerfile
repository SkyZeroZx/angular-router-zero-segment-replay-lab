FROM node:24.16.0-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
# Instrumentation and ablations. none (default) leaves the router stock.
ARG ROUTER_PATCH=none
RUN node patch-router.mjs "$ROUTER_PATCH"
# The two fixes. A script and a switch each, applied independently: either,
# both or neither. Their status is echoed so the build log records which
# router every image was compiled against.
ARG PATCH_70933=0
ARG PATCH_ZERO_SEGMENT=0
RUN if [ "$PATCH_70933" = 1 ]; then node patch-70933.mjs; fi
RUN if [ "$PATCH_ZERO_SEGMENT" = 1 ]; then node patch-zero-segment.mjs; fi
RUN node patch-70933.mjs status && node patch-zero-segment.mjs status
# production (default) is where the defect exists: @angular/build substitutes
# ngDevMode with false in an optimized build, so the branch dies and
# checkOutletNameUniqueness is tree-shaken out. BUILD_CONFIG=development keeps
# it, which is the dev-versus-prod arm.
ARG BUILD_CONFIG=production
RUN npx ng build --configuration "$BUILD_CONFIG"
# On the record, in the image: whether the validation survived the build. The
# identifier is not the thing to look for - minification renames it whether the
# call survives or not. The numeric code behind NG04006 is, because minifiers do
# not rewrite numeric literals, and 4006 appears only inside the throw in that
# function: once in a development build, never in an optimized one.
RUN (grep -rlq "4006" dist/router-replay-e2e/server/ \
      && echo present || echo tree-shaken) > /app/outlet-check.txt \
    && cat /app/outlet-check.txt

FROM node:24.16.0-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production PORT=4000
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json /app/outlet-check.txt ./
EXPOSE 4000
CMD ["node", "dist/router-replay-e2e/server/server.mjs"]
