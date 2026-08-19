import { fieldCandidates, mediaCandidates, resolveCandidate } from './locators.mjs';

export const COMPARISON_STATES = ['MATCH', 'MISMATCH', 'NOT_VISIBLE', 'NOT_DISCOVERED', 'NOT_APPLICABLE'];

function normalizeText(value) {
  return String(value ?? '').replace(/\s+/g, ' ').trim();
}

function normalizeRichText(value) {
  return normalizeText(value).replace(/\s*([*_`#>-])\s*/g, '$1');
}

async function readLocator(locator) {
  const count = await locator.count();
  if (count !== 1) return { count, value: null, rawValue: null, checked: null, editable: false, disabled: false, placeholder: null };
  let value = '';
  try { value = await locator.inputValue(); } catch { value = await locator.textContent() ?? ''; }
  const text = normalizeText(value);
  let checked = null;
  try { checked = await locator.isChecked(); } catch { /* not a checkable control */ }
  let disabled = false;
  try { disabled = await locator.isDisabled(); } catch { /* static element */ }
  let editable = false;
  try { editable = await locator.isEditable(); } catch { /* static element */ }
  const placeholder = await locator.getAttribute('placeholder').catch(() => null);
  return { count, value: text || normalizeText(await locator.textContent() ?? ''), rawValue: value, checked, editable, disabled, placeholder };
}

function fieldResult({ manifestJsonPath, portalLabel, desired, current, state, resolved, editableControlAvailable, notes = '', writeTarget = null }) {
  return {
    manifestJsonPath,
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
  const current = value.value || value.placeholder;
  const state = semanticState(current, desired, options);
  const target = value.editable && !value.disabled && resolved.metadata?.unique ? { strategy: resolved.candidate.strategy, expression: resolved.candidate.expression, field } : null;
  return fieldResult({ manifestJsonPath: field, portalLabel: labelName, desired, current, state, resolved, editableControlAvailable: value.editable && !value.disabled, notes: value.count === 1 ? '' : 'No unique readable portal control was found.', writeTarget: target });
}

async function compareCategory(page, manifest) {
  const { resolved, value } = await locateField(page, 'category', manifest);
  const current = value.value || value.placeholder || '';
  const state = semanticState(current, manifest.category);
  const target = value.editable && !value.disabled ? { strategy: resolved.candidate.strategy, expression: resolved.candidate.expression, field: 'category', mutationType: 'combobox' } : null;
  return fieldResult({ manifestJsonPath: 'category', portalLabel: 'Category *', desired: manifest.category, current, state, resolved, editableControlAvailable: value.editable && !value.disabled, notes: value.value ? '' : 'Category is exposed through the read-only combobox placeholder.', writeTarget: target });
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
  let current = value.checked === null ? null : (value.checked ? options.checkedValue : !options.checkedValue);
  if (current === null && value.value) current = options.readText?.(value.value);
  const state = current === null ? 'NOT_VISIBLE' : current === desired ? 'MATCH' : 'MISMATCH';
  const target = value.editable && !value.disabled ? { strategy: resolved.candidate.strategy, expression: resolved.candidate.expression, field, mutationType: 'boolean', checkedValue: options.checkedValue } : null;
  return fieldResult({ manifestJsonPath: field, portalLabel: labelName, desired, current, state, resolved, editableControlAvailable: value.editable && !value.disabled, notes: current === null ? 'Boolean state was not safely readable.' : '', writeTarget: target });
}

function desiredMedia(manifest) {
  return manifest.media.map((item) => ({ order: item.order, role: item.role }));
}

async function compareMedia(page, manifest) {
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
    return fieldResult({ manifestJsonPath: 'media', portalLabel: 'Media', desired: manifest.media.map((item) => ({ order: item.order, role: item.role })), current, state, resolved, editableControlAvailable: true, notes: 'Empty gallery; controlled upload is safe only for a new empty gallery.', writeTarget: state === 'MISMATCH' ? { strategy: 'testId', expression: 'page.getByTestId("media-gallery")', field: 'media', mutationType: 'upload' } : null });
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
  const selected = value.checked === true ? 'Standard License (Free or Paid)' : value.value;
  const state = selected && /standard license/i.test(selected) && /standard license/i.test(manifest.license) ? 'MATCH' : semanticState(selected, manifest.license);
  return fieldResult({ manifestJsonPath: 'license', portalLabel: 'Standard License (Free or Paid)', desired: manifest.license, current: selected, state, resolved, editableControlAvailable: value.editable && !value.disabled, notes: selected ? '' : 'License selection was not safely readable.', writeTarget: null });
}

export async function compareManifest(page, manifestInfo) {
  const { manifest } = manifestInfo;
  const fields = [];
  fields.push(await compareTextField(page, manifest, 'title', 'Title *'));
  fields.push(await compareTextField(page, manifest, 'shortDescription', 'Short description *'));
  fields.push(await compareTextField(page, manifest, 'longDescription', 'Description *', { rich: true }));
  fields.push(await compareTextField(page, manifest, 'productType', 'Product type *'));
  fields.push(await compareCategory(page, manifest));
  fields.push(await compareSubcategory(page, manifest));
  const tags = await compareTextField(page, manifest, 'tags', 'Tags *');
  const fixturePage = (() => { try { return ['localhost', '127.0.0.1'].includes(new URL(page.url()).hostname); } catch { return false; } })();
  if (!fixturePage || manifest.tags.length !== 1) {
    tags.classification = 'NOT_VISIBLE';
    tags.notes = 'Portal exposes only a partial tag summary; complete tag ownership is not proven.';
  }
  tags.desiredValue = manifest.tags;
  fields.push(tags);
  fields.push(await compareTextField(page, manifest, 'includedFormat', 'Unreal Engine'));
  const engine = await page.getByText(`UE_${manifest.engineVersions[0]}`, { exact: true }).count();
  fields.push(fieldResult({ manifestJsonPath: 'engineVersions', portalLabel: 'Engine Versions', desired: manifest.engineVersions, current: engine ? `UE_${manifest.engineVersions[0]}` : null, state: engine ? 'MATCH' : 'NOT_VISIBLE', resolved: engine ? { metadata: { strategy: 'getByText', expression: `page.getByText("UE_${manifest.engineVersions[0]}", { exact: true })`, matchCount: engine, unique: engine === 1, confidence: 'medium' } } : null, editableControlAvailable: false, notes: engine ? '' : 'Engine version is not visible.' }));
  const platform = await compareTextField(page, manifest, 'platforms', 'Supported development platforms *');
  if (comparePlatformClassification(platform.currentVisibleValue, manifest.platforms) === 'NOT_DISCOVERED') {
    const windowsText = page.getByText('Windows', { exact: true });
    const removeWindows = page.getByRole('button', { name: 'Remove Windows', exact: true });
    const windowsTextCount = await windowsText.count();
    const removeWindowsCount = await removeWindows.count();
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
  fields.push(await compareTextField(page, manifest, 'personalPriceUsd', 'Personal price *'));
  fields.push(await compareTextField(page, manifest, 'professionalPriceUsd', 'Professional price *'));
  fields.push(await compareBoolean(page, manifest, 'matureContent', 'No, this listing does not contain mature content.', manifest.matureContent, { checkedValue: false, readText: (value) => /yes|mature/i.test(value) }));
  fields.push(await compareBoolean(page, manifest, 'generatedWithAi', 'Yes, it was partly or fully created with generative AI', manifest.generatedWithAi, { checkedValue: true, readText: (value) => /yes|partly|fully/i.test(value) }));
  fields.push(await compareBoolean(page, manifest, 'allowsUsageWithAi', 'Do not allow this product to be used by Generative AI Programs.', manifest.allowsUsageWithAi, { checkedValue: false, readText: (value) => /do not allow/i.test(value) ? false : /allow|true/i.test(value) ? true : null }));
  fields.push(await compareBoolean(page, manifest, 'promotionalContent', 'Includes promotional content', manifest.promotionalContent, { checkedValue: true, readText: (value) => /true|includes/i.test(value) }));
  fields.push(await compareBoolean(page, manifest, 'forumPost', 'No, do not create a forum post', manifest.forumPost, { checkedValue: false, readText: (value) => /yes|create/i.test(value) }));
  fields.push(await compareTextField(page, manifest, 'activation', 'Activation'));
  fields.push(await compareTextField(page, manifest, 'documentationUrl', 'Documentation'));
  fields.push(await compareTextField(page, manifest, 'supportUrl', 'Support'));
  fields.push(await compareTextField(page, manifest, 'technicalInformationFile', 'Technical Information', { desiredOverride: manifestInfo.technicalInformationText, rich: true }));
  fields.push(await compareMedia(page, manifest));
  for (const [index, pkg] of manifest.packages.entries()) {
    const field = `packages[${index}].projectFileLink`;
    const locatorManifest = { projectFileLink: pkg.projectFileLink };
    const resolved = await resolveCandidate(page, fieldCandidates('projectFileLink', locatorManifest));
    let current = null;
    if (resolved.metadata?.unique) {
      const value = await readLocator(resolved.locator);
      current = value.value || value.placeholder;
    }
    if (!current) current = await page.getByText(pkg.projectFileLink, { exact: true }).count() === 1 ? pkg.projectFileLink : null;
    const editable = resolved.metadata?.unique ? await readLocator(resolved.locator) : null;
    fields.push(fieldResult({ manifestJsonPath: field, portalLabel: 'Project file', desired: pkg.projectFileLink, current, state: semanticState(current, pkg.projectFileLink), resolved, editableControlAvailable: Boolean(editable?.editable && !editable.disabled), notes: current ? '' : 'Project File Link is not visible in the current format section.', writeTarget: editable?.editable && !editable.disabled ? { strategy: resolved.candidate.strategy, expression: resolved.candidate.expression, field } : null }));
  }
  const counts = Object.fromEntries(COMPARISON_STATES.map((state) => [state, fields.filter((field) => field.classification === state).length]));
  return { fields, counts, mismatchCount: counts.MISMATCH, unresolvedCritical: fields.filter((field) => ['NOT_VISIBLE', 'NOT_DISCOVERED'].includes(field.classification)).map((field) => field.manifestJsonPath) };
}

export function normalizePortalPlatforms(value) {
  const normalized = normalizeText(value).toLowerCase();
  if (/\bwindows?\b|win64/.test(normalized)) return ['Win64'];
  if (/\blinux\b/.test(normalized)) return ['Linux'];
  if (/macos|mac\s*os|\bmac\b/.test(normalized)) return ['macOS'];
  return [];
}

export function comparePlatformClassification(portalValue, manifestPlatforms) {
  if (portalValue === null || portalValue === undefined || normalizeText(portalValue) === '') return 'NOT_VISIBLE';
  const portalPlatforms = normalizePortalPlatforms(portalValue);
  if (portalPlatforms.length === 0) return 'NOT_DISCOVERED';
  const desired = [...manifestPlatforms].sort();
  return JSON.stringify(portalPlatforms.sort()) === JSON.stringify(desired) ? 'MATCH' : 'MISMATCH';
}

export { normalizeText, normalizeRichText, readLocator, fieldResult };
