import { CompanyForm } from "@/components/master-data/company-form";
import { PageHeader } from "@/components/ui/page-header";
export default function NewCompanyPage() { return <div className="mx-auto max-w-5xl"><PageHeader title="Add Company" description="Create an external customer company record. Only the legal name is required."/><CompanyForm/></div>; }
