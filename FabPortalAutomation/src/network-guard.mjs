const SECRET_QUERY_KEYS = /^(?:token|access_token|auth|authorization|signature|sig|key|api[_-]?key)$/i;

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
  // The fixture endpoint is intentionally local-only. Production Fab format
  // creation must be admitted only after observing its exact request identity.
  if (method === 'POST' && ['127.0.0.1', 'localhost'].includes(url.hostname) && url.pathname === '/api/create-format') return 'format-create';
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
  return method === 'POST' || method === 'PUT' || method === 'PATCH' || method === 'DELETE'
    ? intent !== 'query'
    : graph?.type === 'mutation';
}

function phaseAllows(mode, phase, intent) {
  if (mode === 'verify') return false;
  if (intent === 'cancel' || intent === 'delete' || intent === 'unlist' || intent === 'publish') return false;
  if (phase === 'listing-prerequisite-save') return mode === 'save' && intent === 'listing-prerequisite-save';
  if (phase === 'listing-license-save') return mode === 'save' && intent === 'listing-license-save';
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

export function installNetworkGuard(context, { mode = 'verify', listingPrerequisite = null, listingLicense = null } = {}) {
  const effectiveMode = mode === 'write' ? 'save' : mode;
  const state = { mode: effectiveMode, phase: 'stage', phaseHistory: ['stage'], requests: [], observed: 0, blocked: 0 };
  const handler = async (route) => {
    const request = route.request();
    const method = request.method().toUpperCase();
    const url = new URL(request.url());
    const graph = graphqlOperation(request);
    let intent = classifyRequestIntent(url, method, graph);
    let validationReason = null;
    if (method === 'PATCH' && (listingLicense || listingPrerequisite)) {
      const postData = request.postData();
      let body = null;
      try { body = postData ? JSON.parse(postData) : null; } catch { /* validation below fails closed */ }
      const validation = listingLicense
        ? validateListingLicensePayload({ method, url: request.url(), body }, listingLicense)
        : validateListingPrerequisitePayload({ method, url: request.url(), body }, listingPrerequisite);
      if (validation.ok) intent = listingLicense ? 'listing-license-save' : 'listing-prerequisite-save';
      else validationReason = validation.reason;
    }
    const fabRequest = url.hostname === 'www.fab.com' || url.hostname.endsWith('.fab.com') || url.hostname === '127.0.0.1' || url.hostname === 'localhost';
    const mutation = isMutation(method, graph, intent);
    const block = mutation && (!fabRequest || !phaseAllows(effectiveMode, state.phase, intent));
    if (fabRequest && mutation) state.observed += 1;
    if (fabRequest && state.requests.length < 1000) {
      state.requests.push({
        timestamp: new Date().toISOString(),
        method,
        hostname: url.hostname,
        pathname: url.pathname,
        graphqlOperation: graph,
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
