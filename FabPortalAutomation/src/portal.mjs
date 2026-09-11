import { chromium } from 'playwright-core';
import { compareManifest, summarizeComparison } from './comparison.mjs';
import { createStdinManualInteraction, DEFAULT_MANUAL_CHALLENGE_MAX_CYCLES, normalizeManualInteractionDecision } from './manual-handoff.mjs';
import { installNetworkGuard } from './network-guard.mjs';
import { dangerousActionCandidates } from './locators.mjs';
import { classifyFabView, isFormatView } from './view-detection.mjs';

const KNOWN_STATUSES = ['Pending approval', 'Pending Publication', 'Changes needed', 'Draft', 'Approved', 'Live'];
const MANUAL_CHALLENGE_TEXT = [
  /verify you are human/i,
  /cloudflare/i,
  /just a moment/i,
  /attention required/i,
  /security check/i,
  /セキュリティチェック/i,
  /あともう1ステップ/i,
  /継続するには/i,
];

export class ManualChallengeError extends Error {
  constructor() {
    super('MANUAL ACTION REQUIRED: Cloudflare or a browser security challenge is blocking Fab. Complete it manually and rerun.');
    this.name = 'ManualChallengeError';
    this.code = 'MANUAL_CHALLENGE';
  }
}

class ManualChallengeCancelledError extends Error {
  constructor() {
    super('MANUAL_CHALLENGE_CANCELLED');
    this.name = 'ManualChallengeCancelledError';
    this.code = 'MANUAL_CHALLENGE_CANCELLED';
  }
}

function normalized(value) {
  return String(value ?? '').replace(/\s+/g, ' ').trim();
}

async function exactText(page, textValue) {
  const locator = page.getByText(textValue, { exact: true });
  const count = await locator.count();
  let visibleCount = 0;
  for (let index = 0; index < count; index += 1) {
    if (await locator.nth(index).isVisible().catch(() => false)) visibleCount += 1;
  }
  return { locator, count: visibleCount };
}

async function readStatus(page) {
  const data = page.getByTestId('listing-status');
  if (await data.count() === 1) return normalized(await data.textContent());
  for (const status of KNOWN_STATUSES) {
    const found = await exactText(page, status);
    if (found.count === 1) return status;
  }
  throw new Error('Fab listing status could not be read from an approved status locator.');
}

async function requireExactTitle(page, title) {
  const heading = page.getByRole('heading', { name: title, exact: true });
  const headingCount = await heading.count();
  let visibleHeadingCount = 0;
  for (let index = 0; index < headingCount; index += 1) {
    if (await heading.nth(index).isVisible().catch(() => false)) visibleHeadingCount += 1;
  }
  if (visibleHeadingCount === 1) return;
  const text = page.getByText(title, { exact: true });
  const textCount = await text.count();
  let visibleTextCount = 0;
  for (let index = 0; index < textCount; index += 1) {
    if (await text.nth(index).isVisible().catch(() => false)) visibleTextCount += 1;
  }
  if (visibleTextCount !== 1) throw new Error(`Fab listing title is not uniquely visible as ${title}.`);
}

async function hasVisibleChallengeText(page, pattern) {
  // getByText() may return a visible ancestor whose textContent includes a
  // hidden challenge fragment. Restrict the search to element descendants and
  // require the element's rendered innerText and viewport intersection to
  // contain the evidence.
  const locator = page.locator('body *').filter({ hasText: pattern });
  const count = await locator.count().catch(() => 0);
  const viewport = await page.evaluate(() => ({ width: window.innerWidth, height: window.innerHeight })).catch(() => null);
  for (let index = 0; index < count; index += 1) {
    const candidate = locator.nth(index);
    if (!await candidate.isVisible().catch(() => false)) continue;
    const box = await candidate.boundingBox().catch(() => null);
    if (viewport && (!box || box.width <= 0 || box.height <= 0 || box.x + box.width <= 0 || box.y + box.height <= 0 || box.x >= viewport.width || box.y >= viewport.height)) continue;
    const renderedText = await candidate.innerText().catch(() => '');
    if (pattern.test(renderedText)) return true;
  }
  return false;
}

async function detectManualBlock(page) {
  for (const pattern of MANUAL_CHALLENGE_TEXT) {
    if (await hasVisibleChallengeText(page, pattern)) {
      throw new ManualChallengeError();
    }
  }
  const currentUrl = new URL(page.url());
  if (/(?:\/login|\/signin|\/sign-in|\/authenticate)(?:\/|$)/i.test(currentUrl.pathname) || /^(?:auth|accounts?)\./i.test(currentUrl.hostname)) {
    throw new Error('MANUAL ACTION REQUIRED: Fab authentication is required. Complete login/MFA manually and rerun.');
  }
  const passwordCount = await page.locator('input[type="password"]').count().catch(() => 0);
  const formCount = await page.locator('form').count().catch(() => 0);
  const signInButtonCount = await page.getByRole('button', { name: /^(?:sign in|log in)$/i }).count().catch(() => 0);
  if (passwordCount > 0 && formCount > 0 && signInButtonCount > 0) {
    throw new Error('MANUAL ACTION REQUIRED: Fab authentication is required. Complete login/MFA manually and rerun.');
  }
}

function targetListingPath(listingId) {
  return `/portal/listings/${listingId}/edit`;
}

function pageMatchesTargetListing(page, manifest, origin) {
  try {
    const current = new URL(page.url());
    const expectedOrigin = new URL(origin);
    const pathname = current.pathname.replace(/\/$/, '');
    return current.hostname === expectedOrigin.hostname && pathname === targetListingPath(manifest.listingId);
  } catch {
    return false;
  }
}

export function selectExistingTargetPage(context, manifest, origin = 'https://www.fab.com') {
  const pages = context.pages();
  const matches = pages.filter((candidate) => pageMatchesTargetListing(candidate, manifest, origin));
  if (matches.length !== 1) {
    throw new Error(`MANUAL ACTION REQUIRED: exactly one already-open Fab listing page is required for ${targetListingPath(manifest.listingId)}; found ${matches.length}. Do not navigate automatically.`);
  }
  return matches[0];
}

async function ensurePassiveTarget(page, manifest, origin) {
  if (!pageMatchesTargetListing(page, manifest, origin)) {
    let current = 'unknown';
    try { current = new URL(page.url()).pathname; } catch { /* retain sanitized placeholder */ }
    throw new Error(`MANUAL ACTION REQUIRED: the already-open Fab page is not the expected listing path. Expected ${targetListingPath(manifest.listingId)}; received ${current}. Do not navigate automatically.`);
  }
  const deadline = Date.now() + 3000;
  let lastTitleError = null;
  while (Date.now() < deadline) {
    await detectManualBlock(page);
    try {
      await requireExactTitle(page, manifest.title);
      return { finalUrl: page.url() };
    } catch (error) {
      lastTitleError = error;
    }
    await page.waitForTimeout(50);
  }
  throw lastTitleError ?? new Error('Fab listing title was not readable during passive attach.');
}

function createNavigationDiagnostics(context, result) {
  const handlers = new Map();
  const observePage = (page) => {
    if (!page || handlers.has(page)) return;
    const handler = (frame) => {
      if (frame !== page.mainFrame()) return;
      result.humanObservedNavigationCount += 1;
    };
    handlers.set(page, handler);
    page.on('framenavigated', handler);
  };
  for (const page of context.pages()) observePage(page);
  const onPage = (page) => observePage(page);
  context.on('page', onPage);
  return {
    observePage,
    dispose() {
      context.off('page', onPage);
      for (const [page, handler] of handlers) page.off('framenavigated', handler);
    },
  };
}

function isManualChallengeError(error) {
  return error?.code === 'MANUAL_CHALLENGE';
}

async function withManualChallengeHandoff({ context, page, manifest, origin, action, result, manualInteraction, maxCycles, diagnostics }) {
  let currentPage = page;
  while (true) {
    try {
      return { page: currentPage, value: await action(currentPage) };
    } catch (error) {
      if (!isManualChallengeError(error)) throw error;
      result.manualChallengeDetected = true;
      if (result.manualChallengeHandoffCount >= maxCycles) {
        throw new Error(`Manual Cloudflare handoff exceeded the maximum of ${maxCycles} cycles.`);
      }
      result.manualChallengeHandoffCount += 1;
      if (!manualInteraction || typeof manualInteraction.waitForConfirmation !== 'function') {
        throw new Error('Cloudflare challenge requires an injectable manual interaction provider.');
      }
      const decision = normalizeManualInteractionDecision(await manualInteraction.waitForConfirmation({
        cycle: result.manualChallengeHandoffCount,
        maxCycles,
      }));
      if (decision === 'cancelled') {
        result.manualChallengeCancelled = true;
        throw new ManualChallengeCancelledError();
      }
      if (decision !== 'confirmed') {
        throw new Error('Manual Cloudflare handoff requires Enter to continue or q + Enter to cancel.');
      }
      let revalidatedPage;
      try {
        revalidatedPage = selectExistingTargetPage(context, manifest, origin);
        diagnostics?.navigationDiagnostics?.observePage(revalidatedPage);
        await ensurePassiveTarget(revalidatedPage, manifest, origin);
        await readStatus(revalidatedPage);
      } catch (revalidationError) {
        if (isManualChallengeError(revalidationError)) continue;
        throw revalidationError;
      }
      result.manualChallengeCompleted = true;
      currentPage = revalidatedPage;
    }
  }
}

async function isVisibleUnique(locator) {
  if (await locator.count() !== 1) return false;
  return await locator.isVisible().catch(() => false);
}

function listingSummaryLocator(page, manifest) {
  const escapedTitle = String(manifest.title).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return page.getByRole('button', { name: new RegExp(`^${escapedTitle}(?:\\s|$)`), exact: false });
}

async function navigateToListingMain(page, manifest, guard) {
  const candidates = [
    { locator: page.getByRole('button', { name: 'Back to listing', exact: true }), reason: 'Back to listing' },
    { locator: listingSummaryLocator(page, manifest), reason: 'listing summary' },
  ];
  let selected = null;
  for (const candidate of candidates) {
    if (await isVisibleUnique(candidate.locator)) {
      selected = candidate;
      break;
    }
  }
  if (!selected) throw new Error('MANUAL ACTION REQUIRED: Fab format view is open but no unique read-only listing-main navigation control is available. Do not navigate automatically.');
  await detectManualBlock(page);
  const beforeMutations = guard?.summary().networkMutationRequestsObserved ?? 0;
  await selected.locator.click();
  await detectManualBlock(page);
  const afterMutations = guard?.summary().networkMutationRequestsObserved ?? beforeMutations;
  if (afterMutations > beforeMutations) throw new Error(`Read-only ${selected.reason} navigation caused a network mutation; discovery was aborted safely.`);
}

async function ensureListingView(page, manifest, origin, guard = null) {
  await ensurePassiveTarget(page, manifest, origin);
  if (await isFormatView(page)) {
    await navigateToListingMain(page, manifest, guard);
    await ensurePassiveTarget(page, manifest, origin);
  }
  if (!await isVisibleUnique(page.getByRole('button', { name: manifest.includedFormat, exact: true }))) {
    throw new Error('MANUAL ACTION REQUIRED: the expected Fab listing main view could not be proven without navigation.');
  }
}

async function ensureFormatView(page, manifest, origin, guard) {
  await ensureListingView(page, manifest, origin, guard);
  const format = page.getByRole('button', { name: manifest.includedFormat, exact: true });
  if (!await isVisibleUnique(format)) throw new Error('Unreal Engine format navigation control is not uniquely visible.');
  await detectManualBlock(page);
  const beforeMutations = guard?.summary().networkMutationRequestsObserved ?? 0;
  await format.click();
  await detectManualBlock(page);
  await page.waitForTimeout(100);
  const afterMutations = guard?.summary().networkMutationRequestsObserved ?? beforeMutations;
  if (afterMutations > beforeMutations) throw new Error('Read-only format navigation caused a network mutation; discovery was aborted safely.');
  await waitForFormatView(page, manifest);
  await detectManualBlock(page);
  if (!await isFormatView(page)) throw new Error('Fab Unreal Engine format view could not be proven after navigation.');
}

async function waitForFormatView(page, manifest) {
  const isFixture = (() => { try { return ['localhost', '127.0.0.1'].includes(new URL(page.url()).hostname); } catch { return false; } })();
  if (isFixture) return;
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    await detectManualBlock(page);
    if (await isFormatView(page)) return;
    const engineVersion = page.getByText(/^UE_[0-9]+(?:\.[0-9]+)+$/, { exact: false });
    const formatHeading = page.getByRole('heading', { name: 'Project Versions*', exact: true });
    const platformChip = page.getByRole('button', { name: /^Remove (?:Windows|Win64|Linux|Mac(?: OS)?|macOS)$/ });
    const locators = [engineVersion, formatHeading, platformChip];
    if (manifest.packages[0].projectFileLink !== null) locators.unshift(page.getByText(manifest.packages[0].projectFileLink, { exact: true }));
    for (const locator of locators) {
      if (await locator.count() === 0) continue;
      for (let index = 0; index < await locator.count(); index += 1) {
        if (await locator.nth(index).isVisible().catch(() => false)) return;
      }
    }
    await page.waitForTimeout(50);
  }
}

const FORMAT_COMPARISON_FIELDS = new Set(['engineVersions', 'platforms', 'technicalInformationFile', 'media']);
const FORMAT_READ_EVIDENCE_FIELDS = new Set(['documentationUrl']);

function comparisonEvidenceRank(field) {
  return ['MATCH', 'MISMATCH'].includes(field?.classification) ? 2 : field?.classification === 'NOT_APPLICABLE' ? 1 : 0;
}

function mergeComparisonField(mainField, formatField) {
  if (!formatField) return mainField;
  const path = mainField.manifestJsonPath;
  const formatOwned = FORMAT_COMPARISON_FIELDS.has(path) || /^packages\[\d+\]\.projectFileLink$/.test(path);
  const formatReadEvidence = FORMAT_READ_EVIDENCE_FIELDS.has(path);
  if (!formatOwned && !formatReadEvidence) return mainField;
  const mainRank = comparisonEvidenceRank(mainField);
  const formatRank = comparisonEvidenceRank(formatField);
  if (formatRank > mainRank) return formatField;
  return mainField;
}

export function mergeListingAndFormatComparisons(listingComparison, formatComparison, manifest) {
  const formatFields = new Map(formatComparison.fields.map((field) => [field.manifestJsonPath, field]));
  const fields = listingComparison.fields.map((field) => mergeComparisonField(field, formatFields.get(field.manifestJsonPath)));
  for (const [index] of manifest.packages.entries()) {
    const field = `packages[${index}].projectFileLink`;
    const replacement = formatFields.get(field);
    const position = fields.findIndex((item) => item.manifestJsonPath === field);
    if (replacement && position >= 0) fields[position] = mergeComparisonField(fields[position], replacement);
  }
  return summarizeComparison(fields);
}

export async function collectPortalComparison(page, manifestInfo, { guard, origin = 'https://www.fab.com' } = {}) {
  const actions = [];
  const manifest = manifestInfo.manifest;
  await ensureListingView(page, manifest, origin, guard);
  actions.push(...await prepareReadOnlySections(page, guard));
  const listingComparison = await compareManifest(page, manifestInfo, { view: 'listing' });
  await ensureFormatView(page, manifest, origin, guard);
  actions.push('opened Unreal Engine format section');
  actions.push(...await prepareReadOnlySections(page, guard));
  const formatComparison = await compareManifest(page, manifestInfo, { view: 'format' });
  return { comparison: mergeListingAndFormatComparisons(listingComparison, formatComparison, manifest), readOnlyUiActions: actions };
}

const READ_ONLY_SECTION_TOGGLES = [
  'toggle Compatibility and file information',
  'toggle Third party software usage',
  'toggle Tools and plugins',
  'toggle Additional information',
];

async function prepareReadOnlySections(page, guard) {
  const actions = [];
  for (const name of READ_ONLY_SECTION_TOGGLES) {
    const locator = page.getByRole('button', { name, exact: true });
    if (await locator.count() !== 1) continue;
    if (await locator.isDisabled().catch(() => true)) continue;
    const expanded = await locator.getAttribute('aria-expanded');
    if (expanded !== 'false') continue;
    if (!await locator.getAttribute('aria-controls')) continue;
    await detectManualBlock(page);
    const before = guard.summary().networkMutationRequestsObserved;
    await locator.click();
    await page.waitForTimeout(100);
    await detectManualBlock(page);
    const after = guard.summary().networkMutationRequestsObserved;
    if (after > before) throw new Error(`Read-only section expansion ${name} caused a network mutation; discovery was aborted safely.`);
    if (await locator.getAttribute('aria-expanded') !== 'true') throw new Error(`Read-only section expansion ${name} did not reach an expanded state.`);
    actions.push(name);
  }
  return actions;
}

async function readDangerousActions(page) {
  const found = [];
  for (const [kind, pattern] of dangerousActionCandidates()) {
    const locator = page.getByRole('button', { name: pattern });
    const count = await locator.count();
    if (count > 0) {
      found.push({ kind, text: pattern.toString(), role: 'button', matchCount: count, disabled: await locator.first().isDisabled().catch(() => false) });
    }
  }
  return found;
}

export async function runPortalAutomation({ manifestInfo, cdpEndpoint, mode = 'verify', origin = 'https://www.fab.com', page: injectedPage = null, context: injectedContext = null, manualInteraction = null, maxManualChallengeCycles = DEFAULT_MANUAL_CHALLENGE_MAX_CYCLES }) {
  if (mode !== 'verify') throw new Error('Fab Portal automation supports verify mode only.');
  let browser = null;
  let context = injectedContext;
  let page = injectedPage;
  const interaction = manualInteraction ?? createStdinManualInteraction();
  let targetPageSelectionReason = injectedPage ? 'Caller-supplied page was used for controlled fixture verification.' : null;
  if (!page) {
    if (!context && !cdpEndpoint) throw new Error('A CDP endpoint is required for the production browser connection.');
    if (!context) {
      browser = await chromium.connectOverCDP(cdpEndpoint);
      context = browser.contexts()[0];
    }
    if (!context) throw new Error('The CDP browser has no default context.');
    page = selectExistingTargetPage(context, manifestInfo.manifest, origin);
    targetPageSelectionReason = 'Selected the only existing page with the exact Fab hostname and listing pathname; query/hash ignored.';
  }
  const guard = installNetworkGuard(context);
  const result = {
    schemaVersion: 1,
    mode: 'verify',
    listingId: manifestInfo.manifest.listingId,
    listingTitle: manifestInfo.manifest.title,
    listingStatus: null,
    manifestSha256: manifestInfo.manifestSha256,
    verificationTransport: 'cdp',
    observationSource: 'cdp',
    observationSha256: null,
    portalReady: manifestInfo.manifest.portalReady,
    comparison: null,
    portalMismatchCount: 0,
    portalUnresolvedCount: 0,
    portalVerificationComplete: false,
    comparisonAfter: null,
    plannedMutations: [],
    executedMutations: [],
    saveInvoked: false,
    submitInvoked: false,
    submitAccepted: false,
    postSubmitStatus: null,
    writeInteractionsPerformed: 0,
    dangerousActionsFound: [],
    blockers: [],
    result: 'FAIL',
    readOnlyUiActions: [],
    writeReady: false,
    writeBlockers: [],
    selectedPageUrl: page?.url() ?? null,
    targetPageSelectionReason,
    initialNavigationPerformed: false,
    hardNavigationCount: 0,
    reloadCount: 0,
    automationHardNavigationCount: 0,
    humanObservedNavigationCount: 0,
    manualChallengeDetected: false,
    manualChallengeHandoffCount: 0,
    manualChallengeCompleted: false,
    manualChallengeCancelled: false,
    passiveAttach: true,
  };
  const navigationDiagnostics = createNavigationDiagnostics(context, result);
  Object.defineProperty(result, 'navigationDiagnostics', { value: navigationDiagnostics, enumerable: false, configurable: true });
  Object.defineProperty(result, 'page', { value: page, enumerable: false, configurable: true });
  Object.defineProperty(result, 'browser', { value: browser, enumerable: false, configurable: true });
  try {
    const initialTarget = await withManualChallengeHandoff({
      context,
      page,
      manifest: manifestInfo.manifest,
      origin,
      result,
      manualInteraction: interaction,
      maxCycles: maxManualChallengeCycles,
      diagnostics: result,
      action: (candidatePage) => ensurePassiveTarget(candidatePage, manifestInfo.manifest, origin),
    });
    page = initialTarget.page;
    const initialRead = await withManualChallengeHandoff({
      context,
      page,
      manifest: manifestInfo.manifest,
      origin,
      result,
      manualInteraction: interaction,
      maxCycles: maxManualChallengeCycles,
      diagnostics: result,
      action: async (candidatePage) => {
        await detectManualBlock(candidatePage);
        return readStatus(candidatePage);
      },
    });
    page = initialRead.page;
    result.listingStatus = initialRead.value;
    result.dangerousActionsFound = await readDangerousActions(page);
    const collectedResult = await withManualChallengeHandoff({
      context,
      page,
      manifest: manifestInfo.manifest,
      origin,
      result,
      manualInteraction: interaction,
      maxCycles: maxManualChallengeCycles,
      diagnostics: result,
      action: (candidatePage) => collectPortalComparison(candidatePage, manifestInfo, { guard, origin }),
    });
    page = collectedResult.page;
    const collected = collectedResult.value;
    result.readOnlyUiActions.push(...collected.readOnlyUiActions);
    result.comparison = collected.comparison;
    result.portalMismatchCount = result.comparison.mismatchCount;
    result.portalUnresolvedCount = result.comparison.unresolvedCritical.length;
    result.portalVerificationComplete = result.portalMismatchCount === 0 && result.portalUnresolvedCount === 0;
    if (result.comparison.mismatchCount > 0) result.blockers.push(`${result.comparison.mismatchCount} manifest mismatch(es).`);
    result.result = result.blockers.length === 0 ? 'PASS' : 'FAIL';
    return result;
  } catch (error) {
    if (isManualChallengeError(error)) result.manualChallengeDetected = true;
    result.blockers.push(error instanceof Error ? error.message : String(error));
    if (error?.code === 'MANUAL_CHALLENGE_CANCELLED') result.result = 'MANUAL_CHALLENGE_CANCELLED';
    return result;
  } finally {
    result.selectedPageUrl = page?.url() ?? result.selectedPageUrl;
    Object.defineProperty(result, 'page', { value: page, enumerable: false, configurable: true });
    result.network = guard.summary();
    navigationDiagnostics.dispose();
    await guard.dispose().catch(() => undefined);
    // The CLI disconnects after reports are written. This keeps screenshots and
    // post-run evidence available without using the browser as a write channel.
  }
}

export { detectManualBlock, prepareReadOnlySections, readStatus, requireExactTitle };
