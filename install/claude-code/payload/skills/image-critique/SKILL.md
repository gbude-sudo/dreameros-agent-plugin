---
name: image-critique
description: Score an existing image against its intended prompt with the DreamerOS 3-engine vision quorum (GPT, Claude, Gemini). Use when asked to grade, critique, or rate how well an image matches its prompt, or to decide if a generated frame is good enough to ship.
---

Score a PNG you already have against the prompt it was supposed to fulfill,
using the same vision judges the VividDream baker uses: OpenAI gpt-4o,
Anthropic claude-sonnet-4-6, and Google gemini-3.1-pro. Each judge returns a
single 0.0-1.0 prompt-fidelity score; you average the judges that answered.
Judges whose key is absent sit out, and the result says so.

This is the read-only sibling of `image-gen`: same judges, same scoring, but
it grades an existing file instead of generating one.

Paths below are relative to the repo root.

## Prerequisites

Node 22. Environment keys (presence decides which judges score; at least one
is needed for any score at all):

```bash
export OPENAI_API_KEY=...     # GPT vision judge (gpt-4o)
export ANTHROPIC_API_KEY=...  # Claude vision judge (claude-sonnet-4-6)
export GOOGLE_AI_API_KEY=...  # Gemini vision judge (gemini-3.1-pro)
```

A judge with no key is skipped. With all three you get the full quorum; with
one or two you get a reduced bench and the output names who answered. No key
value is ever printed (presence booleans only; the Google key rides in a
header, never the URL). Real network egress to the vendor APIs is required.

## Where the judge logic lives

The authoritative judge implementations are in
`scripts/generate-showcase.mjs` (the `buildJudges` function: the exact request
shape per vendor, and `parseScore` which extracts the first numeric token and
clamps it to 0-1). `scripts/gen-image.mjs` carries the same judge code. Read
either to see how a judge call is built; the snippet below is a standalone
critique-only runner that mirrors that same logic.

## Run (inline node snippet)

Save this as `/tmp/critique.mjs` and run it with the image path and the
intended prompt. It reads the PNG, base64-encodes it, calls every seated
judge, and prints each score plus the average.

```bash
cat > /tmp/critique.mjs <<'EOF'
import { readFile } from "node:fs/promises";

const imgPath = process.argv[2];
const prompt = process.argv[3];
if (!imgPath || !prompt) {
  console.error('usage: node /tmp/critique.mjs <image.png> "<intended prompt>"');
  process.exit(1);
}

const keys = {
  openai: process.env.OPENAI_API_KEY || "",
  anthropic: process.env.ANTHROPIC_API_KEY || "",
  google: process.env.GOOGLE_AI_API_KEY || "",
};
console.log(
  `keys present: openai=${Boolean(keys.openai)} anthropic=${Boolean(keys.anthropic)} google=${Boolean(keys.google)}`,
);

const b64 = (await readFile(imgPath)).toString("base64");

function instruction(p) {
  return [
    "You are a strict art director scoring how well a generated image fulfills its text prompt.",
    `Prompt: "${p}"`,
    "Judge prompt fidelity, composition, lighting, and technical quality as one overall score.",
    "Reply with ONLY a single decimal number between 0.0 and 1.0. No other words.",
  ].join("\n");
}
function parseScore(text) {
  if (typeof text !== "string") return null;
  const m = text.match(/-?\d+(?:\.\d+)?/);
  if (!m) return null;
  const v = Number.parseFloat(m[0]);
  if (!Number.isFinite(v)) return null;
  return Math.min(1, Math.max(0, v));
}

async function openai() {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${keys.openai}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "gpt-4o",
      max_completion_tokens: 16,
      messages: [{ role: "user", content: [
        { type: "text", text: instruction(prompt) },
        { type: "image_url", image_url: { url: `data:image/png;base64,${b64}` } },
      ] }],
    }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const d = await res.json();
  return parseScore(d?.choices?.[0]?.message?.content || "");
}
async function anthropic() {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": keys.anthropic, "anthropic-version": "2023-06-01", "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "claude-sonnet-4-6",
      max_tokens: 16,
      messages: [{ role: "user", content: [
        { type: "image", source: { type: "base64", media_type: "image/png", data: b64 } },
        { type: "text", text: instruction(prompt) },
      ] }],
    }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const d = await res.json();
  const text = (Array.isArray(d?.content) ? d.content : [])
    .filter((b) => b?.type === "text").map((b) => b.text).join(" ");
  return parseScore(text);
}
async function google() {
  const res = await fetch(
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-pro:generateContent",
    {
      method: "POST",
      headers: { "x-goog-api-key": keys.google, "Content-Type": "application/json" },
      body: JSON.stringify({ contents: [{ parts: [
        { text: instruction(prompt) },
        { inline_data: { mime_type: "image/png", data: b64 } },
      ] }] }),
    },
  );
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const d = await res.json();
  const parts = d?.candidates?.[0]?.content?.parts || [];
  return parseScore(parts.map((p) => p?.text || "").join(" "));
}

const bench = [];
if (keys.openai) bench.push(["openai", openai]);
if (keys.anthropic) bench.push(["anthropic", anthropic]);
if (keys.google) bench.push(["google", google]);
if (bench.length === 0) {
  console.error("no judge keys set; nothing to score. Set at least OPENAI_API_KEY.");
  process.exit(1);
}

const got = [];
for (const [name, fn] of bench) {
  try {
    const s = await fn();
    if (s === null) throw new Error("no parseable 0-1 score in reply");
    console.log(`  ${name}: ${s.toFixed(2)}`);
    got.push(s);
  } catch (e) {
    console.warn(`  ${name}: skip (${String(e.message || e)})`);
  }
}
if (got.length === 0) {
  console.error("every judge call failed; no aggregate.");
  process.exit(1);
}
const avg = got.reduce((a, b) => a + b, 0) / got.length;
console.log(`aggregate: ${avg.toFixed(2)} (${got.length}/${bench.length} judges answered)`);
EOF

node /tmp/critique.mjs public/vividdream/lighthouse-dusk.png \
  "Long exposure blue hour seascape: a lone lighthouse on a basalt headland, volumetric beam, mirror-calm tide, cinematic wide, photographic"
```

Expected shape of the output:

```
keys present: openai=true anthropic=true google=true
  openai: 0.82
  anthropic: 0.78
  google: 0.80
aggregate: 0.80 (3/3 judges answered)
```

## Score interpretation

The number is a prompt-fidelity-plus-craft score, the same scale the baker
uses to pick a winner and decide on a reroll:

- **>= 0.80**: strong. Ships without hesitation.
- **0.60 - 0.79**: acceptable. Above the baker's reroll threshold; usable.
- **< 0.60**: weak. This is exactly the line at which the VividDream baker
  generates one extra candidate and re-judges. Treat a sub-0.6 image as a
  reroll candidate, not a ship.

The aggregate is the mean of only the judges that returned a parseable score.
A 1-judge aggregate is one opinion; a 3-judge aggregate is the full quorum and
is the more trustworthy number.

## Judges sit out when their key is absent

A judge with no key is never called and never counted; it shows nothing
(or `skip` if the key was present but the call failed). This is honest by
design: the aggregate only reflects judges that actually scored, and the
`(N/M judges answered)` tail tells you how many of the seated judges responded.
If you want a full quorum reading, set all three keys.

## Gotchas

- **Egress required.** Each judge is a live API call. A blocked sandbox makes
  every judge `skip` and the runner exits 1 with no aggregate. Run where the
  vendor APIs are reachable.
- **No keys at all = no score.** With zero judge keys the snippet exits 1
  immediately. At minimum set `OPENAI_API_KEY`.
- **One image, one prompt.** This grades a single file against a single
  intended prompt. To grade a set, loop the snippet over each (file, prompt)
  pair.
- **Format.** The judges are wired for `image/png`. Convert other formats to
  PNG first, or adjust the `media_type` / `mime_type` and the data URL in the
  snippet to match.
