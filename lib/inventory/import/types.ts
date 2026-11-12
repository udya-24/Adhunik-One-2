export type MasterResolution = { table: string; name: string; state: "NEW" | "REUSED" | "EMPTY" | "INACTIVE" | "AMBIGUOUS"; code?: string | null; id?: string; record?: Record<string, unknown> };
export type PreviewRow = { row: number; raw: Record<string, string>; action: "CREATE" | "REUSED"; item_id?: string; cogs: number | null; errors: string[]; warnings: string[]; mappings: Record<string, MasterResolution> };
export type ImportPreview = { rows: PreviewRow[]; summary: Record<string, number> };
export type ImportBatch = { id: string; source_name: string; source_sha256: string; source_base64: string; sheet: string; parser_version: string; source_rows: { row: number; raw: Record<string, string>; issues: string[]; warnings: string[] }[]; preview: ImportPreview; revision: number; state: "PREVIEW" | "IMPORTING" | "PARTIAL" | "COMMITTED" | "CANCELLED"; result: Record<string, unknown> | null; created_by: string; created_at: string; committed_by: string | null; committed_at: string | null };
export type StockProposalRow = { row: number; item_id: string; item_code: string; item_name: string; unit: string; unit_mapping_matches: boolean; location: string; raw: Record<string, string>; on_hand: number; reserved: number; damaged: number; available: number; operation: "UNDETERMINED"; proposed_delta: null; resulting_balance: null };
export type StockProposal = { id: string; batch_id: string; revision: number; state: "DRAFT" | "REVIEWED_POSTING_DISABLED" | "REJECTED" | "CANCELLED"; snapshot: StockProposalRow[]; created_by: string; created_at: string; reviewed_by: string | null; reviewed_at: string | null; reason: string | null; posting_enabled: false };
export type ImportRecovery = { source_state: string; source_rows: number; existing_matching: number; existing_conflicting: number; linked_rows: number };
export type ImportJobProgress = {
  id: string; batch_id: string; state: "RUNNING" | "PAUSED" | "COMPLETED"; batch_size: number;
  total: number; created: number; existing: number; completed: number; pending: number; failed: number; percent: number;
  completed_batches: number; failed_batches: number; total_batches: number; atomic_scope: "CHUNK";
  recovery_before: ImportRecovery;
  next: { chunk_number: number; request_key: string; state: "PENDING" | "FAILED"; error_code: string | null; error: string | null } | null;
};
export type ImportJob = { id: string; batch_id: string; request_key: string; preview_revision: number; batch_size: number; state: ImportJobProgress["state"]; selected_count: number; recovery_before: ImportRecovery; approved_by: string; created_at: string; updated_at: string; completed_at: string | null };
export type ImportChunk = { job_id: string; chunk_number: number; request_key: string; state: "PENDING" | "COMPLETED" | "FAILED"; row_count: number; attempts: number; last_attempt_key: string | null; created_count: number; reused_count: number; elapsed_ms: number | null; last_error_code: string | null; last_error: string | null; started_at: string | null; finished_at: string | null };
