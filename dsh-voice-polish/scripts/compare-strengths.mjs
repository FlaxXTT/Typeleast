import { dshBase, dshToken } from './dsh-base.mjs';

/** Compare the three strengths on one dictated paragraph. */
const token = await dshToken();
const BASE = (await dshBase()) + '/api/voice-polish/polish';
const text = "就是那个周会的问题啊，那个时间安排嘛，嗯，然后我想把它挪到周四，因为周三人不齐，然后其实呢又想保留线上参加的方式，所以呢最好是周四下午开。";

for (const strength of ['conservative', 'prompt', 'maximal']) {
  const response = await fetch(BASE, {
    method: 'POST',
    headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' },
    body: JSON.stringify({ text, strength }),
  });
  const body = await response.json();
  console.log('--- ' + strength + '  ' + JSON.stringify(body.ms) + '  fallback=' + body.fallback);
  console.log(body.text);
  console.log('');
}
