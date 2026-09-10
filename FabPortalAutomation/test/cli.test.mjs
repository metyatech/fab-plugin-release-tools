import assert from 'node:assert/strict';
import test from 'node:test';
import { help, main } from '../src/cli.mjs';

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
  assert.deepEqual(loadOptions, { requirePortalReady: false });
  assert.equal(typeof received.manualInteraction.waitForConfirmation, 'function');
});

test('CLI help exposes read-only verification without write usage', async () => {
  const { code } = await invoke(['--help']);
  assert.equal(code, 0);
  assert.doesNotMatch(help(), /-SaveDraft|-SubmitForReview|--save-draft|--submit-for-review/);
});

test('CLI rejects all write intents before loading or attaching to Fab', async () => {
  for (const flags of [['--save-draft'], ['--submit-for-review'], ['--save-draft', '--submit-for-review']]) {
    await assert.rejects(
      () => invoke(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', ...flags, '--json']),
      /Fab Portal write automation is disabled/,
    );
  }
});
