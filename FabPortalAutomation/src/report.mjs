import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

function timestamp() {
  return new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
}

export async function createRunDirectory(outputRoot, pluginName) {
  const root = path.resolve(outputRoot ?? path.resolve('artifacts'));
  const directory = path.join(root, pluginName, 'FabPortalRuns', timestamp());
  await mkdir(path.join(directory, 'screenshots'), { recursive: true });
  return directory;
}

async function writeJson(directory, name, value) {
  await writeFile(path.join(directory, name), `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function markdown(result, comparison, after, network) {
  const counts = comparison?.counts ?? {};
  const afterCounts = after?.counts ?? null;
  return `# Fab Portal Automation Run

- Mode: ${result.mode}
- Result: ${result.result}
- Verification transport: ${result.verificationTransport ?? 'unknown'}
- Observation source: ${result.observationSource ?? 'null'}
- Observation SHA-256: ${result.observationSha256 ?? 'null'}
- Listing: ${result.listingTitle} (${result.listingId})
- Status: ${result.listingStatus ?? 'unknown'}
- Portal mismatch count: ${result.portalMismatchCount ?? comparison?.mismatchCount ?? 0}
- Portal unresolved count: ${result.portalUnresolvedCount ?? comparison?.unresolvedCritical?.length ?? 0}
- Portal verification complete: ${result.portalVerificationComplete ?? false}
- Legacy write diagnostics: interactions=${result.writeInteractionsPerformed}; saveInvoked=${result.saveInvoked}; submitInvoked=${result.submitInvoked}; submitAccepted=${result.submitAccepted}; postSubmitStatus=${result.postSubmitStatus ?? 'null'}
- Write ready: ${result.writeReady}
- Write interactions: ${result.writeInteractionsPerformed}
- Passive attach: ${result.passiveAttach}
- Selected page URL: ${result.selectedPageUrl ?? 'unknown'}
- Target page selection: ${result.targetPageSelectionReason ?? 'unknown'}
- Initial navigation performed: ${result.initialNavigationPerformed}
- Hard navigation count: ${result.hardNavigationCount}
- Automation hard navigation count: ${result.automationHardNavigationCount}
- Reload count: ${result.reloadCount}
- Human-observed navigation count: ${result.humanObservedNavigationCount}
- Manual challenge detected: ${result.manualChallengeDetected}
- Manual challenge handoff count: ${result.manualChallengeHandoffCount}
- Manual challenge completed: ${result.manualChallengeCompleted}
- Manual challenge cancelled: ${result.manualChallengeCancelled}
- Network mutations observed/blocked: ${network?.networkMutationRequestsObserved ?? 0}/${network?.networkMutationRequestsBlocked ?? 0}
- Read-only UI actions: ${result.readOnlyUiActions?.length ? result.readOnlyUiActions.join(', ') : 'none'}

## Comparison before

${Object.entries(counts).map(([key, value]) => `- ${key}: ${value}`).join('\n') || '- not available'}

## Comparison after

${afterCounts ? Object.entries(afterCounts).map(([key, value]) => `- ${key}: ${value}`).join('\n') : '- not applicable'}

## Blockers

${result.blockers.length ? result.blockers.map((item) => `- ${item}`).join('\n') : '- none'}

## Write blockers

${result.writeBlockers?.length ? result.writeBlockers.map((item) => `- ${item}`).join('\n') : '- none'}
`;
}

export async function writeRunReport({ directory, result, comparison, comparisonAfter = null, network, page = null }) {
  await writeJson(directory, 'run.json', {
    schemaVersion: result.schemaVersion,
    mode: result.mode,
    listingId: result.listingId,
    listingTitle: result.listingTitle,
    listingStatus: result.listingStatus,
    manifestSha256: result.manifestSha256,
    verificationTransport: result.verificationTransport ?? null,
    observationSource: result.observationSource ?? null,
    observationSha256: result.observationSha256 ?? null,
    portalReady: result.portalReady,
    comparisonCounts: comparison?.counts ?? null,
    portalMismatchCount: result.portalMismatchCount ?? comparison?.mismatchCount ?? 0,
    portalUnresolvedCount: result.portalUnresolvedCount ?? comparison?.unresolvedCritical?.length ?? 0,
    portalVerificationComplete: result.portalVerificationComplete ?? false,
    plannedMutations: result.plannedMutations,
    executedMutations: result.executedMutations,
    saveInvoked: result.saveInvoked,
    submitInvoked: result.submitInvoked,
    submitAccepted: result.submitAccepted,
    postSubmitStatus: result.postSubmitStatus,
    writeReady: result.writeReady,
    writeBlockers: result.writeBlockers,
    selectedPageUrl: result.selectedPageUrl,
    targetPageSelectionReason: result.targetPageSelectionReason,
    initialNavigationPerformed: result.initialNavigationPerformed,
    hardNavigationCount: result.hardNavigationCount,
    automationHardNavigationCount: result.automationHardNavigationCount,
    reloadCount: result.reloadCount,
    humanObservedNavigationCount: result.humanObservedNavigationCount,
    manualChallengeDetected: result.manualChallengeDetected,
    manualChallengeHandoffCount: result.manualChallengeHandoffCount,
    manualChallengeCompleted: result.manualChallengeCompleted,
    manualChallengeCancelled: result.manualChallengeCancelled,
    passiveAttach: result.passiveAttach,
    readOnlyUiActions: result.readOnlyUiActions,
    writeInteractionsPerformed: result.writeInteractionsPerformed,
    networkMutationRequestsObserved: network?.networkMutationRequestsObserved ?? 0,
    networkMutationRequestsBlocked: network?.networkMutationRequestsBlocked ?? 0,
    result: result.result,
    blockers: result.blockers,
    generatedAtUtc: new Date().toISOString(),
  });
  await writeJson(directory, 'comparison-before.json', comparison ?? { fields: [], counts: {} });
  if (comparisonAfter) await writeJson(directory, 'comparison-after.json', comparisonAfter);
  await writeJson(directory, 'network-summary.json', network ?? { networkMutationRequestsObserved: 0, networkMutationRequestsBlocked: 0, requests: [] });
  await writeFile(path.join(directory, 'RunReport.md'), markdown(result, comparison, comparisonAfter, network), 'utf8');
  if (page) await page.screenshot({ path: path.join(directory, 'screenshots', '01-listing.png'), fullPage: true }).catch(() => undefined);
  return directory;
}
