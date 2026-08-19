import readline from 'node:readline/promises';

export const DEFAULT_MANUAL_CHALLENGE_MAX_CYCLES = 3;

export function normalizeManualInteractionDecision(value) {
  if (value === true || value === 'confirmed' || value?.confirmed === true) return 'confirmed';
  if (value === false || value === 'cancelled' || value === 'canceled' || value?.cancelled === true) return 'cancelled';
  return 'invalid';
}

export function createStdinManualInteraction({ input = process.stdin, output = process.stdout } = {}) {
  return {
    async waitForConfirmation({ cycle, maxCycles }) {
      output.write('\nCloudflare challenge detected.\n');
      output.write('Complete it manually in the dedicated Chrome.\n');
      output.write('When the normal Fab listing page is visible, return here and press Enter.\n');
      output.write(`Manual handoff cycle ${cycle} of ${maxCycles}. Press q + Enter to cancel.\n`);
      const prompt = readline.createInterface({ input, output });
      try {
        const answer = await prompt.question('> ');
        const normalized = answer.trim().toLowerCase();
        if (normalized === 'q') return 'cancelled';
        if (normalized === '') return 'confirmed';
        return 'invalid';
      } finally {
        prompt.close();
      }
    },
  };
}
