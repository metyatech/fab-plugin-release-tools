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
  if (phase === 'media-upload') return (mode === 'save' || mode === 'submit') && intent === 'media-upload';
  if (phase === 'field-update') return (mode === 'save' || mode === 'submit') && intent === 'save';
  if (mode === 'save') return phase === 'save' && intent === 'save';
  if (mode === 'submit') return (phase === 'save' && intent === 'save') || (phase === 'submit' && intent === 'submit');
  return false;
}

export function installNetworkGuard(context, { mode = 'verify' } = {}) {
  const effectiveMode = mode === 'write' ? 'save' : mode;
  const state = { mode: effectiveMode, phase: 'stage', phaseHistory: ['stage'], requests: [], observed: 0, blocked: 0 };
  const handler = async (route) => {
    const request = route.request();
    const method = request.method().toUpperCase();
    const url = new URL(request.url());
    const graph = graphqlOperation(request);
    const intent = classifyRequestIntent(url, method, graph);
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
        blocked: block,
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
