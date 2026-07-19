// The browser half of /link: a real local HTTP server (127.0.0.1 only,
// never exposed to the network) serving a real page — "Connect Eaon CLI to
// Eaon" — that the user's actual default browser opens to. Nothing is
// written to the CLI's config until the user clicks Connect on that page;
// closing the tab or letting it time out changes nothing.

import http from "node:http";
import type { DiscoveryResult } from "./localAuth.js";

export interface LinkFlowResult {
  approved: boolean;
  timedOut: boolean;
  /** What was actually checked on the page when Connect was clicked —
   * empty/false across the board on cancel, timeout, or a deselect-all
   * submit (all three mean "nothing to import", just for different reasons). */
  includeAquaKey: boolean;
  selectedProviderIds: string[];
}

const TIMEOUT_MS = 3 * 60_000;

/** A discovered item the user can individually opt in/out of importing.
 * `checkName` is null for informational-only rows (nothing found, or a
 * provider skipped for an unrecognized format) — there's nothing to select. */
interface PickableRow {
  checkName: string | null;
  label: string;
}

function pickableRows(discovery: DiscoveryResult): PickableRow[] {
  const rows: PickableRow[] = [
    discovery.aquaApiKey
      ? { checkName: "aqua", label: "Aqua API key" }
      : { checkName: null, label: "No Aqua API key found" },
  ];
  for (const p of discovery.customProviders) rows.push({ checkName: `provider_${p.id}`, label: `Custom provider — ${p.displayName}` });
  if (discovery.skippedUnrecognizedFormat > 0) {
    rows.push({ checkName: null, label: `${discovery.skippedUnrecognizedFormat} provider${discovery.skippedUnrecognizedFormat === 1 ? "" : "s"} skipped (unrecognized format)` });
  }
  return rows;
}

function renderPage(
  discovery: DiscoveryResult,
  opts: { state: "pending" | "approved" | "cancelled" | "expired"; selection?: LinkFlowResult }
): string {
  const accent = "#F17455";
  const accentDim = "#C85A3A";
  const bg = "#121212";
  const card = "#1A1A1A";
  const cardBorder = "rgba(255,255,255,0.08)";
  const text = "#F2F2F2";
  const muted = "#9B9BA5";
  const green = "#3FB950";

  const rows = pickableRows(discovery);
  const anySelectable = rows.some((r) => r.checkName !== null);

  // The pending page: every discovered item gets its own checkbox
  // (checked by default — "import everything" is still one click away),
  // so the user can pick exactly what lands in the CLI instead of it
  // being all-or-nothing.
  const pendingRowsHtml = rows
    .map((row) =>
      row.checkName
        ? `
      <label class="row row-checkable">
        <input type="checkbox" name="${row.checkName}" class="row-check" checked>
        <span class="row-label">${escapeHtml(row.label)}</span>
      </label>`
        : `
      <div class="row row-disabled">
        <span class="badge badge-no">–</span>
        <span class="row-label">${escapeHtml(row.label)}</span>
      </div>`
    )
    .join("");

  // The approved page: a plain (non-interactive) summary of exactly what
  // was checked when Connect was clicked, so "Connected" doesn't leave the
  // user guessing what actually landed in their CLI config.
  const approvedRowsHtml = rows
    .map((row) => {
      const checked = row.checkName !== null && !!opts.selection && (row.checkName === "aqua" ? opts.selection.includeAquaKey : opts.selection.selectedProviderIds.includes(row.checkName.slice("provider_".length)));
      if (row.checkName === null) return "";
      return `
      <div class="row">
        <span class="badge ${checked ? "badge-ok" : "badge-no"}">${checked ? "✓" : "–"}</span>
        <span class="row-label">${escapeHtml(row.label)}</span>
      </div>`;
    })
    .join("");

  const brand = `<div class="brand"><span class="brand-mark">E</span><span class="brand-word">Eaon</span></div>`;

  const nothingImported = !!opts.selection && !opts.selection.includeAquaKey && opts.selection.selectedProviderIds.length === 0;

  const body =
    opts.state === "approved"
      ? nothingImported
        ? `${brand}<div class="status-icon status-neutral">–</div><h1>Nothing imported</h1><p class="muted">Everything was unchecked, so there was nothing to bring in. You can close this tab.</p>`
        : `${brand}<div class="status-icon status-ok">✓</div><h1>Connected</h1><div class="rows">${approvedRowsHtml}</div><p class="muted">You can close this tab and return to your terminal.</p>`
      : opts.state === "cancelled"
        ? `${brand}<div class="status-icon status-neutral">–</div><h1>Cancelled</h1><p class="muted">Nothing was imported. You can close this tab.</p>`
        : opts.state === "expired"
          ? `${brand}<div class="status-icon status-neutral">⏱</div><h1>Link expired</h1><p class="muted">Run <code>/link</code> again in the CLI to retry.</p>`
          : `
      ${brand}
      <h1>Connect Eaon CLI to Eaon</h1>
      <p class="muted">Pick what to copy from Eaon Desktop, on this Mac, into the Eaon CLI. Everything is checked by default — uncheck anything you don't want.</p>
      <form method="POST" action="/approve">
        <div class="rows">
          ${pendingRowsHtml}
        </div>
        ${anySelectable ? `<div class="select-toggle"><a href="#" onclick="document.querySelectorAll('.row-check').forEach(c=>c.checked=true);return false;">Select all</a><span class="dot">·</span><a href="#" onclick="document.querySelectorAll('.row-check').forEach(c=>c.checked=false);return false;">Select none</a></div>` : ""}
        <div class="actions">
          <button class="primary" type="submit">Import selected</button>
          <button class="secondary" type="submit" formaction="/cancel">Cancel</button>
        </div>
      </form>
      <p class="footnote">🔒 Runs locally at 127.0.0.1 — nothing leaves this Mac.</p>
    `;

  return `<!doctype html>
<html><head><meta charset="utf-8"><title>Connect Eaon CLI to Eaon</title>
<style>
  * { box-sizing: border-box; }
  body {
    background: radial-gradient(circle at 50% 0%, #1c1c1c 0%, ${bg} 60%);
    color: ${text};
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    display: flex; align-items: center; justify-content: center;
    min-height: 100vh; margin: 0; padding: 24px;
    -webkit-font-smoothing: antialiased;
  }
  .card {
    background: ${card};
    border: 1px solid ${cardBorder};
    border-radius: 20px;
    padding: 40px 36px;
    max-width: 440px; width: 100%;
    box-shadow: 0 24px 60px rgba(0,0,0,0.45), 0 2px 0 rgba(255,255,255,0.02) inset;
    text-align: center;
  }
  .brand { display: flex; align-items: center; justify-content: center; gap: 10px; margin-bottom: 28px; }
  .brand-mark {
    width: 30px; height: 30px; border-radius: 8px;
    background: linear-gradient(135deg, ${accent}, ${accentDim});
    color: #1a1008; font-weight: 800; font-size: 15px;
    display: flex; align-items: center; justify-content: center;
    box-shadow: 0 4px 12px rgba(241,116,85,0.35);
  }
  .brand-word { font-weight: 700; letter-spacing: 0.02em; color: ${muted}; font-size: 14px; text-transform: uppercase; }
  h1 { font-size: 21px; margin: 0 0 10px; font-weight: 650; letter-spacing: -0.01em; }
  p.muted { color: ${muted}; line-height: 1.55; font-size: 14.5px; margin: 0 0 22px; }
  .rows { text-align: left; margin-bottom: 12px; border-top: 1px solid ${cardBorder}; }
  .row { display: flex; align-items: center; gap: 12px; padding: 12px 2px; border-bottom: 1px solid ${cardBorder}; }
  .row-checkable { cursor: pointer; }
  .row-checkable:hover { background: rgba(255,255,255,0.03); }
  .row-check { flex: none; width: 17px; height: 17px; accent-color: ${accent}; cursor: pointer; }
  .row-disabled { opacity: 0.7; }
  .row-label { font-size: 14px; color: ${text}; }
  .badge {
    flex: none; width: 22px; height: 22px; border-radius: 999px;
    display: flex; align-items: center; justify-content: center;
    font-size: 12px; font-weight: 700;
  }
  .badge-ok { background: rgba(63,185,80,0.15); color: ${green}; }
  .badge-no { background: rgba(255,255,255,0.06); color: ${muted}; }
  code { background: rgba(255,255,255,0.08); padding: 2px 6px; border-radius: 5px; font-size: 13px; }
  .select-toggle { text-align: left; margin: 12px 2px 22px; font-size: 13px; }
  .select-toggle a { color: ${muted}; text-decoration: none; }
  .select-toggle a:hover { color: ${text}; text-decoration: underline; }
  .select-toggle .dot { margin: 0 8px; color: ${cardBorder}; }
  .actions { display: flex; gap: 10px; justify-content: center; }
  button {
    font-size: 14.5px; padding: 11px 22px; border-radius: 10px; border: none;
    cursor: pointer; font-weight: 650; transition: transform 0.06s ease, filter 0.15s ease;
    font-family: inherit;
  }
  button:hover { filter: brightness(1.08); }
  button:active { transform: scale(0.98); }
  button.primary { background: linear-gradient(135deg, ${accent}, ${accentDim}); color: #1a1008; box-shadow: 0 6px 16px rgba(241,116,85,0.3); }
  button.secondary { background: transparent; color: ${muted}; border: 1px solid rgba(255,255,255,0.14); }
  button.secondary:hover { background: rgba(255,255,255,0.04); }
  .footnote { margin: 22px 0 0; font-size: 12px; color: ${muted}; opacity: 0.8; }
  .status-icon {
    width: 52px; height: 52px; border-radius: 999px; margin: 0 auto 18px;
    display: flex; align-items: center; justify-content: center; font-size: 24px; font-weight: 700;
  }
  .status-ok { background: rgba(63,185,80,0.15); color: ${green}; }
  .status-neutral { background: rgba(255,255,255,0.06); color: ${muted}; }
</style></head>
<body><div class="card">${body}</div></body></html>`;
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/** Reads a request body to completion — small and local-only (a plain HTML
 * form POST from the user's own browser), so no size cap is needed here. */
function readRequestBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

/** A checked HTML checkbox shows up in an `application/x-www-form-urlencoded`
 * body as `name=on`; an unchecked one is simply absent — there's no
 * "false" to parse, just presence or absence. */
function parseSelection(body: string, discovery: DiscoveryResult): { includeAquaKey: boolean; selectedProviderIds: string[] } {
  const params = new URLSearchParams(body);
  return {
    includeAquaKey: !!discovery.aquaApiKey && params.has("aqua"),
    selectedProviderIds: discovery.customProviders.filter((p) => params.has(`provider_${p.id}`)).map((p) => p.id),
  };
}

/** Starts the local confirmation server, resolving once the user approves,
 * cancels, or the link expires. The server is always closed before this
 * resolves — never left listening in the background. */
export function runLinkServer(discovery: DiscoveryResult): { url: Promise<string>; result: Promise<LinkFlowResult> } {
  let resolveUrl!: (url: string) => void;
  let rejectUrl!: (err: Error) => void;
  let resolveResult!: (result: LinkFlowResult) => void;
  const urlPromise = new Promise<string>((res, rej) => { resolveUrl = res; rejectUrl = rej; });
  const resultPromise = new Promise<LinkFlowResult>((res) => { resolveResult = res; });

  let settled = false;
  const finish = (result: LinkFlowResult, finalState: "approved" | "cancelled" | "expired") => {
    if (settled) return;
    settled = true;
    clearTimeout(timeout);
    resolveResult(result);
    // Give the final response a moment to actually flush before closing.
    setTimeout(() => server.close(), 500);
    void finalState;
  };

  const server = http.createServer((req, res) => {
    void handleRequest(req, res).catch(() => {
      // The response may already be partially written by the time
      // something here throws — best-effort only, never let a malformed
      // request crash the whole /link flow (or the process).
      try {
        if (!res.headersSent) res.writeHead(500, { "Content-Type": "text/plain" });
        if (!res.writableEnded) res.end("Internal error");
      } catch {
        // nothing more to do
      }
    });
  });

  async function handleRequest(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    if (req.method === "GET" && req.url === "/") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(renderPage(discovery, { state: settled ? "expired" : "pending" }));
      return;
    }
    if (req.method === "POST" && req.url === "/approve") {
      const selection = parseSelection(await readRequestBody(req), discovery);
      const result: LinkFlowResult = { approved: true, timedOut: false, ...selection };
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(renderPage(discovery, { state: "approved", selection: result }));
      finish(result, "approved");
      return;
    }
    if (req.method === "POST" && req.url === "/cancel") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(renderPage(discovery, { state: "cancelled" }));
      finish({ approved: false, timedOut: false, includeAquaKey: false, selectedProviderIds: [] }, "cancelled");
      return;
    }
    res.writeHead(404);
    res.end();
  }

  const timeout = setTimeout(
    () => finish({ approved: false, timedOut: true, includeAquaKey: false, selectedProviderIds: [] }, "expired"),
    TIMEOUT_MS
  );

  // An unhandled 'error' event on an EventEmitter (which http.Server is)
  // throws synchronously with no listener — e.g. a transient bind/socket
  // failure would otherwise crash the whole CLI process instead of just
  // failing /link. Settle both promises so the caller gets a normal
  // rejection/outcome to handle, never a hang or an uncaught throw.
  server.on("error", (err) => {
    clearTimeout(timeout);
    if (!settled) {
      settled = true;
      resolveResult({ approved: false, timedOut: false, includeAquaKey: false, selectedProviderIds: [] });
    }
    rejectUrl(err instanceof Error ? err : new Error(String(err)));
  });

  // Loopback only, port 0 — the OS picks a free local port; never bound to
  // a real network interface, so nothing outside this Mac can ever reach it.
  server.listen(0, "127.0.0.1", () => {
    const address = server.address();
    const port = typeof address === "object" && address ? address.port : 0;
    resolveUrl(`http://127.0.0.1:${port}/`);
  });

  return { url: urlPromise, result: resultPromise };
}
