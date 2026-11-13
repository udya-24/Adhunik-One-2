export type OpeningSnapshot = {
  row: number; item_id: string | null; unit_id: string | null; source_unit_id: string | null; location_id: string | null; item_code: string;
  item_name: string | null; source_name: string; unit: string | null; location: string | null; source_store: string;
  source_status: string; classification: string | null; excel_quantity: string; rejected_quantity: string;
  quantity_policy?: string; rejected_posting_quantity?: string; existing_rejected?: string; quantity: string | null; existing_quantity: string; delta: string; resulting_quantity: string; resulting_available?: string;
  validation: "VALID" | "INVALID" | "ZERO" | "EXISTING"; errors: string[]; warnings: string[]; inventory: Record<string, unknown> | null;
};
export type OpeningImport = {
  id: string; source_batch_id: string; state: "DRAFT" | "RUNNING" | "PAUSED" | "COMPLETED" | "CANCELLED"; revision: number;
  quantity_policy: "USABLE_OPENING_EXCLUDE_REJECTED" | "USABLE_PLUS_REJECTED"; existing_policy: "SKIP" | "REVIEW"; batch_size: number;
  effective_date: string | null; reason: string | null; approved_by: string | null; approved_at: string | null; request_key: string | null;
  created_by: string; created_at: string; updated_at: string;
};
export type OpeningRow = {
  id: string; import_id: string; source_row: number; raw: Record<string, string>; parser_issues: string[]; quantity_text: string;
  location_override: string | null; is_selected: boolean; item_id: string | null; unit_id: string | null; location_id: string | null;
  rejected_quantity_text: string | null; rejected_quantity: number | null; rejected_transaction_id: string | null; quantity: number | null; snapshot: OpeningSnapshot; state: "DRAFT" | "PENDING" | "POSTED" | "SKIPPED" | "INVALID";
  chunk_id: string | null; transaction_id: string | null; approved_snapshot: OpeningSnapshot | null; posted_at: string | null; posted_by: string | null; skip_reason: string | null;
};
export type OpeningChunk = { id: string; import_id: string; revision: number; sequence: number; state: "PENDING" | "POSTED" | "FAILED" | "SUPERSEDED"; request_key: string; row_count: number; approval: Record<string, unknown>; attempts: number; last_attempt_key: string | null; last_error_code: string | null; last_error: string | null; posted_at: string | null };
export type OpeningProgress = {
  id: string; state: OpeningImport["state"]; revision: number; batch_size: number; quantity_policy: string; existing_policy: string;
  matched?: number; unmatched?: number; ready?: number; total: number; valid: number; invalid: number; existing: number; selected: number; posted: number; skipped: number; pending: number;
  quantities_by_unit: Record<string,{unit:string;selected:string;posted:string;excel?:string;excel_rejected?:string;rejected?:string;available?:string;rejected_posted?:string}>; rejected_rows: number; failed_batches: number; posted_batches: number; percent: number;
  next: {id: string; request_key: string; sequence: number; error: string | null; code: string | null} | null;
};
export type OpeningEdit = {row: number; quantity: string; rejected?: string; selected: boolean; location: string | null};
export type OpeningResult = {import_id?:string;error?: string; success?: string; sheets?: string[]; progress?: OpeningProgress};
