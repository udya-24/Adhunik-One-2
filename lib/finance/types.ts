export type Numeric = number | string;
export type GpLine = {id:string;gp_invoice_id:string;line_number:number;item_id:string;item_code_snapshot:string;item_name_snapshot:string;category_id_snapshot:string|null;category_name_snapshot:string|null;rate:Numeric;quantity:Numeric;cogs_unit_snapshot:Numeric|null;sales_value:Numeric;total_cogs:Numeric|null;gp_value:Numeric|null;gp_percentage:Numeric|null;created_at:string;updated_at:string};
export type GpInvoice = {id:string;company_id:string;customer_company_id:string;financial_year_id:string;invoice_no:string;invoice_date:string;buyer_name_snapshot:string;state_snapshot:string;sales_person_employee_id:string;sales_person_name_snapshot:string;gp_type_id:string;gp_type_snapshot:string;freight:Numeric;status:'DRAFT'|'CONFIRMED'|'CANCELLED';version:number;created_by:string;created_at:string;updated_by:string;updated_at:string;cancellation_reason:string|null};
export type GpRecord = GpInvoice & {items:GpLine[]};
export type GpDocument = {id:string;gp_invoice_id:string;document_type:'BILL'|'LR';file_name:string;storage_path:string;mime_type:string;file_size:number;uploaded_by:string;uploaded_at:string};
export type GpActivity = {id:string;activity_type:string;description:string;created_by:string;created_at:string};
export type MasterOption = {id:string;label:string;detail:string;state?:string;cogs?:Numeric|null;code?:string;category_id?:string;category_name?:string};
export type GpFilters = Record<string,string>;
