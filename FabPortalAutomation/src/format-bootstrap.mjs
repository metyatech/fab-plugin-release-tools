import { acquireResponsiveViewportLease } from './responsive-viewport.mjs';

const SUPPORTED_FORMATS = new Set(['Unreal Engine']);
const FORMAT_CHOOSER_TIMEOUT_MS = 30000;
const FORMAT_CHOOSER_POLL_MS = 100;
const FORMAT_FIELD_OPTION_TIMEOUT_MS = 10000;
const PORTAL_PLATFORM_LABELS = Object.freeze({ Win64: 'Windows' });

function portalPlatformLabel(value) {
  const label = PORTAL_PLATFORM_LABELS[value];
  if (!label) throw new Error(`No observed Fab platform label is available for canonical platform ${value}.`);
  return label;
}

function visibleCount(locator) {
  return (async () => {
    const visible = [];
    for (let index = 0; index < await locator.count(); index += 1) {
      if (await locator.nth(index).isVisible().catch(() => false)) visible.push(locator.nth(index));
    }
    return visible;
  })();
}

function exactButton(page, name) {
  return page.getByRole('button', { name, exact: true });
}

function includedFilesRegion(page) {
  return page.getByRole('region', { name: 'Included Files', exact: true });
}

async function formatNavigationMounted(page, manifest, formatCount) {
  const region = includedFilesRegion(page);
  if (await region.count() === 1 && await region.isVisible().catch(() => false)) return true;
  const control = formatCount === 0
    ? exactButton(page, 'Add new format')
    : exactButton(page, manifest.includedFormat);
  return (await visibleCount(control)).length > 0;
}

async function productFormatButtons(page) {
  const buttons = includedFilesRegion(page).getByRole('button', { name: /.+/, exact: true });
  const formats = [];
  for (let index = 0; index < await buttons.count(); index += 1) {
    const button = buttons.nth(index);
    if (!await button.isVisible().catch(() => false)) continue;
    const name = (await button.innerText().catch(() => '')).trim();
    if (name !== 'Add new format') formats.push(button);
  }
  return formats;
}

function formatChoice(page) {
  const root = page.locator('[role="dialog"]:visible').first();
  return {
    heading: root.getByRole('heading', { name: /(?:Choose a format|Add new format)/i }),
    options: root.getByRole('option', { name: 'Unreal Engine', exact: true }),
    buttons: root.getByRole('button', { name: 'Unreal Engine', exact: true }),
  };
}

async function advanceFormatChooser(page, formatName) {
  const chooser = formatChoice(page);
  const dialog = chooser.heading.locator('xpath=ancestor::*[@role="dialog"]');
  const candidates = dialog.getByRole('button');
  const nextMatches = [];
  for (let index = 0; index < await candidates.count(); index += 1) {
    const candidate = candidates.nth(index);
    if (!await candidate.isVisible().catch(() => false)) continue;
    const text = (await candidate.innerText().catch(() => '')).trim();
    const ariaLabel = (await candidate.getAttribute('aria-label')) ?? '';
    if (text === 'Next' || /^Confirm selected option:\s*/i.test(ariaLabel)) nextMatches.push(candidate);
  }
  const next = nextMatches;
  if (next.length === 0) return false;
  if (next.length !== 1) throw new Error(`Format chooser Next control visible match count is ${next.length}.`);
  if (await next[0].isDisabled().catch(() => true)) throw new Error('Format chooser Next control was disabled after selecting Unreal Engine.');
  await next[0].click();
  return true;
}

async function confirmFormatCreation(page) {
  const confirm = await visibleCount(page.getByRole('button', { name: 'Confirm', exact: true }));
  if (confirm.length === 0) return false;
  if (confirm.length !== 1) throw new Error(`Format creation Confirm control visible match count is ${confirm.length}.`);
  if (await confirm[0].isDisabled().catch(() => true)) throw new Error('Format creation Confirm control was disabled after the format choice was confirmed.');
  await confirm[0].click();
  return true;
}

async function visibleLabeledControl(page, labels, field, placeholders = []) {
  const matches = [];
  for (const label of labels) {
    const locator = page.getByLabel(label, { exact: true });
    for (let index = 0; index < await locator.count(); index += 1) {
      if (await locator.nth(index).isVisible().catch(() => false)) matches.push(locator.nth(index));
    }
    if (matches.length > 0) break;
  }
  if (matches.length === 0) {
    for (const placeholder of placeholders) {
      const locator = page.getByPlaceholder(placeholder, { exact: true });
      for (let index = 0; index < await locator.count(); index += 1) {
        if (await locator.nth(index).isVisible().catch(() => false)) matches.push(locator.nth(index));
      }
      if (matches.length > 0) break;
    }
  }
  if (matches.length !== 1) throw new Error(`${field} control visible match count was ${matches.length}.`);
  return matches[0];
}

async function fillTextControl(page, labels, field, value, placeholders = []) {
  const control = await visibleLabeledControl(page, labels, field, placeholders);
  const metadata = await control.evaluate((element) => ({ tagName: element.tagName, readOnly: element.readOnly === true, disabled: element.disabled === true, role: element.getAttribute('role') }));
  if (metadata.disabled || metadata.readOnly || !['INPUT', 'TEXTAREA'].includes(metadata.tagName)) throw new Error(`${field} control was not an enabled writable text control.`);
  await control.fill(value);
}

async function chooseExactOption(page, labels, field, value, placeholders = []) {
  const control = await visibleLabeledControl(page, labels, field, placeholders);
  const metadata = await control.evaluate((element) => ({ tagName: element.tagName, disabled: element.disabled === true, role: element.getAttribute('role') }));
  if (metadata.disabled) throw new Error(`${field} control was disabled.`);
  if (metadata.tagName === 'SELECT') {
    const options = await control.locator('option').evaluateAll((items) => items.map((item) => ({ label: item.textContent?.trim() ?? '', disabled: item.disabled })));
    const matches = options.filter((option) => option.label === value);
    if (matches.length !== 1 || matches[0].disabled) throw new Error(`${field} did not expose exactly one enabled option for ${value}.`);
    await control.selectOption({ label: value });
    return;
  }
  if (metadata.role !== 'combobox' && metadata.tagName !== 'INPUT') throw new Error(`${field} control shape was not a supported combobox.`);
  await control.click();
  const option = page.getByRole('option', { name: value, exact: true });
  const labeled = page.getByLabel(value, { exact: true });
  const deadline = Date.now() + FORMAT_FIELD_OPTION_TIMEOUT_MS;
  while (Date.now() <= deadline) {
    const visible = [];
    for (let index = 0; index < await option.count(); index += 1) {
      if (await option.nth(index).isVisible().catch(() => false)) visible.push(option.nth(index));
    }
    if (visible.length > 1) throw new Error(`${field} did not expose exactly one enabled option for ${value}.`);
    if (visible.length === 1) {
      if (await visible[0].isDisabled().catch(() => true)) throw new Error(`${field} did not expose exactly one enabled option for ${value}.`);
      const inputValue = await control.inputValue().catch(() => '');
      const alreadySelected = inputValue === value || await visible[0].getAttribute('aria-selected') === 'true';
      if (alreadySelected) {
        await waitForSelectionEvidence(page, control, field, value);
        return;
      }
      await visible[0].click();
      await waitForSelectionEvidence(page, control, field, value);
      return;
    }
    const labeledVisible = [];
    for (let index = 0; index < await labeled.count(); index += 1) {
      if (await labeled.nth(index).isVisible().catch(() => false)) labeledVisible.push(labeled.nth(index));
    }
    if (labeledVisible.length > 1) throw new Error(`${field} did not expose exactly one enabled labeled control for ${value}.`);
    if (labeledVisible.length === 1) {
      if (await labeledVisible[0].isDisabled().catch(() => true)) throw new Error(`${field} did not expose exactly one enabled labeled control for ${value}.`);
      await labeledVisible[0].click();
      await waitForSelectionEvidence(page, control, field, value);
      return;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`${field} did not expose exactly one enabled option for ${value} within ${FORMAT_FIELD_OPTION_TIMEOUT_MS}ms.`);
}

async function waitForSelectionEvidence(page, control, field, value) {
  const deadline = Date.now() + FORMAT_FIELD_OPTION_TIMEOUT_MS;
  while (Date.now() <= deadline) {
    const inputValue = await control.inputValue().catch(() => '');
    if (inputValue === value) return;
    const removal = await visibleCount(exactButton(page, `Remove ${value}`));
    if (removal.length === 1) return;
    const selected = page.getByRole('option', { name: value, exact: true });
    for (let index = 0; index < await selected.count(); index += 1) {
      if (await selected.nth(index).isVisible().catch(() => false) && await selected.nth(index).getAttribute('aria-selected') === 'true') return;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`${field} did not expose selected-state evidence for ${value} within ${FORMAT_FIELD_OPTION_TIMEOUT_MS}ms.`);
}

async function fillUnrealVersionForm(page, manifest) {
  const version = String(manifest.engineVersions?.[0] ?? '');
  const packageInfo = manifest.packages?.find((item) => String(item?.engineVersion) === version);
  if (!version || !packageInfo) throw new Error('Canonical first Unreal Engine package was not available for format bootstrap.');
  if (typeof packageInfo.versionTitle !== 'string' || packageInfo.versionTitle.trim() === '') throw new Error(`Canonical Version title is missing for UE${version}.`);
  if (typeof packageInfo.projectFileLink !== 'string' || packageInfo.projectFileLink.trim() === '') throw new Error(`Canonical Project File Link is missing for UE${version}.`);
  if (!Array.isArray(manifest.platforms) || manifest.platforms.length !== 1 || typeof manifest.platforms[0] !== 'string' || manifest.platforms[0].trim() === '') throw new Error('Canonical supported target platforms were not an exact single-value configuration.');
  await fillTextControl(page, ['Version title *', 'Version title'], 'Version title', packageInfo.versionTitle, ['Enter version title']);
  await fillTextControl(page, ['Project file link *', 'Project file link'], 'Project file link', packageInfo.projectFileLink, ['www.filesharing.com/link/to/project']);
  await chooseExactOption(page, ['Supported engine version *', 'Supported engine version', 'Support Unreal Engine versions multi select field with search'], 'Supported engine version', version, ['Search or select engine versions']);
  const portalPlatform = portalPlatformLabel(manifest.platforms[0]);
  await chooseExactOption(page, ['Supported target platforms *', 'Supported target platforms', 'Support target platforms multi select field with search'], 'Supported target platforms', portalPlatform, ['Search or select target platforms']);
  return { engineVersion: version, versionTitle: packageInfo.versionTitle, projectFileLink: packageInfo.projectFileLink, platform: manifest.platforms[0], portalPlatform };
}

async function formatChooserActionEvidence(page) {
  return page.evaluate(() => {
    const visible = (element) => Boolean(element?.getClientRects?.().length);
    const text = (element) => (element?.innerText ?? '').trim();
    const dialog = Array.from(document.querySelectorAll('[role="dialog"]')).find(visible);
    const root = dialog ?? document;
    return Array.from(root.querySelectorAll('button,[role="button"]'))
      .filter(visible)
      .filter((element) => dialog || /^(?:next|create|add|confirm|continue|unreal engine|unity|additional files)$/i.test(text(element)) || /^(?:next|create|add|confirm|continue|unreal engine|unity|additional files)$/i.test(element.getAttribute('aria-label') ?? ''))
      .map((element) => ({
        text: text(element),
        ariaLabel: element.getAttribute('aria-label'),
        role: element.getAttribute('role') ?? 'button',
        disabled: Boolean(element.disabled) || element.getAttribute('aria-disabled') === 'true',
      }));
  });
}

async function readChooserState(page) {
  const choice = formatChoice(page);
  const options = await visibleCount(choice.options);
  const buttons = await visibleCount(choice.buttons);
  const state = await page.evaluate(() => {
    const visible = (element) => Boolean(element?.getClientRects?.().length);
    const text = (element) => (element?.innerText ?? '').trim();
    const skeletons = Array.from(document.querySelectorAll('[aria-busy="true"], [class*="skeleton" i], [class*="animate-pulse" i]'))
      .filter(visible);
    const errors = Array.from(document.querySelectorAll('[role="alert"], [aria-live="assertive"], [data-state="error"]'))
      .filter(visible)
      .map(text)
      .filter(Boolean);
    const next = Array.from(document.querySelectorAll('button'))
      .filter(visible)
      .find((element) => /^Next$/i.test(text(element)));
    return {
      headingCount: Array.from(document.querySelectorAll('h1,h2,h3,[role="heading"]'))
        .filter(visible)
        .filter((element) => /^(?:Choose a format|Add new format)$/i.test(text(element))).length,
      skeletonCount: skeletons.length,
      nextEnabled: next ? !next.disabled : null,
      errors: errors.slice(0, 5),
    };
  });
  return {
    ...state,
    optionCount: buttons.length > 0 ? buttons.length : options.length,
    options,
    buttons,
  };
}

export async function waitForFormatChooserReady(page, { timeoutMs = FORMAT_CHOOSER_TIMEOUT_MS, pollMs = FORMAT_CHOOSER_POLL_MS } = {}) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() <= deadline) {
    last = await readChooserState(page);
    if (last.errors.length > 0) return { ready: false, reason: 'error', ...last };
    if (last.headingCount === 1 && last.skeletonCount === 0 && last.optionCount > 1) {
      return { ready: false, reason: 'ambiguous', ...last };
    }
    if (last.headingCount === 1 && last.skeletonCount === 0 && last.optionCount === 1) {
      return { ready: true, ...last, choice: last.buttons[0] ?? last.options[0] };
    }
    await page.waitForTimeout(pollMs);
  }
  return { ready: false, reason: 'timeout', ...(last ?? await readChooserState(page)) };
}

const PREFETCHED_DATA_SELECTOR = '#js-json-data-prefetched-data';

export async function readPrefetchedFormatInventory(page, listingId) {
  return page.evaluate(({ selector, expectedListingId }) => {
    const source = document.querySelector(selector);
    if (!source) return { status: 'unknown', source: 'prefetched-listing-data', reason: 'Prefetched listing data script was not found.' };
    let data;
    try {
      data = JSON.parse(source.textContent ?? '');
    } catch {
      return { status: 'unknown', source: 'prefetched-listing-data', reason: 'Prefetched listing data was not valid JSON.' };
    }
    const key = `/i/portal/listings/${expectedListingId}`;
    const listing = data && typeof data === 'object' && !Array.isArray(data) ? data[key] : undefined;
    if (!listing || typeof listing !== 'object' || Array.isArray(listing)) {
      return { status: 'unknown', source: 'prefetched-listing-data', reason: 'The exact listing UUID was not present in prefetched data.' };
    }
    if (listing.uid !== expectedListingId) {
      return { status: 'unknown', source: 'prefetched-listing-data', reason: 'Prefetched listing UUID did not exactly match the target UUID.' };
    }
    if (!Array.isArray(listing.assetFormats)) {
      return { status: 'unknown', source: 'prefetched-listing-data', reason: 'Prefetched assetFormats was not a JSON array.' };
    }
    const identities = listing.assetFormats.map((format, index) => {
      const type = format && typeof format === 'object' && !Array.isArray(format) ? format.assetFormatType : null;
      if (!type || typeof type !== 'object' || Array.isArray(type) || typeof type.code !== 'string' || typeof type.name !== 'string' || !type.code.trim() || !type.name.trim()) {
        return { status: 'unknown', index };
      }
      return { status: 'known', index, code: type.code, name: type.name };
    });
    return {
      status: 'known',
      source: 'prefetched-listing-data',
      listingId: expectedListingId,
      formatCount: listing.assetFormats.length,
      identities,
      identityStatus: identities.every((item) => item.status === 'known') ? 'known' : 'unknown',
    };
  }, { selector: PREFETCHED_DATA_SELECTOR, expectedListingId: listingId });
}

export function supportedBootstrapFormat(value) {
  return SUPPORTED_FORMATS.has(String(value ?? ''));
}

export async function inspectFormatBootstrap(page, manifest, { guard = null, openChooser = true, closeChooser = false, viewportLease = null, holdViewportLease = false, portalViewport = null } = {}) {
  const result = {
    required: false,
    available: false,
    formatCount: null,
    matchingFormatCount: 0,
    addControlCount: 0,
    choiceCount: 0,
    resumedVersionForm: false,
    inventorySource: null,
    inventoryStatus: 'unknown',
    inventoryReason: null,
    blockers: [],
    choice: null,
  };
  if (!supportedBootstrapFormat(manifest.includedFormat)) {
    result.blockers.push(`Unsupported format bootstrap value: ${manifest.includedFormat}.`);
    return result;
  }

  const prefetched = await readPrefetchedFormatInventory(page, manifest.listingId);
  result.inventorySource = prefetched.source ?? null;
  result.inventoryStatus = prefetched.status;
  result.inventoryReason = prefetched.reason ?? null;
  if (prefetched.status !== 'known') {
    result.blockers.push(`Prefetched listing format inventory is unknown: ${prefetched.reason}`);
    return result;
  }
  result.formatCount = prefetched.formatCount;
  const viewportEvidence = portalViewport ?? {};
  const lease = viewportLease ?? await acquireResponsiveViewportLease(page, {
    diagnostics: viewportEvidence,
    isMounted: () => formatNavigationMounted(page, manifest, prefetched.formatCount),
  });
  Object.defineProperty(result, 'viewportLease', { value: lease, enumerable: false, configurable: true });
  try {
    const region = includedFilesRegion(page);
    const regionVisible = await region.count() === 1 && await region.isVisible().catch(() => false);
    const formats = regionVisible ? await productFormatButtons(page) : [];
    if (regionVisible && formats.length !== prefetched.formatCount) {
      result.blockers.push(`DOM and prefetched format inventory disagree (${formats.length} vs ${prefetched.formatCount}).`);
      return result;
    }
    if (prefetched.identityStatus !== 'known') {
      result.blockers.push('At least one prefetched product format identity was not strictly readable.');
      return result;
    }
    let matching;
    if (prefetched.formatCount === 0) {
      matching = [];
    } else if (regionVisible) {
      matching = [];
      for (const format of formats) {
        if ((await format.innerText().catch(() => '')).trim() === manifest.includedFormat) matching.push(format);
      }
    } else {
      matching = await visibleCount(exactButton(page, manifest.includedFormat));
    }
    result.matchingFormatCount = matching.length;
    if (regionVisible) {
      const domNames = [];
      for (const format of formats) domNames.push((await format.innerText().catch(() => '')).trim());
      const prefetchedNames = prefetched.identities.map((item) => item.name);
      if (JSON.stringify(domNames) !== JSON.stringify(prefetchedNames)) {
        result.blockers.push('DOM and prefetched product format identities disagree.');
        return result;
      }
    }
    result.required = matching.length === 0;
    if (matching.length > 1) {
      result.blockers.push(`Multiple ${manifest.includedFormat} product formats are visible.`);
      return result;
    }
    if (!result.required) {
      if (result.formatCount !== 1) result.blockers.push(`Expected exactly one product format, found ${result.formatCount}.`);
      else result.available = true;
      return result;
    }
    if (result.formatCount !== 0) {
      result.blockers.push(`A non-${manifest.includedFormat} product format already exists; bootstrap is fail-closed.`);
      return result;
    }
    const add = await visibleCount(exactButton(page, 'Add new format'));
    result.addControlCount = add.length;
    if (add.length !== 1) {
      result.blockers.push(`Add new format control visible match count is ${add.length}.`);
      return result;
    }
    if (!openChooser) {
      result.blockers.push('Unreal Engine choice was not inspected.');
      return result;
    }
    const versionHeading = page.getByRole('heading', { name: /Add Unreal Engine version/i });
    if (await versionHeading.count() === 1 && await versionHeading.isVisible().catch(() => false)) {
      result.available = true;
      result.resumedVersionForm = true;
      return result;
    }
    const chooserHeading = page.getByRole('heading', { name: /(?:Choose a format|Add new format)/i });
    const chooserAlreadyOpen = await chooserHeading.count() === 1 && await chooserHeading.isVisible().catch(() => false);
    if (!chooserAlreadyOpen) {
      const before = guard?.summary().networkMutationRequestsObserved ?? 0;
      try {
        await add[0].click();
        await page.waitForTimeout(100);
      } catch (error) {
        result.blockers.push(`Add new format chooser could not be opened: ${error instanceof Error ? error.message : String(error)}`);
        return result;
      }
      const after = guard?.summary().networkMutationRequestsObserved ?? before;
      if (after > before) {
        result.blockers.push('Opening Add new format caused a network mutation; read-only bootstrap inspection was blocked.');
        return result;
      }
    }
    const chooser = await waitForFormatChooserReady(page);
    result.choiceCount = chooser.optionCount;
    if (!chooser.ready) {
      result.blockers.push(chooser.reason === 'error'
        ? `Format chooser reported an error: ${chooser.errors.join(' ')}`
        : chooser.reason === 'ambiguous'
          ? `Unreal Engine choice visible match count is ${chooser.optionCount}.`
          : `Format chooser was not ready before timeout (skeletons=${chooser.skeletonCount}, Unreal Engine choices=${chooser.optionCount}).`);
      return result;
    }
    result.choice = chooser.choice;
    result.available = true;
    return result;
  } catch (error) {
    if (holdViewportLease) await lease.release().catch(() => undefined);
    throw error;
  } finally {
    if (closeChooser) {
      const chooserHeading = page.getByRole('heading', { name: /(?:Choose a format|Add new format)/i });
      if (await chooserHeading.count() === 1 && await chooserHeading.isVisible().catch(() => false)) {
        await page.keyboard.press('Escape').catch(() => undefined);
      }
    }
    if (!holdViewportLease) await lease.release();
  }
}

export async function executeFormatBootstrap(page, manifest, inspection, { guard, onMutation = null } = {}) {
  if (!inspection.required || !inspection.available || (!inspection.choice && !inspection.resumedVersionForm)) throw new Error('Format bootstrap was not proven safe before execution.');
  guard.setPhase('format-create');
  try {
    await onMutation?.();
    if (!inspection.resumedVersionForm) {
      await inspection.choice.click();
      await page.waitForTimeout(150);
      await advanceFormatChooser(page, manifest.includedFormat);
      await page.waitForTimeout(150);
    }
    let versionEvidence = null;
    const versionHeading = page.getByRole('heading', { name: /Add Unreal Engine version/i });
    if (await versionHeading.count() === 1 && await versionHeading.isVisible().catch(() => false)) {
      versionEvidence = await fillUnrealVersionForm(page, manifest);
    }
    const confirmClicked = await confirmFormatCreation(page);
    if (confirmClicked) await page.waitForTimeout(150);
    const region = includedFilesRegion(page);
    const formats = await productFormatButtons(page);
    const matching = [];
    for (const format of formats) {
      if ((await format.innerText().catch(() => '')).trim() === manifest.includedFormat) matching.push(format);
    }
    if (await region.count() !== 1 || formats.length !== 1 || matching.length !== 1) {
      const actions = await formatChooserActionEvidence(page);
      const evidence = actions.length > 0 ? ` Visible chooser actions: ${JSON.stringify(actions)}.` : '';
      throw new Error(`Format bootstrap did not produce exactly one Unreal Engine product format.${evidence}`);
    }
    return { created: true, versionEvidence };
  } finally {
    guard.setPhase('stage');
  }
}

export const DEFERRED_FORMAT_FIELDS = Object.freeze([
  'includedFormat', 'engineVersions', 'platforms', 'documentationUrl', 'supportUrl', 'technicalInformationFile', 'media',
]);

export function isDeferredFormatField(path) {
  return DEFERRED_FORMAT_FIELDS.includes(path) || /^packages\[\d+\]\.projectFileLink$/.test(path);
}
