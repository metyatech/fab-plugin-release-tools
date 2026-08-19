import { chromium } from 'playwright-core';
import { compareManifest, summarizeComparison } from './comparison.mjs';
import { buildMutationPlan, executeMutationPlan, preflightMutationPlan } from './mutation-plan.mjs';
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
  if (headingCount === 1) return;
  const text = page.getByText(title, { exact: true });
  const textCount = await text.count();
  if (textCount !== 1) throw new Error(`Fab listing title is not uniquely visible as ${title}.`);
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
      throw new Error('MANUAL ACTION REQUIRED: Cloudflare or a browser security challenge is blocking Fab. Complete it manually and rerun.');
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

async function ensureTarget(page, manifest, origin) {
  const expected = listingEditUrl(manifest.listingId, origin);
  const formatView = page.getByRole('heading', { name: 'Project Versions*', exact: true });
  const formatViewVisible = await formatView.count() > 0 && await formatView.first().isVisible().catch(() => false);
  if (page.url() !== expected || formatViewVisible) await page.goto(expected, { waitUntil: 'domcontentloaded' });
  await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => undefined);
  await detectManualBlock(page);
  const parsed = new URL(page.url());
  const match = parsed.pathname.match(/^\/portal\/listings\/([^/]+)\/(?:edit)?$/);
  if (!match || match[1] !== manifest.listingId) throw new Error(`Fab listing URL UUID mismatch. Expected ${manifest.listingId}; received ${parsed.pathname}.`);
  await requireExactTitle(page, manifest.title);
  return { expectedUrl: expected, finalUrl: page.url() };
}

async function openFormatIfNeeded(page, manifest, guard) {
  const link = page.getByText(manifest.packages[0].projectFileLink, { exact: true });
  for (let index = 0; index < await link.count(); index += 1) {
    if (await link.nth(index).isVisible().catch(() => false)) return false;
  }
  const format = page.getByRole('button', { name: manifest.includedFormat, exact: true });
  if (await format.count() === 1) {
    await format.click();
    await page.waitForTimeout(100);
    if ((guard?.summary().networkMutationRequestsObserved ?? 0) > 0) throw new Error('Read-only format expansion caused a network mutation; discovery was aborted safely.');
    return true;
  }
  return false;
}

async function waitForFormatView(page, manifest) {
  const isFixture = (() => { try { return ['localhost', '127.0.0.1'].includes(new URL(page.url()).hostname); } catch { return false; } })();
  if (isFixture) return;
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const projectLink = page.getByText(manifest.packages[0].projectFileLink, { exact: true });
    const engineVersion = page.getByText(/^UE_[0-9]+(?:\.[0-9]+)+$/, { exact: false });
    const formatHeading = page.getByRole('heading', { name: 'Project Versions*', exact: true });
    const platformChip = page.getByRole('button', { name: /^Remove (?:Windows|Win64|Linux|Mac(?: OS)?|macOS)$/ });
    for (const locator of [projectLink, engineVersion, formatHeading, platformChip]) {
      if (await locator.count() === 0) continue;
      for (let index = 0; index < await locator.count(); index += 1) {
        if (await locator.nth(index).isVisible().catch(() => false)) return;
      }
    }
    await page.waitForTimeout(50);
  }
}

const FORMAT_COMPARISON_FIELDS = new Set(['engineVersions', 'platforms', 'technicalInformationFile', 'media']);

function mergeListingAndFormatComparisons(listingComparison, formatComparison, manifest) {
  const formatFields = new Map(formatComparison.fields.map((field) => [field.manifestJsonPath, field]));
  const fields = listingComparison.fields.map((field) => {
    if (FORMAT_COMPARISON_FIELDS.has(field.manifestJsonPath) && formatFields.has(field.manifestJsonPath)) return formatFields.get(field.manifestJsonPath);
    return field;
  });
  for (const [index] of manifest.packages.entries()) {
    const field = `packages[${index}].projectFileLink`;
    const replacement = formatFields.get(field);
    const position = fields.findIndex((item) => item.manifestJsonPath === field);
    if (replacement && position >= 0) fields[position] = replacement;
  }
  return summarizeComparison(fields);
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
    const before = guard.summary().networkMutationRequestsObserved;
    await locator.click();
    await page.waitForTimeout(100);
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

function writeReadiness(listingStatus, comparison, manifest) {
  const blockers = [];
  if (REVIEW_LOCKED.has(normalized(listingStatus).toLowerCase())) blockers.push(`Listing status ${listingStatus} is review-locked.`);
  blockers.push(...criticalBlockers(comparison, manifest));
  return { writeReady: blockers.length === 0, writeBlockers: [...new Set(blockers)] };
}

async function verifyAfterStaging(page, manifestInfo) {
  const after = await compareManifest(page, manifestInfo);
  const blockers = criticalBlockers(after, manifestInfo.manifest);
  if (after.mismatchCount > 0 || blockers.length > 0) throw new Error(`Staged portal values did not satisfy the manifest: ${[...blockers, `${after.mismatchCount} mismatch(es)`].join(' ')}`);
  return after;
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

export async function runPortalAutomation({ manifestInfo, cdpEndpoint, mode = 'verify', saveDraftAuthorized = false, outputDirectory = null, origin = 'https://www.fab.com', page: injectedPage = null, context: injectedContext = null }) {
  if (mode === 'save' && !saveDraftAuthorized) throw new Error('Save Draft requires explicit Save Draft authorization.');
  if (mode === 'submit' && !saveDraftAuthorized) throw new Error('Submit for review requires explicit Save Draft authorization.');
  let browser = null;
  let context = injectedContext;
  let page = injectedPage;
  if (!page) {
    if (!cdpEndpoint) throw new Error('A CDP endpoint is required for the production browser connection.');
    browser = await chromium.connectOverCDP(cdpEndpoint);
    context = browser.contexts()[0];
    if (!context) throw new Error('The CDP browser has no default context.');
    const fabPages = context.pages().filter((candidate) => { try { return new URL(candidate.url()).hostname === 'www.fab.com'; } catch { return false; } });
    page = fabPages[0] ?? await context.newPage();
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
  };
  Object.defineProperty(result, 'page', { value: page, enumerable: false, configurable: true });
  Object.defineProperty(result, 'browser', { value: browser, enumerable: false, configurable: true });
  try {
    await ensureTarget(page, manifestInfo.manifest, origin);
    result.listingStatus = await readStatus(page);
    result.dangerousActionsFound = await readDangerousActions(page);
    result.readOnlyUiActions.push(...await prepareReadOnlySections(page, guard));
    const listingComparison = await compareManifest(page, manifestInfo);
    const formatOpened = await openFormatIfNeeded(page, manifestInfo.manifest, guard);
    if (formatOpened) {
      result.readOnlyUiActions.push('opened Unreal Engine format section');
      await waitForFormatView(page, manifestInfo.manifest);
      result.readOnlyUiActions.push(...await prepareReadOnlySections(page, guard));
      const formatComparison = await compareManifest(page, manifestInfo);
      result.comparison = mergeListingAndFormatComparisons(listingComparison, formatComparison, manifestInfo.manifest);
    } else {
      result.comparison = listingComparison;
    }
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
      const preflight = await preflightMutationPlan(page, mutation.plan, manifestInfo.manifest);
      if (!preflight.ok) throw new Error(`Mutation preflight failed: ${preflight.failures.join(' ')}`);
      guard.setPhase('stage');
      result.executedMutations = await executeMutationPlan(page, preflight, manifestInfo, { setPhase: (phase) => guard.setPhase(phase) });
      result.writeInteractionsPerformed += result.executedMutations.length;
      guard.setPhase('stage');
      result.comparisonAfter = await verifyAfterStaging(page, manifestInfo);
      ({ writeReady: result.writeReady, writeBlockers: result.writeBlockers } = writeReadiness(result.listingStatus, result.comparisonAfter, manifestInfo.manifest));
      guard.setPhase('save');
      const save = await uniqueAction(page, saveCandidates(), 'Save Draft');
      await save.locator.click();
      result.saveInvoked = true;
      result.writeInteractionsPerformed += 1;
      await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => undefined);
      guard.setPhase('stage');
      await page.reload({ waitUntil: 'domcontentloaded' });
      await ensureTarget(page, manifestInfo.manifest, origin);
      result.listingStatus = await readStatus(page);
      result.comparisonAfter = await verifyAfterStaging(page, manifestInfo);
      ({ writeReady: result.writeReady, writeBlockers: result.writeBlockers } = writeReadiness(result.listingStatus, result.comparisonAfter, manifestInfo.manifest));
    }
    if (mode === 'submit') {
      if (!result.saveInvoked && result.plannedMutations.length > 0) throw new Error('Submit for review requires a completed Save Draft operation.');
      if (result.comparisonAfter.mismatchCount > 0 || criticalBlockers(result.comparisonAfter, manifestInfo.manifest).length > 0) throw new Error('Submit for review blocked by post-save comparison.');
      await executeSubmitFlow(page, guard, result);
    }
    result.result = 'PASS';
    return result;
  } catch (error) {
    result.blockers.push(error instanceof Error ? error.message : String(error));
    return result;
  } finally {
    result.network = guard.summary();
    await guard.dispose().catch(() => undefined);
    // The CLI disconnects after reports are written. This keeps screenshots and
    // post-run evidence available without using the browser as a write channel.
  }
}

export { CRITICAL_OWNED_FIELDS, criticalBlockers, detectManualBlock, prepareReadOnlySections, readStatus, requireExactTitle, writeReadiness };
