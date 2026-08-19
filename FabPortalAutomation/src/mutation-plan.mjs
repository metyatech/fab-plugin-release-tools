import { resolveLocatorDescriptor } from './locators.mjs';

const SUPPORTED_MUTATIONS = new Set(['text', 'richText', 'combobox', 'boolean', 'upload']);

function mutationType(field) {
  if (field === 'longDescription') return 'richText';
  if (field === 'category' || field === 'productType') return 'combobox';
  if (['matureContent', 'generatedWithAi', 'allowsUsageWithAi', 'promotionalContent', 'forumPost'].includes(field)) return 'boolean';
  if (field === 'media') return 'upload';
  return 'text';
}

export function buildMutationPlan(comparison, manifestInfo) {
  const plan = [];
  const blockers = [];
  for (const field of comparison.fields) {
    if (field.classification !== 'MISMATCH') continue;
    const fieldName = field.manifestJsonPath;
    const type = field.writeTarget?.mutationType ?? mutationType(fieldName);
    if (!field.writeTarget || !SUPPORTED_MUTATIONS.has(type)) {
      blockers.push(`${fieldName} differs but has no approved writable locator.`);
      continue;
    }
    if (fieldName === 'media' && field.notes.includes('Existing media')) {
      blockers.push('Existing media is ambiguous and will not be replaced automatically.');
      continue;
    }
    const packageMatch = fieldName.match(/^packages\[(\d+)\]\.projectFileLink$/);
    const desired = packageMatch
      ? manifestInfo.manifest.packages[Number(packageMatch[1])].projectFileLink
      : fieldName === 'technicalInformationFile' ? manifestInfo.technicalInformationText : manifestInfo.manifest[fieldName];
    plan.push({ fieldName, view: field.writeTarget.view ?? field.view ?? 'listing', currentNormalizedValue: field.currentNormalizedValue, desiredNormalizedValue: desired, locator: field.writeTarget.locator ?? null, locatorStrategy: field.writeTarget.strategy, locatorExpression: field.writeTarget.expression, mutationType: type, checkedValue: field.writeTarget.checkedValue });
  }
  const keys = plan.map((entry) => `${entry.view}:${JSON.stringify(entry.locator)}`);
  if (new Set(keys).size !== keys.length) blockers.push('Mutation plan contains duplicate target locators.');
  return { plan, blockers };
}

async function resolveExactWritableTarget(page, item) {
  const locator = resolveLocatorDescriptor(page, item.locator);
  if (!locator) return { ok: false, failures: [`${item.fieldName}: approved locator descriptor is missing or unsupported.`] };
  const count = await locator.count();
  const visibleIndexes = [];
  for (let index = 0; index < count; index += 1) {
    if (await locator.nth(index).isVisible().catch(() => false)) visibleIndexes.push(index);
  }
  if (visibleIndexes.length !== 1) return { ok: false, failures: [`${item.fieldName}: approved locator visible match count is ${visibleIndexes.length}.`] };
  const target = locator.nth(visibleIndexes[0]);
  const disabled = await target.isDisabled().catch(() => false);
  if (disabled) return { ok: false, failures: [`${item.fieldName}: approved locator is disabled.`] };
  if (item.mutationType !== 'upload' && !await target.isEditable().catch(() => false)) return { ok: false, failures: [`${item.fieldName}: approved locator is not writable.`] };
  return { ok: true, locator: target };
}

export async function preflightMutationPlan(page, plan, manifest) {
  const checked = new Set();
  const failures = [];
  const resolvedTargets = [];
  for (const item of plan) {
    const key = `${item.view ?? 'listing'}:${JSON.stringify(item.locator)}`;
    if (checked.has(key)) failures.push(`${item.fieldName}: duplicate locator target.`);
    checked.add(key);
    const resolved = await resolveExactWritableTarget(page, item);
    if (!resolved.ok) failures.push(...resolved.failures);
    else resolvedTargets.push({ item, locator: resolved.locator });
  }
  return { ok: failures.length === 0, failures, targets: resolvedTargets };
}

async function selectExactOption(page, desired) {
  const options = page.getByRole('option', { name: String(desired), exact: true });
  const count = await options.count();
  if (count !== 1) throw new Error(`Expected exactly one option named ${desired}; found ${count}.`);
  await options.click();
}

export async function executeMutationPlan(page, preflight, manifestInfo, { setPhase = null, assertView = null } = {}) {
  const executed = [];
  for (const { item } of preflight.targets) {
    await assertView?.(item.view ?? 'listing');
    const exact = await resolveExactWritableTarget(page, item);
    if (!exact.ok) throw new Error(`Execution target validation failed: ${exact.failures.join(' ')}`);
    const locator = exact.locator;
    setPhase?.(item.mutationType === 'upload' ? 'media-upload' : 'field-update');
    const packageMatch = item.fieldName.match(/^packages\[(\d+)\]\.projectFileLink$/);
    const desired = packageMatch
      ? manifestInfo.manifest.packages[Number(packageMatch[1])].projectFileLink
      : item.fieldName === 'technicalInformationFile' ? manifestInfo.technicalInformationText : manifestInfo.manifest[item.fieldName];
    try {
      if (item.mutationType === 'text' || item.mutationType === 'richText') await locator.fill(String(desired));
      else if (item.mutationType === 'combobox') {
        await locator.click();
        await selectExactOption(page, desired);
      } else if (item.mutationType === 'boolean') {
        const checked = await locator.isChecked();
        const checkedValue = item.checkedValue ?? true;
        const currentValue = checked ? checkedValue : !checkedValue;
        if (currentValue !== Boolean(desired)) {
          if (Boolean(desired) === checkedValue) await locator.check();
          else await locator.uncheck();
        }
      } else if (item.mutationType === 'upload') {
        const files = manifestInfo.mediaFiles.map((file) => file.path);
        await locator.setInputFiles(files);
      }
    } finally {
      setPhase?.('stage');
    }
    executed.push(item.fieldName);
  }
  return executed;
}
