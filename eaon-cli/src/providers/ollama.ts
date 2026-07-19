// Local Ollama — tags/pull/delete against the native Ollama API, chat
// itself goes through the shared OpenAI-compatible streamChat() at
// {baseUrl}/v1. Verified-outcome deletes (re-checks the tags list rather
// than trusting a 200) mirrors the same fix the Mac app and Tauri core both
// needed after "deleted but storage didn't change" turned out to be real.

export const DEFAULT_OLLAMA_URL = "http://127.0.0.1:11434";

export interface OllamaModel {
  name: string;
  sizeBytes: number;
  paramSize: string | null;
  quantization: string | null;
  family: string | null;
  /** True when Ollama's own /api/tags reports "tools" in this model's
   * capabilities — a real signal, not a name-based guess, for whether
   * native tool-calling is worth attempting first. */
  supportsTools: boolean;
}

interface TagsResponse {
  models?: Array<{
    name: string;
    size?: number;
    remote_host?: string | null;
    details?: { family?: string | null; parameter_size?: string | null; quantization_level?: string | null };
    capabilities?: string[];
  }>;
}

/** Live installed-model list. Excludes cloud-proxied entries (remote_host
 * set — they run on ollama.com, not this machine) and embedding models
 * (can't chat), same filter as the Mac app's refreshOllamaModels. */
export async function fetchOllamaTags(baseUrl: string): Promise<OllamaModel[]> {
  const response = await fetch(`${baseUrl.replace(/\/+$/, "")}/api/tags`, { signal: AbortSignal.timeout(3000) });
  if (!response.ok) throw new Error(`Ollama returned ${response.status}`);
  const json = (await response.json()) as TagsResponse;
  return (json.models ?? [])
    .filter((m) => !m.remote_host && !m.name.toLowerCase().includes("embed"))
    .map((m) => ({
      name: m.name,
      sizeBytes: m.size ?? 0,
      paramSize: m.details?.parameter_size || null,
      quantization: m.details?.quantization_level || null,
      family: m.details?.family || null,
      supportsTools: m.capabilities?.includes("tools") ?? false,
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

export async function isOllamaReachable(baseUrl: string): Promise<boolean> {
  try {
    await fetchOllamaTags(baseUrl);
    return true;
  } catch {
    return false;
  }
}

export type PullEvent =
  | { type: "progress"; status: string; completed: number; total: number }
  | { type: "done" }
  | { type: "error"; message: string };

/** Streams `ollama pull` progress via the NDJSON /api/pull endpoint. */
export async function* pullOllamaModel(baseUrl: string, model: string): AsyncGenerator<PullEvent, void, void> {
  let response: Response;
  try {
    response = await fetch(`${baseUrl.replace(/\/+$/, "")}/api/pull`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model, stream: true }),
    });
  } catch (e) {
    yield { type: "error", message: `Couldn't reach Ollama: ${e instanceof Error ? e.message : String(e)}` };
    return;
  }
  if (!response.ok || !response.body) {
    yield { type: "error", message: `Ollama returned ${response.status}` };
    return;
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let newlineIndex: number;
    while ((newlineIndex = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, newlineIndex).trim();
      buffer = buffer.slice(newlineIndex + 1);
      if (!line) continue;
      let json: any;
      try {
        json = JSON.parse(line);
      } catch {
        continue;
      }
      if (typeof json.error === "string") {
        yield { type: "error", message: json.error };
        return;
      }
      yield { type: "progress", status: json.status ?? "", completed: json.completed ?? 0, total: json.total ?? 0 };
    }
  }
  yield { type: "done" };
}

/** Deletes AND verifies the model is actually gone before reporting success. */
export async function deleteOllamaModel(baseUrl: string, model: string): Promise<string | null> {
  const base = baseUrl.replace(/\/+$/, "");
  let response: Response;
  try {
    response = await fetch(`${base}/api/delete`, {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model }),
    });
  } catch (e) {
    return `Couldn't reach Ollama to delete ${model}: ${e instanceof Error ? e.message : String(e)}`;
  }
  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    return `Ollama refused to delete ${model}: ${detail || `HTTP ${response.status}`}`;
  }
  try {
    const tags = await fetchOllamaTags(base);
    if (tags.some((m) => m.name === model)) {
      return `Ollama reported success deleting ${model}, but it's still in the model list — try again, or run \`ollama rm ${model}\`.`;
    }
  } catch {
    // Tags refresh failing right after a successful delete isn't itself a
    // delete failure — don't report a false negative.
  }
  return null;
}
