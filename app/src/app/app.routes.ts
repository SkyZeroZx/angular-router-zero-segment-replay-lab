import { ActivatedRouteSnapshot, Routes } from "@angular/router";
import { resource } from "@angular/core";
import { Aside, Dashboard, DetailPanel, NotFound, Panel, Report, Shell } from "./pages";
import { BACKEND_URL, CANACTIVATECHILD_MS, RESOLVE_MS } from "./env";

// Fetches the row the panel is about. resolveData() runs these with concatMap,
// so they go one after another and the request holds its slot for the sum.
let resolverCalls = 0;
let reportTimer: ReturnType<typeof setTimeout> | undefined;

const resolveDetail = (route: ActivatedRouteSnapshot) => {
  resolverCalls++;
  clearTimeout(reportTimer);
  reportTimer = setTimeout(() => {
    console.log(JSON.stringify({ resolverCalls }));
    resolverCalls = 0;
  }, 400);
  if (!BACKEND_URL) return "d";
  const id = route.params["id"];
  return fetch(BACKEND_URL + "/item/" + id)
    .then((r) => r.json())
    .catch(() => "unavailable");
};

// Separate from resolveDetail so the backend table keeps measuring what it
// measured. No I/O, just a promise: the await is the part that matters.
const resolveLive = () =>
  new Promise<string>((done) => setTimeout(() => done("d"), RESOLVE_MS));

// Three resources per activated route, loaders on 300 ms timers. Copied from
// the lab that measured this, down to reading params() inside the resource.
const reportResources = ({ params }: { params: () => Record<string, string> }) => {
  const make = (field: string) =>
    resource({
      params: () => params()["id"],
      loader: async ({ params: id }: { params: string }) => {
        await new Promise<void>((done) => setTimeout(done, 300));
        return `${field}:${id}`;
      },
    });
  return {
    product: make("product"),
    reviews: make("reviews"),
    recommendations: make("recommendations"),
  };
};// Declared once on the parent, but runCanActivateChild() (:2600) runs every
// ancestor's guard for every activated route, so it fires once per node.
const slowChild = () =>
  new Promise<boolean>((r) => setTimeout(() => r(true), CANACTIVATECHILD_MS));

// Always-on widgets. An empty-path route in a named outlet is the documented
// way to mount one.
const WIDGETS: Routes = [
  { path: "", outlet: "w1", component: Aside },
  { path: "", outlet: "w2", component: Aside },
  { path: "", outlet: "w3", component: Aside },
];

export const routes: Routes = [
  // The ladder: same dashboard, same named outlet, different contents. Fan-out
  // is snapshots per matched detail route, and none of it shows up in the URL.

  // fan-out 1.
  {
    path: "dashboard",
    component: Dashboard,
    children: [{ path: ":id", outlet: "detail", component: DetailPanel }],
  },

  // fan-out 2: one aside.
  {
    path: "nested",
    component: Dashboard,
    children: [
      {
        path: ":id",
        outlet: "detail",
        component: DetailPanel,
        children: [{ path: "", outlet: "aside", component: Aside }],
      },
    ],
  },

  // fan-out 4: the aside holds two widgets.
  {
    path: "nested2",
    component: Dashboard,
    children: [
      {
        path: ":id",
        outlet: "detail",
        component: DetailPanel,
        children: [
          {
            path: "",
            outlet: "aside",
            component: Aside,
            children: WIDGETS.slice(0, 2),
          },
        ],
      },
    ],
  },

  // fan-out 13: three panels, three widgets each. An ordinary dashboard.
  {
    path: "nested3",
    component: Dashboard,
    children: [
      {
        path: ":id",
        outlet: "detail",
        component: DetailPanel,
        children: [
          { path: "", outlet: "p1", component: Aside, children: WIDGETS },
          { path: "", outlet: "p2", component: Aside, children: WIDGETS },
          { path: "", outlet: "p3", component: Aside, children: WIDGETS },
        ],
      },
    ],
  },

  // nested3 with an async canActivateChild. The only place recognition yields,
  // so the trees overlap instead of queueing.
  {
    path: "guarded",
    component: Dashboard,
    canActivateChild: [slowChild],
    children: [
      {
        path: ":id",
        outlet: "detail",
        component: DetailPanel,
        children: [
          { path: "", outlet: "p1", component: Aside, children: WIDGETS },
          { path: "", outlet: "p2", component: Aside, children: WIDGETS },
          { path: "", outlet: "p3", component: Aside, children: WIDGETS },
        ],
      },
    ],
  },

  // nested3 with a primary sibling beside the named one: the main area shows a
  // record and the panel shows another. Ordinary master-detail, and the most
  // common shape of all. Two routes match per replayed group instead of one, so
  // the tree doubles for 3 extra bytes per group in the URL.
  {
    path: "master",
    component: Dashboard,
    children: [
      {
        path: ":id",
        component: DetailPanel,
        children: [
          { path: "", outlet: "p1", component: Aside, children: WIDGETS },
          { path: "", outlet: "p2", component: Aside, children: WIDGETS },
          { path: "", outlet: "p3", component: Aside, children: WIDGETS },
        ],
      },
      {
        path: ":id",
        outlet: "detail",
        component: DetailPanel,
        children: [
          { path: "", outlet: "p1", component: Aside, children: WIDGETS },
          { path: "", outlet: "p2", component: Aside, children: WIDGETS },
          { path: "", outlet: "p3", component: Aside, children: WIDGETS },
        ],
      },
    ],
  },
  // nested3 that also loads its data, which is what a real page does. The
  // resolver's await is what makes concurrent requests overlap.
  {
    path: "live",
    component: Dashboard,
    children: [
      {
        path: ":id",
        outlet: "detail",
        component: DetailPanel,
        resolve: { d: resolveLive },
        children: [
          { path: "", outlet: "p1", component: Aside, children: WIDGETS },
          { path: "", outlet: "p2", component: Aside, children: WIDGETS },
          { path: "", outlet: "p3", component: Aside, children: WIDGETS },
        ],
      },
    ],
  },
  // The four-line config plus a resolver. Fan-out 1, so every call is one
  // replayed group. This is the one that reaches the backend.
  {
    path: "resolved",
    component: Dashboard,
    children: [
      {
        path: ":id",
        outlet: "detail",
        component: DetailPanel,
        resolve: { d: resolveDetail },
      },
    ],
  },

  // The resources shape, from the lab that measured it. Its inflation is the
  // empty-path outlet exemption at :3123, not the replay. Kept last so it does
  // not shadow the shapes above.
  {
    path: "",
    component: Shell,
    children: [
      { path: ":id", component: Report, resources: reportResources },
      { path: "", outlet: "side", component: Panel },
    ],
  },

  // The catch-all. Without it the SSR route tree answers 404 before the URL
  // reaches recognition.
  { path: "**", component: NotFound },
];
