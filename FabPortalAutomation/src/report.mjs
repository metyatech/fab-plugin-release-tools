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
- Listing: ${result.listingTitle} (${result.listingId})
- Status: ${result.listingStatus ?? 'unknown'}
- Save invoked: ${result.saveInvoked}
- Submit invoked: ${result.submitInvoked}
- Write interactions: ${result.writeInteractionsPerformed}
- Network mutations observed/blocked: ${network?.networkMutationRequestsObserved ?? 0}/${network?.networkMutationRequestsBlocked ?? 0}

## Comparison before

${Object.entries(counts).map(([key, value]) => `- ${key}: ${value}`).join('\n') || '- not available'}

## Comparison after

${afterCounts ? Object.entries(afterCounts).map(([key, value]) => `- ${key}: ${value}`).join('\n') : '- not applicable'}

## Planned mutations

${result.plannedMutations.length ? result.plannedMutations.map((item) => `- ${item.fieldName}: ${item.mutationType}`).join('\n') : '- none'}

## Blockers

${result.blockers.length ? result.blockers.map((item) => `- ${item}`).join('\n') : '- none'}
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
    portalReady: result.portalReady,
    comparisonCounts: comparison?.counts ?? null,
    plannedMutations: result.plannedMutations,
    executedMutations: result.executedMutations,
    saveInvoked: result.saveInvoked,
    submitInvoked: result.submitInvoked,
    writeInteractionsPerformed: result.writeInteractionsPerformed,
    networkMutationRequestsObserved: network?.networkMutationRequestsObserved ?? 0,
    networkMutationRequestsBlocked: network?.networkMutationRequestsBlocked ?? 0,
    result: result.result,
    blockers: result.blockers,
    generatedAtUtc: new Date().toISOString(),
  });
  await writeJson(directory, 'comparison-before.json', comparison ?? { fields: [], counts: {} });
  await writeJson(directory, 'mutation-plan.json', result.plannedMutations);
  if (comparisonAfter) await writeJson(directory, 'comparison-after.json', comparisonAfter);
  await writeJson(directory, 'network-summary.json', network ?? { networkMutationRequestsObserved: 0, networkMutationRequestsBlocked: 0, requests: [] });
  await writeFile(path.join(directory, 'RunReport.md'), markdown(result, comparison, comparisonAfter, network), 'utf8');
  if (page) await page.screenshot({ path: path.join(directory, 'screenshots', '01-listing.png'), fullPage: true }).catch(() => undefined);
  return directory;
}
