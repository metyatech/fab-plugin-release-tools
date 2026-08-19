import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { chromium } from 'playwright-core';
import { buildMutationPlan, preflightMutationPlan } from '../src/mutation-plan.mjs';
import { installNetworkGuard } from '../src/network-guard.mjs';
import { comparePlatformClassification, comparePriceClassification } from '../src/comparison.mjs';
import { detectManualBlock, runPortalAutomation } from '../src/portal.mjs';
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
  assert.equal(result.submitAccepted, false);
  assert.equal(result.postSubmitStatus, null);
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
  assert.equal(result.submitAccepted, true);
  assert.equal(result.postSubmitStatus, 'Pending approval');
  assert.equal(result.saveInvoked, false);
  assert.equal(fixture.mutations.some((item) => item.pathname === '/api/submit'), true);
});

test('direct Submit succeeds only after an accepted status transition', async () => {
  const { result, fixture } = await scenario({ mode: 'submit', saveDraftAuthorized: true, state: { submitFlow: 'direct' } });
  assert.equal(result.result, 'PASS');
  assert.equal(result.submitInvoked, true);
  assert.equal(result.submitAccepted, true);
  assert.equal(result.postSubmitStatus, 'Pending approval');
  assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/submit').length, 1);
  assert.deepEqual(result.network.phaseHistory, ['stage', 'submit', 'stage']);
  assert.equal(result.network.requests.find((item) => item.pathname === '/api/submit')?.phase, 'submit');
});

test('direct Submit accepts a plain visible status without listing-status testid', async () => {
  const { result, fixture } = await scenario({ mode: 'submit', saveDraftAuthorized: true, state: { statusRendering: 'plain-text' } });
  assert.equal(result.result, 'PASS');
  assert.equal(result.submitInvoked, true);
  assert.equal(result.submitAccepted, true);
  assert.equal(result.postSubmitStatus, 'Pending approval');
  assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/submit').length, 1);
});

test('pre-existing unrelated dialog is not mistaken for submit confirmation', async () => {
  const { result, fixture } = await scenario({ mode: 'submit', saveDraftAuthorized: true, state: { preExistingDialog: true } });
  assert.equal(result.result, 'PASS');
  assert.equal(result.submitInvoked, true);
  assert.equal(result.submitAccepted, true);
  assert.equal(result.postSubmitStatus, 'Pending approval');
  assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/submit').length, 1);
  assert.equal(fixture.mutations.some((item) => item.pathname === '/api/cancel'), false);
});

test('confirmation Submit scopes the confirmation and keeps submit phase active', async () => {
  const { result, fixture } = await scenario({ mode: 'submit', saveDraftAuthorized: true, state: { submitFlow: 'confirmation' } });
  assert.equal(result.result, 'PASS');
  assert.equal(result.submitInvoked, true);
  assert.equal(result.submitAccepted, true);
  assert.equal(result.postSubmitStatus, 'Pending approval');
  assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/submit').length, 1);
  assert.deepEqual(result.network.phaseHistory, ['stage', 'submit', 'stage']);
  assert.equal(result.network.requests.find((item) => item.pathname === '/api/submit')?.phase, 'submit');
  assert.equal(result.network.requests.find((item) => item.pathname === '/api/submit')?.blocked, false);
});

test('ambiguous confirmation actions fail without a confirmed submit', async () => {
  const { result, fixture } = await scenario({ mode: 'submit', saveDraftAuthorized: true, state: { submitFlow: 'confirmation', submitConfirmationButtons: ['Confirm', 'Submit for review'] } });
  assert.equal(result.result, 'FAIL');
  assert.equal(result.submitInvoked, false);
  assert.equal(result.submitAccepted, false);
  assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/submit').length, 0);
  assert.equal(fixture.mutations.some((item) => item.pathname === '/api/cancel'), false);
});

test('confirmation with only Cancel fails without clicking Cancel', async () => {
  const { result, fixture } = await scenario({ mode: 'submit', saveDraftAuthorized: true, state: { submitFlow: 'confirmation', submitConfirmationButtons: [] } });
  assert.equal(result.result, 'FAIL');
  assert.equal(result.submitInvoked, false);
  assert.equal(result.submitAccepted, false);
  assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/submit').length, 0);
  assert.equal(fixture.mutations.some((item) => item.pathname === '/api/cancel'), false);
});

test('Submit fails when neither confirmation nor accepted status appears', async () => {
  const { result, fixture } = await scenario({ mode: 'submit', saveDraftAuthorized: true, state: { submitFlow: 'direct', submitStaysDraft: true } });
  assert.equal(result.result, 'FAIL');
  assert.equal(result.submitInvoked, true);
  assert.equal(result.submitAccepted, false);
  assert.equal(result.postSubmitStatus, 'Draft');
  assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/submit').length, 1);
});

test('blocked Submit request cannot be accepted', async () => {
  const { result, fixture } = await scenario({ mode: 'submit', saveDraftAuthorized: true, state: { submitFlow: 'direct', submitRequestPath: '/api/action' } });
  assert.equal(result.result, 'FAIL');
  assert.equal(result.submitInvoked, true);
  assert.equal(result.submitAccepted, false);
  assert.equal(result.postSubmitStatus, 'Draft');
  assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/submit').length, 0);
  assert.equal(result.network.networkMutationRequestsBlocked, 1);
});

test('failed Submit response cannot be accepted', async () => {
  const { result, fixture } = await scenario({ mode: 'submit', saveDraftAuthorized: true, state: { submitFlow: 'direct', submitRequestFailure: true } });
  assert.equal(result.result, 'FAIL');
  assert.equal(result.submitInvoked, true);
  assert.equal(result.submitAccepted, false);
  assert.equal(result.postSubmitStatus, 'Draft');
  assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/submit').length, 1);
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

test('GraphQL query is allowed while GraphQL mutation is blocked in verify mode', async () => {
  const fixture = await startFixture(fixtureState(makeManifest()));
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  const guard = installNetworkGuard(context, { mode: 'verify' });
  await page.evaluate(async () => {
    await fetch('/graphql', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ query: 'query Listing { listing { id } }', operationName: 'Listing' }) });
    await fetch('/graphql', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ query: 'mutation SaveDraft { saveDraft { id } }', operationName: 'SaveDraft' }) }).catch(() => undefined);
  });
  const summary = guard.summary();
  await guard.dispose();
  await context.close();
  await fixture.close();
  assert.equal(summary.networkMutationRequestsObserved, 1);
  assert.equal(summary.networkMutationRequestsBlocked, 1);
  assert.equal(fixture.mutations.length, 0);
  assert.equal(summary.requests.find((item) => item.graphqlOperation?.type === 'query')?.blocked, false);
});

test('GraphQL Save mutation is allowed only in save phase', async () => {
  const fixture = await startFixture(fixtureState(makeManifest()));
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  const guard = installNetworkGuard(context, { mode: 'save' });
  guard.setPhase('save');
  await page.evaluate(() => fetch('/graphql', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ query: 'mutation SaveDraft { saveDraft { id } }', operationName: 'SaveDraft' }) }));
  const summary = guard.summary();
  await guard.dispose();
  await context.close();
  await fixture.close();
  assert.equal(summary.networkMutationRequestsObserved, 1);
  assert.equal(summary.networkMutationRequestsBlocked, 0);
  assert.equal(fixture.mutations[0].body.operationName, 'SaveDraft');
});

test('Submit is blocked in save phase and allowed only in submit phase', async () => {
  const fixture = await startFixture(fixtureState(makeManifest()));
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  const guard = installNetworkGuard(context, { mode: 'submit' });
  guard.setPhase('save');
  await page.evaluate(() => fetch('/graphql', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ query: 'mutation SubmitForReview { submitForReview { id } }', operationName: 'SubmitForReview' }) }).catch(() => undefined));
  guard.setPhase('submit');
  await page.evaluate(() => fetch('/graphql', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ query: 'mutation SubmitForReview { submitForReview { id } }', operationName: 'SubmitForReview' }) }));
  const summary = guard.summary();
  await guard.dispose();
  await context.close();
  await fixture.close();
  assert.equal(summary.networkMutationRequestsObserved, 2);
  assert.equal(summary.networkMutationRequestsBlocked, 1);
  assert.equal(fixture.mutations.length, 1);
});

test('Cancel and Delete GraphQL mutations are always blocked', async () => {
  const fixture = await startFixture(fixtureState(makeManifest()));
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  const guard = installNetworkGuard(context, { mode: 'submit' });
  guard.setPhase('submit');
  for (const operationName of ['CancelSubmission', 'DeleteProduct']) {
    await page.evaluate((name) => fetch('/graphql', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ query: `mutation ${name} { action { id } }`, operationName: name }) }).catch(() => undefined), operationName);
  }
  const summary = guard.summary();
  await guard.dispose();
  await context.close();
  await fixture.close();
  assert.equal(summary.networkMutationRequestsObserved, 2);
  assert.equal(summary.networkMutationRequestsBlocked, 2);
  assert.equal(fixture.mutations.length, 0);
});

test('media upload network intent requires the explicit media-upload phase', async () => {
  const fixture = await startFixture(fixtureState(makeManifest()));
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  const guard = installNetworkGuard(context, { mode: 'save' });
  guard.setPhase('save');
  await page.evaluate(() => fetch('/api/media-upload', { method: 'POST', body: 'blocked-before-upload-phase' }).catch(() => undefined));
  guard.setPhase('media-upload');
  await page.evaluate(() => fetch('/api/media-upload', { method: 'POST', body: 'allowed-upload-phase' }));
  await page.evaluate(() => fetch('/api/upload', { method: 'POST', body: 'unclassified-upload' }).catch(() => undefined));
  const summary = guard.summary();
  await guard.dispose();
  await context.close();
  await fixture.close();
  assert.equal(summary.networkMutationRequestsObserved, 3);
  assert.equal(summary.networkMutationRequestsBlocked, 2);
  assert.equal(summary.requests.filter((item) => item.intent === 'media-upload' && !item.blocked).length, 1);
});

test('submit mode permits media upload only in its explicit pre-save phase', async () => {
  const fixture = await startFixture(fixtureState(makeManifest()));
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  const guard = installNetworkGuard(context, { mode: 'submit' });
  guard.setPhase('save');
  await page.evaluate(() => fetch('/api/media-upload', { method: 'POST', body: 'blocked-in-save' }).catch(() => undefined));
  guard.setPhase('media-upload');
  await page.evaluate(() => fetch('/api/media-upload', { method: 'POST', body: 'allowed-before-save' }));
  guard.setPhase('stage');
  await page.evaluate(() => fetch('/api/media-upload', { method: 'POST', body: 'blocked-after-stage' }).catch(() => undefined));
  const summary = guard.summary();
  await guard.dispose();
  await context.close();
  await fixture.close();
  assert.equal(summary.networkMutationRequestsObserved, 3);
  assert.equal(summary.networkMutationRequestsBlocked, 2);
  assert.equal(summary.requests.filter((item) => item.intent === 'media-upload' && !item.blocked).length, 1);
});

test('platform normalization only maps Windows to Win64', () => {
  assert.equal(comparePlatformClassification('Windows', ['Win64']), 'MATCH');
  assert.equal(comparePlatformClassification('Linux', ['Win64']), 'MISMATCH');
  assert.equal(comparePlatformClassification('macOS', ['Win64']), 'MISMATCH');
  assert.equal(comparePlatformClassification(null, ['Win64']), 'NOT_VISIBLE');
});

test('platform comparison requires the complete normalized set', () => {
  assert.equal(comparePlatformClassification('Windows Linux', ['Win64', 'Linux']), 'MATCH');
  assert.equal(comparePlatformClassification('Windows', ['Win64', 'Linux']), 'MISMATCH');
  assert.equal(comparePlatformClassification('Windows Linux macOS', ['Win64', 'Linux']), 'MISMATCH');
  assert.equal(comparePlatformClassification('mac os', ['macOS']), 'MATCH');
});

test('USD price comparison normalizes exact cents without accepting other currencies', () => {
  assert.equal(comparePriceClassification('$9.99', 9.99), 'MATCH');
  assert.equal(comparePriceClassification('USD 9.99', 9.99), 'MATCH');
  assert.equal(comparePriceClassification('9.99 USD', 9.99), 'MATCH');
  assert.equal(comparePriceClassification('9.99 (USD)', 9.99), 'MATCH');
  assert.equal(comparePriceClassification(9.99, 9.99), 'MATCH');
  assert.equal(comparePriceClassification('$10.99', 9.99), 'MISMATCH');
  assert.equal(comparePriceClassification('€9.99', 9.99), 'MISMATCH');
  assert.equal(comparePriceClassification('about $9.99', 9.99), 'MISMATCH');
  assert.equal(comparePriceClassification('$29.99', 29.99), 'MATCH');
  assert.equal(comparePriceClassification(null, 9.99), 'NOT_VISIBLE');
});

test('engine comparison requires an exact visible engine set', async () => {
  const manifest = makeManifest({ engineVersions: ['5.7', '5.8'] });
  const matching = await scenario({ manifest, state: { engineVersions: ['5.7', '5.8'] } });
  assert.equal(matching.result.comparison.fields.find((item) => item.manifestJsonPath === 'engineVersions').classification, 'MATCH');
  const missing = await scenario({ manifest, state: { engineVersions: ['5.8'] } });
  assert.equal(missing.result.comparison.fields.find((item) => item.manifestJsonPath === 'engineVersions').classification, 'MISMATCH');
  const extra = await scenario({ manifest, state: { engineVersions: ['5.7', '5.8', '5.9'] } });
  assert.equal(extra.result.comparison.fields.find((item) => item.manifestJsonPath === 'engineVersions').classification, 'MISMATCH');
});

test('manual-block detection is generic and does not depend on a product title', async () => {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.setContent('<main><h1>Server Manage Tool</h1><footer>Sign in to continue shopping</footer></main>');
  await assert.doesNotReject(() => detectManualBlock(page));
  await page.setContent('<main><h1>Other Product</h1><footer>Sign in to continue shopping</footer></main>');
  await assert.doesNotReject(() => detectManualBlock(page));
  await context.close();
});

test('manual-block detection ignores hidden challenge text on normal listing pages', async () => {
  const context = await browser.newContext();
  const page = await context.newPage();
  for (const hiddenText of ['Cloudflare', 'security check', 'セキュリティチェック']) {
    await page.setContent(`<main><h1>Other Product</h1><section aria-label="Product information">Normal Fab listing</section><div hidden>${hiddenText}</div></main>`);
    await assert.doesNotReject(() => detectManualBlock(page));
  }
  await context.close();
});

test('manual-block detection blocks visible challenge evidence', async () => {
  const context = await browser.newContext();
  const page = await context.newPage();
  for (const visibleText of ['Verify you are human', 'Just a moment...', 'Attention Required', 'Cloudflare security check']) {
    await page.setContent(`<main><h1>${visibleText}</h1></main>`);
    await assert.rejects(() => detectManualBlock(page), /MANUAL ACTION REQUIRED: Cloudflare/);
  }
  await context.close();
});

test('verify PASS reports unresolved write readiness separately', async () => {
  const ready = await scenario();
  assert.equal(ready.result.result, 'PASS');
  assert.equal(ready.result.writeReady, true);
  assert.deepEqual(ready.result.writeBlockers, []);
  const locked = await scenario({ state: { status: 'Pending approval' } });
  assert.equal(locked.result.result, 'PASS');
  assert.equal(locked.result.writeReady, false);
  assert.match(locked.result.writeBlockers.join(' '), /review-locked/);
  const unresolved = await scenario({ state: { mediaExisting: 'existing' } });
  assert.equal(unresolved.result.result, 'PASS');
  assert.equal(unresolved.result.writeReady, false);
  assert.match(unresolved.result.writeBlockers.join(' '), /media/);
});

test('read-only section expansion is recorded without mutation', async () => {
  const { result, fixture } = await scenario({ state: { readOnlySections: ['Additional information'] } });
  assert.deepEqual(result.readOnlyUiActions, ['toggle Additional information', 'opened Unreal Engine format section']);
  assert.equal(result.writeInteractionsPerformed, 0);
  assert.equal(fixture.mutations.length, 0);
});

test('a mutation caused by a supposed read-only expansion is blocked safely', async () => {
  const { result, fixture } = await scenario({ state: { readOnlySections: ['Additional information'], readOnlySectionMutation: true } });
  assert.equal(result.result, 'FAIL');
  assert.equal(result.writeInteractionsPerformed, 0);
  assert.equal(result.network.networkMutationRequestsObserved, 1);
  assert.equal(result.network.networkMutationRequestsBlocked, 1);
  assert.equal(fixture.mutations.length, 0);
});

test('mixed mutation plans switch phases narrowly and submit permits pre-save media upload', async () => {
  const manifest = makeManifest({
    shortDescription: 'Changed short description',
    media: [
      { order: 1, role: 'thumbnail', bundleRelativePath: 'media/001.jpg', sha256: 'a'.repeat(64) },
      { order: 2, role: 'gallery', bundleRelativePath: 'media/002.jpg', sha256: 'c'.repeat(64) },
    ],
  });
  const directory = await mkdtemp(path.join(os.tmpdir(), 'fab-media-submit-'));
  const first = path.join(directory, '001.jpg');
  const second = path.join(directory, '002.jpg');
  await writeFile(first, 'thumbnail');
  await writeFile(second, 'gallery');
  const { result, fixture } = await scenario({
    manifest,
    state: { shortDescription: 'Old short description', mediaExisting: 'empty' },
    mediaFiles: [{ path: first }, { path: second }],
    mode: 'submit',
    saveDraftAuthorized: true,
  });
  assert.equal(result.result, 'PASS');
  assert.deepEqual(result.executedMutations, ['shortDescription', 'media']);
  assert.deepEqual(result.network.phaseHistory, ['stage', 'field-update', 'stage', 'media-upload', 'stage', 'save', 'stage', 'submit', 'stage']);
  assert.equal(fixture.mutations.some((item) => item.pathname === '/api/save'), true);
  assert.equal(fixture.mutations.some((item) => item.pathname === '/api/submit'), true);
});

test('allowsUsageWithAi uses Fab negative-control polarity', async () => {
  const matchingAllowed = await scenario({ manifest: makeManifest({ allowsUsageWithAi: true }), state: { allowsUsageWithAi: true } });
  assert.equal(matchingAllowed.result.comparison.fields.find((item) => item.manifestJsonPath === 'allowsUsageWithAi').classification, 'MATCH');
  const disallowedControlChecked = await scenario({ manifest: makeManifest({ allowsUsageWithAi: true }), state: { allowsUsageWithAi: false } });
  assert.equal(disallowedControlChecked.result.comparison.fields.find((item) => item.manifestJsonPath === 'allowsUsageWithAi').classification, 'MISMATCH');
  const matchingDisallowed = await scenario({ manifest: makeManifest({ allowsUsageWithAi: false }), state: { allowsUsageWithAi: false } });
  assert.equal(matchingDisallowed.result.comparison.fields.find((item) => item.manifestJsonPath === 'allowsUsageWithAi').classification, 'MATCH');
  const allowedControlUnchecked = await scenario({ manifest: makeManifest({ allowsUsageWithAi: false }), state: { allowsUsageWithAi: true } });
  assert.equal(allowedControlUnchecked.result.comparison.fields.find((item) => item.manifestJsonPath === 'allowsUsageWithAi').classification, 'MISMATCH');
});

test('allowsUsageWithAi mutation changes only the negative control state', async () => {
  const { result, fixture } = await scenario({ manifest: makeManifest({ allowsUsageWithAi: true }), state: { allowsUsageWithAi: false }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'PASS');
  assert.deepEqual(result.executedMutations, ['allowsUsageWithAi']);
  assert.equal(fixture.mutations[0].body.allowsUsageWithAi, true);
});

test('Technical Information writes file content, never its bundle-relative path', async () => {
  const manifest = makeManifest();
  const { result, fixture } = await scenario({ manifest, state: { technicalInformationText: manifest.technicalInformationFile }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'PASS');
  assert.deepEqual(result.executedMutations, ['technicalInformationFile']);
  assert.equal(fixture.mutations[0].body.technicalInformationText, 'Fixture technical information');
  assert.notEqual(fixture.mutations[0].body.technicalInformationText, manifest.technicalInformationFile);
});

test('Technical Information post-save read-back compares exact normalized content', async () => {
  const manifest = makeManifest();
  const { result, fixture } = await scenario({ manifest, state: { technicalInformationText: 'old content' }, fixtureOptions: { dropSaveFields: ['technicalInformationText'] }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'FAIL');
  assert.equal(result.saveInvoked, true);
  assert.match(result.blockers.join(' '), /Technical Information|technicalInformationFile|mismatch/i);
  assert.equal(fixture.mutations[0].body.technicalInformationText, 'Fixture technical information');
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
