export const FAB_WRITE_AUTOMATION_DISABLED_MESSAGE = 'Fab Portal write automation is disabled. Use an interactive AI agent or the Fab Portal UI to make listing changes.';
export const FAB_WRITE_AUTOMATION_DISABLED = true;

export function assertFabPortalReadOnly(mode) {
  if (FAB_WRITE_AUTOMATION_DISABLED && mode !== 'verify') throw new Error(FAB_WRITE_AUTOMATION_DISABLED_MESSAGE);
}
