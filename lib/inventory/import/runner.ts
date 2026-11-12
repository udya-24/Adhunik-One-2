import type { ImportJobProgress } from "./types.ts";
export type ImportStepResult = { progress?: ImportJobProgress; error?: string };
/** One request per chunk. Never retries a failed/uncertain request automatically. */
export async function runImportChunks(initial: ImportJobProgress, step: (progress: ImportJobProgress) => Promise<ImportStepResult>, onProgress: (progress: ImportJobProgress) => void) {
  let progress = initial;
  onProgress(progress);
  while (progress.state === "RUNNING" && progress.next) {
    const result = await step(progress);
    if (result.error || !result.progress) throw new Error(result.error || "Could not read import progress. Refresh and resume.");
    const next = result.progress;
    if (next.state === "RUNNING" && next.completed <= progress.completed && next.next?.request_key === progress.next.request_key) throw new Error("Import progress did not advance. Refresh progress before resuming.");
    progress = next; onProgress(progress);
  }
  return progress;
}
export function importErrorMessage(code?: string, message?: string) {
  if (code === "57014") return "This batch exceeded the database time limit. Completed batches remain saved. Reduce the batch size and select Retry / Resume Import.";
  if (code === "55P03") return "Another request is working on these records. Wait, refresh progress, and resume.";
  if (code === "23505") return "A duplicate item code or classification was detected. Review the affected batch before resuming.";
  if (code === "23503") return "A required master reference changed. Review Configuration before resuming.";
  if (code === "42501" || message === "FORBIDDEN" || message === "UNAUTHORIZED") return "Active administrator access is required.";
  if (message?.startsWith("Import review required:") || message?.startsWith("Choose a batch size") || message?.startsWith("Select distinct valid") || message?.startsWith("Selected rows contain") || message?.startsWith("Administrator confirmation") || message?.startsWith("Refresh the import page:")) return message.slice(0, 500);
  return "The import request could not be confirmed. Refresh progress before resuming; completed batches will not be reprocessed.";
}
