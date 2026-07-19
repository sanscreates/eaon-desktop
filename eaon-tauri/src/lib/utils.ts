import type { Conversation } from "./types";

/** Mirrors ChatViewModel.deriveTitle — first line, 42 chars + ellipsis. */
export function deriveTitle(text: string): string {
  const flat = text.replace(/\n/g, " ").trim();
  const clipped = flat.length > 42 ? flat.slice(0, 42) + "…" : flat;
  return clipped || "New chat";
}

export function uid(): string {
  return crypto.randomUUID();
}

export function formatBytes(bytes: number): string {
  if (bytes >= 1_000_000_000) return `${(bytes / 1_000_000_000).toFixed(1)} GB`;
  if (bytes >= 1_000_000) return `${(bytes / 1_000_000).toFixed(0)} MB`;
  if (bytes >= 1_000) return `${(bytes / 1_000).toFixed(0)} KB`;
  return `${bytes} B`;
}

export interface ConversationBucket {
  title: string;
  conversations: Conversation[];
}

/** ChatGPT-style date buckets, mirroring SidebarView.dateBuckets. */
export function dateBuckets(conversations: Conversation[]): ConversationBucket[] {
  const buckets: ConversationBucket[] = [];
  const now = new Date();
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const day = 86_400_000;

  const titleFor = (updatedAt: number): string => {
    if (updatedAt >= startOfToday) return "Today";
    if (updatedAt >= startOfToday - day) return "Yesterday";
    if (updatedAt >= startOfToday - 7 * day) return "Previous 7 Days";
    if (updatedAt >= startOfToday - 30 * day) return "Previous 30 Days";
    return "Older";
  };

  for (const conversation of conversations) {
    const title = titleFor(conversation.updatedAt);
    const last = buckets[buckets.length - 1];
    if (last && last.title === title) last.conversations.push(conversation);
    else buckets.push({ title, conversations: [conversation] });
  }
  return buckets;
}

export async function copyToClipboard(text: string): Promise<void> {
  await navigator.clipboard.writeText(text);
}

export const isMac = navigator.platform.toUpperCase().includes("MAC");
/** ⌘ on macOS, Ctrl elsewhere — shortcut hints and handlers both use this. */
export const modKeyLabel = isMac ? "⌘" : "Ctrl";
export function isModKey(e: KeyboardEvent): boolean {
  return isMac ? e.metaKey : e.ctrlKey;
}
