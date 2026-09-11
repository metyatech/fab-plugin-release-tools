import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { compareObservation } from './comparison.mjs';
import { loadSubmissionManifest } from './manifest.mjs';
import { createStdinManualInteraction } from './manual-handoff.mjs';
import { loadFabPortalObservation } from './observation.mjs';
import { runPortalAutomation } from './portal.mjs';
import { createRunDirectory, writeRunReport } from './report.mjs';

const VERSION = '0.7.9';

function help() {
  return `Fab Publisher Portal automation

Usage:
  pwsh .\\Invoke-FabPortalSubmission.ps1 -ManifestPath <FabPortalSubmission.json> (-CdpEndpoint <endpoint> | -ObservationPath <FabPortalObservation.json>)

Fab Portal automation supports verify mode only. Listing changes must be made
by an interactive AI agent or the Fab Portal UI. For interactive workflows,
use the agent's authenticated built-in browser, let Fab autosave each field,
reload to confirm persistence, create a structured observation, and verify it.
If a visible Cloudflare challenge is detected, automation pauses without
browser operations until you complete it manually and press Enter; q + Enter
cancels the run.

Acquisition modes (choose exactly one):
  --cdp-endpoint <url>    Existing dedicated Chrome CDP endpoint
  --observation <path>    Structured FabPortalObservation.json collected by a browser

Options:
  --manifest <path>       FabPortalSubmission.json (required)
  --output <directory>    Artifact root (default: ./artifacts)
  --json                  Emit one machine-readable result object
  --verbose               Emit additional non-secret diagnostics
  --help, -h              Show this help
  --version, -V           Show the version

Observation mode compares the supplied facts offline and does not launch or
attach to a browser. Description text stays separate from structured
descriptionLinks, and verification checks the actual persisted HTTPS href for
each configured link. Literal Markdown link text is not a hyperlink. It is not
cryptographic proof of Portal source bytes.
`;
}

function parseArgs(argv) {
  const result = { output: null, json: false, verbose: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help' || arg === '-h') result.help = true;
    else if (arg === '--version' || arg === '-V') result.version = true;
    else if (arg === '--json') result.json = true;
    else if (arg === '--verbose') result.verbose = true;
    else if (['--manifest', '--cdp-endpoint', '--observation', '--output'].includes(arg)) {
      const value = argv[++index];
      if (!value || value.startsWith('--')) throw new Error(`${arg} requires a value.`);
      result[arg.slice(2).replaceAll('-', '')] = value;
    } else throw new Error(`Unknown option: ${arg}. Use --help.`);
  }
  const hasCdp = Boolean(result.cdpendpoint);
  const hasObservation = Boolean(result.observation);
  if (!result.help && !result.version) {
    if (!result.manifest) throw new Error('--manifest is required. Use --help.');
    if (hasCdp === hasObservation) throw new Error('Exactly one of --cdp-endpoint or --observation is required. Use --help.');
  }
  return result;
}

function emit(value, json) {
  if (json) process.stdout.write(`${JSON.stringify(value)}\n`);
  else {
    process.stdout.write(`FAB PORTAL AUTOMATION: ${value.result}\n`);
    process.stdout.write(`Mode: ${value.mode}\nListing: ${value.listingTitle} (${value.listingId})\nStatus: ${value.listingStatus ?? 'unknown'}\n`);
    process.stdout.write(`verificationTransport=${value.verificationTransport ?? 'unknown'} observationSource=${value.observationSource ?? 'null'} observationSha256=${value.observationSha256 ?? 'null'}\n`);
    if (value.comparison?.counts) process.stdout.write(`MATCH=${value.comparison.counts.MATCH ?? 0} MISMATCH=${value.comparison.counts.MISMATCH ?? 0} NOT_VISIBLE=${value.comparison.counts.NOT_VISIBLE ?? 0} NOT_DISCOVERED=${value.comparison.counts.NOT_DISCOVERED ?? 0} NOT_APPLICABLE=${value.comparison.counts.NOT_APPLICABLE ?? 0}\n`);
    process.stdout.write(`portalMismatchCount=${value.portalMismatchCount ?? 0} portalUnresolvedCount=${value.portalUnresolvedCount ?? 0} portalVerificationComplete=${value.portalVerificationComplete ?? false}\n`);
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

function observationResult(manifestInfo, observationInfo, comparison) {
  const { observation } = observationInfo;
  const unresolved = comparison.unresolvedCritical ?? [];
  const blockers = [];
  if (comparison.mismatchCount > 0) blockers.push(`${comparison.mismatchCount} manifest mismatch(es).`);
  if (unresolved.length > 0) blockers.push(`Unresolved portal fields: ${unresolved.join(', ')}.`);
  return {
    schemaVersion: 1,
    mode: 'verify',
    verificationTransport: 'observation',
    observationSource: observation.source,
    observationSha256: observationInfo.observationSha256,
    listingId: observation.listingId,
    listingTitle: observation.listingTitle,
    listingStatus: observation.listingStatus,
    manifestSha256: manifestInfo.manifestSha256,
    portalReady: manifestInfo.manifest.portalReady,
    comparison,
    comparisonAfter: null,
    portalMismatchCount: comparison.mismatchCount,
    portalUnresolvedCount: unresolved.length,
    portalVerificationComplete: comparison.mismatchCount === 0 && unresolved.length === 0,
    plannedMutations: [],
    executedMutations: [],
    saveInvoked: false,
    submitInvoked: false,
    submitAccepted: false,
    postSubmitStatus: null,
    writeInteractionsPerformed: 0,
    dangerousActionsFound: [],
    blockers,
    result: blockers.length === 0 ? 'PASS' : 'FAIL',
    readOnlyUiActions: [],
    writeReady: false,
    writeBlockers: [],
    selectedPageUrl: null,
    targetPageSelectionReason: null,
    initialNavigationPerformed: false,
    hardNavigationCount: 0,
    reloadCount: 0,
    automationHardNavigationCount: 0,
    humanObservedNavigationCount: 0,
    manualChallengeDetected: false,
    manualChallengeHandoffCount: 0,
    manualChallengeCompleted: false,
    manualChallengeCancelled: false,
    passiveAttach: false,
    network: { networkMutationRequestsObserved: 0, networkMutationRequestsBlocked: 0, requests: [] },
  };
}

export async function main(argv = process.argv.slice(2), dependencies = {}) {
  const args = parseArgs(argv);
  if (args.help) { process.stdout.write(help()); return 0; }
  if (args.version) { process.stdout.write(`${VERSION}\n`); return 0; }
  const loadManifest = dependencies.loadManifest ?? loadSubmissionManifest;
  const createDirectory = dependencies.createDirectory ?? createRunDirectory;
  const writeReportFile = dependencies.writeReport ?? writeRunReport;
  const run = dependencies.run ?? runPortalAutomation;
  const loadObservation = dependencies.loadObservation ?? loadFabPortalObservation;
  const compareObservationValue = dependencies.compareObservation ?? compareObservation;
  const manualInteraction = args.observation ? null : dependencies.manualInteraction ?? createStdinManualInteraction();
  const manifestInfo = await loadManifest(args.manifest, { requirePortalReady: false });
  const artifactDirectory = await createDirectory(args.output ?? path.resolve('artifacts'), manifestInfo.manifest.pluginName);
  let result;
  if (args.observation) {
    const observationInfo = await loadObservation(args.observation, manifestInfo);
    result = observationResult(manifestInfo, observationInfo, compareObservationValue(manifestInfo, observationInfo.observation));
  } else {
    result = await run({ manifestInfo, cdpEndpoint: args.cdpendpoint, manualInteraction });
  }
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
