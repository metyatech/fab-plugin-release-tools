import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { loadSubmissionManifest } from './manifest.mjs';
import { createStdinManualInteraction } from './manual-handoff.mjs';
import { runPortalAutomation } from './portal.mjs';
import { createRunDirectory, writeRunReport } from './report.mjs';

const VERSION = '1.0.0';

function help() {
  return `Fab Publisher Portal automation

Usage:
  pwsh .\\Invoke-FabPortalSubmission.ps1 -ManifestPath <FabPortalSubmission.json> -CdpEndpoint <endpoint>
  pwsh .\\Invoke-FabPortalSubmission.ps1 -ManifestPath <FabPortalSubmission.json> -CdpEndpoint <endpoint> -SaveDraft
  pwsh .\\Invoke-FabPortalSubmission.ps1 -ManifestPath <FabPortalSubmission.json> -CdpEndpoint <endpoint> -SaveDraft -SubmitForReview

Default mode is read-only verification. Save Draft and Submit for review are
explicit, guarded operations. Pending approval listings are never modified and
Cancel submission is never invoked automatically. If a visible Cloudflare
challenge is detected, automation pauses without browser operations until you
complete it manually and press Enter; q + Enter cancels the run.

Options:
  --manifest <path>       FabPortalSubmission.json (required)
  --cdp-endpoint <url>    Existing dedicated Chrome CDP endpoint (required)
  --output <directory>    Artifact root (default: ./artifacts)
  --save-draft            Explicitly authorize Save Draft
  --submit-for-review     Explicitly authorize Submit for review; requires --save-draft
  --json                  Emit one machine-readable result object
  --verbose               Emit additional non-secret diagnostics
  --help, -h              Show this help
  --version, -V           Show the version
`;
}

function parseArgs(argv) {
  const result = { output: null, saveDraft: false, submitForReview: false, json: false, verbose: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help' || arg === '-h') result.help = true;
    else if (arg === '--version' || arg === '-V') result.version = true;
    else if (arg === '--save-draft') result.saveDraft = true;
    else if (arg === '--submit-for-review') result.submitForReview = true;
    else if (arg === '--json') result.json = true;
    else if (arg === '--verbose') result.verbose = true;
    else if (['--manifest', '--cdp-endpoint', '--output'].includes(arg)) {
      const value = argv[++index];
      if (!value || value.startsWith('--')) throw new Error(`${arg} requires a value.`);
      result[arg.slice(2).replaceAll('-', '')] = value;
    } else throw new Error(`Unknown option: ${arg}. Use --help.`);
  }
  if (result.submitForReview && !result.saveDraft) throw new Error('--submit-for-review requires --save-draft.');
  if (!result.help && !result.version && (!result.manifest || !result.cdpendpoint)) throw new Error('--manifest and --cdp-endpoint are required. Use --help.');
  return result;
}

function emit(value, json) {
  if (json) process.stdout.write(`${JSON.stringify(value)}\n`);
  else {
    process.stdout.write(`FAB PORTAL AUTOMATION: ${value.result}\n`);
    process.stdout.write(`Mode: ${value.mode}\nListing: ${value.listingTitle} (${value.listingId})\nStatus: ${value.listingStatus ?? 'unknown'}\n`);
    if (value.comparison?.counts) process.stdout.write(`MATCH=${value.comparison.counts.MATCH ?? 0} MISMATCH=${value.comparison.counts.MISMATCH ?? 0} NOT_VISIBLE=${value.comparison.counts.NOT_VISIBLE ?? 0} NOT_DISCOVERED=${value.comparison.counts.NOT_DISCOVERED ?? 0} NOT_APPLICABLE=${value.comparison.counts.NOT_APPLICABLE ?? 0}\n`);
    process.stdout.write(`writeInteractionsPerformed=${value.writeInteractionsPerformed} Save=${value.saveInvoked} Submit=${value.submitInvoked}\n`);
    process.stdout.write(`submitAccepted=${value.submitAccepted} postSubmitStatus=${value.postSubmitStatus ?? 'null'}\n`);
    process.stdout.write(`writeReady=${value.writeReady} writeBlockers=${value.writeBlockers?.length ?? 0}\n`);
    process.stdout.write(`manualChallengeDetected=${value.manualChallengeDetected} manualChallengeHandoffCount=${value.manualChallengeHandoffCount} manualChallengeCompleted=${value.manualChallengeCompleted} manualChallengeCancelled=${value.manualChallengeCancelled}\n`);
    process.stdout.write(`automationHardNavigationCount=${value.automationHardNavigationCount} humanObservedNavigationCount=${value.humanObservedNavigationCount}\n`);
    process.stdout.write(`networkMutationRequestsObserved=${value.network?.networkMutationRequestsObserved ?? 0} networkMutationRequestsBlocked=${value.network?.networkMutationRequestsBlocked ?? 0}\n`);
    process.stdout.write(`Artifacts: ${value.artifactDirectory}\n`);
    if (value.blockers?.length) process.stdout.write(`Blockers: ${value.blockers.join(' | ')}\n`);
  }
}

export async function main(argv = process.argv.slice(2), dependencies = {}) {
  const args = parseArgs(argv);
  if (args.help) { process.stdout.write(help()); return 0; }
  if (args.version) { process.stdout.write(`${VERSION}\n`); return 0; }
  const loadManifest = dependencies.loadManifest ?? loadSubmissionManifest;
  const createDirectory = dependencies.createDirectory ?? createRunDirectory;
  const writeReportFile = dependencies.writeReport ?? writeRunReport;
  const run = dependencies.run ?? runPortalAutomation;
  const manualInteraction = dependencies.manualInteraction ?? createStdinManualInteraction();
  const manifestInfo = await loadManifest(args.manifest);
  const artifactDirectory = await createDirectory(args.output ?? path.resolve('artifacts'), manifestInfo.manifest.pluginName);
  const mode = args.submitForReview ? 'submit' : args.saveDraft ? 'save' : 'verify';
  const result = await run({ manifestInfo, cdpEndpoint: args.cdpendpoint, mode, saveDraftAuthorized: args.saveDraft, outputDirectory: artifactDirectory, manualInteraction });
  result.artifactDirectory = artifactDirectory;
  await writeReportFile({ directory: artifactDirectory, result, comparison: result.comparison, comparisonAfter: result.comparisonAfter, network: result.network, page: result.page });
  if (result.browser) await result.browser.close().catch(() => undefined);
  delete result.page;
  delete result.browser;
  emit(result, args.json);
  return result.result === 'PASS' ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().then((code) => { process.exitCode = code; }).catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}

export { VERSION, help, parseArgs };
