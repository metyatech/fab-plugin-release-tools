import assert from 'node:assert/strict';
import test from 'node:test';
import { chromium } from 'playwright-core';
import { buildMutationPlan, executeMutationPlan, preflightMutationPlan } from '../src/mutation-plan.mjs';
import { installNetworkGuard } from '../src/network-guard.mjs';
import { compareManifest, comparePlatformClassification, comparePriceClassification } from '../src/comparison.mjs';
import { detectManualBlock, mergeListingAndFormatComparisons, runPortalAutomation, selectExistingTargetPage } from '../src/portal.mjs';
import { parseArgs } from '../src/cli.mjs';
import { classifyFabView, FAB_VIEW } from '../src/view-detection.mjs';
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

async function scenario({ manifest = makeManifest(), state = {}, fixtureOptions = {}, mode = 'verify', saveDraftAuthorized = false, mediaFiles = [], manualInteraction = null } = {}) {
  const fixture = await startFixture(fixtureState(manifest, state), fixtureOptions);
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest, { mediaFiles });
  try {
    await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
    const result = await runPortalAutomation({ manifestInfo: info, mode, saveDraftAuthorized, origin: fixture.origin, page, context, manualInteraction });
    return { result, fixture };
  } finally {
    await context.close();
    await fixture.close();
  }
}

async function attachedRunSetup({ manifest = makeManifest(), state = {}, mode = 'verify', saveDraftAuthorized = false, manualInteraction = null, query = '' } = {}) {
  const fixture = await startFixture(fixtureState(manifest, state));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit${query}`);
  return { fixture, context, page, info, mode, saveDraftAuthorized, manualInteraction };
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

test('portal write modes fail closed before browser attachment', async () => {
  const info = await makeManifestInfo(makeManifest());
  for (const mode of ['save', 'submit']) {
    await assert.rejects(
      () => runPortalAutomation({ manifestInfo: info, mode, saveDraftAuthorized: true }),
      /Fab Portal write automation is disabled/,
    );
  }
});

test('verify-only compares portal-unready manifests without writing', async () => {
  const manifest = makeManifest({
    portalReady: false,
    packages: [{ engineVersion: '5.8', bundleRelativePath: 'packages/UE5.8/package.zip', sha256: 'b'.repeat(64), projectFileLink: null }],
  });
  const { result, fixture } = await scenario({ manifest });
  const field = result.comparison.fields.find((item) => item.manifestJsonPath === 'packages[0].projectFileLink');
  assert.equal(result.result, 'PASS');
  assert.equal(result.writeReady, false);
  assert.match(result.writeBlockers.join(' '), /Submission manifest portalReady is false/);
  assert.equal(result.writeInteractionsPerformed, 0);
  assert.equal(result.saveInvoked, false);
  assert.equal(result.submitInvoked, false);
  assert.equal(fixture.mutations.length, 0);
  assert.equal(field.classification, 'NOT_APPLICABLE');
  assert.equal(field.desiredValue, null);
  assert.equal(field.writeTarget, null);
  assert.equal(field.editableControlAvailable, false);
  assert.equal(field.notes, 'The staging manifest has no verified Project File Link for this engine version; the existing Fab value was intentionally not compared or managed.');
});

test('fixture contenteditable comparison preserves multiline Description structure', async () => {
  const manifest = makeManifest({
    longDescription: 'Heading\n\n• First\n• Second\n\nSupport: https://example.com/support',
  });
  const matching = await scenario({ manifest });
  assert.equal(matching.result.result, 'PASS');
  assert.equal(matching.result.comparison.fields.find((item) => item.manifestJsonPath === 'longDescription').classification, 'MATCH');

  const flattened = await scenario({ manifest, state: { longDescription: manifest.longDescription.replace(/\n+/g, ' ') } });
  assert.equal(flattened.result.result, 'FAIL');
  assert.equal(flattened.result.comparison.fields.find((item) => item.manifestJsonPath === 'longDescription').classification, 'MISMATCH');
});



test('passive target selection chooses the exact listing page among Fab tabs', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest));
  const context = await browser.newContext();
  const unrelated = await context.newPage();
  const target = await context.newPage();
  try {
    await unrelated.goto(`${fixture.origin}/portal/listings/22222222-2222-4222-8222-222222222222/edit`);
    await target.goto(`${fixture.origin}/portal/listings/${listingId}/edit?foo=bar#section`);
    assert.equal(selectExistingTargetPage(context, manifest, fixture.origin), target);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('passive target selection rejects ambiguous duplicate listing tabs', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest));
  const context = await browser.newContext();
  const first = await context.newPage();
  const second = await context.newPage();
  try {
    await first.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
    await second.goto(`${fixture.origin}/portal/listings/${listingId}/edit?duplicate=true`);
    assert.throws(() => selectExistingTargetPage(context, manifest, fixture.origin), /exactly one.*found 2/i);
    assert.equal(context.pages().length, 2);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('passive target selection rejects unrelated Fab pages without creating or navigating', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest));
  const context = await browser.newContext();
  const unrelated = await context.newPage();
  try {
    await unrelated.goto(`${fixture.origin}/portal/listings/22222222-2222-4222-8222-222222222222/edit`);
    const pageCount = context.pages().length;
    const url = unrelated.url();
    assert.throws(() => selectExistingTargetPage(context, manifest, fixture.origin), /MANUAL ACTION REQUIRED.*already-open/i);
    assert.equal(context.pages().length, pageCount);
    assert.equal(unrelated.url(), url);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('verify-only passively attaches to a ready target without navigation or reload', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  let navigationsAfterAttach = 0;
  let networkIdleWaitsAfterAttach = 0;
  try {
    await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit?foo=bar#section`);
    page.on('framenavigated', (frame) => { if (frame === page.mainFrame()) navigationsAfterAttach += 1; });
    const originalWaitForLoadState = page.waitForLoadState.bind(page);
    page.waitForLoadState = async (...args) => {
      if (args[0] === 'networkidle') networkIdleWaitsAfterAttach += 1;
      return originalWaitForLoadState(...args);
    };
    const result = await runPortalAutomation({ manifestInfo: info, mode: 'verify', origin: fixture.origin, page, context });
    assert.equal(result.result, 'PASS');
    assert.equal(result.passiveAttach, true);
    assert.equal(result.initialNavigationPerformed, false);
    assert.equal(result.hardNavigationCount, 0);
    assert.equal(result.reloadCount, 0);
    assert.equal(result.selectedPageUrl, page.url());
    assert.equal(navigationsAfterAttach, 0);
    assert.equal(networkIdleWaitsAfterAttach, 0);
    assert.equal(context.pages().length, 1);
  } finally {
    await context.close();
    await fixture.close();
  }
});





async function waitForPrompt(promptState) {
  const deadline = Date.now() + 3000;
  while (!promptState.entered && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(promptState.entered, true, 'manual challenge prompt was not reached');
}

test('startup Cloudflare challenge pauses without browser operations until human confirmation', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest, { challengeVisible: true }));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  let gotoCount = 0;
  let reloadCount = 0;
  const originalGoto = page.goto.bind(page);
  const originalReload = page.reload.bind(page);
  page.goto = async (...args) => { gotoCount += 1; return originalGoto(...args); };
  page.reload = async (...args) => { reloadCount += 1; return originalReload(...args); };
  const promptState = { entered: false };
  let releasePrompt;
  const manualInteraction = {
    waitForConfirmation: () => {
      promptState.entered = true;
      return new Promise((resolve) => { releasePrompt = resolve; });
    },
  };
  const resultPromise = runPortalAutomation({ manifestInfo: info, mode: 'verify', origin: fixture.origin, page, context, manualInteraction });
  try {
    await waitForPrompt(promptState);
    assert.equal(gotoCount, 0);
    assert.equal(reloadCount, 0);
    assert.equal(fixture.mutations.length, 0);
    assert.equal(fixture.requests.some((request) => request.method === 'POST'), false);
    fixture.state.challengeVisible = false;
    await page.evaluate(() => { document.querySelector('[data-testid="fixture-challenge"]').hidden = true; });
    releasePrompt('confirmed');
    const result = await resultPromise;
    assert.equal(result.result, 'PASS');
    assert.equal(result.manualChallengeDetected, true);
    assert.equal(result.manualChallengeHandoffCount, 1);
    assert.equal(result.manualChallengeCompleted, true);
    assert.equal(result.manualChallengeCancelled, false);
    assert.equal(result.writeInteractionsPerformed, 0);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('manual handoff repeats when the challenge remains after confirmation', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest, { challengeVisible: true }));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  let prompts = 0;
  const manualInteraction = {
    waitForConfirmation: async () => {
      prompts += 1;
      if (prompts === 2) {
        fixture.state.challengeVisible = false;
        await page.evaluate(() => { document.querySelector('[data-testid="fixture-challenge"]').hidden = true; });
      }
      return 'confirmed';
    },
  };
  try {
    const result = await runPortalAutomation({ manifestInfo: info, mode: 'verify', origin: fixture.origin, page, context, manualInteraction });
    assert.equal(result.result, 'PASS');
    assert.equal(prompts, 2);
    assert.equal(result.manualChallengeHandoffCount, 2);
    assert.equal(result.manualChallengeCompleted, true);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('manual handoff fails safely after the maximum number of cycles', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest, { challengeVisible: true }));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  let prompts = 0;
  try {
    const result = await runPortalAutomation({
      manifestInfo: info,
      mode: 'verify',
      origin: fixture.origin,
      page,
      context,
      manualInteraction: { waitForConfirmation: async () => { prompts += 1; return 'confirmed'; } },
      maxManualChallengeCycles: 3,
    });
    assert.equal(result.result, 'FAIL');
    assert.equal(prompts, 3);
    assert.equal(result.manualChallengeHandoffCount, 3);
    assert.equal(result.manualChallengeCompleted, false);
    assert.match(result.blockers.join(' '), /maximum of 3 cycles/i);
    assert.equal(result.writeInteractionsPerformed, 0);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('human cancellation reports MANUAL_CHALLENGE_CANCELLED without writes', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest, { challengeVisible: true }));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  try {
    const result = await runPortalAutomation({ manifestInfo: info, mode: 'verify', origin: fixture.origin, page, context, manualInteraction: { waitForConfirmation: async () => 'cancelled' } });
    assert.equal(result.result, 'MANUAL_CHALLENGE_CANCELLED');
    assert.equal(result.manualChallengeCancelled, true);
    assert.equal(result.writeInteractionsPerformed, 0);
    assert.equal(fixture.mutations.length, 0);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('human reload during handoff is observed and the exact target is rediscovered', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest, { challengeVisible: true }));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  let prompts = 0;
  const manualInteraction = {
    waitForConfirmation: async () => {
      prompts += 1;
      fixture.state.challengeVisible = false;
      await page.reload();
      await page.evaluate(() => { document.querySelector('[data-testid="fixture-challenge"]').hidden = true; });
      return 'confirmed';
    },
  };
  try {
    const result = await runPortalAutomation({ manifestInfo: info, mode: 'verify', origin: fixture.origin, page, context, manualInteraction });
    assert.equal(result.result, 'PASS');
    assert.equal(prompts, 1);
    assert.equal(result.humanObservedNavigationCount, 1);
    assert.equal(result.selectedPageUrl, page.url());
    assert.equal(result.automationHardNavigationCount, 0);
  } finally {
    await context.close();
    await fixture.close();
  }
});



test('challenge during approved read-only expansion can hand off before mutation', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest, { readOnlySections: ['Additional information'], challengeOnReadOnlyExpansion: true }));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  try {
    const result = await runPortalAutomation({
      manifestInfo: info,
      mode: 'verify',
      origin: fixture.origin,
      page,
      context,
      manualInteraction: { waitForConfirmation: async () => { fixture.state.challengeVisible = false; await page.evaluate(() => { document.querySelector('[data-testid="fixture-challenge"]').hidden = true; }); return 'confirmed'; } },
    });
    assert.equal(result.result, 'PASS');
    assert.equal(result.manualChallengeHandoffCount, 1);
    assert.equal(result.writeInteractionsPerformed, 0);
    assert.equal(fixture.mutations.length, 0);
  } finally {
    await context.close();
    await fixture.close();
  }
});











test('format view owns format controls and hides listing controls', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest));
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  assert.equal(await classifyFabView(page), FAB_VIEW.LISTING_MAIN_VIEW);
  assert.equal(await page.getByLabel('Short description *', { exact: true }).isVisible(), true);
  assert.equal(await page.getByLabel('Project File Link', { exact: true }).isVisible(), false);
  await page.getByRole('button', { name: 'Unreal Engine', exact: true }).click();
  assert.equal(await classifyFabView(page), FAB_VIEW.FORMAT_VIEW);
  assert.equal(await page.getByLabel('Short description *', { exact: true }).isVisible(), false);
  assert.equal(await page.getByLabel('Project File Link', { exact: true }).isVisible(), true);
  await context.close();
  await fixture.close();
});

test('Project Versions on the listing main view does not trigger Back to listings navigation', async () => {
  const { result, fixture } = await scenario({ state: { mainProjectVersionsVisible: true } });
  assert.equal(result.result, 'PASS');
  assert.equal(result.hardNavigationCount, 0);
  assert.equal(result.writeInteractionsPerformed, 0);
  assert.equal(fixture.mutations.length, 0);
});

test('Back to listings is never accepted as the format back control', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest, { mainProjectVersionsVisible: true }));
  const context = await browser.newContext();
  const page = await context.newPage();
  try {
    await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
    assert.equal(await page.getByRole('link', { name: 'Back to listings', exact: true }).getAttribute('href'), '/portal/listings');
    assert.equal(await classifyFabView(page), FAB_VIEW.LISTING_MAIN_VIEW);
    assert.equal(page.url(), `${fixture.origin}/portal/listings/${listingId}/edit`);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('format view without singular back uses the observed listing summary control', async () => {
  const setup = await attachedRunSetup({ state: { omitFormatBack: true, formatListingSummaryVisible: true, formatTitleVisible: true } });
  try {
    await setup.page.getByRole('button', { name: 'Unreal Engine', exact: true }).click();
    assert.equal(await classifyFabView(setup.page), FAB_VIEW.FORMAT_VIEW);
    const result = await runPortalAutomation({ manifestInfo: setup.info, mode: setup.mode, saveDraftAuthorized: setup.saveDraftAuthorized, origin: setup.fixture.origin, page: setup.page, context: setup.context, manualInteraction: setup.manualInteraction });
    assert.equal(result.result, 'PASS');
    assert.equal(result.hardNavigationCount, 0);
    assert.equal(result.writeInteractionsPerformed, 0);
    assert.equal(setup.fixture.mutations.length, 0);
  } finally {
    await setup.context.close();
    await setup.fixture.close();
  }
});

test('format evidence merges documentation while support remains Description-derived', () => {
  const manifest = makeManifest();
  const makeField = (path, classification, view) => ({ manifestJsonPath: path, classification, view, currentVisibleValue: classification === 'MATCH' ? manifest[path] : null });
  const main = { fields: [makeField('documentationUrl', 'NOT_VISIBLE', 'listing'), makeField('supportUrl', 'NOT_DISCOVERED', 'listing')] };
  const format = { fields: [makeField('documentationUrl', 'MATCH', 'format'), makeField('supportUrl', 'MATCH', 'format')] };
  const merged = mergeListingAndFormatComparisons(main, format, manifest);
  assert.equal(merged.fields.find((field) => field.manifestJsonPath === 'documentationUrl').classification, 'MATCH');
  assert.equal(merged.fields.find((field) => field.manifestJsonPath === 'documentationUrl').view, 'format');
  assert.equal(merged.fields.find((field) => field.manifestJsonPath === 'supportUrl').classification, 'NOT_DISCOVERED');
  assert.equal(merged.fields.find((field) => field.manifestJsonPath === 'supportUrl').view, 'listing');
  const mainMatch = { fields: [makeField('documentationUrl', 'MATCH', 'listing')] };
  const weakFormat = { fields: [makeField('documentationUrl', 'NOT_VISIBLE', 'format')] };
  assert.equal(mergeListingAndFormatComparisons(mainMatch, weakFormat, manifest).fields[0].view, 'listing');
});

test('fixture format technical details recover documentation and support values', async () => {
  const { result } = await scenario();
  const documentation = result.comparison.fields.find((field) => field.manifestJsonPath === 'documentationUrl');
  const support = result.comparison.fields.find((field) => field.manifestJsonPath === 'supportUrl');
  assert.equal(documentation.classification, 'MATCH');
  assert.equal(documentation.view, 'format');
  assert.equal(support.classification, 'MATCH');
  assert.equal(support.view, 'listing');
});




test('listing locator cannot be preflighted while format view is active', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest));
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  await page.getByRole('button', { name: 'Unreal Engine', exact: true }).click();
  const preflight = await preflightMutationPlan(page, [{ fieldName: 'shortDescription', view: 'listing', locator: { strategy: 'getByLabel', name: 'Short description *', exact: true }, locatorStrategy: 'getByLabel', locatorExpression: 'page.getByLabel("Short description *")', mutationType: 'text' }], manifest);
  assert.equal(preflight.ok, false);
  assert.match(preflight.failures.join(' '), /not visible|match count/i);
  await context.close();
  await fixture.close();
});


test('preflight never falls back from the comparison-approved locator', async () => {
  const manifest = makeManifest({ title: 'Changed title' });
  const fixture = await startFixture(fixtureState(manifest, { title: 'Old title' }));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  try {
    await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
    const comparison = await compareManifest(page, info, { view: 'listing' });
    const mutation = buildMutationPlan(comparison, info);
    assert.equal(mutation.plan[0].locator.strategy, 'getByLabel');
    await page.evaluate(() => {
      document.querySelector('[aria-label="Title *"]').closest('label').remove();
      const fallback = document.createElement('input');
      fallback.setAttribute('aria-label', 'Title');
      fallback.value = 'Fallback control';
      document.body.append(fallback);
    });
    const preflight = await preflightMutationPlan(page, mutation.plan, manifest);
    assert.equal(preflight.ok, false);
    assert.match(preflight.failures.join(' '), /approved|target|match count/i);
    assert.deepEqual(preflight.targets, []);
    assert.equal(fixture.mutations.length, 0);
  } finally {
    await context.close();
    await fixture.close();
  }
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

test('direct mutation plan execution fails before touching the DOM', async () => {
  let domOperations = 0;
  const page = new Proxy({}, {
    get() {
      domOperations += 1;
      throw new Error('DOM operation should not be reached');
    },
  });
  const manifest = makeManifest();
  const preflight = {
    targets: [{ item: { fieldName: 'title', view: 'listing', locator: { strategy: 'getByLabel', name: 'Title', exact: true }, mutationType: 'text' } }],
  };
  await assert.rejects(
    () => executeMutationPlan(page, preflight, { manifest, mediaFiles: [] }),
    /Fab Portal write automation is disabled/,
  );
  assert.equal(domOperations, 0);
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

test('network guard blocks every Fab write in every phase', async () => {
  const fixture = await startFixture(fixtureState(makeManifest()));
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  const guard = installNetworkGuard(context, { mode: 'submit' });
  for (const request of [
    ['/api/save', 'POST'],
    ['/api/submit', 'POST'],
    ['/api/unknown', 'PATCH'],
  ]) {
    await page.evaluate(([url, method]) => fetch(url, { method, body: '{}' }).catch(() => undefined), request);
  }
  const summary = guard.summary();
  await guard.dispose();
  await context.close();
  await fixture.close();
  assert.equal(summary.networkMutationRequestsObserved, 3);
  assert.equal(summary.networkMutationRequestsBlocked, 3);
  assert.equal(fixture.mutations.length, 0);
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


test('subcategory=[] is NOT_APPLICABLE when the portal has no control', async () => {
  const { result } = await scenario();
  const field = result.comparison.fields.find((item) => item.manifestJsonPath === 'subcategory');
  assert.equal(field.classification, 'NOT_APPLICABLE');
});
