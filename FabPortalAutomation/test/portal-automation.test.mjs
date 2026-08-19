import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { chromium } from 'playwright-core';
import { buildMutationPlan, executeMutationPlan, preflightMutationPlan } from '../src/mutation-plan.mjs';
import { installNetworkGuard } from '../src/network-guard.mjs';
import { compareManifest, comparePlatformClassification, comparePriceClassification } from '../src/comparison.mjs';
import { detectManualBlock, mergeListingAndFormatComparisons, runPortalAutomation, selectExistingTargetPage } from '../src/portal.mjs';
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

test('Save mode passively attaches the exact target before startup handoff', async () => {
  const manifest = makeManifest({ shortDescription: 'Changed after Save handoff' });
  const setup = await attachedRunSetup({ manifest, state: { shortDescription: 'Old before Save handoff', challengeVisible: true }, mode: 'save', saveDraftAuthorized: true, query: '?foo=bar#section' });
  const { fixture, context, page, info } = setup;
  let gotoCount = 0;
  let reloadCount = 0;
  const originalGoto = page.goto.bind(page);
  const originalReload = page.reload.bind(page);
  page.goto = async (...args) => { gotoCount += 1; return originalGoto(...args); };
  page.reload = async (...args) => { reloadCount += 1; return originalReload(...args); };
  const promptState = { entered: false };
  let releasePrompt;
  const resultPromise = runPortalAutomation({
    manifestInfo: info,
    mode: setup.mode,
    saveDraftAuthorized: setup.saveDraftAuthorized,
    origin: fixture.origin,
    context,
    manualInteraction: {
      waitForConfirmation: () => {
        promptState.entered = true;
        return new Promise((resolve) => { releasePrompt = resolve; });
      },
    },
  });
  try {
    await waitForPrompt(promptState);
    assert.equal(gotoCount, 0);
    assert.equal(reloadCount, 0);
    assert.equal(context.pages().length, 1);
    fixture.state.challengeVisible = false;
    await page.evaluate(() => { document.querySelector('[data-testid="fixture-challenge"]').hidden = true; });
    releasePrompt('confirmed');
    const result = await resultPromise;
    assert.equal(result.result, 'PASS');
    assert.equal(result.saveInvoked, true);
    assert.equal(gotoCount, 0);
    assert.equal(reloadCount, 1);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('Submit mode passively attaches the exact target before startup handoff', async () => {
  const manifest = makeManifest({ shortDescription: 'Changed after Submit handoff' });
  const setup = await attachedRunSetup({ manifest, state: { shortDescription: 'Old before Submit handoff', challengeVisible: true }, mode: 'submit', saveDraftAuthorized: true, query: '?foo=bar#section' });
  const { fixture, context, page, info } = setup;
  let gotoCount = 0;
  let reloadCount = 0;
  const originalGoto = page.goto.bind(page);
  const originalReload = page.reload.bind(page);
  page.goto = async (...args) => { gotoCount += 1; return originalGoto(...args); };
  page.reload = async (...args) => { reloadCount += 1; return originalReload(...args); };
  const promptState = { entered: false };
  let releasePrompt;
  const resultPromise = runPortalAutomation({
    manifestInfo: info,
    mode: setup.mode,
    saveDraftAuthorized: setup.saveDraftAuthorized,
    origin: fixture.origin,
    context,
    manualInteraction: {
      waitForConfirmation: () => {
        promptState.entered = true;
        return new Promise((resolve) => { releasePrompt = resolve; });
      },
    },
  });
  try {
    await waitForPrompt(promptState);
    assert.equal(gotoCount, 0);
    assert.equal(reloadCount, 0);
    assert.equal(context.pages().length, 1);
    fixture.state.challengeVisible = false;
    await page.evaluate(() => { document.querySelector('[data-testid="fixture-challenge"]').hidden = true; });
    releasePrompt('confirmed');
    const result = await resultPromise;
    assert.equal(result.result, 'PASS');
    assert.equal(result.submitInvoked, true);
    assert.equal(result.submitAccepted, true);
    assert.equal(gotoCount, 0);
    assert.equal(reloadCount, 1);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('write mode chooses the exact target instead of the first Fab tab', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest));
  const context = await browser.newContext();
  const unrelated = await context.newPage();
  const target = await context.newPage();
  const info = await makeManifestInfo(manifest);
  try {
    await unrelated.goto(`${fixture.origin}/portal/listings/22222222-2222-4222-8222-222222222222/edit`);
    await target.goto(`${fixture.origin}/portal/listings/${listingId}/edit?foo=bar#section`);
    const result = await runPortalAutomation({ manifestInfo: info, mode: 'save', saveDraftAuthorized: true, origin: fixture.origin, context });
    assert.equal(result.result, 'PASS');
    assert.match(result.targetPageSelectionReason, /only existing page with the exact Fab hostname and listing pathname/i);
    assert.equal(context.pages().length, 2);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('write mode fails without an exact existing target and does not create a page', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest));
  const context = await browser.newContext();
  const unrelated = await context.newPage();
  const info = await makeManifestInfo(manifest);
  try {
    await unrelated.goto(`${fixture.origin}/portal/listings/22222222-2222-4222-8222-222222222222/edit`);
    await assert.rejects(
      () => runPortalAutomation({ manifestInfo: info, mode: 'save', saveDraftAuthorized: true, origin: fixture.origin, context }),
      /MANUAL ACTION REQUIRED.*exactly one already-open Fab listing page/i,
    );
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

test('startup challenge can be cleared before a guarded Save Draft mutation', async () => {
  const manifest = makeManifest({ shortDescription: 'Changed after handoff' });
  const fixture = await startFixture(fixtureState(manifest, { challengeVisible: true, shortDescription: 'Old before handoff' }));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  try {
    const result = await runPortalAutomation({
      manifestInfo: info,
      mode: 'save',
      saveDraftAuthorized: true,
      origin: fixture.origin,
      page,
      context,
      manualInteraction: { waitForConfirmation: async () => { fixture.state.challengeVisible = false; await page.evaluate(() => { document.querySelector('[data-testid="fixture-challenge"]').hidden = true; }); return 'confirmed'; } },
    });
    assert.equal(result.result, 'PASS');
    assert.equal(result.saveInvoked, true);
    assert.equal(result.manualChallengeCompleted, true);
    assert.equal(fixture.mutations.some((item) => item.pathname === '/api/save'), true);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('startup challenge can be cleared before guarded Submit for review', async () => {
  const manifest = makeManifest({ shortDescription: 'Changed before submit' });
  const fixture = await startFixture(fixtureState(manifest, { challengeVisible: true, shortDescription: 'Old before submit' }));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  try {
    const result = await runPortalAutomation({
      manifestInfo: info,
      mode: 'submit',
      saveDraftAuthorized: true,
      origin: fixture.origin,
      page,
      context,
      manualInteraction: { waitForConfirmation: async () => { fixture.state.challengeVisible = false; await page.evaluate(() => { document.querySelector('[data-testid="fixture-challenge"]').hidden = true; }); return 'confirmed'; } },
    });
    assert.equal(result.result, 'PASS');
    assert.equal(result.submitInvoked, true);
    assert.equal(result.submitAccepted, true);
    assert.equal(result.manualChallengeCompleted, true);
    assert.equal(fixture.mutations.some((item) => item.pathname === '/api/submit'), true);
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

test('challenge after Save fails safely and is reported without repeating Save', async () => {
  const manifest = makeManifest({ shortDescription: 'Changed before post-save challenge' });
  const fixture = await startFixture(fixtureState(manifest, { shortDescription: 'Old before post-save challenge', challengeAfterSave: true }));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  let reloadCount = 0;
  const originalReload = page.reload.bind(page);
  page.reload = async (...args) => { reloadCount += 1; return originalReload(...args); };
  try {
    const result = await runPortalAutomation({ manifestInfo: info, mode: 'save', saveDraftAuthorized: true, origin: fixture.origin, page, context, manualInteraction: { waitForConfirmation: async () => 'confirmed' } });
    assert.equal(result.result, 'FAIL');
    assert.equal(result.manualChallengeDetected, true);
    assert.equal(result.saveInvoked, true);
    assert.equal(result.submitInvoked, false);
    assert.equal(result.manualChallengeHandoffCount, 0);
    assert.equal(reloadCount, 0);
    assert.match(result.blockers.join(' '), /after Save|clean listing state/i);
    assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/save').length, 1);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('challenge after a format mutation fails before Back navigation', async () => {
  const manifest = makeManifest({ packages: [{ engineVersion: '5.8', bundleRelativePath: 'packages/UE5.8/package.zip', sha256: 'b'.repeat(64), projectFileLink: 'https://example.com/new-package.zip' }] });
  const fixture = await startFixture(fixtureState(manifest, { projectFileLink: 'https://example.com/old-package.zip', challengeAfterFirstMutation: true }));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  let gotoCount = 0;
  const originalGoto = page.goto.bind(page);
  page.goto = async (...args) => { gotoCount += 1; return originalGoto(...args); };
  try {
    const result = await runPortalAutomation({ manifestInfo: info, mode: 'save', saveDraftAuthorized: true, origin: fixture.origin, page, context, manualInteraction: { waitForConfirmation: async () => 'confirmed' } });
    assert.equal(result.result, 'FAIL');
    assert.equal(result.manualChallengeDetected, true);
    assert.equal(result.manualChallengeHandoffCount, 0);
    assert.equal(result.writeInteractionsPerformed, 1);
    assert.equal(result.saveInvoked, false);
    assert.equal(result.submitInvoked, false);
    assert.equal(gotoCount, 0);
    assert.equal(await page.locator('#format-view').isVisible(), true);
    assert.equal(fixture.mutations.some((item) => item.pathname === '/api/save'), false);
    assert.equal(fixture.mutations.some((item) => item.pathname === '/api/submit'), false);
    assert.match(result.blockers.join(' '), /staged|clean listing state/i);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('challenge after a staged mutation fails safe without Save or Submit', async () => {
  const manifest = makeManifest({ shortDescription: 'Changed staged value' });
  const fixture = await startFixture(fixtureState(manifest, { shortDescription: 'Old staged value', challengeAfterFirstMutation: true }));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  try {
    const result = await runPortalAutomation({ manifestInfo: info, mode: 'save', saveDraftAuthorized: true, origin: fixture.origin, page, context, manualInteraction: { waitForConfirmation: async () => 'confirmed' } });
    assert.equal(result.result, 'FAIL');
    assert.equal(result.manualChallengeDetected, true);
    assert.equal(result.manualChallengeHandoffCount, 0);
    assert.equal(result.saveInvoked, false);
    assert.equal(result.submitInvoked, false);
    assert.equal(result.writeInteractionsPerformed, 1);
    assert.match(result.blockers.join(' '), /staged|clean listing state/i);
    assert.equal(fixture.mutations.some((item) => item.pathname === '/api/save'), false);
    assert.equal(fixture.mutations.some((item) => item.pathname === '/api/submit'), false);
  } finally {
    await context.close();
    await fixture.close();
  }
});

test('wrong listing UUID blocks after a redirect before mutation', async () => {
  const manifest = makeManifest({ listingId: '22222222-2222-4222-8222-222222222222' });
  const { result, fixture } = await scenario({ manifest, mode: 'save', saveDraftAuthorized: true, fixtureOptions: { redirectListingId: listingId } });
  assert.equal(result.result, 'FAIL');
  assert.match(result.blockers.join(' '), /MANUAL ACTION REQUIRED.*expected listing path/i);
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

test('format view owns format controls and hides listing controls', async () => {
  const manifest = makeManifest();
  const fixture = await startFixture(fixtureState(manifest));
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
  assert.equal(await page.getByLabel('Short description *', { exact: true }).isVisible(), true);
  assert.equal(await page.getByLabel('Project File Link', { exact: true }).isVisible(), false);
  await page.getByRole('button', { name: 'Unreal Engine', exact: true }).click();
  assert.equal(await page.getByLabel('Short description *', { exact: true }).isVisible(), false);
  assert.equal(await page.getByLabel('Project File Link', { exact: true }).isVisible(), true);
  await context.close();
  await fixture.close();
});

test('format evidence merges documentation and support when the listing view is unresolved', () => {
  const manifest = makeManifest();
  const makeField = (path, classification, view) => ({ manifestJsonPath: path, classification, view, currentVisibleValue: classification === 'MATCH' ? manifest[path] : null });
  const main = { fields: [makeField('documentationUrl', 'NOT_VISIBLE', 'listing'), makeField('supportUrl', 'NOT_DISCOVERED', 'listing')] };
  const format = { fields: [makeField('documentationUrl', 'MATCH', 'format'), makeField('supportUrl', 'MATCH', 'format')] };
  const merged = mergeListingAndFormatComparisons(main, format, manifest);
  assert.equal(merged.fields.find((field) => field.manifestJsonPath === 'documentationUrl').classification, 'MATCH');
  assert.equal(merged.fields.find((field) => field.manifestJsonPath === 'documentationUrl').view, 'format');
  assert.equal(merged.fields.find((field) => field.manifestJsonPath === 'supportUrl').classification, 'MATCH');
  assert.equal(merged.fields.find((field) => field.manifestJsonPath === 'supportUrl').view, 'format');
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
  assert.equal(support.view, 'format');
});

test('disabled planned locator fails preflight with zero mutations', async () => {
  const manifest = makeManifest({ shortDescription: 'New Fixture Short Description' });
  const { result, fixture } = await scenario({ manifest, state: { shortDescription: 'Old Fixture Short Description', disableFields: ['shortDescription'] }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'FAIL');
  assert.match(result.blockers.join(' '), /writable locator|preflight/i);
  assert.equal(result.writeInteractionsPerformed, 0);
  assert.equal(fixture.mutations.length, 0);
});

test('format-only mutation carries format ownership and executes in format view', async () => {
  const manifest = makeManifest({ packages: [{ engineVersion: '5.8', bundleRelativePath: 'packages/UE5.8/package.zip', sha256: 'b'.repeat(64), projectFileLink: 'https://example.com/new-package.zip' }] });
  const { result, fixture } = await scenario({ manifest, state: { projectFileLink: 'https://example.com/old-package.zip' }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'PASS');
  assert.deepEqual(result.plannedMutations.map((item) => item.view), ['format']);
  assert.deepEqual(result.executedMutations, ['packages[0].projectFileLink']);
  assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/save').length, 1);
});

test('format preflight failure after listing preflight causes zero mutations everywhere', async () => {
  const manifest = makeManifest({ shortDescription: 'Changed listing text', packages: [{ engineVersion: '5.8', bundleRelativePath: 'packages/UE5.8/package.zip', sha256: 'b'.repeat(64), projectFileLink: 'https://example.com/new-package.zip' }] });
  const { result, fixture } = await scenario({ manifest, state: { shortDescription: 'Old listing text', projectFileLink: 'https://example.com/old-package.zip', disableFields: ['projectFileLink'] }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'FAIL');
  assert.match(result.blockers.join(' '), /projectFileLink|disabled|preflight/i);
  assert.deepEqual(result.executedMutations, []);
  assert.equal(result.writeInteractionsPerformed, 0);
  assert.equal(fixture.mutations.length, 0);
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

test('technical information uses the approved contenteditable target without an aria label', async () => {
  const manifest = makeManifest({ technicalInformationText: 'New technical information' });
  const { result, fixture } = await scenario({ manifest, state: { technicalInformationText: 'Old technical information', technicalInformationNoLabel: true }, mode: 'save', saveDraftAuthorized: true });
  const technical = result.plannedMutations.find((item) => item.fieldName === 'technicalInformationFile');
  assert.equal(result.result, 'PASS');
  assert.equal(technical.view, 'format');
  assert.equal(technical.locator.strategy, 'contenteditable');
  assert.equal(technical.locator.selector, '[contenteditable="true"]');
  assert.equal(result.executedMutations.includes('technicalInformationFile'), true);
  assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/save').length, 1);
  assert.equal(fixture.mutations[0].body.technicalInformationText, 'New technical information');
  assert.equal(fixture.mutations[0].body.technicalInformationText.includes('FabTechnicalInformation.txt'), false);
});

test('preflight never falls back from the comparison-approved locator', async () => {
  const manifest = makeManifest({ shortDescription: 'Changed short description' });
  const fixture = await startFixture(fixtureState(manifest, { shortDescription: 'Old short description' }));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  try {
    await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
    const comparison = await compareManifest(page, info, { view: 'listing' });
    const mutation = buildMutationPlan(comparison, info);
    assert.equal(mutation.plan[0].locator.strategy, 'getByLabel');
    await page.evaluate(() => {
      document.querySelector('[aria-label="Short description *"]').closest('label').remove();
      const fallback = document.createElement('input');
      fallback.setAttribute('aria-label', 'Short description');
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

test('DOM change after global preflight fails before the first exact-target mutation', async () => {
  const manifest = makeManifest({ shortDescription: 'Changed short description' });
  const fixture = await startFixture(fixtureState(manifest, { shortDescription: 'Old short description' }));
  const context = await browser.newContext();
  const page = await context.newPage();
  const info = await makeManifestInfo(manifest);
  try {
    await page.goto(`${fixture.origin}/portal/listings/${listingId}/edit`);
    const comparison = await compareManifest(page, info, { view: 'listing' });
    const mutation = buildMutationPlan(comparison, info);
    const preflight = await preflightMutationPlan(page, mutation.plan, manifest);
    assert.equal(preflight.ok, true);
    await page.evaluate(() => document.querySelector('[aria-label="Short description *"]').remove());
    await assert.rejects(
      executeMutationPlan(page, preflight, info),
      /approved|target|match count|visible/i,
    );
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

test('mixed staging runs a full multi-view comparison before Save', async () => {
  const manifest = makeManifest({ shortDescription: 'Changed listing text', packages: [{ engineVersion: '5.8', bundleRelativePath: 'packages/UE5.8/package.zip', sha256: 'b'.repeat(64), projectFileLink: 'https://example.com/new-package.zip' }] });
  const { result, fixture } = await scenario({ manifest, state: { shortDescription: 'Old listing text', projectFileLink: 'https://example.com/old-package.zip' }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'PASS');
  assert.equal(result.comparisonAfter.counts.MISMATCH, 0);
  assert.equal(result.comparisonAfter.fields.find((field) => field.manifestJsonPath === 'shortDescription').view, 'listing');
  assert.equal(result.comparisonAfter.fields.find((field) => field.manifestJsonPath === 'packages[0].projectFileLink').view, 'format');
  assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/save').length, 1);
});

test('format mismatch during staged multi-view verification prevents Save', async () => {
  const manifest = makeManifest({ packages: [{ engineVersion: '5.8', bundleRelativePath: 'packages/UE5.8/package.zip', sha256: 'b'.repeat(64), projectFileLink: 'https://example.com/new-package.zip' }] });
  const { result, fixture } = await scenario({ manifest, state: { projectFileLink: 'https://example.com/old-package.zip', dropStagedFields: ['projectFileLink'] }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'FAIL');
  assert.equal(result.saveInvoked, false);
  assert.equal(fixture.mutations.some((item) => item.pathname === '/api/save'), false);
  assert.match(result.blockers.join(' '), /projectFileLink|mismatch|staged/i);
});

test('post-save read-back rechecks the format view', async () => {
  const manifest = makeManifest({ packages: [{ engineVersion: '5.8', bundleRelativePath: 'packages/UE5.8/package.zip', sha256: 'b'.repeat(64), projectFileLink: 'https://example.com/new-package.zip' }] });
  const { result, fixture } = await scenario({ manifest, state: { projectFileLink: 'https://example.com/old-package.zip' }, fixtureOptions: { dropSaveFields: ['projectFileLink'] }, mode: 'save', saveDraftAuthorized: true });
  assert.equal(result.result, 'FAIL');
  assert.equal(result.saveInvoked, true);
  assert.equal(result.comparisonAfter.fields.find((field) => field.manifestJsonPath === 'packages[0].projectFileLink').view, 'format');
  assert.equal(result.comparisonAfter.fields.find((field) => field.manifestJsonPath === 'packages[0].projectFileLink').classification, 'MISMATCH');
  assert.equal(fixture.mutations.filter((item) => item.pathname === '/api/save').length, 1);
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
