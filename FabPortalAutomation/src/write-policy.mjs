export const FAB_WRITE_AUTOMATION_DISABLED_MESSAGE = 'Fab Portal write automation is disabled. Use an interactive AI agent or manual Fab Portal workflow for listing changes.';

export function assertFabWriteAutomationEnabled(mode, writeAutomationEnabled = false) {
  if (mode !== 'verify' && writeAutomationEnabled !== true) {
    throw new Error(FAB_WRITE_AUTOMATION_DISABLED_MESSAGE);
  }
}
