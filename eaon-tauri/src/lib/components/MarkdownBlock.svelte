<script lang="ts">
  // Port of MarkdownBlockView.swift — headings, paragraphs, bullet/numbered
  // lists with indent levels, blockquotes with the 3px bar, real tables in
  // a rounded card, horizontal rules, and inline bold/italic/code/links.
  import { parseMarkdown, renderInline } from "$lib/markdown";

  let { text = "" }: { text?: string } = $props();

  const lines = $derived(parseMarkdown(text));

  const headingSize = (level: number) =>
    level === 1 ? "calc(var(--message-font-size) + 8px)"
    : level === 2 ? "calc(var(--message-font-size) + 5px)"
    : level === 3 ? "calc(var(--message-font-size) + 2px)"
    : "calc(var(--message-font-size) + 1px)";
</script>

<div class="md selectable">
  {#each lines as line}
    {#if line.type === "heading"}
      <div class="heading" class:top={line.level <= 2} style="font-size:{headingSize(line.level)}">
        {@html renderInline(line.content)}
      </div>
    {:else if line.type === "paragraph"}
      <p>{@html renderInline(line.content)}</p>
    {:else if line.type === "bullet"}
      <div class="li" style="padding-left:{line.indent * 18}px">
        <span class="dot"></span>
        <span class="li-body">{@html renderInline(line.content)}</span>
      </div>
    {:else if line.type === "numbered"}
      <div class="li" style="padding-left:{line.indent * 18}px">
        <span class="num">{line.number}.</span>
        <span class="li-body">{@html renderInline(line.content)}</span>
      </div>
    {:else if line.type === "quote"}
      <div class="quote">
        <span class="bar"></span>
        <span class="quote-body">{@html renderInline(line.content)}</span>
      </div>
    {:else if line.type === "table"}
      <div class="table-card">
        <table>
          <thead>
            <tr>
              {#each line.headers as header, i}
                <th style="text-align:{line.alignments[i] === 'center' ? 'center' : line.alignments[i] === 'trailing' ? 'right' : 'left'}">
                  {@html renderInline(header)}
                </th>
              {/each}
            </tr>
          </thead>
          <tbody>
            {#each line.rows as row}
              <tr>
                {#each line.headers as _, colIndex}
                  <td style="text-align:{line.alignments[colIndex] === 'center' ? 'center' : line.alignments[colIndex] === 'trailing' ? 'right' : 'left'}">
                    {@html renderInline(row[colIndex] ?? "")}
                  </td>
                {/each}
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {:else if line.type === "rule"}
      <div class="rule"></div>
    {:else if line.type === "spacer"}
      <div class="spacer"></div>
    {/if}
  {/each}
</div>

<style>
  .md {
    font-family: var(--font-sans);
    font-size: var(--message-font-size);
    color: var(--text-primary);
    line-height: 1.6;
    word-break: break-word;
  }
  .md :global(a) {
    color: var(--link);
    text-decoration: none;
  }
  .md :global(a:hover) {
    text-decoration: underline;
  }
  .heading {
    font-weight: 600;
    padding: 10px 0 4px;
  }
  .heading.top {
    padding-top: 14px;
  }
  p {
    margin: 0;
    padding: 4px 0;
  }
  .li {
    display: flex;
    gap: 8px;
    padding-top: 3px;
    padding-bottom: 3px;
    align-items: baseline;
  }
  .dot {
    width: 5px;
    height: 5px;
    border-radius: 50%;
    background: var(--text-secondary);
    flex-shrink: 0;
    transform: translateY(-2.5px);
  }
  .num {
    font-weight: 500;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
    flex-shrink: 0;
  }
  .li-body {
    flex: 1;
  }
  .quote {
    display: flex;
    gap: 10px;
    padding: 4px 0;
  }
  .bar {
    width: 3px;
    border-radius: 2px;
    background: var(--border-medium);
    flex-shrink: 0;
  }
  .quote-body {
    color: var(--text-secondary);
    flex: 1;
  }
  .table-card {
    margin: 8px 0;
    border: 1px solid var(--border-subtle);
    border-radius: 10px;
    background: var(--bg-subtle);
    overflow-x: auto;
  }
  table {
    border-collapse: collapse;
    width: 100%;
  }
  th {
    font-size: calc(var(--message-font-size) - 1px);
    font-weight: 600;
    color: var(--text-primary);
    padding: 8px 12px;
    border-bottom: 1px solid var(--border-medium);
  }
  td {
    font-size: calc(var(--message-font-size) - 1px);
    color: var(--text-secondary);
    padding: 8px 12px;
    border-bottom: 1px solid var(--border-subtle);
  }
  tr:last-child td {
    border-bottom: none;
  }
  .rule {
    height: 1px;
    background: var(--border-subtle);
    margin: 12px 0;
  }
  .spacer {
    height: 6px;
  }
</style>
