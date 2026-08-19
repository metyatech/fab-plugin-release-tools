import { chromium } from 'playwright-core';
import { compareManifest } from './comparison.mjs';
import { buildMutationPlan, executeMutationPlan, preflightMutationPlan } from './mutation-plan.mjs';
import { installNetworkGuard } from './network-guard.mjs';
import { dangerousActionCandidates, listingEditUrl, resolveCandidate, saveCandidates, submitCandidates } from './locators.mjs';

const REVIEW_LOCKED = new Set(['pending approval', 'pending publication', 'approved', 'live']);
const KNOWN_STATUSES = ['Pending approval', 'Pending Publication', 'Changes needed', 'Draft', 'Approved', 'Live'];

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
  return { locator, count };
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

async function detectManualBlock(page) {
  const body = normalized(await page.locator('body').textContent().catch(() => ''));
  if (/verify you are human|cloudflare|just a moment|attention required/i.test(body)) {
    throw new Error('MANUAL ACTION REQUIRED: Cloudflare or a browser security challenge is blocking Fab. Complete it manually and rerun.');
  }
  if (/sign in|log in|authenticate/i.test(body) && !/Server Manage Tool/.test(body)) {
    throw new Error('MANUAL ACTION REQUIRED: Fab authentication is required. Complete login/MFA manually and rerun.');
  }
}

async function ensureTarget(page, manifest, origin) {
  const expected = listingEditUrl(manifest.listingId, origin);
  if (page.url() !== expected) await page.goto(expected, { waitUntil: 'domcontentloaded' });
  await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => undefined);
  await detectManualBlock(page);
  const parsed = new URL(page.url());
  const match = parsed.pathname.match(/^\/portal\/listings\/([^/]+)\/(?:edit)?$/);
  if (!match || match[1] !== manifest.listingId) throw new Error(`Fab listing URL UUID mismatch. Expected ${manifest.listingId}; received ${parsed.pathname}.`);
  await requireExactTitle(page, manifest.title);
  return { expectedUrl: expected, finalUrl: page.url() };
}

async function openFormatIfNeeded(page, manifest) {
  const link = page.getByText(manifest.packages[0].projectFileLink, { exact: true });
  if (await link.count() === 1) return false;
  const format = page.getByRole('button', { name: manifest.includedFormat, exact: true });
  if (await format.count() === 1) {
    await format.click();
    await page.waitForTimeout(100);
    return true;
  }
  return false;
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
  const resolved = await resolveCandidate(page, candidates);
  if (!resolved.metadata?.unique) throw new Error(`${actionName} action is not uniquely available.`);
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

async function verifyAfterStaging(page, manifestInfo) {
  const after = await compareManifest(page, manifestInfo);
  const blockers = criticalBlockers(after, manifestInfo.manifest);
  if (after.mismatchCount > 0 || blockers.length > 0) throw new Error(`Staged portal values did not satisfy the manifest: ${[...blockers, `${after.mismatchCount} mismatch(es)`].join(' ')}`);
  return after;
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
    writeInteractionsPerformed: 0,
    dangerousActionsFound: [],
    blockers: [],
    result: 'FAIL',
    readOnlyUiActions: [],
  };
  Object.defineProperty(result, 'page', { value: page, enumerable: false, configurable: true });
  Object.defineProperty(result, 'browser', { value: browser, enumerable: false, configurable: true });
  try {
    await ensureTarget(page, manifestInfo.manifest, origin);
    result.listingStatus = await readStatus(page);
    result.dangerousActionsFound = await readDangerousActions(page);
    const formatOpened = await openFormatIfNeeded(page, manifestInfo.manifest);
    if (formatOpened) result.readOnlyUiActions.push('opened Unreal Engine format section');
    result.comparison = await compareManifest(page, manifestInfo);
    if (mode === 'verify') {
      if (result.comparison.mismatchCount > 0) result.blockers.push(`${result.comparison.mismatchCount} manifest mismatch(es).`);
      result.result = result.blockers.length === 0 ? 'PASS' : 'FAIL';
      return result;
    }
    if (REVIEW_LOCKED.has(result.listingStatus.toLowerCase())) throw new Error(`Listing status ${result.listingStatus} is review-locked; no write interaction is allowed.`);
    const unresolved = criticalBlockers(result.comparison, manifestInfo.manifest);
    if (unresolved.length > 0) throw new Error(`Write blocked by unresolved critical portal fields: ${unresolved.join(' ')}`);
    const mutation = buildMutationPlan(result.comparison, manifestInfo);
    result.plannedMutations = mutation.plan;
    result.blockers.push(...mutation.blockers);
    if (result.blockers.length > 0) throw new Error(result.blockers.join(' '));
    if (mutation.plan.length === 0) {
      result.comparisonAfter = result.comparison;
    } else {
      const preflight = await preflightMutationPlan(page, mutation.plan, manifestInfo.manifest);
      if (!preflight.ok) throw new Error(`Mutation preflight failed: ${preflight.failures.join(' ')}`);
      guard.setPhase(mutation.plan.some((item) => item.mutationType === 'upload') ? 'media-upload' : 'save');
      result.executedMutations = await executeMutationPlan(page, preflight, manifestInfo);
      result.writeInteractionsPerformed += result.executedMutations.length;
      guard.setPhase('stage');
      result.comparisonAfter = await verifyAfterStaging(page, manifestInfo);
      guard.setPhase('save');
      const save = await uniqueAction(page, saveCandidates(), 'Save Draft');
      await save.locator.click();
      result.saveInvoked = true;
      result.writeInteractionsPerformed += 1;
      await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => undefined);
      await page.reload({ waitUntil: 'domcontentloaded' });
      await ensureTarget(page, manifestInfo.manifest, origin);
      result.listingStatus = await readStatus(page);
      result.comparisonAfter = await verifyAfterStaging(page, manifestInfo);
    }
    if (mode === 'submit') {
      if (!result.saveInvoked && result.plannedMutations.length > 0) throw new Error('Submit for review requires a completed Save Draft operation.');
      if (result.comparisonAfter.mismatchCount > 0 || criticalBlockers(result.comparisonAfter, manifestInfo.manifest).length > 0) throw new Error('Submit for review blocked by post-save comparison.');
      guard.setPhase('submit');
      const submit = await uniqueAction(page, submitCandidates(), 'Submit for review');
      await submit.locator.click();
      result.submitInvoked = true;
      result.writeInteractionsPerformed += 1;
      const confirmation = page.getByRole('button', { name: /^(Submit for review|Submit for Review|Confirm)$/ });
      if (await confirmation.count() === 1) {
        await confirmation.click();
        result.writeInteractionsPerformed += 1;
      }
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

export { CRITICAL_OWNED_FIELDS, criticalBlockers, readStatus, requireExactTitle };
