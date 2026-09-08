const SECRET_QUERY_KEYS = /^(?:token|access_token|auth|authorization|signature|sig|key|api[_-]?key)$/i;
const TAG_UID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function sanitizeUrl(url) {
  const parsed = new URL(url);
  const query = [...parsed.searchParams.keys()]
    .filter((key) => !SECRET_QUERY_KEYS.test(key))
    .map((key) => `${encodeURIComponent(key)}=redacted`)
    .join('&');
  return `${parsed.protocol}//${parsed.hostname}${parsed.pathname}${query ? `?${query}` : ''}`;
}

function graphqlOperation(request) {
  if (request.method().toUpperCase() !== 'POST') return null;
  try {
    const body = JSON.parse(request.postData() ?? '{}');
    const query = typeof body.query === 'string' ? body.query.trim() : '';
    if (!query) return null;
    const match = query.match(/^(?:query|mutation|subscription)\s*([A-Za-z0-9_]+)?/i);
    const type = match?.[0].match(/^(query|mutation|subscription)/i)?.[1]?.toLowerCase() ?? (query.startsWith('{') ? 'query' : null);
    if (!type) return null;
    return { type, name: body.operationName ?? match?.[1] ?? null };
  } catch {
    return null;
  }
}

function classifyRequestIntent(url, method, graph) {
  const haystack = `${url.pathname} ${graph?.name ?? ''}`.toLowerCase();
  if (method === 'POST' && url.hostname === 'www.fab.com' && url.pathname.startsWith('/cdn-cgi/challenge-platform/')) return 'security-challenge';
  // The fixture endpoint is intentionally local-only. Production Fab format
  // creation must be admitted only after observing its exact request identity.
  if (method === 'POST' && ['127.0.0.1', 'localhost'].includes(url.hostname) && url.pathname === '/api/create-format') return 'format-create';
  if (method === 'POST' && url.hostname === 'www.fab.com' && /^\/i\/portal\/listings\/[^/]+\/asset-formats\/unreal-engine$/.test(url.pathname)) return 'format-create';
  if (/(?:cancel|abort)/.test(haystack)) return 'cancel';
  if (method === 'DELETE' || /(?:delete|destroy)/.test(haystack)) return 'delete';
  if (/(?:unlist|unpublish)/.test(haystack)) return 'unlist';
  if (/(?:publish|publication)/.test(haystack)) return 'publish';
  if (/(?:media[-_ ]?upload|upload[-_ ]?media)/.test(haystack)) return 'media-upload';
  if (/(?:submit|review)/.test(haystack)) return 'submit';
  if (/(?:save|draft|update|write|edit)/.test(haystack)) return 'save';
  if (graph?.type === 'mutation') return 'other-mutation';
  if (method === 'PUT' || method === 'PATCH') return 'other-mutation';
  return graph?.type === 'query' ? 'query' : 'other';
}

function isMutation(method, graph, intent) {
  if (intent === 'security-challenge') return false;
  return method === 'POST' || method === 'PUT' || method === 'PATCH' || method === 'DELETE'
    ? intent !== 'query'
    : graph?.type === 'mutation';
}

const SAFE_FORMAT_PAYLOAD_KEYS = new Set([
  'listingId', 'listing_id', 'format', 'formatId', 'format_id', 'formatName', 'format_name',
  'engineVersion', 'engine_version', 'versionTitle', 'version_title', 'projectFileLink',
  'project_file_link', 'supportedEngineVersion', 'supported_engine_version', 'platforms',
  'targetPlatforms', 'target_platforms', 'name', 'type', 'operation', 'operationName',
]);

function safePayloadShape(request) {
  const method = request.method().toUpperCase();
  if (!['POST', 'PUT', 'PATCH'].includes(method)) return null;
  const raw = request.postData();
  if (!raw) return { contentType: null, topLevelKeys: [], knownFields: {} };
  let body;
  try { body = JSON.parse(raw); } catch { return { contentType: 'non-json', topLevelKeys: [], knownFields: {} }; }
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { contentType: 'json-non-object', topLevelKeys: [], knownFields: {} };
  const knownFields = {};
  for (const key of SAFE_FORMAT_PAYLOAD_KEYS) {
    if (!Object.prototype.hasOwnProperty.call(body, key)) continue;
    const value = body[key];
    knownFields[key] = Array.isArray(value)
      ? { type: 'array', length: value.length, itemTypes: [...new Set(value.map((item) => typeof item))] }
      : value && typeof value === 'object'
        ? { type: 'object', keys: Object.keys(value).sort() }
        : { type: typeof value, value: typeof value === 'string' ? value : value };
  }
  return { contentType: 'json-object', topLevelKeys: Object.keys(body).sort(), knownFields };
}

function phaseAllows(mode, phase, intent) {
  if (mode === 'verify') return false;
  if (intent === 'cancel' || intent === 'delete' || intent === 'unlist' || intent === 'publish') return false;
  if (phase === 'listing-prerequisite-save') return mode === 'save' && intent === 'listing-prerequisite-save';
  if (phase === 'listing-license-save') return mode === 'save' && intent === 'listing-license-save';
  if (phase === 'listing-license-pricing-save') return mode === 'save' && intent === 'listing-license-pricing-save';
  if (phase === 'listing-tags-save') return (mode === 'save' || mode === 'tags-only') && intent === 'listing-tags-save';
  if (phase === 'format-create') return (mode === 'save' || mode === 'submit') && intent === 'format-create';
  if (phase === 'media-upload') return (mode === 'save' || mode === 'submit') && intent === 'media-upload';
  if (phase === 'field-update') return (mode === 'save' || mode === 'submit') && intent === 'save';
  if (mode === 'save') return phase === 'save' && intent === 'save';
  if (mode === 'submit') return (phase === 'save' && intent === 'save') || (phase === 'submit' && intent === 'submit');
  return false;
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}

function sameJson(left, right) {
  return canonicalJson(left) === canonicalJson(right);
}

function exactObjectKeys(value, keys) {
  return value && typeof value === 'object' && !Array.isArray(value)
    && sameJson(Object.keys(value).sort(), [...keys].sort());
}

export function validateFormatCreatePayload({ method, url, body }, expected) {
  if (!expected || typeof expected !== 'object') return { ok: false, reason: 'No format-create contract was configured.' };
  if (String(method).toUpperCase() !== 'POST') return { ok: false, reason: 'Format creation requires POST.' };
  let parsedUrl;
  try { parsedUrl = new URL(url); } catch { return { ok: false, reason: 'Format-create URL was invalid.' }; }
  if (parsedUrl.origin !== expected.origin) return { ok: false, reason: 'Format-create origin did not match the expected Fab origin.' };
  if (parsedUrl.pathname !== `/i/portal/listings/${expected.listingId}/asset-formats/unreal-engine`) return { ok: false, reason: 'Format-create pathname did not match the exact Unreal Engine target listing path.' };
  if (parsedUrl.search || parsedUrl.hash) return { ok: false, reason: 'Format-create URL contained unexpected query or hash data.' };
  if (!exactObjectKeys(body, [])) return { ok: false, reason: 'Format-create payload was not the observed empty JSON object shape.' };
  return { ok: true };
}

function validateExactListingPayload({ method, url, body }, expected, label) {
  if (!expected || typeof expected !== 'object') return { ok: false, reason: 'No listing prerequisite contract was configured.' };
  if (String(method).toUpperCase() !== 'PATCH') return { ok: false, reason: `${label} persistence requires PATCH.` };
  let parsedUrl;
  try { parsedUrl = new URL(url); } catch { return { ok: false, reason: `${label} URL was invalid.` }; }
  if (parsedUrl.origin !== expected.origin) return { ok: false, reason: `${label} origin did not match the expected Fab origin.` };
  if (parsedUrl.pathname !== `/i/portal/listings/${expected.listingId}`) return { ok: false, reason: `${label} pathname did not match the target listing UUID.` };
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { ok: false, reason: `${label} payload was not a JSON object.` };
  const keys = Object.keys(body).sort();
  const expectedKeys = [...expected.payloadKeys].sort();
  if (JSON.stringify(keys) !== JSON.stringify(expectedKeys)) return { ok: false, reason: `${label} payload keys were not exact.` };
  return { ok: true, expectedKeys };
}

export function validateListingPrerequisitePayload({ method, url, body }, expected) {
  const base = validateExactListingPayload({ method, url, body }, expected, 'Listing prerequisite');
  if (!base.ok) return base;
  if (body.category !== expected.categoryId) return { ok: false, reason: 'Listing prerequisite category identity did not match the expected category.' };
  for (const key of base.expectedKeys) {
    if (key !== 'category' && !sameJson(body[key], expected.unchanged[key])) return { ok: false, reason: `Listing prerequisite sibling field changed unexpectedly: ${key}.` };
  }
  return { ok: true };
}

export function validateListingLicensePayload({ method, url, body }, expected) {
  const base = validateExactListingPayload({ method, url, body }, expected, 'Listing license prerequisite');
  if (!base.ok) return base;
  if (expected.licenseToken !== 'standard') return { ok: false, reason: 'Listing license prerequisite did not declare the exact standard license token.' };
  const explicitStandardPayload = expected.licensePayload === 'standard'
    || (Array.isArray(expected.licensePayload) && expected.licensePayload.length === 1 && expected.licensePayload[0] === 'standard');
  if (!explicitStandardPayload) return { ok: false, reason: 'Listing license prerequisite had no explicit standard-license identity in the observed payload contract.' };
  if (!sameJson(body.licenses, expected.licensePayload)) return { ok: false, reason: 'Listing license prerequisite license payload did not match the observed standard-license shape.' };
  for (const key of base.expectedKeys) {
    if (key !== 'licenses' && !sameJson(body[key], expected.unchanged[key])) return { ok: false, reason: `Listing license prerequisite sibling field changed unexpectedly: ${key}.` };
  }
  return { ok: true };
}

export function validateListingLicensePricingPayload({ method, url, body }, expected) {
  const base = validateExactListingPayload({ method, url, body }, expected, 'Listing license pricing prerequisite');
  if (!base.ok) return base;
  if (expected.licenseToken !== 'standard') return { ok: false, reason: 'Listing license pricing prerequisite did not declare the exact standard license token.' };
  if (!Array.isArray(expected.licensePayload) || expected.licensePayload.length !== 2) return { ok: false, reason: 'Listing license pricing prerequisite did not declare exactly two expected license entries.' };
  if (!Array.isArray(body.licenses) || body.licenses.length !== 2) return { ok: false, reason: 'Listing license pricing payload was not a complete two-entry license configuration.' };
  if (body.licenses.some((item) => !exactObjectKeys(item, ['licenseId', 'priceTierId']))) return { ok: false, reason: 'Listing license pricing payload contained an unexpected license-entry shape.' };
  const [personal, professional] = body.licenses;
  const [expectedPersonal, expectedProfessional] = expected.licensePayload;
  if (!sameJson(personal, expectedPersonal)) return { ok: false, reason: 'Listing license pricing Personal entry did not match the observed exact identity.' };
  if (!sameJson(professional, expectedProfessional)) return { ok: false, reason: 'Listing license pricing Professional entry did not match the observed exact identity.' };
  for (const key of base.expectedKeys) {
    if (key !== 'licenses' && !sameJson(body[key], expected.unchanged[key])) return { ok: false, reason: `Listing license pricing sibling field changed unexpectedly: ${key}.` };
  }
  return { ok: true };
}

export function validateListingTagsPayload({ method, url, body }, expected) {
  const base = validateExactListingPayload({ method, url, body }, expected, 'Listing tags');
  if (!base.ok) return base;
  if (!TAG_UID_PATTERN.test(String(expected.categoryId ?? '')) || body.category !== expected.categoryId) return { ok: false, reason: 'Listing tags category identity did not match the exact unchanged category.' };
  if (!Array.isArray(expected.expectedTagIds) || expected.expectedTagIds.length === 0) return { ok: false, reason: 'Listing tags did not declare an expected non-empty tag identity set.' };
  if (!Array.isArray(body.tags) || body.tags.length !== expected.expectedTagIds.length) return { ok: false, reason: 'Listing tags payload length did not match the expected full tag set.' };
  if (new Set(body.tags).size !== body.tags.length) return { ok: false, reason: 'Listing tags payload contained duplicate identities.' };
  if (!sameJson([...body.tags].sort(), [...expected.expectedTagIds].sort())) return { ok: false, reason: 'Listing tags payload identities did not match the expected full tag set.' };
  for (const key of base.expectedKeys) {
    if (key !== 'category' && key !== 'tags' && !sameJson(body[key], expected.unchanged[key])) return { ok: false, reason: `Listing tags sibling field changed unexpectedly: ${key}.` };
  }
  return { ok: true };
}

export function installNetworkGuard(context, { mode = 'verify', writeAutomationEnabled = false, listingPrerequisite = null, listingLicense = null, listingLicensePricing = null, listingTags = null, formatCreate = null } = {}) {
  const effectiveMode = mode === 'write' ? 'save' : mode;
  const state = { mode: effectiveMode, phase: 'stage', phaseHistory: ['stage'], requests: [], observed: 0, blocked: 0 };
  const handler = async (route) => {
    const request = route.request();
    const method = request.method().toUpperCase();
    const url = new URL(request.url());
    const graph = graphqlOperation(request);
    let intent = classifyRequestIntent(url, method, graph);
    let validationReason = null;
    if (method === 'POST' && state.phase === 'format-create' && formatCreate && intent === 'format-create') {
      const postData = request.postData();
      let body = null;
      try { body = postData ? JSON.parse(postData) : null; } catch { /* validation below fails closed */ }
      const validation = validateFormatCreatePayload({ method, url: request.url(), body }, formatCreate);
      if (validation.ok) intent = 'format-create';
      else {
        validationReason = validation.reason;
        intent = 'other-mutation';
      }
    } else if (method === 'PATCH' && state.phase === 'listing-tags-save' && listingTags) {
      const postData = request.postData();
      let body = null;
      try { body = postData ? JSON.parse(postData) : null; } catch { /* validation below fails closed */ }
      const validation = validateListingTagsPayload({ method, url: request.url(), body }, listingTags);
      if (validation.ok) intent = 'listing-tags-save';
      else validationReason = validation.reason;
    } else if (method === 'PATCH' && (listingLicensePricing || listingLicense || listingPrerequisite)) {
      const postData = request.postData();
      let body = null;
      try { body = postData ? JSON.parse(postData) : null; } catch { /* validation below fails closed */ }
      const validation = listingLicensePricing
        ? validateListingLicensePricingPayload({ method, url: request.url(), body }, listingLicensePricing)
        : listingLicense
          ? validateListingLicensePayload({ method, url: request.url(), body }, listingLicense)
          : validateListingPrerequisitePayload({ method, url: request.url(), body }, listingPrerequisite);
      if (validation.ok) intent = listingLicensePricing ? 'listing-license-pricing-save' : listingLicense ? 'listing-license-save' : 'listing-prerequisite-save';
      else validationReason = validation.reason;
    }
    const fabRequest = url.hostname === 'www.fab.com' || url.hostname.endsWith('.fab.com') || url.hostname === '127.0.0.1' || url.hostname === 'localhost';
    const mutation = isMutation(method, graph, intent);
    const block = mutation && (!fabRequest || !writeAutomationEnabled || !phaseAllows(effectiveMode, state.phase, intent));
    if (fabRequest && mutation) state.observed += 1;
    if (fabRequest && state.requests.length < 1000) {
      state.requests.push({
        timestamp: new Date().toISOString(),
        method,
        hostname: url.hostname,
        pathname: url.pathname,
        graphqlOperation: graph,
        ...(state.phase === 'format-create' ? { payloadShape: safePayloadShape(request) } : {}),
        intent,
        mutation,
        phase: state.phase,
        blocked: block,
        ...(validationReason ? { validationReason } : {}),
      });
    }
    if (block) {
      if (fabRequest) state.blocked += 1;
      await route.abort('blockedbyclient');
    } else {
      await route.continue();
    }
  };
  context.route('**/*', handler);
  return {
    setPhase(phase) {
      state.phase = phase;
      if (state.phaseHistory[state.phaseHistory.length - 1] !== phase) state.phaseHistory.push(phase);
    },
    summary() {
      return {
        mode: state.mode,
        phase: state.phase,
        phaseHistory: [...state.phaseHistory],
        networkMutationRequestsObserved: state.observed,
        networkMutationRequestsBlocked: state.blocked,
        requests: state.requests,
      };
    },
    async dispose() { await context.unroute('**/*', handler); },
  };
}

export { classifyRequestIntent, graphqlOperation, sanitizeUrl };
