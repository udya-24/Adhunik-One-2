import { redirect } from "next/navigation";import { requireAdmin } from "@/lib/identity/data";
export default async function ConfigurationLayout({children}:{children:React.ReactNode}){try{await requireAdmin()}catch{redirect("/dashboard")}return children}
