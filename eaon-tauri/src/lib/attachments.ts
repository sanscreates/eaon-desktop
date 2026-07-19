// Attachments — the cross-platform port of the Mac app's AttachmentStore +
// ImagePayloadBuilder + ModelCatalog.supportsVision. Images are normalized
// on import (canvas → PNG, long edge capped) so a picked HEIC/oversized
// photo neither blows a provider's payload limit nor balloons token cost;
// non-image files ride along as a "[Attached: …]" note exactly like macOS.

import * as api from "./api";
import type { ContentPart, MessageAttachment } from "./types";
import { uid } from "./utils";

/** Anthropic's own docs note no vision-quality benefit past this on the
 *  long edge — the same provider-agnostic cap the Mac app uses. */
const MAX_IMAGE_DIMENSION = 1568;

/** Mirrors ModelCatalog.supportsVision — which model ids get real image
 *  parts vs. the filename fallback note. */
export function supportsVision(modelId: string): boolean {
  const id = modelId.toLowerCase();

  const textOnly = new Set([
    "gpt-oss", "hermes", "nemotron", "step-3.7", "sonar", "mistral",
    "mistral-3.5", "minimax-m2.7", "minimax-m3", "gemma-4", "gpt-5-nano",
    "llama-3.1",
  ]);
  if (textOnly.has(id)) return false;

  if (id.startsWith("gemini")) return true;
  if (id.startsWith("gpt-5") || id.startsWith("gpt-4")) return true;
  if (id.startsWith("haiku") || id.startsWith("sonnet") || id.startsWith("opus") || id.startsWith("fable")) return true;
  if (id.startsWith("grok")) return true;
  if (id.includes("qwen")) return true;
  if (id.includes("llama-4")) return true;
  if (id.includes("glm")) return true;
  if (id.includes("kimi")) return true;
  if (id.includes("deepseek-v4")) return true;
  if (id.startsWith("nova")) return true;
  if (id.includes("mimo")) return true;
  // Ollama vision-capable families (the /api/tags names have no dashes).
  if (id.includes("llava") || id.includes("moondream") || id.includes("minicpm-v")) return true;
  if (id.startsWith("gemma3") || id.includes("gemma3:")) return true;

  return false;
}

/** File → base64 (no data: prefix). */
function fileToBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error ?? new Error("read failed"));
    reader.onload = () => {
      const url = String(reader.result);
      const comma = url.indexOf(",");
      resolve(comma === -1 ? url : url.slice(comma + 1));
    };
    reader.readAsDataURL(file);
  });
}

/** Decodes, caps to MAX_IMAGE_DIMENSION on the long edge, re-encodes as
 *  PNG. Returns null when the webview can't decode the format (rare —
 *  e.g. HEIC on Windows), in which case the raw bytes are stored as-is. */
async function normalizedPngBase64(file: File): Promise<string | null> {
  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(file);
  } catch {
    return null;
  }
  try {
    const longEdge = Math.max(bitmap.width, bitmap.height);
    const scale = longEdge > MAX_IMAGE_DIMENSION ? MAX_IMAGE_DIMENSION / longEdge : 1;
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext("2d");
    if (!ctx) return null;
    ctx.drawImage(bitmap, 0, 0, width, height);
    const dataUrl = canvas.toDataURL("image/png");
    return dataUrl.slice(dataUrl.indexOf(",") + 1);
  } finally {
    bitmap.close();
  }
}

/** Imports one picked/pasted/dropped file: images are normalized to PNG and
 *  capped; everything else is stored byte-for-byte. Returns the attachment
 *  record plus a ready thumbnail data URL for images. */
export async function importFile(file: File): Promise<{ attachment: MessageAttachment; previewDataUrl: string | null }> {
  const isImage = file.type.startsWith("image/");
  if (isImage) {
    const png = await normalizedPngBase64(file);
    if (png) {
      const fileName = file.name.replace(/\.[a-z0-9]+$/i, "") + ".png";
      const stored = await api.saveAttachment(png, fileName || "image.png");
      return {
        attachment: { id: uid(), fileName: file.name || "Pasted image.png", kind: "image", storedFileName: stored, mimeType: "image/png" },
        previewDataUrl: `data:image/png;base64,${png}`,
      };
    }
    // Undecodable in this webview — store raw and send with its real mime;
    // vision providers accept jpeg/png/webp/gif directly.
    const raw = await fileToBase64(file);
    const stored = await api.saveAttachment(raw, file.name || "image");
    return {
      attachment: { id: uid(), fileName: file.name || "image", kind: "image", storedFileName: stored, mimeType: file.type || "image/png" },
      previewDataUrl: `data:${file.type || "image/png"};base64,${raw}`,
    };
  }

  const raw = await fileToBase64(file);
  const stored = await api.saveAttachment(raw, file.name || "file");
  return {
    attachment: { id: uid(), fileName: file.name || "file", kind: "file", storedFileName: stored, mimeType: file.type || "application/octet-stream" },
    previewDataUrl: null,
  };
}

/** Builds the request content for one message: real image parts for what
 *  the model can see, the "[Attached: …]" fallback note for the rest —
 *  the exact split ChatViewModel.historyTurn/apiContent makes. */
export async function buildContent(
  text: string,
  attachments: MessageAttachment[] | undefined,
  modelId: string
): Promise<string | ContentPart[]> {
  const all = attachments ?? [];
  if (!all.length) return text;

  const vision = supportsVision(modelId);
  const parts: ContentPart[] = [];
  const unsent: MessageAttachment[] = [];

  for (const attachment of all) {
    if (vision && attachment.kind === "image") {
      try {
        const base64 = await api.readAttachment(attachment.storedFileName);
        parts.push({ type: "image_url", image_url: { url: `data:${attachment.mimeType};base64,${base64}` } });
      } catch {
        unsent.push(attachment);
      }
    } else {
      unsent.push(attachment);
    }
  }

  let body = text;
  if (unsent.length) {
    const note = `[Attached: ${unsent.map((a) => a.fileName).join(", ")}]`;
    body = body ? `${body}\n\n${note}` : note;
  }

  if (!parts.length) return body;
  const out: ContentPart[] = [];
  if (body) out.push({ type: "text", text: body });
  return [...out, ...parts];
}
