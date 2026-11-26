import { libraryRequest } from "../lib/agent-library.js";

const publicErrors = new Set(["changed", "invalid-library", "library-full", "invalid-request",
  "github-link", "github-unavailable", "github-rate-limit", "github-too-large", "github-no-skill"]);

const chunks = [];
let bytes = 0;
try {
  for await (const chunk of process.stdin) {
    bytes += chunk.length;
    if (bytes > 4 * 1024 * 1024) throw new Error("invalid-request");
    chunks.push(chunk);
  }
  const request = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  const result = await libraryRequest(request, { storage: process.argv[2] });
  process.stdout.write(JSON.stringify(result));
} catch (error) {
  process.stdout.write(JSON.stringify({ error: publicErrors.has(error.message) ? error.message : "unavailable" }));
}
