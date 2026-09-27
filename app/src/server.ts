import {
  AngularNodeAppEngine,
  createNodeRequestHandler,
  isMainModule,
  writeResponseToNodeResponse,
} from "@angular/ssr/node";
import express from "express";

const app = express();
const angularApp = new AngularNodeAppEngine({
  allowedHosts: ["app", "nginx", "localhost", "127.0.0.1"],
});

// Registered BEFORE the Angular handler, so it never goes through recognition.
// /health answered late is a worker whose event loop is blocked; /health not
// answered at all is a worker that is gone. That distinction is the difference
// between the two failure modes this lab reports, so it has to be measurable
// without the Router in the way.
app.get("/health", (_req, res) => res.type("text/plain").send("ok"));

app.use((req, res, next) => {
  angularApp
    .handle(req)
    .then((response) =>
      response ? writeResponseToNodeResponse(response, res) : next(),
    )
    .catch(next);
});

if (isMainModule(import.meta.url)) {
  app.listen(Number(process.env["PORT"] ?? 4000), "0.0.0.0", (error) => {
    if (error) throw error;
    console.log("Angular SSR listening on :4000");
  });
}

export const reqHandler = createNodeRequestHandler(app);
