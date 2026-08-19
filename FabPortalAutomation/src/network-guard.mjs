const SECRET_QUERY_KEYS = /^(?:token|access_token|auth|authorization|signature|sig|key|api[_-]?key)$/i;
const ALWAYS_FORBIDDEN_PATH = /(?:cancel|delete|unlist|remove|replace|upload|publish)/i;
const WRITE_PATH = /(?:save|update|write|submit|create)/i;

function sanitizeUrl(url) {
  const parsed = new URL(url);
  const query = [...parsed.searchParams.keys()]
    .filter((key) => !SECRET_QUERY_KEYS.test(key))
    .map((key) => `${encodeURIComponent(key)}=redacted`)
    .join('&');
  return `${parsed.protocol}//${parsed.hostname}${parsed.pathname}${query ? `?${query}` : ''}`;
}

function graphqlOperation(request) {
  if (!request.method().toUpperCase().includes('POST')) return null;
  try {
    const body = JSON.parse(request.postData() ?? '{}');
    const query = typeof body.query === 'string' ? body.query : '';
    const match = query.match(/\b(?:query|mutation|subscription)\s+([A-Za-z0-9_]+)/i);
    return { type: /\bmutation\b/i.test(query) ? 'mutation' : 'query', name: body.operationName ?? match?.[1] ?? null };
  } catch {
    return null;
  }
}

export function installNetworkGuard(context, { mode = 'verify' } = {}) {
  const state = { mode, phase: null, requests: [], observed: 0, blocked: 0 };
  const handler = async (route) => {
    const request = route.request();
    const method = request.method().toUpperCase();
    const url = new URL(request.url());
    const graph = graphqlOperation(request);
    const fabRequest = url.hostname === 'www.fab.com' || url.hostname.endsWith('.fab.com') || url.hostname === '127.0.0.1' || url.hostname === 'localhost';
    const mutation = method === 'PUT' || method === 'PATCH' || method === 'DELETE' || graph?.type === 'mutation' || WRITE_PATH.test(url.pathname) || ALWAYS_FORBIDDEN_PATH.test(url.pathname);
    const forbidden = method === 'DELETE' || ALWAYS_FORBIDDEN_PATH.test(url.pathname);
    const allowedPhase = state.phase === 'save' && !/submit/i.test(url.pathname) || state.phase === 'submit' && /submit/i.test(url.pathname);
    const block = mutation && (!fabRequest || forbidden || state.mode === 'verify' || !allowedPhase || (graph?.type === 'mutation' && state.phase === null));
    if (fabRequest) {
      state.observed += mutation ? 1 : 0;
      if (state.requests.length < 1000) {
        state.requests.push({
          timestamp: new Date().toISOString(),
          method,
          hostname: url.hostname,
          pathname: url.pathname,
          graphqlOperation: graph,
          mutation,
          blocked: block,
        });
      }
    }
    if (block) {
      state.blocked += 1;
      await route.abort('blockedbyclient');
    } else {
      await route.continue();
    }
  };
  context.route('**/*', handler);
  return {
    setPhase(phase) { state.phase = phase; },
    summary() { return { mode: state.mode, phase: state.phase, networkMutationRequestsObserved: state.observed, networkMutationRequestsBlocked: state.blocked, requests: state.requests.map(({ timestamp, method, hostname, pathname, graphqlOperation, mutation, blocked }) => ({ timestamp, method, hostname, pathname, graphqlOperation, mutation, blocked })) }; },
    async dispose() { await context.unroute('**/*', handler); },
  };
}

export { sanitizeUrl };
