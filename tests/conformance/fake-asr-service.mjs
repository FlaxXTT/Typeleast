#!/usr/bin/env node
// Reference-only adapter for the offline positive /dictate contract.
// It is not included in either desktop app or release package.
import { parseArgs } from 'node:util';
import { startService } from '../../service/lib/server.js';

const { values } = parseArgs({ options: {
  'state-dir': { type: 'string' }, 'models-dir': { type: 'string' }, port: { type: 'string' },
} });
const phrases = new Map([
  [1, '帮我把会议记录整理成纪要，发给团队看，要详细一点'],
  [2, '还要发给客户看'],
  [3, '不对，只给团队内部看'],
]);
const recognizer = {
  snapshot: () => ({ providerId: 'fake-asr', engine: 'conformance', phase: 'ready', ready: true, languages: ['auto', 'zh', 'en'] }),
  prepare: async () => {},
  transcribe: async (wav, language) => {
    const id = wav.readInt16LE(44);
    const text = id === 4 ? language === 'en' ? 'Send the report.' : '请发送报告。' : phrases.get(id);
    if (!text) throw Object.assign(new Error('unknown test utterance'), { code: 'invalid-audio' });
    return { text };
  },
};
const handle = await startService({
  stateDir: values['state-dir'], modelsDir: values['models-dir'], port: Number(values.port ?? 0), recognizer,
  logger: { info() {}, warn() {}, debug() {} },
});
process.stdout.write(JSON.stringify({ event: 'ready', port: handle.port, pid: process.pid, version: handle.service.version }) + '\n');
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => void handle.close().then(() => process.exit(0)));
