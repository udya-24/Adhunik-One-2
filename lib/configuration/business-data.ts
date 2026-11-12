import "server-only";import {createClient} from "@/lib/supabase/server";
export async function getNumbering(){const db=await createClient();const [{data:overview},{data:configs}]=await Promise.all([db.rpc("get_numbering_overview"),db.from("numbering_configurations").select("*").order("entity_type")]);return {overview:overview??[],configs:configs??[]}}
export async function getFinancialYears(){const db=await createClient();const {data}=await db.from("financial_years").select("*").is("deleted_at",null).order("start_date",{ascending:false});return data??[]}
export async function getSystemSettings(){const db=await createClient();const {data}=await db.from("system_settings").select("*").order("category").order("key");return data??[]}
export async function getPaymentTerms(){const db=await createClient();const {data}=await db.from("payment_terms").select("*").is("deleted_at",null).order("sort_order").order("name");return data??[]}
