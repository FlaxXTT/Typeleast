import { llmRoute, serviceBase, serviceToken } from './service-env.mjs';

/**
 * Live acceptance for the cleanup prompt.
 *
 * Cases with a known expected shape, from the prompt's own rules and this
 * project's standing cases. Start the service first (npm start). Uses your API quota.
 */
const BASE = await serviceBase();
const token = await serviceToken();
const llm = llmRoute();

const CASES = [
  {
    label: 'ITN: spoken numbers to digits',
    text: '不是派森，是派森三，呃，三点一二版本，转化率提高了百分之二十五',
    must: [/Python 3\.12/, /25%/],
    mustNot: [/呃/],
  },
  {
    label: 'repetition + GitHub capitalisation',
    text: 'You take that code… code and push it to github, remember to check the branch.',
    must: [/GitHub/],
    mustNot: [/code… code/],
  },
  {
    label: 'phonetic mapping: Chinese homophones to English',
    text: '我们用派森把接口写一下，然后那个数据就用杰森传，前端用微优伊',
    must: [/Python/i, /JSON/i, /Vue/i],
    mustNot: [/派森/, /杰森/, /微优伊/],
  },
  {
    label: 'filler removal (那个/呃/就是说/然后)',
    text: '嗯那个就是说我们这个项目的话进展还是比较顺利的然后预算方面的话也没有超支',
    must: [/项目/],
    mustNot: [/那个/, /呃/, /就是说/],
  },
  {
    label: 'self-correction keeps the last version',
    text: 'How about we meet tomorrow at, um, 7 am? Oh, actually, let us do 3 pm.',
    must: [/3 ?pm/i],
    mustNot: [/7 ?am/i],
  },
];

let failures = 0;
for (const item of CASES) {
  const response = await fetch(BASE + '/api/voice-polish/polish', {
    method: 'POST',
    headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' },
    body: JSON.stringify({ text: item.text, strength: 'prompt', appHint: 'com.microsoft.VSCode', llm }),
  });
  const body = await response.json();
  const problems = [];
  if (body.fallback !== false) problems.push('fell back: ' + (body.fallbackReason ?? '?'));
  for (const pattern of item.must) if (!pattern.test(body.text)) problems.push('missing ' + pattern);
  for (const pattern of item.mustNot) if (pattern.test(body.text)) problems.push('kept ' + pattern);
  if (problems.length > 0) failures += 1;
  console.log((problems.length === 0 ? 'PASS  ' : 'FAIL  ') + item.label);
  console.log('      in : ' + item.text);
  console.log('      out: ' + JSON.stringify(body.text));
  if (problems.length > 0) console.log('      !! ' + problems.join('; '));
}
console.log('');
console.log(failures === 0 ? 'ALL CLEANUP CASES PASSED' : failures + ' CASE(S) FAILED');
process.exit(failures === 0 ? 0 : 1);
