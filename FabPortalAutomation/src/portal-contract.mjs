function normalizeText(value) { return String(value ?? '').replace(/\s+/g, ' ').trim(); }

export const TECHNICAL_ITEM_STATES = ['MATCH', 'STALE', 'MISSING', 'PORTAL_ONLY'];

function technicalItems(value) {
  return String(value ?? '')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const separator = line.indexOf(':');
      if (separator < 1) return { key: line, value: '' };
      return { key: line.slice(0, separator).trim(), value: line.slice(separator + 1).trim() };
    });
}

export function compareTechnicalInformationItems(canonical, portal) {
  const desired = technicalItems(canonical);
  const actual = technicalItems(portal);
  const groupByKey = (items) => {
    const groups = new Map();
    for (const item of items) {
      const key = normalizeText(item.key).toLocaleLowerCase();
      groups.set(key, [...(groups.get(key) ?? []), item]);
    }
    return groups;
  };
  const desiredByKey = groupByKey(desired);
  const actualByKey = groupByKey(actual);
  const items = [];
  for (const [key, expectedItems] of desiredByKey) {
    const currentItems = actualByKey.get(key) ?? [];
    for (const item of expectedItems) {
      const duplicate = expectedItems.length > 1 || currentItems.length > 1;
      const current = currentItems[0];
      const state = !current ? 'MISSING' : duplicate || normalizeText(current.value) !== normalizeText(item.value) ? 'STALE' : 'MATCH';
      items.push({ key: item.key, canonicalValue: item.value, portalValue: currentItems.length > 1 ? currentItems.map((entry) => entry.value) : current?.value ?? null, state });
    }
  }
  for (const [key, currentItems] of actualByKey) {
    if (desiredByKey.has(key)) continue;
    for (const item of currentItems) items.push({ key: item.key, canonicalValue: null, portalValue: item.value, state: 'PORTAL_ONLY' });
  }
  const blocking = items.some((item) => item.state === 'STALE' || item.state === 'MISSING');
  return { items, counts: Object.fromEntries(TECHNICAL_ITEM_STATES.map((state) => [state, items.filter((item) => item.state === state).length])), submissionReady: !blocking, portalOnlyKeys: items.filter((item) => item.state === 'PORTAL_ONLY').map((item) => normalizeText(item.key).toLocaleLowerCase()) };
}

export function verifyAdditionalFileIdentity({ format = null, role = null, uploadCompleted = false, expectedSizeBytes = null, portalSizeBytes = null, localSha256 = null, expectedSha256 = null, portalSha256 = null, sourceFileName = null, displayFileName = null } = {}) {
  const roleMatches = normalizeText(format).toLocaleLowerCase() === 'additional files'
    && normalizeText(role).toLocaleLowerCase() === 'additional file';
  const sizeMatches = Number.isSafeInteger(expectedSizeBytes) && expectedSizeBytes >= 0
    && Number.isSafeInteger(portalSizeBytes) && expectedSizeBytes === portalSizeBytes;
  const localHashVerified = /^[a-f0-9]{64}$/i.test(localSha256 ?? '')
    && (!expectedSha256 || localSha256.toLowerCase() === expectedSha256.toLowerCase());
  const remoteHashPresent = portalSha256 !== null && portalSha256 !== undefined && portalSha256 !== '';
  const remoteHashVerified = !remoteHashPresent
    ? null
    : /^[a-f0-9]{64}$/i.test(portalSha256) && localHashVerified
      ? localSha256.toLowerCase() === portalSha256.toLowerCase()
      : false;
  const nameNormalized = Boolean(sourceFileName && displayFileName)
    && normalizeText(sourceFileName).toLocaleLowerCase() !== normalizeText(displayFileName).toLocaleLowerCase();
  const passed = roleMatches && uploadCompleted && sizeMatches && localHashVerified && remoteHashVerified !== false;
  return {
    state: passed ? 'PASS' : 'FAIL',
    roleMatches,
    uploadCompleted: uploadCompleted === true,
    sizeMatches,
    localHashVerified,
    remoteHashVerified,
    nameNormalized,
    sourceFileName,
    displayFileName,
    identityBasis: passed ? 'role, completed upload, size, and pre-upload local SHA-256; remote hash is reported only when available' : 'identity evidence is incomplete or contradictory',
  };
}

export function assessPublicationPhase({ phase, expectedMode, observedMode = null } = {}) {
  if (phase === 'edit') return { state: 'NOT_APPLICABLE', blocker: false, note: 'Publication mode is selected in the Submit for review flow.' };
  if (phase !== 'submission') return { state: 'UNKNOWN', blocker: false, note: 'Publication mode has not been observed in a recognized phase.' };
  if (!observedMode) return { state: 'MISSING', blocker: true, note: 'Publication mode must be verified in the submission flow.' };
  const normalizeMode = (value) => normalizeText(value).toLocaleLowerCase().replace(/\bactivation\b/g, 'publication');
  return normalizeMode(observedMode) === normalizeMode(expectedMode)
    ? { state: 'MATCH', blocker: false, note: 'Publication mode was verified in the submission flow.' }
    : { state: 'STALE', blocker: true, note: 'Observed publication mode does not match the expected submission mode.' };
}

export function assessDescriptionPreview({ expected, rendered, styleLimitation = false, previewObserved = false } = {}) {
  if (!previewObserved) return { state: 'UNKNOWN', structure: 'UNKNOWN', content: 'UNKNOWN', blocker: false, note: 'Portal Preview has not been visually verified.' };
  if (!expected || !rendered || !Array.isArray(expected.blocks) || !Array.isArray(rendered.blocks)) {
    return { state: 'FAIL', structure: 'FAIL', content: 'UNKNOWN', blocker: true, note: 'Rendered Description structure could not be read.' };
  }
  const expectedTypes = expected.blocks.map((block) => block.type);
  const renderedTypes = rendered.blocks.map((block) => block.type);
  const structure = JSON.stringify(expectedTypes) === JSON.stringify(renderedTypes) ? 'PASS' : 'FAIL';
  const content = JSON.stringify(expected) === JSON.stringify(rendered) ? 'PASS' : 'FAIL';
  if (structure === 'FAIL' || content === 'FAIL') return { state: 'FAIL', structure, content, blocker: true, note: 'Preview collapsed or changed required Description structure or content.' };
  return { state: styleLimitation ? 'PASS_WITH_PLATFORM_STYLE_LIMITATION' : 'PASS', structure: 'PASS', content: 'PASS', blocker: false, note: styleLimitation ? 'Fab controls spacing and typography; meaningful structure and content remain intact.' : 'Preview preserves Description structure and content.' };
}

export function assessRecordedDescriptionPreview(evidence = null) {
  if (!evidence) return { state: 'UNKNOWN', blocker: false, note: 'Portal Preview has not been visually verified.' };
  const checks = ['paragraphsDistinct', 'unorderedListsRendered', 'orderedListsRendered', 'queryExamplesDistinct', 'headingsDistinct', 'linksCorrect'];
  const passed = checks.every((key) => evidence[key] === true);
  if (!passed || evidence.state === 'FAIL') return { state: 'FAIL', blocker: true, note: evidence.note ?? 'Portal Preview content or structure did not pass.' };
  return {
    state: evidence.styleLimitation ? 'PASS_WITH_PLATFORM_STYLE_LIMITATION' : 'PASS',
    blocker: false,
    note: evidence.note ?? 'Portal Preview structure and content were visually verified.',
    evidenceSource: evidence.evidenceSource,
    observedAtUtc: evidence.observedAtUtc,
  };
}

export function deriveReadiness({ artifactReady = false, portalInputsReady = false, portalVerified = false, humanVisualAcceptance = 'UNKNOWN', submitted = false } = {}) {
  return {
    artifactReady: artifactReady === true,
    portalInputsReady: portalInputsReady === true,
    portalVerified: portalVerified === true,
    humanVisualAcceptance,
    readyToSubmit: artifactReady === true && portalInputsReady === true && portalVerified === true && humanVisualAcceptance === 'PASS',
    submitted: submitted === true,
  };
}
