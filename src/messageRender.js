/*
 * Rendering helpers for chat messages. Message text comes from other users,
 * so everything that ends up in the DOM goes through DOMPurify, and
 * markdown-it runs with raw HTML disabled (see MessageMarkdown.vue).
 */
import DOMPurify from "dompurify";

// Custom emoji such as `:party-jerboa:` or `:jerboa::modifier:`. The match is
// interpolated into HTML below, so keep the character class this strict.
const EMOJI_RE = /:([A-Za-z0-9_+-]+(?:::[A-Za-z0-9_+-]+)?):/g;

const PURIFY_CONFIG = {
  // Markdown never produces these; there is no reason to let them through.
  FORBID_TAGS: ["style", "form", "button", "textarea", "select"],
};

export function sanitizeHtml(html) {
  return DOMPurify.sanitize(html, PURIFY_CONFIG);
}

// A message starting with `>>>` is quoted as a whole (Slack style). Express
// that as a markdown blockquote instead of raw HTML.
export function preMessageRender(text) {
  if (text.startsWith(">>>")) {
    return text
      .replace(/^>>>[ \t]*/, "")
      .split("\n")
      .map((line) => "> " + line)
      .join("\n");
  }
  return text;
}

export function postMessageRender(html) {
  let data = html.replace(
    EMOJI_RE,
    "<img class='emoji' src='" +
      process.env.VUE_APP_SERVER_BASE +
      "emoji/$1' alt=':$1:'/>"
  );

  // If the message is only emoji, show them large.
  let text = html
    .substring(3, html.length - 5)
    .replace(EMOJI_RE, "")
    .trim();
  if (!text) data = "<h1>" + data + "</h1>";

  return sanitizeHtml(data);
}
