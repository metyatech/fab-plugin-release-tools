import assert from 'node:assert/strict';
import test from 'node:test';
import { main } from '../src/cli.mjs';

const manifestInfo = {
  manifest: { pluginName: 'FixturePlugin', listingId: '11111111-1111-4111-8111-111111111111', title: 'Fixture Product', portalReady: true },
  manifestSha256: 'fixture-manifest-sha256',
};

async function invoke(args) {
  let received;
  const code = await main(args, {
    loadManifest: async () => manifestInfo,
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
  return { code, received };
}

test('actual CLI main path denies write authorization by default', async () => {
  const { code, received } = await invoke(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--json']);
  assert.equal(code, 0);
  assert.equal(received.mode, 'verify');
  assert.equal(received.saveDraftAuthorized, false);
  assert.equal(typeof received.manualInteraction.waitForConfirmation, 'function');
});

test('actual CLI main path propagates explicit Save Draft authorization', async () => {
  const { code, received } = await invoke(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--save-draft', '--json']);
  assert.equal(code, 0);
  assert.equal(received.mode, 'save');
  assert.equal(received.saveDraftAuthorized, true);
});

test('CLI rejects Submit for review without Save Draft before core execution', async () => {
  await assert.rejects(() => invoke(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--submit-for-review', '--json']), /requires --save-draft/);
});

test('actual CLI main path propagates submit mode with Save Draft authorization', async () => {
  const { code, received } = await invoke(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--save-draft', '--submit-for-review', '--json']);
  assert.equal(code, 0);
  assert.equal(received.mode, 'submit');
  assert.equal(received.saveDraftAuthorized, true);
});
