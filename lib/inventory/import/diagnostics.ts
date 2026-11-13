import { randomUUID } from "node:crypto";

export const importOperations = {
  list_batches: ["Load recent import batches", "item_import_batches"],
  load_batch: ["Open import batch", "item_import_batches"],
  load_audit: ["Load import audit history", "item_master_admin_activities"],
  find_completed_source: ["Check for an already completed workbook", "completed_item_import_source"],
  load_preview_page: ["Load saved preview page", "item_import_preview_page"],
  load_job: ["Load saved import job", "item_import_jobs"],
  load_progress: ["Load saved import progress", "item_import_job_progress"],
  recovery: ["Check previous import results", "item_import_recovery"],
  stage_workbook: ["Validate and stage workbook", "stage_item_import"],
  refresh_preview: ["Revalidate workbook preview", "refresh_item_import"],
  start_import: ["Approve Item Master import", "start_item_import_job"],
  resume_import: ["Resume Item Master import", "resume_item_import_job"],
  post_chunk: ["Process Item Master batch", "process_item_import_chunk"],
  record_interruption: ["Reconcile interrupted Item Master batch", "record_item_import_chunk_failure"],
  legacy_stock_review: ["Review legacy stock proposal", "review_item_import_stock"],
  legacy_stock_freshness: ["Check legacy stock proposal freshness", "item_import_stock_review_current"],
  load_legacy_stock: ["Load legacy stock proposal", "item_import_stock_proposals"],
} as const;
export type ImportOperation = keyof typeof importOperations;
type QueryResult<T> = { data: T | null; error: { code?: string; message?: string } | null };
export class ImportOperationError extends Error {
  readonly operation: ImportOperation;
  readonly code: string;
  readonly reference: string;
  constructor(operation: ImportOperation, code: string, reference: string, detail?: string) {
    const reason = code === "57014" ? "Database statement timed out. No retry was started."
      : code === "55P03" ? "Another request holds the required database lock."
      : ["PGRST202", "PGRST204", "42P01", "42703", "42883"].includes(code) ? "The database schema does not match this application. Check the required import migrations."
      : detail?.startsWith("Import review required:") ? detail.slice(0, 500)
      : "The database request failed. Inspect this operation in the server logs before retrying.";
    super(`${importOperations[operation][0]} (${importOperations[operation][1]}): ${reason} Code ${code}; reference ${reference}.`);
    this.name = "ImportOperationError";
    this.operation=operation;this.code=code;this.reference=reference;
  }
}
/** Logs identifiers/timings only: never credentials, source rows, SQL details or response bodies. */
export async function runImportQuery<R extends QueryResult<unknown>>(operation: ImportOperation, query: () => PromiseLike<R>, log: (entry: Record<string, unknown>) => void = entry => console.info(JSON.stringify(entry))): Promise<R> {
  const reference = randomUUID(), start = performance.now();
  try {
    const result = await query();
    const code = result.error?.code || (result.error ? "DATABASE" : null);
    log({ event: "item_import_operation", operation, target: importOperations[operation][1], reference, elapsed_ms: Math.round(performance.now() - start), status: code ? "FAILED" : "OK", code });
    if (result.error) throw new ImportOperationError(operation, code!, reference, result.error.message);
    return result;
  } catch (error) {
    if (error instanceof ImportOperationError) throw error;
    log({ event: "item_import_operation", operation, target: importOperations[operation][1], reference, elapsed_ms: Math.round(performance.now() - start), status: "FAILED", code: "TRANSPORT" });
    throw new ImportOperationError(operation, "TRANSPORT", reference);
  }
}
export function importAuditLabel(event: string) {
  return ["IMPORT_ATTEMPT_FAILED", "IMPORT_CHUNK_FAILED", "IMPORT_CHUNK_INTERRUPTED"].includes(event)
    ? "Historical failed attempt — saved audit event, not a new request"
    : event;
}
