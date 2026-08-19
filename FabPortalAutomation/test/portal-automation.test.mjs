import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { chromium } from 'playwright-core';
import { buildMutationPlan, preflightMutationPlan } from '../src/mutation-plan.mjs';
import { installNetworkGuard } from '../src/network-guard.mjs';
import { runPortalAutomation } from '../src/portal.mjs';
import { parseArgs } from '../src/cli.mjs';
import { startFixture } from './fixtures/server.mjs';
import { fixtureState, makeManifest, makeManifestInfo, listingId } from './helpers.mjs';

const chrome = process.env.FAB_CHROME_PATH ?? 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
let browser;

test.before(async () => {
  browser = await chromium.launch({ executablePath: chrome, headless: true });
});

test.after(async () => {
  await browser.close();
});

async function scenario({ manifest = makeManifest(), state = {}, fixtureOptions = {}, mode = 'verify', saveDraftAuthorized = false, mediaFiles = [] } = {}) {
  const fixture = await startFixture(fixtureState(manifest, state), fixtureOptions);
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest, { mediaFiles });
  try {
    await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
    const result = await runPortalAutomation({ manifestInfo: info, mode, saveDraftAuthorized, origin: fixture.origin, page, context });
    return { result, fixture };
  } finally {
    await context.close();
    await fixture.close();
  }
}

test('verify-only performs zero writes', async () => {
  const { result, fixture } = await scenario();
  assert.equal(result.result, 'PASS');
  assert.equal(result.writeInteractionsPerformed, 0);
  assert.equal(result.saveInvoked, false);
  assert.equal(result.submitInvoked, false);
  assert.equal(fixture.mutations.length, 0);
});

test('wrong listing UUID blocks after a redirect before mutation', async () => {
  const manifest = makeManifest({ listingId: '22222222-2222-4222-8222-222222222222' });
  const { result, fixture } = await scenario({ manifest, mode: 'save', saveDraftAuthorized: true, fixtureOptions: { redirectListingId: listingId } });
  assert.equal(result.result, 'FAIL');
  assert.match(result.blockers.join(' '), /UUID mismatch/);
  assert.equal(result.writeInteractionsPerformed, 0);
  assert.equal(fixture.mutations.length, 0);
});

test('wrong title blocks before mutation', async () => {
  const manifest = makeManifest({ title: 'Expected Product' });
  const { result, fixture } = await scenario({ manifest, state: { title: 'Actual Product' }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'FAIL');
  assert.match(result.blockers.join(' '), /title/i);
  assert.equal(fixture.mutations.length, 0);
});

test('Pending approval blocks Save Draft before any write', async () => {
  const { result, fixture } = await scenario({ state: { status: 'Pending approval' }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'FAIL');
  assert.match(result.blockers.join(' '), /review-locked/i);
  assert.equal(result.writeInteractionsPerformed, 0);
  assert.equal(fixture.mutations.length, 0);
});

test('Pending approval blocks Submit for review before any write', async () => {
  const { result, fixture } = await scenario({ state: { status: 'Pending approval' }, mode: 'submit', saveDraftAuthorized: true });
  assert.equal(result.result, 'FAIL');
  assert.match(result.blockers.join(' '), /review-locked/i);
  assert.equal(result.writeInteractionsPerformed, 0);
  assert.equal(fixture.mutations.find((item) => item.pathname === '/api/cancel'), undefined);
});

test('Cancel submission is never clicked', async () => {
  const { fixture } = await scenario({ state: { status: 'Pending approval' }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(fixture.mutations.some((item) => item.pathname === '/api/cancel'), false);
});

test('identical manifest creates an empty plan and does not click Save', async () => {
  const { result, fixture } = await scenario({ mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'PASS');
  assert.deepEqual(result.plannedMutations, []);
  assert.equal(result.saveInvoked, false);
  assert.equal(fixture.mutations.length, 0);
});

test('one changed field changes only that field', async () => {
  const manifest = makeManifest({ shortDescription: 'New Fixture Short Description' });
  const { result, fixture } = await scenario({ manifest, state: { shortDescription: 'Old Fixture Short Description' }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'PASS');
  assert.deepEqual(result.executedMutations, ['shortDescription']);
  assert.equal(result.saveInvoked, true);
  assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/save').length, 1);
  assert.equal(fixture.mutations[0].body.shortDescription, 'New Fixture Short Description');
});

test('disabled planned locator fails preflight with zero mutations', async () => {
  const manifest = makeManifest({ shortDescription: 'New Fixture Short Description' });
  const { result, fixture } = await scenario({ manifest, state: { shortDescription: 'Old Fixture Short Description', disableFields: ['shortDescription'] }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'FAIL');
  assert.match(result.blockers.join(' '), /writable locator|preflight/i);
  assert.equal(result.writeInteractionsPerformed, 0);
  assert.equal(fixture.mutations.length, 0);
});

test('duplicate mutation targets are rejected before execution', () => {
  const manifest = makeManifest();
  const comparison = { fields: [
    { manifestJsonPath: 'title', classification: 'MISMATCH', currentNormalizedValue: 'a', writeTarget: { strategy: 'getByLabel', expression: 'same' } },
    { manifestJsonPath: 'shortDescription', classification: 'MISMATCH', currentNormalizedValue: 'a', writeTarget: { strategy: 'getByLabel', expression: 'same' } },
  ] };
  const plan = buildMutationPlan(comparison, { manifest });
  assert.match(plan.blockers.join(' '), /duplicate/i);
  assert.equal(plan.plan.length, 2);
});

test('Save occurs only after all staged values verify', async () => {
  const manifest = makeManifest({ shortDescription: 'Verified Short Description' });
  const { result, fixture } = await scenario({ manifest, state: { shortDescription: 'Old Short Description' }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'PASS');
  assert.equal(result.saveInvoked, true);
  assert.equal(result.comparisonAfter.counts.MISMATCH, 0);
  assert.equal(fixture.mutations[0].pathname, '/api/save');
});

test('post-save mismatch fails and prevents submit', async () => {
  const manifest = makeManifest({ shortDescription: 'Dropped Short Description' });
  const { result, fixture } = await scenario({ manifest, state: { shortDescription: 'Old Short Description' }, fixtureOptions: { dropSaveFields: ['shortDescription'] }, mode: 'submit', saveDraftAuthorized: true });
  assert.equal(result.result, 'FAIL');
  assert.equal(result.saveInvoked, true);
  assert.equal(result.submitInvoked, false);
  assert.equal(fixture.mutations.some((item) => item.pathname === '/api/submit'), false);
});

test('Submit cannot run without Save Draft authorization', () => {
  assert.throws(() => parseArgs(['--manifest', 'manifest.json', '--cdp-endpoint', 'http://127.0.0.1:1', '--submit-for-review']), /requires --save-draft/);
});

test('Submit runs only after exact comparison success', async () => {
  const { result, fixture } = await scenario({ mode: 'submit', saveDraftAuthorized: true });
  assert.equal(result.result, 'PASS');
  assert.equal(result.submitInvoked, true);
  assert.equal(result.saveInvoked, false);
  assert.equal(fixture.mutations.some((item) => item.pathname === '/api/submit'), true);
});

test('unexpected DELETE is blocked by the network guard', async () => {
  const fixture = await startFixture(fixtureState(makeManifest()));
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  const guard = installNetworkGuard(context, { mode: 'verify' });
  await page.evaluate(() => fetch('/api/delete', { method: 'DELETE' }).catch(() => undefined));
  const summary = guard.summary();
  await guard.dispose();
  await context.close();
  await fixture.close();
  assert.equal(fixture.mutations.length, 0);
  assert.equal(summary.networkMutationRequestsBlocked, 1);
});

test('verify-only mutation request is blocked', async () => {
  const fixture = await startFixture(fixtureState(makeManifest()));
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  const guard = installNetworkGuard(context, { mode: 'verify' });
  await page.evaluate(() => fetch('/api/save', { method: 'POST', body: '{}' }).catch(() => undefined));
  const summary = guard.summary();
  await guard.dispose();
  await context.close();
  await fixture.close();
  assert.equal(fixture.mutations.length, 0);
  assert.equal(summary.networkMutationRequestsBlocked, 1);
});

test('subcategory=[] is NOT_APPLICABLE when the portal has no control', async () => {
  const { result } = await scenario();
  const field = result.comparison.fields.find((item) => item.manifestJsonPath === 'subcategory');
  assert.equal(field.classification, 'NOT_APPLICABLE');
});

test('Project File Link updates exactly when it differs', async () => {
  const manifest = makeManifest({ packages: [{ engineVersion: '5.8', bundleRelativePath: 'packages/UE5.8/package.zip', sha256: 'b'.repeat(64), projectFileLink: 'https://example.com/new-package.zip' }] });
  const { result, fixture } = await scenario({ manifest, state: { projectFileLink: 'https://example.com/old-package.zip' }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'PASS');
  assert.deepEqual(result.executedMutations, ['packages[0].projectFileLink']);
  assert.equal(fixture.mutations[0].body.projectFileLink, 'https://example.com/new-package.zip');
});

test('ambiguous existing media is never destructively replaced', async () => {
  const manifest = makeManifest({ shortDescription: 'Changed Short Description' });
  const { result, fixture } = await scenario({ manifest, state: { shortDescription: 'Old Short Description', mediaExisting: 'existing', mediaOrder: '' }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'FAIL');
  assert.equal(result.executedMutations.length, 0);
  assert.equal(fixture.mutations.length, 0);
});

test('new empty media gallery uploads in manifest order', async () => {
  const manifest = makeManifest({ media: [
    { order: 1, role: 'thumbnail', bundleRelativePath: 'media/001.jpg', sha256: 'a'.repeat(64) },
    { order: 2, role: 'gallery', bundleRelativePath: 'media/002.jpg', sha256: 'c'.repeat(64) },
  ] });
  const directory = await mkdtemp(path.join(os.tmpdir(), 'fab-media-'));
  const first = path.join(directory, '001.jpg');
  const second = path.join(directory, '002.jpg');
  await writeFile(first, 'thumbnail');
  await writeFile(second, 'gallery');
  const { result, fixture } = await scenario({ manifest, state: { mediaExisting: 'empty', mediaOrder: '1:thumbnail,2:gallery' }, mediaFiles: [{ path: first }, { path: second }], mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'PASS');
  assert.deepEqual(result.executedMutations, ['media']);
  assert.equal(fixture.mutations[0].body.mediaOrder, '1:thumbnail,2:gallery');
});
