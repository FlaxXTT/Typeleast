import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { Readable } from 'node:stream';

const aad = (direction, id) => Buffer.from(`typeleast-v1:${direction}:${id}`);
export function seal(key, bytes, direction, id) {
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(aad(direction, id));
  return Buffer.concat([nonce, cipher.update(bytes), cipher.final(), cipher.getAuthTag()]);
}
export function open(key, bytes, direction, id) {
  if (bytes.length < 28) throw new Error('invalid envelope');
  const cipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12));
  cipher.setAAD(aad(direction, id));
  cipher.setAuthTag(bytes.subarray(-16));
  return Buffer.concat([cipher.update(bytes.subarray(12, -16)), cipher.final()]);
}

/** Managed Mac transport. Legacy standalone/Windows listeners remain separate. */
export function secureHandler(handler, secret, maxBytes) {
  if (!/^[0-9a-f]{64}$/.test(secret ?? '')) throw new Error('secure transport requires child secret');
  const key = Buffer.from(secret, 'hex');
  const seen = new Set(); // Never evict within a key lifetime; stop accepting when full.
  return async (req, res) => {
    try {
      const id = req.headers['x-typeleast-request'];
      if (req.method !== 'POST' || req.url !== '/secure' || !/^[a-zA-Z0-9-]{36}$/.test(id ?? '') || seen.has(id) || seen.size >= 100000) throw new Error('invalid envelope');
      let size = 0; const chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        if (size > maxBytes) throw new Error('invalid envelope');
        chunks.push(chunk);
      }
      const payload = JSON.parse(open(key, Buffer.concat(chunks), 'request', id));
      if (typeof payload.method !== 'string' || typeof payload.path !== 'string' || !payload.headers || typeof payload.body !== 'string') throw new Error('invalid envelope');
      // Reading bodies yields: another copy may have arrived while this one waited.
      if (seen.has(id) || seen.size >= 100000) throw new Error('replayed envelope');
      seen.add(id);
      const body = Buffer.from(payload.body, 'base64');
      const inner = Readable.from(body.length ? [body] : []);
      inner.method = payload.method; inner.url = payload.path;
      inner.headers = { ...payload.headers, host: '127.0.0.1', 'content-length': String(body.length) };
      let status = 500;
      const response = {
        once: (...args) => res.once(...args),
        get writableEnded() { return res.writableEnded; },
        writeHead(code) { status = code; },
        end(value) {
          const data = Buffer.from(JSON.stringify({ status, body: Buffer.from(value ?? '').toString('base64') }));
          const encrypted = seal(key, data, 'response', id);
          res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': encrypted.length });
          res.end(encrypted);
        },
      };
      await handler(inner, response);
    } catch {
      if (!res.headersSent) res.writeHead(403, { 'content-type': 'application/octet-stream' });
      if (!res.writableEnded) res.end();
    }
  };
}
