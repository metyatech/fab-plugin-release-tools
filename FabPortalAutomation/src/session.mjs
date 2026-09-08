import readline from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import { loadSubmissionManifest } from './manifest.mjs';
import { createStdinManualInteraction } from './manual-handoff.mjs';
import { runPortalAutomation, selectExistingTargetPage } from './portal.mjs';
import { createRunDirectory, writeRunReport } from './report.mjs';
import { connectBrowserTransport } from './transport.mjs';

const SESSION_COMMANDS = new Set(['verify', 'help', 'quit', 'exit', 'q']);

export function normalizeSessionCommand(value) {
  const command = String(value ?? '').trim().toLowerCase();
  if (!SESSION_COMMANDS.has(command)) throw new Error('Unknown session command. This session is read-only; use verify, help, or quit.');
  if (command === 'exit' || command === 'q') return 'quit';
  return command;
}

function resultLine(result) {
  const network = result.network ?? {};
  const blockers = result.blockers?.length ? ` blockers=${result.blockers.length}` : '';
  return `SESSION ${result.mode.toUpperCase()}: ${result.result} `
    + `formatCount=${result.formatBootstrapFormatCount ?? 'unknown'} `
    + `save=${result.saveInvoked} `
    + `mutations=${network.networkMutationRequestsObserved ?? 0}/${network.networkMutationRequestsBlocked ?? 0}${blockers}\n`;
}

async function readCommand(prompt) {
  return normalizeSessionCommand(await prompt.question('fab-session> '));
}

export async function runPortalSession({
  manifestInfo,
  endpoint,
  kind,
  outputDirectory = null,
  input = stdin,
  output = stdout,
  origin = 'https://www.fab.com',
  dependencies = {},
} = {}) {
  const connect = dependencies.connect ?? connectBrowserTransport;
  const run = dependencies.run ?? runPortalAutomation;
  const selectPage = dependencies.selectPage ?? selectExistingTargetPage;
  const createDirectory = dependencies.createDirectory ?? createRunDirectory;
  const writeReport = dependencies.writeReport ?? writeRunReport;
  const browser = await connect({
    endpoint,
    kind,
    manualInteraction: createStdinManualInteraction({ input, output }),
  });
  const context = browser.contexts()[0];
  if (!context) {
    await browser.close().catch(() => undefined);
    throw new Error('The CDP browser has no default context.');
  }

  const prompt = readline.createInterface({ input, output });
  output.write('FAB PORTAL SESSION: READY\n');
  output.write('The browser connection will stay open. This session is read-only. Commands: verify, help, quit.\n');
  let lastResult = null;
  try {
    while (true) {
      let command;
      try {
        command = await readCommand(prompt);
      } catch (error) {
        if (error?.code === 'ERR_USE_AFTER_CLOSE' || /(?:closed|end of input|EOF)/i.test(String(error?.message ?? error))) break;
        output.write(`SESSION INPUT ERROR: ${error instanceof Error ? error.message : String(error)}\n`);
        continue;
      }
      if (command === 'quit') break;
      if (command === 'help') {
        output.write('This session is read-only. Commands: verify, help, quit. Fab listing writes are disabled.\n');
        continue;
      }
      try {
        const page = selectPage(context, manifestInfo.manifest, origin);
        const directory = await createDirectory(outputDirectory ?? undefined, manifestInfo.manifest.pluginName);
        const result = await run({
          manifestInfo,
          mode: command,
          saveDraftAuthorized: false,
          outputDirectory: directory,
          origin,
          context,
          page,
          manualInteraction: createStdinManualInteraction({ input, output, prompt }),
        });
        lastResult = result;
        await writeReport({
          directory,
          result,
          comparison: result.comparison,
          comparisonAfter: result.comparisonAfter,
          network: result.network,
          page: result.page ?? page,
        });
        output.write(resultLine(result));
      } catch (error) {
        output.write(`SESSION COMMAND ERROR: ${error instanceof Error ? error.message : String(error)}\n`);
      }
    }
  } finally {
    prompt.close();
    await browser.close().catch(() => undefined);
  }
  return lastResult?.result === 'FAIL' ? 1 : 0;
}

export async function mainSession({
  manifestPath,
  endpoint,
  kind,
  outputDirectory = null,
  input = stdin,
  output = stdout,
  dependencies = {},
} = {}) {
  const loadManifest = dependencies.loadManifest ?? loadSubmissionManifest;
  const manifestInfo = await loadManifest(manifestPath, { requirePortalReady: false });
  return runPortalSession({ manifestInfo, endpoint, kind, outputDirectory, input, output, dependencies });
}
