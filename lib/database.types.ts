export type AuditFields = { created_at: string; created_by: string | null; updated_at: string; updated_by: string | null; deleted_at: string | null; deleted_by: string | null };
export type CustomerCompany = AuditFields & { id: string; company_code: string | null; legal_name: string; trade_name: string | null; company_type: string | null; customer_type_id: string | null; gstin: string | null; pan: string | null; primary_email: string | null; primary_phone: string | null; website: string | null; payment_terms: string | null; credit_days: number | null; credit_limit: number | null; notes: string | null; is_active: boolean };
export type CustomerContact = AuditFields & { id: string; customer_company_id: string; contact_name: string; designation: string | null; department: string | null; phone: string | null; alternate_phone: string | null; email: string | null; is_primary: boolean; notes: string | null; is_active: boolean };
export type CustomerAddress = AuditFields & { id: string; customer_company_id: string; address_type: string; address_line_1: string; address_line_2: string | null; city: string | null; district: string | null; state: string | null; postal_code: string | null; country: string; is_primary: boolean; is_active: boolean };
export type Department = AuditFields & { id: string; name: string; code: string | null; description: string | null; is_active: boolean; sort_order: number };
export type Designation = Department;
export type EmploymentType = Department;
export type CustomerType = Department;
export type Team = Department & { department_id: string | null };
export type Employee = AuditFields & { id: string; employee_code: string; full_name: string; first_name: string | null; middle_name: string | null; last_name: string | null; gender: string | null; date_of_birth: string | null; joining_date: string | null; department_id: string | null; designation_id: string | null; reporting_manager_id: string | null; official_email: string | null; personal_email: string | null; phone: string | null; alternate_phone: string | null; blood_group: string | null; photo_url: string | null; emergency_contact_name: string | null; emergency_contact_relationship: string | null; emergency_contact_phone: string | null; employment_type: string | null; employment_type_id: string | null; is_active: boolean; notes: string | null };
export type EmployeeTeam = { id: string; employee_id: string; team_id: string; created_at: string; created_by: string | null };
export type EmployeeAddress = AuditFields & { id: string; employee_id: string; address_type: string; address_line_1: string; address_line_2: string | null; city: string | null; district: string | null; state: string | null; postal_code: string | null; country: string; is_primary: boolean; is_active: boolean };
export type ErpRole = { id: string; code: "ADMIN" | "MANAGER" | "USER"; name: string; description: string | null; is_system: boolean; is_active: boolean; created_at: string; updated_at: string };
export type ErpProfile = { id: string; auth_user_id: string; employee_id: string | null; role_id: string; login_email: string; is_active: boolean; last_login_at: string | null; created_at: string; created_by: string | null; updated_at: string; updated_by: string | null };
export type EmployeeInvitation = { id: string; employee_id: string; auth_user_id: string | null; email: string; role_id: string; status: "PENDING" | "ACCEPTED" | "EXPIRED" | "CANCELLED"; invited_by: string; invited_at: string; accepted_at: string | null; expires_at: string | null; created_at: string; updated_at: string; updated_by: string | null };

type Table<Row, Insert = Partial<Row>, Update = Partial<Row>> = { Row: Row; Insert: Insert; Update: Update; Relationships: [] };
export type Database = { public: { Tables: {
  customer_companies: Table<CustomerCompany, Partial<CustomerCompany> & { legal_name: string }>;
  customer_contacts: Table<CustomerContact, Partial<CustomerContact> & { customer_company_id: string; contact_name: string }>;
  customer_addresses: Table<CustomerAddress, Partial<CustomerAddress> & { customer_company_id: string; address_line_1: string }>;
  departments: Table<Department>; designations: Table<Designation>; teams: Table<Team>; employment_types: Table<EmploymentType>; customer_types: Table<CustomerType>;
  employees: Table<Employee, Partial<Employee> & { full_name: string }>;
  employee_teams: Table<EmployeeTeam, Partial<EmployeeTeam> & { employee_id: string; team_id: string }>;
  employee_addresses: Table<EmployeeAddress, Partial<EmployeeAddress> & { employee_id: string; address_line_1: string }>;
  erp_roles: Table<ErpRole, Partial<ErpRole> & { code: ErpRole["code"]; name: string }>;
  erp_profiles: Table<ErpProfile, Partial<ErpProfile> & { auth_user_id: string; role_id: string; login_email: string }>;
  employee_invitations: Table<EmployeeInvitation, Partial<EmployeeInvitation> & { employee_id: string; email: string; role_id: string; invited_by: string }>;
}; Views: Record<string, never>; Functions: { is_erp_admin: { Args: Record<PropertyKey, never>; Returns: boolean }; has_active_erp_access: { Args: Record<PropertyKey, never>; Returns: boolean }; accept_own_erp_invitation: { Args: Record<PropertyKey, never>; Returns: undefined }; record_erp_login: { Args: Record<PropertyKey, never>; Returns: undefined } }; Enums: Record<string, never>; CompositeTypes: Record<string, never> } };
