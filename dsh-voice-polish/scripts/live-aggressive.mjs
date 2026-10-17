import { dshBase, dshToken } from './dsh-base.mjs';

/** Dictation-style sample cases (made up), evaluated against the running service. */
const BASE = (await dshBase()) + '/api/voice-polish/polish';
const token = await dshToken();

const CASES = [
  ['filler + scattered intent',
   "呃，现在呢首先还要解决一个问题，就是我拍的那些照片，其他都是一些截图，这些截图会一直存在手机里嘛，我不想让它一直留着，因为它会慢慢把我的空间占满。然后我想要的是要么隔一段时间清理一次，要么直接不保存截图。",
   'prompt'],
  ['aggressive restructuring',
   "就是那个周会的问题啊，那个时间安排嘛，嗯，然后我想把它挪到周四，因为周三人不齐，然后其实呢又想保留线上参加的方式，所以呢最好是周四下午开。",
   'prompt'],
  ['intent clustering',
   "这个翻译插件的力度不够，就是太死板了。我希望它把我写的话改成口语的说法。对，自然一点的口语。而且它语气词也没去干净，呃嗯啊呢这些还在。",
   'prompt'],
];

for (const [label, text, strength] of CASES) {
  const response = await fetch(BASE, {
    method: 'POST',
    headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' },
    body: JSON.stringify({ text, strength }),
  });
  const body = await response.json();
  console.log('=== ' + label + '  [' + strength + ']  ' + JSON.stringify(body.ms));
  console.log('IN : ' + text);
  console.log('OUT: ' + body.text);
  console.log('fallback=' + body.fallback + (body.fallbackReason ? ' (' + body.fallbackReason + ')' : ''));
  console.log('');
}
