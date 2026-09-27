import { ApplicationConfig } from "@angular/core";
import { provideRouter, withRouterResources } from "@angular/router";
import { routes } from "./app.routes";

// Nothing opted into: no withRouterConfig, no custom UrlSerializer, no
// redirects. The Router is wired the way the CLI wires it.
// Developer preview and opt-in. Without ROUTER_RESOURCES this is the build
// every other table was measured on.
const useResources =
  (globalThis as { process?: { env?: Record<string, string | undefined> } })
    .process?.env?.["ROUTER_RESOURCES"] === "1";

export const appConfig: ApplicationConfig = {
  providers: [
    useResources
      ? provideRouter(routes, withRouterResources())
      : provideRouter(routes),
  ],
};
