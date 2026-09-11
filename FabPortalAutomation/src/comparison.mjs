import { fieldCandidates, mediaCandidates, resolveCandidate } from './locators.mjs';
import { compareDescriptionLinks } from './description-links.mjs';
import { portalFieldLifecycle } from './lifecycle.mjs';
import { isFormatView } from './view-detection.mjs';

export const COMPARISON_STATES = ['MATCH', 'MISMATCH', 'NOT_VISIBLE', 'NOT_DISCOVERED', 'NOT_APPLICABLE'];
const FORMAT_OWNED_FIELDS = new Set(['engineVersions', 'platforms', 'technicalInformationFile', 'media']);

export function fieldView(field) {
  return FORMAT_OWNED_FIELDS.has(field) || /^packages\[\d+\]\.projectFileLink$/.test(field) ? 'format' : 'listing';
}

function writeTargetFor(field, view, target) {
  if (!target || fieldView(field) !== view) return null;
  return { ...target, view, locator: target.locator ?? null };
}

export function normalizeText(value) {
  return String(value ?? '').replace(/\s+/g, ' ').trim();
}

function decimalCents(value) {
  const text = typeof value === 'number' ? String(value) : normalizeText(value);
  if (!/^\d+(?:\.\d{1,2})?$/.test(text)) return null;
  const [whole, fraction = ''] = text.split('.');
  return BigInt(whole) * 100n + BigInt(fraction.padEnd(2, '0'));
}

function parseUsdCents(value) {
  if (value === null || value === undefined) return null;
  const text = normalizeText(value);
  if (text === '') return null;
  let amount = null;
  if (/^\$\d+(?:\.\d{1,2})?$/.test(text)) amount = text.slice(1);
  else if (/^USD\s+\d+(?:\.\d{1,2})?$/i.test(text)) amount = text.replace(/^USD\s+/i, '');
  else if (/^\d+(?:\.\d{1,2})?\s+(?:USD|\(USD\))$/i.test(text)) amount = text.replace(/\s+(?:USD|\(USD\))$/i, '');
  else if (/^\d+(?:\.\d{1,2})?$/.test(text)) amount = text;
  return amount === null ? null : decimalCents(amount);
}

export function comparePriceClassification(portalValue, manifestValue) {
  if (portalValue === null || portalValue === undefined || normalizeText(portalValue) === '') return 'NOT_VISIBLE';
  const portalCents = parseUsdCents(portalValue);
  const manifestCents = decimalCents(manifestValue);
  if (portalCents === null || manifestCents === null) return 'MISMATCH';
  return portalCents === manifestCents ? 'MATCH' : 'MISMATCH';
}

export function normalizeRichText(value) {
  return String(value ?? '')
    .replace(/\r\n?/g, '\n')
    .replace(/\u00a0/g, ' ')
    .split('\n')
    .map((line) => line.replace(/[ \t]+/g, ' ').trim())
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

async function readLocator(locator) {
  const count = await locator.count();
  if (count !== 1) return { count, value: null, rawValue: null, checked: null, editable: false, disabled: false, placeholder: null };
  const visible = await locator.isVisible().catch(() => false);
  let value = '';
  try { value = await locator.inputValue(); } catch { value = await locator.innerText().catch(async () => await locator.textContent() ?? ''); }
  if (!value) value = await locator.textContent().catch(() => '') ?? '';
  const text = normalizeText(value);
  let checked = null;
  try { checked = await locator.isChecked(); } catch { /* not a checkable control */ }
  let disabled = false;
  try { disabled = await locator.isDisabled(); } catch { /* static element */ }
  let editable = false;
  try { editable = await locator.isEditable(); } catch { /* static element */ }
  const placeholder = await locator.getAttribute('placeholder').catch(() => null);
  return { count, visible, value: visible ? text || normalizeText(await locator.textContent() ?? '') : null, rawValue: visible ? value : null, checked: visible ? checked : null, editable: visible && editable, disabled, placeholder: visible ? placeholder : null };
}

function fieldResult({ manifestJsonPath, portalLabel, desired, current, state, resolved, editableControlAvailable, notes = '', writeTarget = null }) {
  return {
    manifestJsonPath,
    lifecycle: portalFieldLifecycle(manifestJsonPath),
    portalSection: null,
    portalLabel,
    currentVisibleValue: current,
    desiredValue: desired,
    currentNormalizedValue: current,
    desiredNormalizedValue: desired,
    candidateLocator: resolved?.metadata ?? null,
    locatorMatchCount: resolved?.metadata?.matchCount ?? 0,
    confidence: resolved?.metadata?.confidence ?? 'low',
    editableControlAvailable: Boolean(editableControlAvailable),
    classification: state,
    notes,
    writeTarget,
  };
}

function lifecycleField(manifestJsonPath, portalLabel, desired, state, notes, view) {
  const result = fieldResult({ manifestJsonPath, portalLabel, desired, current: null, state, resolved: null, editableControlAvailable: false, notes, writeTarget: null });
  result.view = view;
  return result;
}

function fixturePage(page) {
  try { return ['localhost', '127.0.0.1'].includes(new URL(page.url()).hostname); } catch { return false; }
}

function tagKey(value) {
  return normalizeText(value).toLocaleLowerCase();
}

export function compareTagsClassification(observed, desired, { complete = true } = {}) {
  if (!complete) return 'NOT_DISCOVERED';
  if (!Array.isArray(observed)) return 'NOT_DISCOVERED';
  const observedKeys = new Set(observed.map(tagKey));
  return desired.every((tag) => observedKeys.has(tagKey(tag))) ? 'MATCH' : 'MISMATCH';
}

async function compareTagsField(page, manifest, view) {
  if (fixturePage(page)) {
    const legacy = await compareTextField(page, manifest, 'tags', 'Tags *', { view });
    legacy.desiredValue = manifest.tags;
    legacy.classification = manifest.tags.length === 1
      ? compareTagsClassification(legacy.currentVisibleValue ? [legacy.currentVisibleValue] : [], manifest.tags)
      : 'NOT_DISCOVERED';
    legacy.notes = manifest.tags.length === 1 ? '' : 'Fixture tag controls expose only one tag value for this scenario.';
    return legacy;
  }
  const chipLocator = page.getByRole('button', { name: /^Remove (?!Windows$|Win64$|Linux$|Mac(?: OS)?$|macOS$).+/i });
  const chipValues = [];
  for (let index = 0; index < await chipLocator.count(); index += 1) {
    const chip = chipLocator.nth(index);
    if (!await chip.isVisible().catch(() => false)) continue;
    const label = await chip.getAttribute('aria-label').catch(() => null);
    const text = label ?? await chip.textContent().catch(() => '');
    const value = normalizeText(String(text).replace(/^Remove\s+/i, ''));
    if (value) chipValues.push(value);
  }
  const partialSummary = page.getByText(/^\+\d+$/, { exact: true });
  let partialVisible = false;
  for (let index = 0; index < await partialSummary.count(); index += 1) {
    if (await partialSummary.nth(index).isVisible().catch(() => false)) { partialVisible = true; break; }
  }
  const state = compareTagsClassification(chipValues, manifest.tags, { complete: !partialVisible && chipValues.length > 0 });
  return fieldResult({
    manifestJsonPath: 'tags',
    portalLabel: 'Tags *',
    desired: manifest.tags,
    current: chipValues.length > 0 ? chipValues : null,
    state,
    resolved: null,
    editableControlAvailable: false,
    notes: partialVisible
      ? 'Fab exposes a partial tag summary; the complete selected tag set was not proven.'
      : chipValues.length > 0 ? 'Complete selected tag chips were visibly read from the Fab listing.' : 'No complete selected tag set was visibly readable.',
    writeTarget: null,
  });
}

function derivedSupportFromDescription(manifest, descriptionField, view) {
  if (view !== 'listing') return lifecycleField('supportUrl', 'Support', manifest.supportUrl, 'NOT_APPLICABLE', 'Support is derived from the Draft-owned Description field, not a standalone format field.', view);
  const current = descriptionField?.currentVisibleValue;
  if (current === null || current === undefined || current === '') {
    return lifecycleField('supportUrl', 'Support', manifest.supportUrl, descriptionField?.classification === 'NOT_DISCOVERED' ? 'NOT_DISCOVERED' : 'NOT_VISIBLE', 'The support destination cannot be verified until the Draft Description is visible.', view);
  }
  const hasUrl = normalizeRichText(current).includes(normalizeText(manifest.supportUrl));
  return fieldResult({
    manifestJsonPath: 'supportUrl',
    portalLabel: 'Support',
    desired: manifest.supportUrl,
    current: hasUrl ? manifest.supportUrl : current,
    state: hasUrl ? 'MATCH' : 'MISMATCH',
    resolved: null,
    editableControlAvailable: false,
    notes: hasUrl
      ? 'Support destination was verified in the Draft-owned Description field.'
      : 'The exact configured support URL is not represented in the Draft-owned Description field.',
    writeTarget: null,
  });
}

async function locateField(page, field, manifest) {
  const resolved = await resolveCandidate(page, fieldCandidates(field, manifest));
  const value = await readLocator(resolved.locator);
  return { resolved, value };
}

function semanticState(current, desired, { rich = false } = {}) {
  if (current === null || current === undefined || current === '') return 'NOT_VISIBLE';
  const left = rich ? normalizeRichText(current) : normalizeText(current);
  const right = rich ? normalizeRichText(desired) : normalizeText(desired);
  return left === right ? 'MATCH' : 'MISMATCH';
}

async function compareTextField(page, manifest, field, labelName = field, options = {}) {
  const { resolved, value } = await locateField(page, field, manifest);
  const desired = options.desiredOverride ?? manifest[field];
  const current = options.rich ? (value.rawValue ?? value.placeholder) : (value.value || value.placeholder);
  const state = semanticState(current, desired, options);
  const target = value.visible && value.editable && !value.disabled && resolved.metadata?.unique
    ? writeTargetFor(field, options.view ?? 'listing', { strategy: resolved.candidate.strategy, expression: resolved.candidate.expression, field, locator: resolved.candidate.locator })
    : null;
  return fieldResult({ manifestJsonPath: field, portalLabel: labelName, desired, current, state, resolved, editableControlAvailable: value.editable && !value.disabled, notes: value.count === 1 ? '' : 'No unique readable portal control was found.', writeTarget: target });
}

async function compareCategory(page, manifest, view = 'listing') {
  const { resolved, value } = await locateField(page, 'category', manifest);
  const current = value.visible ? value.value || value.placeholder || '' : '';
  const state = semanticState(current, manifest.category);
  const target = value.visible && value.editable && !value.disabled ? writeTargetFor('category', view, { strategy: resolved.candidate.strategy, expression: resolved.candidate.expression, field: 'category', mutationType: 'combobox', locator: resolved.candidate.locator }) : null;
  return fieldResult({ manifestJsonPath: 'category', portalLabel: 'Category *', desired: manifest.category, current, state, resolved, editableControlAvailable: value.visible && value.editable && !value.disabled, notes: value.value ? '' : 'Category is exposed through the read-only combobox placeholder.', writeTarget: target });
}

async function compareSubcategory(page, manifest) {
  const labels = page.getByText(/subcategor(y|ies)/i);
  const count = await labels.count();
  if (count === 0 && Array.isArray(manifest.subcategory) && manifest.subcategory.length === 0) {
    return fieldResult({ manifestJsonPath: 'subcategory', portalLabel: null, desired: [], current: [], state: 'NOT_APPLICABLE', resolved: null, editableControlAvailable: false, notes: 'Fab exposes no distinct Subcategory control or value below the selected Category.' });
  }
  const controls = page.getByRole('combobox', { name: /subcategor(y|ies)/i });
  const controlCount = await controls.count();
  if (controlCount === 0) return fieldResult({ manifestJsonPath: 'subcategory', portalLabel: 'Subcategory', desired: manifest.subcategory, current: null, state: 'NOT_DISCOVERED', resolved: null, editableControlAvailable: false, notes: 'A subcategory label was present but no distinct control could be proven.' });
  const value = await readLocator(controls.first());
  const current = value.value ? [value.value] : [];
  const state = JSON.stringify(current) === JSON.stringify(manifest.subcategory) ? 'MATCH' : 'MISMATCH';
  return fieldResult({ manifestJsonPath: 'subcategory', portalLabel: 'Subcategory', desired: manifest.subcategory, current, state, resolved: { metadata: { strategy: 'getByRole', expression: 'page.getByRole("combobox", { name: /subcategor(y|ies)/i })', matchCount: controlCount, unique: controlCount === 1, confidence: controlCount === 1 ? 'high' : 'low' } }, editableControlAvailable: value.editable && !value.disabled, notes: '', writeTarget: null });
}

async function compareBoolean(page, manifest, field, labelName, desired, options = {}) {
  const { resolved, value } = await locateField(page, field, manifest);
  let current = !value.visible || value.checked === null ? null : (value.checked ? options.checkedValue : !options.checkedValue);
  if (current === null && value.value) current = options.readText?.(value.value);
  const state = current === null ? 'NOT_VISIBLE' : current === desired ? 'MATCH' : 'MISMATCH';
  const target = value.visible && value.editable && !value.disabled ? writeTargetFor(field, options.view ?? 'listing', { strategy: resolved.candidate.strategy, expression: resolved.candidate.expression, field, mutationType: 'boolean', checkedValue: options.checkedValue, locator: resolved.candidate.locator }) : null;
  return fieldResult({ manifestJsonPath: field, portalLabel: labelName, desired, current, state, resolved, editableControlAvailable: value.visible && value.editable && !value.disabled, notes: current === null ? 'Boolean state was not safely readable.' : '', writeTarget: target });
}

async function comparePriceField(page, manifest, field, labelName, view = 'listing') {
  const { resolved, value } = await locateField(page, field, manifest);
  const desired = manifest[field];
  const current = value.visible ? value.value || value.placeholder : null;
  const state = comparePriceClassification(current, desired);
  const target = value.visible && value.editable && !value.disabled && resolved.metadata?.unique
    ? writeTargetFor(field, view, { strategy: resolved.candidate.strategy, expression: resolved.candidate.expression, field, locator: resolved.candidate.locator })
    : null;
  return fieldResult({ manifestJsonPath: field, portalLabel: labelName, desired, current, state, resolved, editableControlAvailable: value.visible && value.editable && !value.disabled, notes: state === 'MISMATCH' && current ? 'Portal price was readable but did not normalize to the manifest USD cents value.' : '', writeTarget: target });
}

function desiredMedia(manifest) {
  return manifest.media.map((item) => ({ order: item.order, role: item.role }));
}

async function compareMedia(page, manifest, view = 'listing') {
  const isFixture = (() => { try { return ['localhost', '127.0.0.1'].includes(new URL(page.url()).hostname); } catch { return false; } })();
  const resolved = await resolveCandidate(page, mediaCandidates({ fixture: isFixture }));
  if (!isFixture) {
    const mediaHeading = page.getByRole('heading', { name: /^Media$/i });
    const thumbnailLabel = page.getByText('Thumbnail', { exact: true });
    const galleryLabel = page.getByText('Gallery', { exact: true });
    const sectionCount = await mediaHeading.count() + await thumbnailLabel.count() + await galleryLabel.count();
    const images = page.locator('main img');
    const imageCount = await images.count();
    const visibleEvidence = sectionCount > 0 || imageCount > 0;
    return fieldResult({ manifestJsonPath: 'media', portalLabel: 'Media', desired: desiredMedia(manifest), current: visibleEvidence ? { visibleImageCount: imageCount } : null, state: visibleEvidence ? 'NOT_DISCOVERED' : 'NOT_VISIBLE', resolved: null, editableControlAvailable: false, notes: visibleEvidence ? 'Fab media UI is visible, but source-to-portal identity and exact order are not provable from stable production DOM evidence; destructive replacement is forbidden.' : 'Media gallery was not visible.' });
  }
  if (!resolved.metadata?.unique) return fieldResult({ manifestJsonPath: 'media', portalLabel: 'Media', desired: manifest.media.map((item) => ({ order: item.order, role: item.role })), current: null, state: 'NOT_VISIBLE', resolved, editableControlAvailable: false, notes: 'Media gallery was not visible.' });
  const locator = resolved.locator;
  const existing = await locator.getAttribute('data-existing').catch(() => null);
  const orderText = normalizeText(await locator.textContent().catch(() => ''));
  if (existing === 'empty') {
    const current = [];
    const state = manifest.media.length === 0 ? 'MATCH' : 'MISMATCH';
    return fieldResult({ manifestJsonPath: 'media', portalLabel: 'Media', desired: manifest.media.map((item) => ({ order: item.order, role: item.role })), current, state, resolved, editableControlAvailable: true, notes: 'Empty gallery; controlled upload is safe only for a new empty gallery.', writeTarget: state === 'MISMATCH' ? writeTargetFor('media', view, { strategy: 'testId', expression: 'page.getByTestId("media-upload")', field: 'media', mutationType: 'upload', locator: { strategy: 'testId', value: 'media-upload' } }) : null });
  }
  if (existing === 'known' || existing === 'uploaded') {
    const desiredOrder = manifest.media.map((item) => `${item.order}:${item.role}`).join(',');
    const currentOrder = await locator.getAttribute('data-order').catch(() => null);
    const state = currentOrder === desiredOrder ? 'MATCH' : 'MISMATCH';
    return fieldResult({ manifestJsonPath: 'media', portalLabel: 'Media', desired: manifest.media.map((item) => ({ order: item.order, role: item.role })), current: currentOrder || orderText, state, resolved, editableControlAvailable: existing === 'empty', notes: existing === 'uploaded' ? 'Fixture upload was read back in exact order.' : 'Existing media identity/order was explicitly supplied by the controlled fixture.', writeTarget: null });
  }
  return fieldResult({ manifestJsonPath: 'media', portalLabel: 'Media', desired: manifest.media.map((item) => ({ order: item.order, role: item.role })), current: orderText || 'existing media', state: 'NOT_VISIBLE', resolved, editableControlAvailable: false, notes: 'Existing media identity/order is not provable; destructive replacement is forbidden.' });
}

async function compareLicense(page, manifest) {
  const { resolved, value } = await locateField(page, 'license', manifest);
  const selected = !value.visible ? null : value.checked === true ? 'Standard License (Free or Paid)' : value.value;
  const state = selected && /standard license/i.test(selected) && /standard license/i.test(manifest.license) ? 'MATCH' : semanticState(selected, manifest.license);
  return fieldResult({ manifestJsonPath: 'license', portalLabel: 'Standard License (Free or Paid)', desired: manifest.license, current: selected, state, resolved, editableControlAvailable: value.visible && value.editable && !value.disabled, notes: selected ? '' : 'License selection was not safely readable.', writeTarget: null });
}

async function visibleContentEditor(page) {
  const locator = page.locator('[contenteditable="true"]');
  const visibleIndexes = [];
  for (let index = 0; index < await locator.count(); index += 1) {
    if (await locator.nth(index).isVisible().catch(() => false)) visibleIndexes.push(index);
  }
  if (visibleIndexes.length !== 1) return null;
  const visible = locator.nth(visibleIndexes[0]);
  return { locator: visible, text: await visible.innerText().catch(() => '') };
}

async function compareDescriptionLinksField(page, manifest, view = 'listing') {
  const desired = manifest.descriptionLinks ?? [];
  if (view !== 'listing') return lifecycleField('descriptionLinks', 'Description links', desired, 'NOT_APPLICABLE', 'Description links are owned by the listing Description editor.', view);
  const editor = await visibleContentEditor(page);
  if (!editor) return lifecycleField('descriptionLinks', 'Description links', desired, 'NOT_VISIBLE', 'The visible Description editor was not uniquely readable.', view);
  const anchors = editor.locator.locator('a');
  const observed = [];
  for (let index = 0; index < await anchors.count(); index += 1) {
    const anchor = anchors.nth(index);
    if (!await anchor.isVisible().catch(() => false)) continue;
    const text = await anchor.innerText().catch(() => '');
    const rawHref = await anchor.getAttribute('href').catch(() => null);
    let href = rawHref;
    if (rawHref) {
      try { href = new URL(rawHref, page.url()).href; } catch { href = rawHref; }
    }
    if (text && href) observed.push({ text, href });
  }
  const state = compareDescriptionLinks(observed, desired);
  return fieldResult({
    manifestJsonPath: 'descriptionLinks',
    portalLabel: 'Description links',
    desired,
    current: observed,
    state,
    resolved: contentEditorResolution(),
    editableControlAvailable: false,
    notes: state === 'MATCH' ? 'Actual persisted anchors were read from the visible Description editor.' : 'Only actual anchors in the visible Description editor were compared; URL-looking plain text is not a link.',
    writeTarget: null,
  });
}

function contentEditorResolution() {
  return {
    metadata: {
      strategy: 'contenteditable',
      expression: 'page.locator(\'[contenteditable="true"]\')',
      matchCount: 1,
      unique: true,
      confidence: 'high',
      reason: 'Stable semantic contenteditable editor uniquely matched the visible format section.',
    },
  };
}

async function compareLabeledTechnicalUrl(page, manifest, field, labelName) {
  const desired = manifest[field];
  if (!await isFormatView(page)) return null;
  const editor = await visibleContentEditor(page);
  const escaped = desired.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  if (editor && new RegExp(`${labelName}\\s*:\\s*${escaped}`, 'i').test(normalizeText(editor.text))) {
    return fieldResult({ manifestJsonPath: field, portalLabel: labelName, desired, current: desired, state: 'MATCH', resolved: contentEditorResolution(), editableControlAvailable: false, notes: `Exact ${labelName} URL was readable in the visible Technical details editor.` });
  }
  const staticValue = page.getByText(`${labelName}: ${desired}`, { exact: true });
  if (await staticValue.count() === 1 && await staticValue.isVisible().catch(() => false)) {
    return fieldResult({ manifestJsonPath: field, portalLabel: labelName, desired, current: desired, state: 'MATCH', resolved: { metadata: { strategy: 'getByText', expression: `page.getByText(${JSON.stringify(`${labelName}: ${desired}`)}, { exact: true })`, matchCount: 1, unique: true, confidence: 'high', reason: 'Exact static technical detail value is visibly rendered in the format view.' } }, editableControlAvailable: false, notes: `Exact ${labelName} URL was readable in the visible Technical details section.` });
  }
  return null;
}

async function compareTechnicalInformation(page, manifestInfo, view = 'listing') {
  const base = await compareTextField(page, manifestInfo.manifest, 'technicalInformationFile', 'Technical Information', { desiredOverride: manifestInfo.technicalInformationText, rich: true, view });
  if (!await isFormatView(page)) return base;
  const editor = await visibleContentEditor(page);
  if (!editor) return base;
  const desired = manifestInfo.technicalInformationText;
  const current = editor.text;
  const state = semanticState(current, desired, { rich: true });
  const editable = await editor.locator.isEditable().catch(() => false);
  const disabled = await editor.locator.isDisabled().catch(() => false);
  const writeTarget = editable && !disabled
    ? writeTargetFor('technicalInformationFile', view, { strategy: 'contenteditable', expression: 'page.locator(\'[contenteditable="true"]\')', field: 'technicalInformationFile', locator: { strategy: 'contenteditable', selector: '[contenteditable="true"]' } })
    : null;
  return fieldResult({ manifestJsonPath: 'technicalInformationFile', portalLabel: 'Technical Information', desired, current, state, resolved: contentEditorResolution(), editableControlAvailable: editable && !disabled, notes: 'Read from the visible Technical details contenteditable editor; the manifest file path remains provenance only.', writeTarget });
}

export async function compareManifest(page, manifestInfo, { view = 'listing' } = {}) {
  const { manifest } = manifestInfo;
  const fields = [];
  fields.push(await compareTextField(page, manifest, 'title', 'Title *', { view }));
  fields.push(lifecycleField('shortDescription', 'Short description', manifest.shortDescription, 'NOT_APPLICABLE', 'shortDescription is source metadata and is not a distinct Draft-owned Fab Portal field.', view));
  const description = await compareTextField(page, manifest, 'longDescription', 'Description *', { rich: true, view });
  fields.push(description);
  fields.push(await compareDescriptionLinksField(page, manifest, view));
  fields.push(await compareTextField(page, manifest, 'productType', 'Product type *', { view }));
  fields.push(await compareCategory(page, manifest, view));
  fields.push(await compareSubcategory(page, manifest));
  fields.push(await compareTagsField(page, manifest, view));
  fields.push(await compareTextField(page, manifest, 'includedFormat', 'Unreal Engine', { view }));
  const engineLocator = page.getByText(/^UE_[0-9]+(?:\.[0-9]+)+$/, { exact: false });
  const engineCount = await engineLocator.count();
  const engineValues = [];
  for (let index = 0; index < engineCount; index += 1) {
    const item = engineLocator.nth(index);
    if (!await item.isVisible().catch(() => false)) continue;
    const value = normalizeText(await item.textContent().catch(() => ''));
    if (/^UE_[0-9]+(?:\.[0-9]+)+$/.test(value) && !engineValues.includes(value)) engineValues.push(value);
  }
  const portalEngines = engineValues.map((value) => value.slice(3));
  const engineDesired = [...manifest.engineVersions].sort();
  const engineState = engineValues.length === 0
    ? 'NOT_VISIBLE'
    : JSON.stringify([...portalEngines].sort()) === JSON.stringify(engineDesired) ? 'MATCH' : 'MISMATCH';
  fields.push(fieldResult({
    manifestJsonPath: 'engineVersions',
    portalLabel: 'Engine Versions',
    desired: manifest.engineVersions,
    current: engineValues.length ? portalEngines : null,
    state: engineState,
    resolved: engineCount > 0 ? { metadata: { strategy: 'getByText', expression: 'page.getByText(/^UE_[0-9]+(?:\\.[0-9]+)+$/, { exact: false })', matchCount: engineCount, unique: engineCount === engineValues.length, confidence: 'medium' } } : null,
    editableControlAvailable: false,
    notes: engineValues.length ? '' : 'Engine version section is not visible.'
  }));
  const platform = await compareTextField(page, manifest, 'platforms', 'Supported development platforms *', { view });
  const platformChips = page.getByRole('button', { name: /^Remove (?:Windows|Win64|Linux|Mac(?: OS)?|macOS)$/ });
  const visiblePlatformChips = [];
  for (let index = 0; index < await platformChips.count(); index += 1) {
    const item = platformChips.nth(index);
    if (await item.isVisible().catch(() => false)) visiblePlatformChips.push(item);
  }
  const platformChipCount = visiblePlatformChips.length;
  if (platformChipCount > 0) {
    const chipValues = [];
    for (const chip of visiblePlatformChips) chipValues.push((await chip.getAttribute('aria-label') ?? await chip.textContent() ?? '').replace(/^Remove\s+/i, '').trim());
    platform.currentVisibleValue = chipValues.join(' ');
    platform.currentNormalizedValue = platform.currentVisibleValue;
    platform.candidateLocator = {
      strategy: 'getByRole',
      expression: 'page.getByRole("button", { name: /^Remove (?:Windows|Win64|Linux|Mac(?: OS)?|macOS)$/ })',
      matchCount: platformChipCount,
      unique: true,
      confidence: 'high',
      reason: 'Stable static platform chip values proven by the read-only Fab discovery.',
    };
    platform.locatorMatchCount = platformChipCount;
    platform.confidence = 'high';
  }
  if (comparePlatformClassification(platform.currentVisibleValue, manifest.platforms) === 'NOT_DISCOVERED') {
    const windowsText = page.getByText('Windows', { exact: true });
    const removeWindows = page.getByRole('button', { name: 'Remove Windows', exact: true });
    const windowsTextCount = (await windowsText.count() === 1 && await windowsText.first().isVisible().catch(() => false)) ? 1 : 0;
    const removeWindowsCount = (await removeWindows.count() === 1 && await removeWindows.first().isVisible().catch(() => false)) ? 1 : 0;
    if (windowsTextCount === 1 || removeWindowsCount === 1) {
      platform.currentVisibleValue = 'Windows';
      platform.currentNormalizedValue = 'Windows';
      platform.candidateLocator = {
        strategy: windowsTextCount === 1 ? 'getByText' : 'getByRole',
        expression: windowsTextCount === 1 ? 'page.getByText("Windows", { exact: true })' : 'page.getByRole("button", { name: "Remove Windows", exact: true })',
        matchCount: 1,
        unique: true,
        confidence: 'high',
        reason: 'Stable static platform value proven by the read-only Fab discovery.',
      };
      platform.locatorMatchCount = 1;
      platform.confidence = 'high';
    }
  }
  platform.desiredValue = manifest.platforms;
  platform.currentNormalizedValue = platform.currentVisibleValue;
  platform.classification = comparePlatformClassification(platform.currentVisibleValue, manifest.platforms);
  fields.push(platform);
  fields.push(await compareLicense(page, manifest));
  fields.push(await comparePriceField(page, manifest, 'personalPriceUsd', 'Personal price *', view));
  fields.push(await comparePriceField(page, manifest, 'professionalPriceUsd', 'Professional price *', view));
  fields.push(await compareBoolean(page, manifest, 'matureContent', 'No, this listing does not contain mature content.', manifest.matureContent, { checkedValue: false, readText: (value) => /yes|mature/i.test(value), view }));
  fields.push(await compareBoolean(page, manifest, 'generatedWithAi', 'Yes, it was partly or fully created with generative AI', manifest.generatedWithAi, { checkedValue: true, readText: (value) => /yes|partly|fully/i.test(value), view }));
  fields.push(await compareBoolean(page, manifest, 'allowsUsageWithAi', 'Do not allow this product to be used by Generative AI Programs.', manifest.allowsUsageWithAi, { checkedValue: false, readText: (value) => /do not allow/i.test(value) ? false : /allow|true/i.test(value) ? true : null, view }));
  fields.push(await compareBoolean(page, manifest, 'promotionalContent', 'Includes promotional content', manifest.promotionalContent, { checkedValue: true, readText: (value) => /true|includes/i.test(value), view }));
  fields.push(await compareBoolean(page, manifest, 'forumPost', 'No, do not create a forum post', manifest.forumPost, { checkedValue: false, readText: (value) => /yes|create/i.test(value), view }));
  fields.push(lifecycleField('activation', 'Activation', manifest.activation, 'NOT_APPLICABLE', 'Activation is selected after Submit for review and is not a Draft-owned field.', view));
  const documentation = await compareTextField(page, manifest, 'documentationUrl', 'Documentation', { view });
  fields.push(documentation.classification === 'NOT_VISIBLE' ? await compareLabeledTechnicalUrl(page, manifest, 'documentationUrl', 'Documentation') ?? documentation : documentation);
  fields.push(derivedSupportFromDescription(manifest, description, view));
  fields.push(await compareTechnicalInformation(page, manifestInfo, view));
  fields.push(await compareMedia(page, manifest, view));
  for (const [index, pkg] of manifest.packages.entries()) {
    const field = `packages[${index}].projectFileLink`;
    if (pkg.projectFileLink === null) {
      fields.push(fieldResult({
        manifestJsonPath: field,
        portalLabel: 'Project file',
        desired: null,
        current: null,
        state: 'NOT_APPLICABLE',
        resolved: null,
        editableControlAvailable: false,
        notes: 'The staging manifest has no verified Project File Link for this engine version; the existing Fab value was intentionally not compared or managed.',
        writeTarget: null,
      }));
      continue;
    }
    const locatorManifest = { projectFileLink: pkg.projectFileLink };
    const resolved = await resolveCandidate(page, fieldCandidates('projectFileLink', locatorManifest));
    let current = null;
    if (resolved.metadata?.unique) {
      const value = await readLocator(resolved.locator);
      current = value.value || value.placeholder;
    }
    if (!current) {
      const link = page.getByText(pkg.projectFileLink, { exact: true });
      current = await link.count() === 1 && await link.isVisible().catch(() => false) ? pkg.projectFileLink : null;
    }
    const editable = resolved.metadata?.unique ? await readLocator(resolved.locator) : null;
    fields.push(fieldResult({ manifestJsonPath: field, portalLabel: 'Project file', desired: pkg.projectFileLink, current, state: semanticState(current, pkg.projectFileLink), resolved, editableControlAvailable: Boolean(editable?.editable && !editable.disabled), notes: current ? '' : 'Project File Link is not visible in the current format section.', writeTarget: editable?.editable && !editable.disabled ? writeTargetFor(field, view, { strategy: resolved.candidate.strategy, expression: resolved.candidate.expression, field, locator: resolved.candidate.locator }) : null }));
  }
  for (const field of fields) field.view = view;
  return summarizeComparison(fields);
}

export function summarizeComparison(fields) {
  const counts = Object.fromEntries(COMPARISON_STATES.map((state) => [state, fields.filter((field) => field.classification === state).length]));
  return { fields, counts, mismatchCount: counts.MISMATCH, unresolvedCritical: fields.filter((field) => ['NOT_VISIBLE', 'NOT_DISCOVERED'].includes(field.classification)).map((field) => field.manifestJsonPath) };
}

export function normalizePortalPlatforms(value) {
  const normalized = normalizeText(value).toLowerCase();
  const platforms = [];
  const add = (platform) => { if (!platforms.includes(platform)) platforms.push(platform); };
  if (/\bwindows?\b|\bwin64\b/.test(normalized)) add('Win64');
  if (/\blinux\b/.test(normalized)) add('Linux');
  if (/\bmacos\b|\bmac\s*os\b|\bmac\b/.test(normalized)) add('macOS');
  return platforms;
}

export function comparePlatformClassification(portalValue, manifestPlatforms) {
  if (portalValue === null || portalValue === undefined || normalizeText(portalValue) === '') return 'NOT_VISIBLE';
  const portalPlatforms = normalizePortalPlatforms(portalValue);
  if (portalPlatforms.length === 0) return 'NOT_DISCOVERED';
  const desired = [...manifestPlatforms].sort();
  return JSON.stringify(portalPlatforms.sort()) === JSON.stringify(desired) ? 'MATCH' : 'MISMATCH';
}

function compareObservationArray(current, desired, { sort = true } = {}) {
  if (!Array.isArray(current)) return 'MISMATCH';
  const left = current.map((value) => normalizeText(value));
  const right = desired.map((value) => normalizeText(value));
  if (sort) {
    left.sort();
    right.sort();
  }
  return JSON.stringify(left) === JSON.stringify(right) ? 'MATCH' : 'MISMATCH';
}

function compareObservationScalar(current, desired, { rich = false } = {}) {
  return semanticState(current, desired, { rich });
}

function observationField({ entry, manifestJsonPath, portalLabel, desired, view, compare, note = '' }) {
  if (!entry) {
    const result = fieldResult({ manifestJsonPath, portalLabel, desired, current: null, state: 'NOT_DISCOVERED', resolved: null, editableControlAvailable: false, notes: 'The observation omitted this expected field.', writeTarget: null });
    result.view = view;
    return result;
  }
  if (entry.state !== 'OBSERVED') {
    const result = fieldResult({ manifestJsonPath, portalLabel, desired, current: null, state: entry.state, resolved: null, editableControlAvailable: false, notes: entry.note ?? '', writeTarget: null });
    result.view = view;
    return result;
  }
  const current = entry.value;
  const state = compare(current, desired);
  const result = fieldResult({ manifestJsonPath, portalLabel, desired, current, state, resolved: null, editableControlAvailable: false, notes: [note, entry.note].filter(Boolean).join(' '), writeTarget: null });
  result.view = view;
  return result;
}

function observationLifecycleField({ entry, manifestJsonPath, portalLabel, desired, view, note }) {
  return observationField({ entry, manifestJsonPath, portalLabel, desired, view, compare: () => 'NOT_APPLICABLE', note });
}

function derivedSupportObservation(manifest, entries) {
  const description = entries.get('longDescription');
  const entry = entries.get('supportUrl');
  const base = { manifestJsonPath: 'supportUrl', portalLabel: 'Support', desired: manifest.supportUrl, view: 'listing' };
  if (!entry) return observationField({ entry: null, ...base, compare: () => 'NOT_DISCOVERED', note: 'The observation omitted the derived support field.' });
  if (!description) return observationField({ entry, ...base, compare: () => 'NOT_DISCOVERED', note: 'The Draft Description observation is missing, so the derived support destination cannot be verified.' });
  if (description.state !== 'OBSERVED') return observationField({ entry, ...base, compare: () => description.state, note: 'Support is derived from the Draft-owned Description field.' });
  const currentDescription = normalizeRichText(description.value);
  const hasUrl = currentDescription.includes(normalizeText(manifest.supportUrl));
  const result = fieldResult({
    manifestJsonPath: 'supportUrl',
    portalLabel: 'Support',
    desired: manifest.supportUrl,
    current: hasUrl ? manifest.supportUrl : currentDescription,
    state: hasUrl ? 'MATCH' : 'MISMATCH',
    resolved: null,
    editableControlAvailable: false,
    notes: [
      'Support is derived from the Draft-owned Description field.',
      entry?.note,
      hasUrl ? 'The exact support URL was present in the observed Description.' : 'The exact configured support URL was absent from the observed Description.',
    ].filter(Boolean).join(' '),
    writeTarget: null,
  });
  result.view = 'listing';
  return result;
}

function compareObservationMedia(current, manifestMedia) {
  const desired = manifestMedia.map((item) => ({ order: item.order, role: item.role }));
  if (!current || typeof current !== 'object' || Array.isArray(current) || current.count !== desired.length || !Array.isArray(current.items)) return 'MISMATCH';
  const actual = current.items.map((item) => ({ order: item.order, role: item.role }));
  return JSON.stringify(actual) === JSON.stringify(desired) ? 'MATCH' : 'MISMATCH';
}

export function compareObservation(manifestInfo, observation) {
  const { manifest } = manifestInfo;
  const entries = new Map((observation?.fields ?? []).map((entry) => [entry.manifestJsonPath, entry]));
  const field = (manifestJsonPath, portalLabel, desired, compare, note = '') => observationField({ entry: entries.get(manifestJsonPath), manifestJsonPath, portalLabel, desired, view: fieldView(manifestJsonPath), compare, note });
  const fields = [
    field('title', 'Title', manifest.title, (current, expected) => compareObservationScalar(current, expected)),
    observationLifecycleField({ entry: entries.get('shortDescription'), manifestJsonPath: 'shortDescription', portalLabel: 'Short description', desired: manifest.shortDescription, view: 'listing', note: 'shortDescription is source metadata and is not a distinct Draft-owned Fab Portal field.' }),
    field('longDescription', 'Description', manifest.longDescription, (current, expected) => compareObservationScalar(current, expected, { rich: true })),
    field('descriptionLinks', 'Description links', manifest.descriptionLinks ?? [], (current, expected) => compareDescriptionLinks(current, expected)),
    field('productType', 'Product type', manifest.productType, (current, expected) => compareObservationScalar(current, expected)),
    field('category', 'Category', manifest.category, (current, expected) => compareObservationScalar(current, expected)),
    field('subcategory', 'Subcategory', manifest.subcategory, (current, expected) => compareObservationArray(current, expected)),
    field('tags', 'Tags', manifest.tags, (current, expected) => compareTagsClassification(current, expected)),
    field('includedFormat', 'Included format', manifest.includedFormat, (current, expected) => compareObservationScalar(current, expected)),
    field('engineVersions', 'Engine versions', manifest.engineVersions, (current, expected) => compareObservationArray(current, expected)),
    field('platforms', 'Platforms', manifest.platforms, (current, expected) => comparePlatformClassification(Array.isArray(current) ? current.join(' ') : current, expected)),
    field('license', 'License', manifest.license, (current, expected) => current && /standard license/i.test(current) && /standard license/i.test(expected) ? 'MATCH' : compareObservationScalar(current, expected)),
    field('personalPriceUsd', 'Personal price', manifest.personalPriceUsd, (current, expected) => comparePriceClassification(current, expected)),
    field('professionalPriceUsd', 'Professional price', manifest.professionalPriceUsd, (current, expected) => comparePriceClassification(current, expected)),
    field('matureContent', 'Mature content', manifest.matureContent, (current, expected) => current === expected ? 'MATCH' : 'MISMATCH'),
    field('generatedWithAi', 'Generated with AI', manifest.generatedWithAi, (current, expected) => current === expected ? 'MATCH' : 'MISMATCH'),
    field('allowsUsageWithAi', 'Allows usage with AI', manifest.allowsUsageWithAi, (current, expected) => current === expected ? 'MATCH' : 'MISMATCH'),
    field('promotionalContent', 'Promotional content', manifest.promotionalContent, (current, expected) => current === expected ? 'MATCH' : 'MISMATCH'),
    field('forumPost', 'Forum post', manifest.forumPost, (current, expected) => current === expected ? 'MATCH' : 'MISMATCH'),
    observationLifecycleField({ entry: entries.get('activation'), manifestJsonPath: 'activation', portalLabel: 'Activation', desired: manifest.activation, view: 'listing', note: 'Activation is selected after Submit for review and is not a Draft-owned field.' }),
    field('documentationUrl', 'Documentation', manifest.documentationUrl, (current, expected) => compareObservationScalar(current, expected)),
    derivedSupportObservation(manifest, entries),
    field('technicalInformationFile', 'Technical information', manifestInfo.technicalInformationText, (current, expected) => compareObservationScalar(current, expected, { rich: true }), 'The observed value is the visible technical text; the manifest path is provenance.'),
    field('media', 'Media', manifest.media.map((item) => ({ order: item.order, role: item.role })), (current) => compareObservationMedia(current, manifest.media), 'Portal observation covers visible count/order/roles only; local approval owns source-byte hashes.'),
  ];
  for (const [index, pkg] of manifest.packages.entries()) {
    const manifestJsonPath = `packages[${index}].projectFileLink`;
    fields.push(field(manifestJsonPath, `Project file link (${pkg.engineVersion})`, pkg.projectFileLink, (current, expected) => expected === null ? 'NOT_APPLICABLE' : compareObservationScalar(current, expected)));
  }
  return summarizeComparison(fields);
}

export { compareDescriptionLinks, readLocator, fieldResult };
