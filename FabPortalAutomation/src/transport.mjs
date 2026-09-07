import { chromium } from 'playwright-core';

const REMOTE_DEBUGGING_PERMISSION_ERROR = /(?:timed? ?out|timeout|permission|websocket)/i;

export function validateBrowserWebSocketEndpoint(value) {
  if (typeof value !== 'string' || value.trim() === '') throw new Error('Browser WebSocket endpoint is required.');
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error('Browser WebSocket endpoint must be a valid URL.');
  }
  if (url.protocol !== 'ws:') throw new Error('Browser WebSocket endpoint must use ws://.');
  if (url.hostname !== '127.0.0.1') throw new Error('Browser WebSocket endpoint must use localhost 127.0.0.1.');
  const port = Number(url.port);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Browser WebSocket endpoint must use a valid TCP port.');
  if (!url.pathname.startsWith('/devtools/browser/') || url.pathname.length <= '/devtools/browser/'.length) {
    throw new Error('Browser WebSocket endpoint must target /devtools/browser/.');
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new Error('Browser WebSocket endpoint must not contain credentials, query, or fragment data.');
  }
  return url.toString();
}

export function resolveBrowserTransport({ cdpEndpoint = null, cdpWebSocketEndpoint = null } = {}) {
  if (cdpEndpoint && cdpWebSocketEndpoint) throw new Error('Specify exactly one of a CDP HTTP endpoint or browser WebSocket endpoint.');
  if (cdpWebSocketEndpoint) return { kind: 'websocket', endpoint: validateBrowserWebSocketEndpoint(cdpWebSocketEndpoint) };
  if (cdpEndpoint) return { kind: 'http', endpoint: cdpEndpoint };
  return null;
}

export function isRemoteDebuggingApprovalError(error) {
  return REMOTE_DEBUGGING_PERMISSION_ERROR.test(String(error?.message ?? error));
}

export async function connectBrowserTransport({ endpoint, kind, manualInteraction = null, maxApprovalCycles = 1, connectOverCDP = chromium.connectOverCDP }) {
  const connect = () => connectOverCDP(endpoint, kind === 'websocket' ? { timeout: 5000 } : undefined);
  try {
    return await connect();
  } catch (error) {
    if (kind !== 'websocket' || !isRemoteDebuggingApprovalError(error)) throw error;
    if (!manualInteraction || typeof manualInteraction.waitForConfirmation !== 'function') {
      throw new Error('MANUAL ACTION REQUIRED: Chrome may be waiting for remote debugging permission. Click Allow in the dedicated Chrome, then rerun.');
    }
    for (let cycle = 1; cycle <= maxApprovalCycles; cycle += 1) {
      const decision = await manualInteraction.waitForConfirmation({
        kind: 'remote-debugging-permission',
        cycle,
        maxCycles: maxApprovalCycles,
        message: 'Chrome may be showing the remote debugging permission dialog. Click Allow manually before continuing.',
      });
      if (decision === 'cancelled' || decision === false || decision?.cancelled === true) {
        throw new Error('REMOTE_DEBUGGING_PERMISSION_CANCELLED');
      }
      if (decision !== 'confirmed' && decision !== true && decision?.confirmed !== true) {
        throw new Error('MANUAL ACTION REQUIRED: confirm that Chrome remote debugging permission was allowed, or cancel the run.');
      }
      try {
        return await connect();
      } catch (retryError) {
        if (!isRemoteDebuggingApprovalError(retryError) || cycle === maxApprovalCycles) throw retryError;
      }
    }
  }
  throw new Error('MANUAL ACTION REQUIRED: Chrome remote debugging permission was not confirmed.');
}
