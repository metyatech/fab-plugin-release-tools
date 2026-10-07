import assert from 'node:assert/strict';
import test from 'node:test';
import { help, main, parseArgs } from '../src/cli.mjs';

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

test('actual CLI main path uses the verify-only runner contract', async () => {
  const { code, received, loadOptions } = await invoke(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--json']);
  assert.equal(code, 0);
  assert.deepEqual(Object.keys(received).sort(), ['cdpEndpoint', 'manifestInfo', 'manualInteraction']);
  assert.deepEqual(loadOptions, { requirePortalReady: false });
  assert.equal(typeof received.manualInteraction.waitForConfirmation, 'function');
});

test('pre-submit CLI path requires portalReady and opts into the live gate', async () => {
  const { code, received, loadOptions } = await invoke(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--pre-submit', '--json']);
  assert.equal(code, 0);
  assert.deepEqual(loadOptions, { requirePortalReady: true });
  assert.equal(received.preSubmit, true);
});

test('pre-submit CLI rejects Observation transport before loading any artifact', async () => {
  await assert.rejects(
    () => main(['--manifest', 'manifest.json', '--observation', 'observation.json', '--pre-submit'], {}),
    /Pre-submit verification requires live browser\/CDP verification and cannot be satisfied by an observation artifact/,
  );
});

test('tag availability CLI passes candidates only to the discovery runner', async () => {
  let received;
  const code = await main(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--tag-availability', '--tag', 'Search', '--tag', 'Find', '--json'], {
    loadManifest: async () => manifestInfo,
    createDirectory: async () => 'fixture-artifact-directory',
    run: async () => { throw new Error('ordinary verifier must not run'); },
    runTagDiscovery: async (options) => {
      received = options;
      return { result: 'PASS', mode: 'tag-availability', blockers: [], candidates: [], network: {} };
    },
    writeReport: async () => undefined,
  });
  assert.equal(code, 0);
  assert.deepEqual(received.tags, ['Search', 'Find']);
  assert.equal(received.cdpEndpoint, 'http://127.0.0.1:1');
});

test('tag availability requires candidate tags', async () => {
  assert.throws(
    () => parseArgs(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--tag-availability']),
    /requires one or more --tag candidates/,
  );
});

test('a passing stale Observation remains audit evidence and never sets pre-submit readiness', async () => {
  let runCalled = false;
  let writtenResult;
  const observation = {
    source: 'interactive-browser',
    listingId: manifestInfo.manifest.listingId,
    listingTitle: manifestInfo.manifest.title,
    listingStatus: 'Draft',
    fields: [{ manifestJsonPath: 'professionalPriceUsd', state: 'OBSERVED', view: 'listing', value: 19.99 }],
  };
  const code = await main(['--manifest', 'manifest.json', '--observation', 'observation.json', '--json'], {
    loadManifest: async (_manifestPath, options) => {
      assert.deepEqual(options, { requirePortalReady: false });
      return { ...manifestInfo, manifest: { ...manifestInfo.manifest, professionalPriceUsd: 19.99 } };
    },
    createDirectory: async () => 'fixture-artifact-directory',
    loadObservation: async () => ({ observation, observationSha256: 'b'.repeat(64) }),
    compareObservation: () => ({ fields: [], counts: { MATCH: 0, MISMATCH: 0, NOT_VISIBLE: 0, NOT_DISCOVERED: 0, NOT_APPLICABLE: 0 }, mismatchCount: 0, unresolvedCritical: [] }),
    run: async () => { runCalled = true; throw new Error('browser runner must not be called'); },
    writeReport: async ({ result }) => { writtenResult = result; },
  });
  assert.equal(code, 0);
  assert.equal(runCalled, false);
  assert.equal(writtenResult.verificationTransport, 'observation');
  assert.equal(writtenResult.preSubmitGate, false);
  assert.equal(writtenResult.preSubmitReady, false);
  assert.equal(writtenResult.portalWritesAllowed, false);
  assert.equal(writtenResult.submitAllowed, false);
});

test('CLI requires exactly one acquisition mode', async () => {
  await assert.rejects(() => main(['--manifest', 'manifest.json', '--json'], {}), /Exactly one of --cdp-endpoint or --observation/);
  await assert.rejects(() => main(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--observation', 'observation.json', '--json'], {}), /Exactly one of --cdp-endpoint or --observation/);
});

test('CLI help exposes read-only verification without write usage', async () => {
  const { code } = await invoke(['--help']);
  assert.equal(code, 0);
  assert.match(help(), /supports verify mode only/i);
  assert.match(help(), /pre-submit mode is live CDP only/i);
  assert.match(help(), /seller-side/);
  assert.doesNotMatch(help(), /-SaveDraft|-SubmitForReview|--save-draft|--submit-for-review/);
});

test('CLI rejects removed write flags as unknown options', async () => {
  for (const flag of ['--save-draft', '--submit-for-review']) {
    assert.throws(() => parseArgs(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', flag]), /Unknown option/);
  }
});
