// Defensive: this module ends up in the browser bundle too.
function env(name: string): string | undefined {
  return (
    globalThis as { process?: { env?: Record<string, string | undefined> } }
  ).process?.env?.[name];
}

// Per-invocation delay of the async canActivateChild on the /guarded shape.
export const CANACTIVATECHILD_MS = Number(env("CANACTIVATECHILD_MS") ?? "") || 0;

// What /resolved queries. Empty means no second process in the way.
export const BACKEND_URL = env("BACKEND_URL") ?? "";

// What the resolver waits. Zero still yields the event loop, which is the part
// that matters.
export const RESOLVE_MS = Number(env("RESOLVE_MS") ?? "") || 0;
