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

export function supportedBootstrapFormat(value) {
  return SUPPORTED_FORMATS.has(String(value ?? ''));
}

export async function inspectFormatBootstrap(page, manifest, { guard = null, openChooser = true } = {}) {
  const result = {
    required: false,
    available: false,
    formatCount: null,
    matchingFormatCount: 0,
    addControlCount: 0,
    choiceCount: 0,
    blockers: [],
    choice: null,
  };
  if (!supportedBootstrapFormat(manifest.includedFormat)) {
    result.blockers.push(`Unsupported format bootstrap value: ${manifest.includedFormat}.`);
    return result;
  }

  const region = includedFilesRegion(page);
  if (await region.count() !== 1 || !await region.isVisible().catch(() => false)) {
    result.blockers.push('Included Files product format inventory is not uniquely visible.');
    return result;
  }
  const formats = await productFormatButtons(page);
  result.formatCount = formats.length;
  const matching = await visibleCount(exactButton(page, manifest.includedFormat));
  result.matchingFormatCount = matching.length;
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
