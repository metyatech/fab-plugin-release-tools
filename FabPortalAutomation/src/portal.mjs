import { chromium } from 'playwright-core';
import { compareManifest, summarizeComparison } from './comparison.mjs';
import { buildMutationPlan, executeMutationPlan, preflightMutationPlan } from './mutation-plan.mjs';
import { createStdinManualInteraction, DEFAULT_MANUAL_CHALLENGE_MAX_CYCLES, normalizeManualInteractionDecision } from './manual-handoff.mjs';
import { installNetworkGuard } from './network-guard.mjs';
import { dangerousActionCandidates, listingEditUrl, resolveCandidate, saveCandidates, submitCandidates } from './locators.mjs';

const REVIEW_LOCKED = new Set(['pending approval', 'pending publication', 'approved', 'live']);
const KNOWN_STATUSES = ['Pending approval', 'Pending Publication', 'Changes needed', 'Draft', 'Approved', 'Live'];
const SUBMIT_ACCEPTED_STATUSES = new Set(['pending approval']);
const SUBMIT_OUTCOME_TIMEOUT_MS = 5000;
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

// These fields are owned by the manifest and must be readable or safely writable
// before a Save Draft or Submit for review operation can begin. Subcategory=[] is
// intentionally excluded because Fab may expose no distinct control for it.
const CRITICAL_OWNED_FIELDS = new Set([
  'shortDescription', 'longDescription', 'productType', 'category', 'tags',
  'includedFormat', 'engineVersions', 'platforms', 'license',
  'personalPriceUsd', 'professionalPriceUsd', 'matureContent', 'generatedWithAi',
  'allowsUsageWithAi', 'promotionalContent', 'forumPost', 'activation',
  'documentationUrl', 'supportUrl', 'technicalInformationFile', 'media',
]);

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
  const automationNavigations = new Map();
  const observePage = (page) => {
    if (!page || handlers.has(page)) return;
    const handler = (frame) => {
      if (frame !== page.mainFrame()) return;
      const pending = automationNavigations.get(page) ?? 0;
      if (pending > 0) {
        if (pending === 1) automationNavigations.delete(page);
        else automationNavigations.set(page, pending - 1);
        return;
      }
      result.humanObservedNavigationCount += 1;
    };
    handlers.set(page, handler);
    page.on('framenavigated', handler);
  };
  const markAutomationNavigation = (page) => automationNavigations.set(page, (automationNavigations.get(page) ?? 0) + 1);
  const clearAutomationNavigation = (page) => {
    const pending = automationNavigations.get(page) ?? 0;
    if (pending <= 1) automationNavigations.delete(page);
    else automationNavigations.set(page, pending - 1);
  };
  for (const page of context.pages()) observePage(page);
  const onPage = (page) => observePage(page);
  context.on('page', onPage);
  return {
    observePage,
    markAutomationNavigation,
    clearAutomationNavigation,
    dispose() {
      context.off('page', onPage);
      for (const [page, handler] of handlers) page.off('framenavigated', handler);
    },
  };
}

async function hardNavigate(page, url, options, diagnostics, initial = false) {
  await detectManualBlock(page);
  if (diagnostics) {
    diagnostics.hardNavigationCount += 1;
    diagnostics.automationHardNavigationCount += 1;
    if (initial) diagnostics.initialNavigationPerformed = true;
    diagnostics.navigationDiagnostics?.markAutomationNavigation(page);
  }
  try {
    const response = await page.goto(url, options);
    await detectManualBlock(page);
    return response;
  } finally {
    diagnostics?.navigationDiagnostics?.clearAutomationNavigation(page);
  }
}

async function reloadWithDiagnostics(page, options, diagnostics) {
  await detectManualBlock(page);
  diagnostics.reloadCount += 1;
  diagnostics.navigationDiagnostics?.markAutomationNavigation(page);
  try {
    const response = await page.reload(options);
    await detectManualBlock(page);
    return response;
  } finally {
    diagnostics.navigationDiagnostics?.clearAutomationNavigation(page);
  }
}

async function ensureTarget(page, manifest, origin, { passive = false, diagnostics = null, initial = false } = {}) {
  if (passive) return ensurePassiveTarget(page, manifest, origin);
  const expected = listingEditUrl(manifest.listingId, origin);
  const formatView = page.getByRole('heading', { name: 'Project Versions*', exact: true });
  const formatViewVisible = await formatView.count() > 0 && await formatView.first().isVisible().catch(() => false);
  if (!pageMatchesTargetListing(page, manifest, origin) || formatViewVisible) await hardNavigate(page, expected, { waitUntil: 'domcontentloaded' }, diagnostics, initial);
  await detectManualBlock(page);
  await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => undefined);
  await detectManualBlock(page);
  const parsed = new URL(page.url());
  const match = parsed.pathname.match(/^\/portal\/listings\/([^/]+)\/(?:edit)?$/);
  if (!match || match[1] !== manifest.listingId) throw new Error(`Fab listing URL UUID mismatch. Expected ${manifest.listingId}; received ${parsed.pathname}.`);
  await requireExactTitle(page, manifest.title);
  return { expectedUrl: expected, finalUrl: page.url() };
}

function isManualChallengeError(error) {
  return error?.code === 'MANUAL_CHALLENGE';
}

function manualChallengeRestartError(result) {
  const phase = result.saveInvoked ? 'after Save' : 'after Fab mutations were staged';
  return new Error(`Cloudflare challenge appeared ${phase}. Restart from a clean listing state; no additional Save or Submit was attempted.`);
}

async function withManualChallengeHandoff({ context, page, manifest, origin, action, result, manualInteraction, maxCycles, diagnostics }) {
  let currentPage = page;
  while (true) {
    try {
      return { page: currentPage, value: await action(currentPage) };
    } catch (error) {
      if (!isManualChallengeError(error)) throw error;
      result.manualChallengeDetected = true;
      if (result.writeInteractionsPerformed > 0) throw manualChallengeRestartError(result);
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

async function ensureListingView(page, manifest, origin, guard = null, { passive = false, diagnostics = null } = {}) {
  if (passive) {
    await ensureTarget(page, manifest, origin, { passive: true, diagnostics });
    const formatHeading = page.getByRole('heading', { name: 'Project Versions*', exact: true });
    if (await isVisibleUnique(formatHeading)) {
      const back = page.getByRole('button', { name: 'Back to listing', exact: true });
      if (!await isVisibleUnique(back)) throw new Error('MANUAL ACTION REQUIRED: Fab format view is open but no unique Back to listing control is available. Do not navigate automatically.');
      await detectManualBlock(page);
      const beforeMutations = guard?.summary().networkMutationRequestsObserved ?? 0;
      await back.click();
      await detectManualBlock(page);
      const afterMutations = guard?.summary().networkMutationRequestsObserved ?? beforeMutations;
      if (afterMutations > beforeMutations) throw new Error('Read-only listing navigation caused a network mutation; discovery was aborted safely.');
      await ensureTarget(page, manifest, origin, { passive: true, diagnostics });
    }
    if (!await isVisibleUnique(page.getByRole('button', { name: manifest.includedFormat, exact: true }))) {
      throw new Error('MANUAL ACTION REQUIRED: the expected Fab listing main view could not be proven without navigation.');
    }
    return;
  }
  const formatHeading = page.getByRole('heading', { name: 'Project Versions*', exact: true });
  const listingControl = page.getByRole('button', { name: manifest.includedFormat, exact: true });
  if (await isVisibleUnique(formatHeading)) {
    const back = page.getByRole('button', { name: 'Back to listing', exact: true });
    if (await isVisibleUnique(back)) {
      await detectManualBlock(page);
      const beforeMutations = guard?.summary().networkMutationRequestsObserved ?? 0;
      await back.click();
      await detectManualBlock(page);
      const afterMutations = guard?.summary().networkMutationRequestsObserved ?? beforeMutations;
      if (afterMutations > beforeMutations) throw new Error('Read-only listing navigation caused a network mutation; discovery was aborted safely.');
    }
    else await hardNavigate(page, listingEditUrl(manifest.listingId, origin), { waitUntil: 'domcontentloaded' }, diagnostics);
  } else if (!await isVisibleUnique(listingControl)) {
    await hardNavigate(page, listingEditUrl(manifest.listingId, origin), { waitUntil: 'domcontentloaded' }, diagnostics);
  }
  await ensureTarget(page, manifest, origin, { diagnostics });
  if (!await isVisibleUnique(page.getByRole('button', { name: manifest.includedFormat, exact: true }))) {
    throw new Error('Fab listing main view could not be proven after navigation.');
  }
}

async function ensureFormatView(page, manifest, origin, guard, options = {}) {
  await ensureListingView(page, manifest, origin, guard, options);
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
  const formatHeading = page.getByRole('heading', { name: 'Project Versions*', exact: true });
  if (!await isVisibleUnique(formatHeading)) throw new Error('Fab Unreal Engine format view could not be proven after navigation.');
}

async function waitForFormatView(page, manifest) {
  const isFixture = (() => { try { return ['localhost', '127.0.0.1'].includes(new URL(page.url()).hostname); } catch { return false; } })();
  if (isFixture) return;
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    await detectManualBlock(page);
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
const FORMAT_READ_EVIDENCE_FIELDS = new Set(['documentationUrl', 'supportUrl']);

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

export async function collectPortalComparison(page, manifestInfo, { guard, origin = 'https://www.fab.com', passive = false, diagnostics = null } = {}) {
  const actions = [];
  const manifest = manifestInfo.manifest;
  await ensureListingView(page, manifest, origin, guard, { passive, diagnostics });
  actions.push(...await prepareReadOnlySections(page, guard));
  const listingComparison = await compareManifest(page, manifestInfo, { view: 'listing' });
  await ensureFormatView(page, manifest, origin, guard, { passive, diagnostics });
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

async function uniqueAction(page, candidates, actionName) {
  let resolved = null;
  for (const candidate of candidates) {
    const locator = candidate.create(page);
    const count = await locator.count();
    const visible = [];
    for (let index = 0; index < count; index += 1) {
      if (await locator.nth(index).isVisible().catch(() => false)) visible.push(locator.nth(index));
    }
    if (visible.length > 0) {
      resolved = { locator: visible[0], candidate, metadata: { matchCount: visible.length, unique: visible.length === 1, strategy: candidate.strategy, expression: candidate.expression, confidence: candidate.confidence, reason: candidate.reason } };
      break;
    }
  }
  if (!resolved?.metadata?.unique) throw new Error(`${actionName} action is not uniquely available.`);
  const disabled = await resolved.locator.isDisabled().catch(() => false);
  if (disabled) throw new Error(`${actionName} action is disabled.`);
  return resolved;
}

function criticalBlockers(comparison, manifest = null) {
  const expected = new Set(CRITICAL_OWNED_FIELDS);
  if (manifest?.packages) for (const [index] of manifest.packages.entries()) expected.add(`packages[${index}].projectFileLink`);
  const fields = comparison.fields;
  const missing = [...expected]
    .filter((path) => !fields.some((field) => field.manifestJsonPath === path))
    .map((path) => `${path} is NOT_DISCOVERED.`);
  return [...missing, ...fields
    .filter((field) => CRITICAL_OWNED_FIELDS.has(field.manifestJsonPath) || /^packages\[\d+\]\.projectFileLink$/.test(field.manifestJsonPath))
    .filter((field) => ['NOT_VISIBLE', 'NOT_DISCOVERED'].includes(field.classification) || (field.classification === 'MISMATCH' && !field.writeTarget))
    .map((field) => `${field.manifestJsonPath} is ${field.classification}${field.classification === 'MISMATCH' ? ' and has no approved writable locator' : ''}.`)];
}

function manifestWriteBlockers(manifest) {
  const blockers = [];
  if (manifest?.portalReady !== true) blockers.push('Submission manifest portalReady is false.');
  for (const [index, pkg] of (manifest?.packages ?? []).entries()) {
    if (pkg.projectFileLink === null) blockers.push(`packages[${index}].projectFileLink is unresolved.`);
  }
  return blockers;
}

function writeReadiness(listingStatus, comparison, manifest) {
  const blockers = manifestWriteBlockers(manifest);
  if (REVIEW_LOCKED.has(normalized(listingStatus).toLowerCase())) blockers.push(`Listing status ${listingStatus} is review-locked.`);
  blockers.push(...criticalBlockers(comparison, manifest));
  return { writeReady: blockers.length === 0, writeBlockers: [...new Set(blockers)] };
}

async function assertView(page, view, manifest) {
  if (view === 'format') {
    if (!await isVisibleUnique(page.getByRole('heading', { name: 'Project Versions*', exact: true }))) throw new Error('Format mutation attempted while the listing view was active.');
    return;
  }
  if (!await isVisibleUnique(page.getByRole('button', { name: manifest.includedFormat, exact: true }))) throw new Error('Listing mutation attempted while the format view was active.');
}

async function preflightMutationViews(page, plan, manifestInfo, origin, guard, diagnostics) {
  const groups = ['listing', 'format']
    .map((view) => ({ view, plan: plan.filter((item) => (item.view ?? 'listing') === view) }))
    .filter((group) => group.plan.length > 0);
  const failures = [];
  const prepared = [];
  for (const group of groups) {
    await (group.view === 'format'
      ? ensureFormatView(page, manifestInfo.manifest, origin, guard, { diagnostics })
      : ensureListingView(page, manifestInfo.manifest, origin, guard, { diagnostics }));
    const preflight = await preflightMutationPlan(page, group.plan, manifestInfo.manifest);
    failures.push(...preflight.failures);
    prepared.push({ ...group, preflight });
  }
  return { ok: failures.length === 0, failures, groups: prepared };
}

function assertCompleteComparison(comparison, manifest) {
  const blockers = criticalBlockers(comparison, manifest);
  if (comparison.mismatchCount > 0 || blockers.length > 0) {
    throw new Error(`Staged portal values did not satisfy the manifest: ${[...blockers, `${comparison.mismatchCount} mismatch(es)`].join(' ')}`);
  }
}

async function tryReadStatus(page) {
  try { return await readStatus(page); } catch { return null; }
}

async function visibleDialogRecords(page) {
  const dialogs = page.getByRole('dialog');
  const records = [];
  for (let index = 0; index < await dialogs.count(); index += 1) {
    const locator = dialogs.nth(index);
    if (!await locator.isVisible().catch(() => false)) continue;
    const signature = await locator.evaluate((element) => JSON.stringify({
      id: element.id || null,
      ariaLabel: element.getAttribute('aria-label'),
      ariaLabelledBy: element.getAttribute('aria-labelledby'),
      testId: element.getAttribute('data-testid'),
      text: (element.textContent || '').replace(/\s+/g, ' ').trim(),
    }));
    records.push({ locator, signature });
  }
  return records;
}

async function waitForSubmitOutcomeSignal(page, beforeDialogs) {
  const knownDialogSignatures = new Set(beforeDialogs.map((dialog) => dialog.signature));
  const deadline = Date.now() + SUBMIT_OUTCOME_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await detectManualBlock(page);
    const status = await tryReadStatus(page);
    if (SUBMIT_ACCEPTED_STATUSES.has(normalized(status).toLowerCase())) return { kind: 'status', status };
    const newlyVisibleDialogs = (await visibleDialogRecords(page)).filter((dialog) => !knownDialogSignatures.has(dialog.signature));
    if (newlyVisibleDialogs.length > 0) return { kind: 'dialog', dialogs: newlyVisibleDialogs };
    await page.waitForTimeout(50);
  }
  return null;
}

async function waitForAcceptedStatus(page) {
  const deadline = Date.now() + SUBMIT_OUTCOME_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await detectManualBlock(page);
    const status = await tryReadStatus(page);
    if (SUBMIT_ACCEPTED_STATUSES.has(normalized(status).toLowerCase())) return status;
    await page.waitForTimeout(50);
  }
  return null;
}

async function recordPostSubmitStatus(page, result) {
  result.postSubmitStatus = await readStatus(page).catch(() => null);
  result.submitAccepted = SUBMIT_ACCEPTED_STATUSES.has(normalized(result.postSubmitStatus).toLowerCase());
  if (!result.submitAccepted) {
    throw new Error(`Fab did not reach an accepted post-submit status. Received ${result.postSubmitStatus ?? 'unknown'}.`);
  }
}

async function executeSubmitFlow(page, guard, result) {
  guard.setPhase('submit');
  try {
    const beforeDialogs = await visibleDialogRecords(page);
    const submit = await uniqueAction(page, submitCandidates(), 'Submit for review');
    await detectManualBlock(page);
    await submit.locator.click();
    result.writeInteractionsPerformed += 1;
    const signal = await waitForSubmitOutcomeSignal(page, beforeDialogs);
    if (signal?.kind === 'dialog') {
      if (signal.dialogs.length !== 1) {
        result.postSubmitStatus = await readStatus(page).catch(() => null);
        throw new Error(`Submit confirmation requires exactly one newly visible dialog; found ${signal.dialogs.length}.`);
      }
      const dialog = signal.dialogs[0].locator;
      const confirmation = dialog.getByRole('button', { name: /^(?:Confirm|Submit for review|Submit for Review)$/ });
      const confirmationCount = await confirmation.count();
      if (confirmationCount !== 1) {
        result.postSubmitStatus = await readStatus(page).catch(() => null);
        throw new Error(`Submit confirmation requires exactly one approved confirmation action; found ${confirmationCount}.`);
      }
      await detectManualBlock(page);
      await confirmation.click();
      result.submitInvoked = true;
      result.writeInteractionsPerformed += 1;
      await waitForAcceptedStatus(page);
      await recordPostSubmitStatus(page, result);
      return;
    }
    if (signal?.kind !== 'status') {
      result.submitInvoked = true;
      result.postSubmitStatus = await readStatus(page).catch(() => null);
      throw new Error('Submit for review produced neither a valid confirmation dialog nor an accepted status transition.');
    }
    result.submitInvoked = true;
    await recordPostSubmitStatus(page, result);
  } finally {
    guard.setPhase('stage');
  }
}

export async function runPortalAutomation({ manifestInfo, cdpEndpoint, mode = 'verify', saveDraftAuthorized = false, outputDirectory = null, origin = 'https://www.fab.com', page: injectedPage = null, context: injectedContext = null, manualInteraction = null, maxManualChallengeCycles = DEFAULT_MANUAL_CHALLENGE_MAX_CYCLES }) {
  if (mode === 'save' && !saveDraftAuthorized) throw new Error('Save Draft requires explicit Save Draft authorization.');
  if (mode === 'submit' && !saveDraftAuthorized) throw new Error('Submit for review requires explicit Save Draft authorization.');
  let browser = null;
  let context = injectedContext;
  let page = injectedPage;
  const passiveAttach = mode === 'verify';
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
  const guard = installNetworkGuard(context, { mode });
  const result = {
    schemaVersion: 1,
    mode,
    listingId: manifestInfo.manifest.listingId,
    listingTitle: manifestInfo.manifest.title,
    listingStatus: null,
    manifestSha256: manifestInfo.manifestSha256,
    portalReady: manifestInfo.manifest.portalReady,
    comparison: null,
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
    passiveAttach,
  };
  const navigationDiagnostics = createNavigationDiagnostics(context, result);
  Object.defineProperty(result, 'navigationDiagnostics', { value: navigationDiagnostics, enumerable: false, configurable: true });
  Object.defineProperty(result, 'page', { value: page, enumerable: false, configurable: true });
  Object.defineProperty(result, 'browser', { value: browser, enumerable: false, configurable: true });
  try {
    const manifestBlockers = manifestWriteBlockers(manifestInfo.manifest);
    if (mode !== 'verify' && manifestBlockers.length > 0) {
      result.writeBlockers = manifestBlockers;
      throw new Error(`Write blocked by manifest readiness gates: ${manifestBlockers.join(' ')}`);
    }
    const initialTarget = await withManualChallengeHandoff({
      context,
      page,
      manifest: manifestInfo.manifest,
      origin,
      result,
      manualInteraction: interaction,
      maxCycles: maxManualChallengeCycles,
      diagnostics: result,
      action: (candidatePage) => ensureTarget(candidatePage, manifestInfo.manifest, origin, { passive: true, diagnostics: result, initial: true }),
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
      action: (candidatePage) => collectPortalComparison(candidatePage, manifestInfo, { guard, origin, passive: passiveAttach, diagnostics: result }),
    });
    page = collectedResult.page;
    const collected = collectedResult.value;
    result.readOnlyUiActions.push(...collected.readOnlyUiActions);
    result.comparison = collected.comparison;
    ({ writeReady: result.writeReady, writeBlockers: result.writeBlockers } = writeReadiness(result.listingStatus, result.comparison, manifestInfo.manifest));
    if (mode === 'verify') {
      if (result.comparison.mismatchCount > 0) result.blockers.push(`${result.comparison.mismatchCount} manifest mismatch(es).`);
      result.result = result.blockers.length === 0 ? 'PASS' : 'FAIL';
      return result;
    }
    if (result.writeBlockers.length > 0) throw new Error(`Write blocked by readiness gates: ${result.writeBlockers.join(' ')}`);
    const mutation = buildMutationPlan(result.comparison, manifestInfo);
    result.plannedMutations = mutation.plan;
    result.blockers.push(...mutation.blockers);
    if (result.blockers.length > 0) throw new Error(result.blockers.join(' '));
    if (mutation.plan.length === 0) {
      result.comparisonAfter = result.comparison;
    } else {
      const mutationRun = await withManualChallengeHandoff({
        context,
        page,
        manifest: manifestInfo.manifest,
        origin,
        result,
        manualInteraction: interaction,
        maxCycles: maxManualChallengeCycles,
        diagnostics: result,
        action: async (candidatePage) => {
          const preflight = await preflightMutationViews(candidatePage, mutation.plan, manifestInfo, origin, guard, result);
          if (!preflight.ok) throw new Error(`Mutation preflight failed: ${preflight.failures.join(' ')}`);
          result.executedMutations = [];
          for (const group of preflight.groups) {
            await (group.view === 'format'
              ? ensureFormatView(candidatePage, manifestInfo.manifest, origin, guard, { diagnostics: result })
              : ensureListingView(candidatePage, manifestInfo.manifest, origin, guard, { diagnostics: result }));
            await executeMutationPlan(candidatePage, group.preflight, manifestInfo, {
              setPhase: (phase) => guard.setPhase(phase),
              assertView: (view) => assertView(candidatePage, view, manifestInfo.manifest),
              beforeMutation: () => detectManualBlock(candidatePage),
              onMutationExecuted: (item) => {
                result.executedMutations.push(item.fieldName);
                result.writeInteractionsPerformed += 1;
              },
            });
          }
          return preflight;
        },
      });
      page = mutationRun.page;
      guard.setPhase('stage');
      const stagedRun = await withManualChallengeHandoff({
        context,
        page,
        manifest: manifestInfo.manifest,
        origin,
        result,
        manualInteraction: interaction,
        maxCycles: maxManualChallengeCycles,
        diagnostics: result,
        action: (candidatePage) => collectPortalComparison(candidatePage, manifestInfo, { guard, origin, diagnostics: result }),
      });
      page = stagedRun.page;
      const staged = stagedRun.value;
      result.readOnlyUiActions.push(...staged.readOnlyUiActions);
      result.comparisonAfter = staged.comparison;
      assertCompleteComparison(result.comparisonAfter, manifestInfo.manifest);
      ({ writeReady: result.writeReady, writeBlockers: result.writeBlockers } = writeReadiness(result.listingStatus, result.comparisonAfter, manifestInfo.manifest));
      await ensureListingView(page, manifestInfo.manifest, origin, guard, { diagnostics: result });
      await detectManualBlock(page);
      guard.setPhase('save');
      const save = await uniqueAction(page, saveCandidates(), 'Save Draft');
      await detectManualBlock(page);
      await save.locator.click();
      result.saveInvoked = true;
      result.writeInteractionsPerformed += 1;
      await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => undefined);
      guard.setPhase('stage');
      await detectManualBlock(page);
      await reloadWithDiagnostics(page, { waitUntil: 'domcontentloaded' }, result);
      const postSaveTarget = await withManualChallengeHandoff({
        context,
        page,
        manifest: manifestInfo.manifest,
        origin,
        result,
        manualInteraction: interaction,
        maxCycles: maxManualChallengeCycles,
        diagnostics: result,
        action: (candidatePage) => ensureTarget(candidatePage, manifestInfo.manifest, origin, { diagnostics: result }),
      });
      page = postSaveTarget.page;
      result.listingStatus = await readStatus(page);
      const postSaveRun = await withManualChallengeHandoff({
        context,
        page,
        manifest: manifestInfo.manifest,
        origin,
        result,
        manualInteraction: interaction,
        maxCycles: maxManualChallengeCycles,
        diagnostics: result,
        action: (candidatePage) => collectPortalComparison(candidatePage, manifestInfo, { guard, origin, diagnostics: result }),
      });
      page = postSaveRun.page;
      const postSave = postSaveRun.value;
      result.readOnlyUiActions.push(...postSave.readOnlyUiActions);
      result.comparisonAfter = postSave.comparison;
      assertCompleteComparison(result.comparisonAfter, manifestInfo.manifest);
      ({ writeReady: result.writeReady, writeBlockers: result.writeBlockers } = writeReadiness(result.listingStatus, result.comparisonAfter, manifestInfo.manifest));
    }
    if (mode === 'submit') {
      if (!result.saveInvoked && result.plannedMutations.length > 0) throw new Error('Submit for review requires a completed Save Draft operation.');
      if (result.comparisonAfter.mismatchCount > 0 || criticalBlockers(result.comparisonAfter, manifestInfo.manifest).length > 0) throw new Error('Submit for review blocked by post-save comparison.');
      const submitRun = await withManualChallengeHandoff({
        context,
        page,
        manifest: manifestInfo.manifest,
        origin,
        result,
        manualInteraction: interaction,
        maxCycles: maxManualChallengeCycles,
        diagnostics: result,
        action: async (candidatePage) => {
          await ensureListingView(candidatePage, manifestInfo.manifest, origin, guard, { diagnostics: result });
          await detectManualBlock(candidatePage);
          await executeSubmitFlow(candidatePage, guard, result);
        },
      });
      page = submitRun.page;
    }
    result.result = 'PASS';
    return result;
  } catch (error) {
    let reportedError = error;
    if (isManualChallengeError(error)) {
      result.manualChallengeDetected = true;
      if (result.writeInteractionsPerformed > 0) reportedError = manualChallengeRestartError(result);
    }
    result.blockers.push(reportedError instanceof Error ? reportedError.message : String(reportedError));
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

export { CRITICAL_OWNED_FIELDS, criticalBlockers, detectManualBlock, prepareReadOnlySections, readStatus, requireExactTitle, writeReadiness };
