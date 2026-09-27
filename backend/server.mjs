// The internal service the application's resolver talks to: a database, a REST
// API, whatever sits behind the SSR tier. It does nothing but answer after a
// realistic round trip and keep score.
//
// It is here because the second failure this lab reports does not happen in the
// Angular worker at all. The worker stays healthy; it is this process that gets
// buried, by traffic that originates inside the operator's own network and
// carries no attacker-controlled identifier of any kind.
import http from "node:http";

// What one query costs. 250 ms is an ordinary indexed lookup across a network
// hop; the lab sweeps it rather than assuming it.
const LATENCY_MS = Number(process.env.BACKEND_MS ?? "250");
const PORT = Number(process.env.PORT ?? "5000");

let total = 0;
let inFlight = 0;
let peakInFlight = 0;
let firstAt = 0;
let lastAt = 0;
let reportTimer;

function reset() {
  total = 0;
  inFlight = 0;
  peakInFlight = 0;
  firstAt = 0;
  lastAt = 0;
}

function stats() {
  return {
    queries: total,
    peakInFlight,
    // Wall time from the first query of a burst to the last. With the Router
    // running resolvers through concatMap this is the SUM of the round trips,
    // not the longest of them.
    spanMs: firstAt ? lastAt - firstAt : 0,
    latencyMs: LATENCY_MS,
  };
}

// One debounced line per burst, so `docker compose logs backend` tells the same
// story the /stats endpoint does.
function report() {
  clearTimeout(reportTimer);
  reportTimer = setTimeout(() => console.log(JSON.stringify(stats())), 500);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://backend");

  if (url.pathname === "/stats") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(stats()));
    return;
  }

  if (url.pathname === "/reset") {
    reset();
    res.writeHead(200, { "content-type": "application/json" });
    res.end('{"ok":true}');
    return;
  }

  if (url.pathname === "/health") {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("ok");
    return;
  }

  // Everything else is a query. This is the line that matters: from here the
  // request is indistinguishable from the application's own legitimate traffic.
  // It arrives on the internal network, from the SSR tier's own address, with
  // the SSR tier's own credentials, and asks for a row by id.
  total += 1;
  inFlight += 1;
  if (inFlight > peakInFlight) peakInFlight = inFlight;
  const now = Date.now();
  if (!firstAt) firstAt = now;
  report();

  setTimeout(() => {
    inFlight -= 1;
    lastAt = Date.now();
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ id: url.pathname.split("/").pop(), title: "row" }));
  }, LATENCY_MS);
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`backend listening on :${PORT}, ${LATENCY_MS} ms per query`);
});
