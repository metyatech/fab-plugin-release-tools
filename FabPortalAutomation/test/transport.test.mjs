import assert from 'node:assert/strict';
import test from 'node:test';
import { connectBrowserTransport, isRemoteDebuggingApprovalError, resolveBrowserTransport, validateBrowserWebSocketEndpoint } from '../src/transport.mjs';

const valid = 'ws://127.0.0.1:50095/devtools/browser/session-id';

test('accepts a localhost browser WebSocket endpoint', () => {
  assert.equal(validateBrowserWebSocketEndpoint(valid), valid);
  assert.deepEqual(resolveBrowserTransport({ cdpWebSocketEndpoint: valid }), { kind: 'websocket', endpoint: valid });
});

test('rejects malformed, remote, credentialed, and non-browser WebSocket endpoints', () => {
  for (const value of [
    'not a url',
    'wss://127.0.0.1:50095/devtools/browser/session-id',
    'ws://localhost:50095/devtools/browser/session-id',
    'ws://192.0.2.10:50095/devtools/browser/session-id',
    'ws://user:secret@127.0.0.1:50095/devtools/browser/session-id',
    'ws://127.0.0.1:50095/json/version',
    'ws://127.0.0.1:50095/devtools/browser/session-id?token=secret',
  ]) assert.throws(() => validateBrowserWebSocketEndpoint(value));
});

test('requires exactly one transport endpoint', () => {
  assert.deepEqual(resolveBrowserTransport({ cdpEndpoint: 'http://127.0.0.1:50095' }), { kind: 'http', endpoint: 'http://127.0.0.1:50095' });
  assert.equal(resolveBrowserTransport({}), null);
  assert.throws(() => resolveBrowserTransport({ cdpEndpoint: 'http://127.0.0.1:50095', cdpWebSocketEndpoint: valid }), /exactly one/);
});

test('recognizes timeout and permission errors as manual approval candidates', () => {
  assert.equal(isRemoteDebuggingApprovalError(new Error('Timeout 5000ms exceeded')), true);
  assert.equal(isRemoteDebuggingApprovalError(new Error('permission denied')), true);
  assert.equal(isRemoteDebuggingApprovalError(new Error('invalid JSON')), false);
});

test('retries the same WebSocket endpoint after manual approval', async () => {
  let attempts = 0;
  const prompts = [];
  const browser = { id: 'attached' };
  const result = await connectBrowserTransport({
    endpoint: valid,
    kind: 'websocket',
    connectOverCDP: async () => {
      attempts += 1;
      if (attempts === 1) throw new Error('Timeout 5000ms exceeded');
      return browser;
    },
    manualInteraction: { waitForConfirmation: async (details) => { prompts.push(details); return 'confirmed'; } },
  });
  assert.equal(result, browser);
  assert.equal(attempts, 2);
  assert.equal(prompts.length, 1);
  assert.equal(prompts[0].kind, 'remote-debugging-permission');
});

test('fails closed when remote debugging approval is cancelled', async () => {
  await assert.rejects(
    () => connectBrowserTransport({ endpoint: valid, kind: 'websocket', connectOverCDP: async () => { throw new Error('Timeout 5000ms exceeded'); }, manualInteraction: { waitForConfirmation: async () => 'cancelled' } }),
    /REMOTE_DEBUGGING_PERMISSION_CANCELLED/,
  );
});

test('does not offer approval handoff for an invalid endpoint error', async () => {
  let prompted = false;
  await assert.rejects(
    () => connectBrowserTransport({ endpoint: valid, kind: 'websocket', connectOverCDP: async () => { throw new Error('invalid endpoint'); }, manualInteraction: { waitForConfirmation: async () => { prompted = true; return 'confirmed'; } } }),
    /invalid endpoint/,
  );
  assert.equal(prompted, false);
});
