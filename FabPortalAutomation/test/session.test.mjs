import assert from 'node:assert/strict';
import { PassThrough, Writable } from 'node:stream';
import test from 'node:test';
import { runPortalSession } from '../src/session.mjs';

test('session mode reuses one browser connection for verify and save commands', async () => {
  const calls = [];
  const reports = [];
  let outputText = '';
  const page = { url: () => 'https://www.fab.com/portal/listings/11111111-1111-4111-8111-111111111111/edit' };
  const context = { pages: () => [page] };
  const browser = {
    contexts: () => [context],
    close: async () => { calls.push({ type: 'close' }); },
  };
  const input = new PassThrough();
  const commands = ['verify\n', 'save\n', 'quit\n'];
  let commandIndex = 0;
  const output = new Writable({
    write(chunk, _encoding, callback) {
      outputText += chunk.toString();
      if (chunk.toString().includes('fab-session> ') && commandIndex < commands.length) {
        const command = commands[commandIndex++];
        setImmediate(() => {
          input.write(command);
          if (commandIndex === commands.length) input.end();
        });
      }
      callback();
    },
  });
  const manifestInfo = {
    manifest: {
      pluginName: 'FixturePlugin',
      listingId: '11111111-1111-4111-8111-111111111111',
      title: 'Fixture Product',
    },
    manifestSha256: 'fixture',
  };

  const exitCode = await runPortalSession({
    manifestInfo,
    endpoint: 'ws://127.0.0.1:50095/devtools/browser/session-id',
    kind: 'websocket',
    input,
    output,
    dependencies: {
      connect: async (options) => {
        calls.push({ type: 'connect', options });
        return browser;
      },
      selectPage: (receivedContext) => {
        assert.equal(receivedContext, context);
        return page;
      },
      createDirectory: async (_root, pluginName) => `directory-${pluginName}-${reports.length}`,
      run: async (options) => {
        calls.push({ type: 'run', options });
        return {
          mode: options.mode,
          result: 'PASS',
          formatBootstrapFormatCount: 0,
          saveInvoked: options.mode === 'save',
          network: { networkMutationRequestsObserved: 0, networkMutationRequestsBlocked: 0 },
          blockers: [],
          comparison: null,
          comparisonAfter: null,
        };
      },
      writeReport: async (report) => { reports.push(report); },
    },
  });

  assert.equal(exitCode, 0);
  assert.equal(calls.filter((call) => call.type === 'connect').length, 1);
  assert.equal(calls.filter((call) => call.type === 'close').length, 1);
  const runs = calls.filter((call) => call.type === 'run');
  assert.deepEqual(runs.map((call) => call.options.mode), ['verify', 'save']);
  assert.equal(runs[0].options.context, context);
  assert.equal(runs[1].options.context, context);
  assert.equal(runs[0].options.page, page);
  assert.equal(runs[1].options.page, page);
  assert.equal(runs[0].options.saveDraftAuthorized, false);
  assert.equal(runs[1].options.saveDraftAuthorized, true);
  assert.equal(reports.length, 2);
  assert.match(outputText, /FAB PORTAL SESSION: READY/);
  assert.match(outputText, /SESSION VERIFY: PASS/);
  assert.match(outputText, /SESSION SAVE: PASS/);
});

test('session command failure keeps the same browser connection for retry', async () => {
  const input = new PassThrough();
  const commands = ['verify\n', 'verify\n', 'quit\n'];
  let commandIndex = 0;
  let outputText = '';
  const output = new Writable({
    write(chunk, _encoding, callback) {
      outputText += chunk.toString();
      if (chunk.toString().includes('fab-session> ') && commandIndex < commands.length) {
        const command = commands[commandIndex++];
        setImmediate(() => {
          input.write(command);
          if (commandIndex === commands.length) input.end();
        });
      }
      callback();
    },
  });
  const page = { url: () => 'https://www.fab.com/portal/listings/11111111-1111-4111-8111-111111111111/edit' };
  const context = { pages: () => [page] };
  let selectCount = 0;
  let connectCount = 0;
  let closeCount = 0;

  const exitCode = await runPortalSession({
    manifestInfo: { manifest: { pluginName: 'FixturePlugin', listingId: '11111111-1111-4111-8111-111111111111', title: 'Fixture Product' }, manifestSha256: 'fixture' },
    endpoint: 'http://127.0.0.1:9222',
    kind: 'http',
    input,
    output,
    dependencies: {
      connect: async () => {
        connectCount += 1;
        return { contexts: () => [context], close: async () => { closeCount += 1; } };
      },
      selectPage: () => {
        selectCount += 1;
        if (selectCount === 1) throw new Error('temporary duplicate target tab');
        return page;
      },
      createDirectory: async () => 'fixture-directory',
      run: async () => ({ mode: 'verify', result: 'PASS', formatBootstrapFormatCount: 0, saveInvoked: false, network: { networkMutationRequestsObserved: 0, networkMutationRequestsBlocked: 0 }, blockers: [], comparison: null, comparisonAfter: null }),
      writeReport: async () => undefined,
    },
  });

  assert.equal(exitCode, 0);
  assert.equal(connectCount, 1);
  assert.equal(closeCount, 1);
  assert.equal(selectCount, 2);
  assert.match(outputText, /SESSION COMMAND ERROR: temporary duplicate target tab/);
  assert.match(outputText, /SESSION VERIFY: PASS/);
});
