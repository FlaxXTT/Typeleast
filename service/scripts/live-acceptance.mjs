import { llmRoute, serviceBase, serviceToken } from './service-env.mjs';

/**
 * Live acceptance run against the running service: each case states what the
 * speaker said and what the cleanup must and must not do. Uses your API quota.
 */
const BASE = (await serviceBase()) + '/api/voice-polish';
const token = await serviceToken();
const llm = llmRoute();

const CASES = [
  {
    label: 'self-correction',
    text: "um so uh we're going to send it tuesday, no wait, wednesday",
    must: [/wednesday/i],
    mustNot: [/tuesday/i, /\bum\b/i, /\buh\b/i],
  },
  {
    label: 'dictated list becomes bullets',
    text: 'so we need to do three things first update the parser second add tests third write the docs',
    must: [/parser/i, /tests/i, /docs/i],
    mustNot: [],
    notes: 'a list is expected to become bullets',
  },
  {
    label: 'prose stays prose',
    text: 'i was thinking about the migration yesterday and honestly it feels riskier than we assumed because the schema changes touch every table',
    must: [/migration/i, /schema/i],
    mustNot: [/^\s*[-\d]/m],
    notes: 'no bullet should be introduced into a narrative',
  },
  {
    label: 'request becomes a structured prompt',
    text: 'i want you to refactor the auth module it should use the new token helper and keep the existing api and add tests',
    must: [/auth/i, /token/i, /tests/i],
    mustNot: [],
  },
];

let failures = 0;
for (const item of CASES) {
  const response = await fetch(BASE + '/polish', {
    method: 'POST',
    headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' },
    body: JSON.stringify({ text: item.text, strength: 'prompt', appHint: 'com.example.app', llm }),
  });
  const body = await response.json();
  const failed = [];
  if (body.fallback !== false) failed.push('fell back: ' + body.fallbackReason);
  for (const pattern of item.must) if (!pattern.test(body.text)) failed.push('missing ' + pattern);
  for (const pattern of item.mustNot) if (pattern.test(body.text)) failed.push('unwanted ' + pattern);
  if (failed.length > 0) failures += 1;
  console.log((failed.length === 0 ? 'PASS  ' : 'FAIL  ') + item.label + (item.notes ? '  (' + item.notes + ')' : ''));
  console.log('      in : ' + item.text);
  console.log('      out: ' + JSON.stringify(body.text));
  console.log('      ms : ' + JSON.stringify(body.ms) + (failed.length > 0 ? '  PROBLEMS: ' + failed.join('; ') : ''));
}
console.log('');
console.log(failures === 0 ? 'ALL LIVE CASES PASSED' : failures + ' LIVE CASE(S) FAILED');
process.exit(failures === 0 ? 0 : 1);
