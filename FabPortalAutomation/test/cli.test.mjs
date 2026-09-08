import assert from 'node:assert/strict';
import test from 'node:test';
import { main, parseArgs } from '../src/cli.mjs';

const manifestInfo = {
  manifest: { pluginName: 'FixturePlugin', listingId: '11111111-1111-4111-8111-111111111111', title: 'Fixture Product', portalReady: true },
  manifestSha256: 'fixture-manifest-sha256',
};

async function invoke(args) {
  let received;
  let loadOptions;
  const code = await main(args, {
    loadManifest: async (_manifestPath, options) => { loadOptions = options; return manifestInfo; },
    createDirectory: async () => 'fixture-artifact-directory',
    writeReport: async () => undefined,
    run: async (options) => {
      received = options;
      return {
        result: 'PASS',
        mode: options.mode,
        listingId: options.manifestInfo.manifest.listingId,
        listingTitle: options.manifestInfo.manifest.title,
        listingStatus: 'Draft',
        writeInteractionsPerformed: 0,
        saveInvoked: false,
        submitInvoked: false,
        comparison: null,
        network: { networkMutationRequestsObserved: 0, networkMutationRequestsBlocked: 0 },
        blockers: [],
      };
    },
  });
  return { code, received, loadOptions };
}

test('actual CLI main path denies write authorization by default', async () => {
  const { code, received, loadOptions } = await invoke(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--json']);
  assert.equal(code, 0);
  assert.equal(received.mode, 'verify');
  assert.equal(received.saveDraftAuthorized, false);
  assert.equal(received.cdpEndpoint, 'http://127.0.0.1:1');
  assert.equal(received.cdpWebSocketEndpoint, null);
  assert.deepEqual(loadOptions, { requirePortalReady: false });
  assert.equal(typeof received.manualInteraction.waitForConfirmation, 'function');
});

test('CLI accepts an explicit localhost browser WebSocket endpoint', async () => {
  const endpoint = 'ws://127.0.0.1:50095/devtools/browser/session-id';
  const { code, received } = await invoke(['--manifest', 'manifest.json', '--cdp-websocket-endpoint', endpoint, '--json']);
  assert.equal(code, 0);
  assert.equal(received.cdpEndpoint, null);
  assert.equal(received.cdpWebSocketEndpoint, endpoint);
});

test('CLI session mode passes one run-scoped transport to the session host', async () => {
  let sessionOptions;
  const code = await main([
    '--manifest', 'manifest.json',
    '--cdp-websocket-endpoint', 'ws://127.0.0.1:50095/devtools/browser/session-id',
    '--session',
  ], {
    runSession: async (options) => {
      sessionOptions = options;
      return 0;
    },
  });
  assert.equal(code, 0);
  assert.deepEqual(sessionOptions, {
    manifestPath: 'manifest.json',
    endpoint: 'ws://127.0.0.1:50095/devtools/browser/session-id',
    kind: 'websocket',
    outputDirectory: null,
    dependencies: { runSession: sessionOptions.dependencies.runSession },
  });
});

test('CLI session mode rejects write flags and JSON output', () => {
  for (const flag of ['--save-draft', '--tags-only', '--submit-for-review']) {
    assert.throws(
      () => parseArgs(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--session', flag]),
      /Fab Portal write automation is disabled/,
    );
  }
  assert.throws(
    () => parseArgs(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--session', '--json']),
    /--session accepts only interactive verify, help, and quit commands/,
  );
});

test('CLI rejects both transport endpoints', async () => {
  await assert.rejects(
    () => invoke(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--cdp-websocket-endpoint', 'ws://127.0.0.1:1/devtools/browser/id', '--json']),
    /exactly one/,
  );
});

test('CLI rejects Save Draft before loading or attaching to Fab', async () => {
  await assert.rejects(
    () => invoke(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--save-draft', '--json']),
    /Fab Portal write automation is disabled/,
  );
});

test('CLI rejects Tags-only write mode before loading or attaching to Fab', async () => {
  await assert.rejects(
    () => invoke(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--tags-only', '--json']),
    /Fab Portal write automation is disabled/,
  );
});

test('CLI rejects every write mode before loading or attaching to Fab', async () => {
  await assert.rejects(() => invoke(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--tags-only', '--save-draft', '--json']), /Fab Portal write automation is disabled/);
  await assert.rejects(() => invoke(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--save-draft', '--submit-for-review', '--json']), /Fab Portal write automation is disabled/);
});

test('CLI rejects Submit for review before loading or attaching to Fab', async () => {
  await assert.rejects(
    () => invoke(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--submit-for-review', '--json']),
    /Fab Portal write automation is disabled/,
  );
});
