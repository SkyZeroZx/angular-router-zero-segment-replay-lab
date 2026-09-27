FROM node:24.16.0-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
# none (default) builds stock @angular/router. See README, "Isolating it".
ARG ROUTER_PATCH=none
RUN node patch-router.mjs "$ROUTER_PATCH"
# production (default) is where the defect exists: @angular/build substitutes
# ngDevMode with false in an optimized build, so the branch dies and
# checkOutletNameUniqueness is tree-shaken out. BUILD_CONFIG=development keeps
# it, which is the dev-versus-prod arm.
ARG BUILD_CONFIG=production
RUN npx ng build --configuration "$BUILD_CONFIG"
# On the record, in the image: whether the validation survived the build.
RUN (grep -rlq "checkOutletNameUniqueness" dist/router-replay-e2e/server/ \
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
