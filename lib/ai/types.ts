export type FeatureCode = "connection_test" | "general" | "inventory_matching" | "document_extraction" | "finance_analysis" | "sales_assistance" | "purchase_analysis" | "dispatch_assistance";
export type AiSettings = {
 company_id: string; enabled: boolean; default_model: string; model_configuration: Partial<Record<FeatureCode,string>>;
 response_length:"short"|"medium"|"long"; max_output_tokens: number; timeout_ms: number; retry_limit: number;
 daily_budget_usd: string; monthly_budget_usd: string; per_request_limit_usd: string;
 per_user_monthly_usd: string; per_user_daily_requests: number; max_concurrent_requests: number;
 alert_thresholds: number[]; disabled_models: string[]; restricted_users: string[];
 usd_to_inr: number | null; exchange_rate_date: string | null;
 tested_models:Record<string,string>; last_test_at: string | null; last_success_at: string | null; last_test_error: string | null; tested_model: string | null;
 updated_at: string; updated_by: string | null;
};
export type AiFeature = {company_id:string;feature_code:FeatureCode;module_code:string;enabled:boolean;model:string|null;required_permission:string;updated_at:string;feature_configuration:Record<string,unknown>};
export type Pricing = {company_id:string;model_identifier:string;pricing_version:string;effective_date:string;input_price_per_million_tokens:string;cached_input_price_per_million_tokens:string;output_price_per_million_tokens:string;pricing_source:string;created_at:string};
export type Usage = {request_id:string;company_id:string;user_id:string;employee_id:string|null;department_id:string|null;module:string;feature:FeatureCode;model:string;input_tokens:number|null;output_tokens:number|null;cached_input_tokens:number|null;total_tokens:number|null;estimated_cost_usd:string;calculated_cost_usd:string|null;pricing_version:string;status:string;error_category:string|null;duration_ms:number|null;created_at:string;completed_at:string|null;pricing_snapshot:Record<string,unknown>};
export type Candidate = {id:string;item_code:string;item_name:string;description:string|null;model_part_number:string|null};

export type AiBudgetReservation={request_id:string;company_id:string;user_id:string;reserved_cost_usd:string;settled_cost_usd:string|null;status:"pending"|"settled"|"released"|"unknown";created_at:string;expires_at:string;finalized_at:string|null};
