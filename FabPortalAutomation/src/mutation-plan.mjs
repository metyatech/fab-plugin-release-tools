import { fieldCandidates, resolveCandidate } from './locators.mjs';

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
    const type = mutationType(fieldName);
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
    plan.push({ fieldName, currentNormalizedValue: field.currentNormalizedValue, desiredNormalizedValue: desired, locatorStrategy: field.writeTarget.strategy, locatorExpression: field.writeTarget.expression, mutationType: type, checkedValue: field.writeTarget.checkedValue });
  }
  const keys = plan.map((entry) => `${entry.locatorStrategy}:${entry.locatorExpression}`);
  if (new Set(keys).size !== keys.length) blockers.push('Mutation plan contains duplicate target locators.');
  return { plan, blockers };
}

export async function preflightMutationPlan(page, plan, manifest) {
  const checked = new Set();
  const failures = [];
  const resolvedTargets = [];
  for (const item of plan) {
    const candidates = item.fieldName === 'media'
      ? [{ strategy: 'testId', expression: 'page.getByTestId("media-upload")', create: (currentPage) => currentPage.getByTestId('media-upload'), confidence: 'high', reason: 'Controlled empty gallery upload target.' }]
      : fieldCandidates(item.fieldName.startsWith('packages[') ? 'projectFileLink' : item.fieldName, manifest);
    const resolved = await resolveCandidate(page, candidates);
    const key = `${resolved.candidate?.strategy}:${resolved.candidate?.expression}`;
    if (checked.has(key)) failures.push(`${item.fieldName}: duplicate locator target.`);
    checked.add(key);
    const count = await resolved.locator.count();
    if (count !== 1) failures.push(`${item.fieldName}: locator match count is ${count}.`);
    if (count === 1) {
      let disabled = false;
      let editable = false;
      try { disabled = await resolved.locator.isDisabled(); } catch { /* static controls are not writable */ }
      try { editable = await resolved.locator.isEditable(); } catch { /* static controls are not writable */ }
      if (disabled) failures.push(`${item.fieldName}: control is disabled.`);
      if (!editable && item.mutationType !== 'upload') failures.push(`${item.fieldName}: control is not writable.`);
      resolvedTargets.push({ item, locator: resolved.locator, resolved });
    }
  }
  return { ok: failures.length === 0, failures, targets: resolvedTargets };
}

async function selectExactOption(page, desired) {
  const options = page.getByRole('option', { name: String(desired), exact: true });
  const count = await options.count();
  if (count !== 1) throw new Error(`Expected exactly one option named ${desired}; found ${count}.`);
  await options.click();
}

export async function executeMutationPlan(page, preflight, manifestInfo) {
  const executed = [];
  for (const { item, locator } of preflight.targets) {
    const packageMatch = item.fieldName.match(/^packages\[(\d+)\]\.projectFileLink$/);
    const desired = packageMatch
      ? manifestInfo.manifest.packages[Number(packageMatch[1])].projectFileLink
      : item.fieldName === 'technicalInformationFile' ? manifestInfo.technicalInformationText : manifestInfo.manifest[item.fieldName];
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
      await page.getByTestId('media-upload').setInputFiles(files);
    }
    executed.push(item.fieldName);
  }
  return executed;
}
