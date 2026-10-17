import { factTokens, inventedFacts, validateOutput } from '../lib/validate.js';

const CASES = [
  ['self-correction', "um so we should send the report on tuesday, no wait, wednesday", "Send the report on Wednesday."],
  ['filler removal', "um uh so basically we need to ship the feature by friday", "We need to ship the feature by Friday."],
  ['list', "so we need to do three things first update the parser second add tests third write the docs", "We need to do three things:\n- Update the parser\n- Add tests\n- Write the docs"],
  ['prompt', "i want you to refactor the auth module it should use the new token helper and keep the existing api and add tests", "Refactor the auth module.\n\n- Use the new token helper.\n- Keep the existing API.\n- Add tests."],
  ['short', "sounds good", "Sounds good."],
  ['fenced', "the answer is to restart the service and then check the logs", "Restart the service, then check the logs."],
];
for (const [label, raw, out] of CASES) {
  const invented = inventedFacts(raw, out);
  const v = validateOutput({ rawText: raw, output: out, strength: 'prompt' });
  console.log(label.padEnd(18) + ' ok=' + String(v.ok).padEnd(5) + ' reason=' + String(v.reason ?? '-').padEnd(14) + ' invented=' + JSON.stringify(invented));
}
