import { acquireResponsiveViewportLease } from './responsive-viewport.mjs';

const SUPPORTED_FORMATS = new Set(['Unreal Engine']);

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
  const dialog = page.getByRole('dialog', { name: /add (?:new )?format/i });
  return {
    dialog,
    options: dialog.getByRole('option', { name: 'Unreal Engine', exact: true }),
    buttons: dialog.getByRole('button', { name: 'Unreal Engine', exact: true }),
  };
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
    const matching = await visibleCount(exactButton(page, manifest.includedFormat));
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
    const choice = formatChoice(page);
    const options = await visibleCount(choice.options);
    const buttons = options.length === 0 ? await visibleCount(choice.buttons) : [];
    result.choiceCount = options.length + buttons.length;
    if (result.choiceCount !== 1) {
      result.blockers.push(`Unreal Engine choice visible match count is ${result.choiceCount}.`);
      return result;
    }
    result.choice = options.length === 1 ? options[0] : buttons[0];
    result.available = true;
    return result;
  } catch (error) {
    if (holdViewportLease) await lease.release().catch(() => undefined);
    throw error;
  } finally {
    if (closeChooser) {
      const dialog = page.getByRole('dialog', { name: /add (?:new )?format/i });
      if (await dialog.count() === 1 && await dialog.isVisible().catch(() => false)) {
        await page.keyboard.press('Escape').catch(() => undefined);
      }
    }
    if (!holdViewportLease) await lease.release();
  }
}

export async function executeFormatBootstrap(page, manifest, inspection, { guard, onMutation = null } = {}) {
  if (!inspection.required || !inspection.available || !inspection.choice) throw new Error('Format bootstrap was not proven safe before execution.');
  guard.setPhase('format-create');
  try {
    await onMutation?.();
    await inspection.choice.click();
    await page.waitForTimeout(150);
    const region = includedFilesRegion(page);
    const formats = await productFormatButtons(page);
    const matching = await visibleCount(exactButton(page, manifest.includedFormat));
    if (await region.count() !== 1 || formats.length !== 1 || matching.length !== 1) {
      throw new Error('Format bootstrap did not produce exactly one Unreal Engine product format.');
    }
    return { created: true };
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
