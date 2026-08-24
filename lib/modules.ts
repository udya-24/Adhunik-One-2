import type { LucideIcon } from "lucide-react";
import {
  Boxes, BriefcaseBusiness, ChartNoAxesCombined, ClipboardCheck,
  ContactRound, Factory, FileText, Gauge, HardHat, Landmark,
  PackageCheck, PanelsTopLeft, Settings, ShieldCheck, ShoppingCart, Smartphone,
  Truck, UsersRound,
} from "lucide-react";

export type ModuleDefinition = {
  label: string;
  title: string;
  href: string;
  phase: string;
  icon: LucideIcon;
};

export const primaryNavigation: ModuleDefinition[] = [
  { label: "Dashboard", title: "Enterprise Foundation", href: "/dashboard", phase: "Phase 1A", icon: Gauge },
  { label: "Employees", title: "Employee & Identity Management", href: "/employees", phase: "Phase 2", icon: UsersRound },
  { label: "Configuration", title: "Enterprise Configuration Engine", href: "/configuration", phase: "Phase 3", icon: PanelsTopLeft },
  { label: "CRM", title: "CRM & Customer Management", href: "/crm", phase: "Phase 4", icon: ContactRound },
  { label: "Sales", title: "Sales & Quotations", href: "/sales", phase: "Phase 5", icon: BriefcaseBusiness },
  { label: "Dispatch", title: "Dispatch", href: "/dispatch", phase: "Phase 6", icon: Truck },
  { label: "Inventory", title: "Inventory Foundation & Enterprise Item Master", href: "/inventory", phase: "Phase 7", icon: Boxes },
  { label: "Purchase", title: "Purchase Management & Procurement Execution", href: "/purchase", phase: "Phase 8", icon: ShoppingCart },
  { label: "Production", title: "Production / Manufacturing", href: "/production", phase: "Phase 9", icon: Factory },
  { label: "Finance", title: "Finance & Accounts", href: "/finance", phase: "Phase 10", icon: Landmark },
  { label: "HR & Payroll", title: "HR & Payroll", href: "/hr-payroll", phase: "Phase 11", icon: HardHat },
  { label: "Documents", title: "Enterprise Document Management System", href: "/documents", phase: "Phase 12", icon: FileText },
  { label: "Approvals", title: "Enterprise Workflow & Approval Engine", href: "/approvals", phase: "Phase 13", icon: ClipboardCheck },
  { label: "Reports & BI", title: "Enterprise Reports & BI", href: "/reports", phase: "Phase 14", icon: ChartNoAxesCombined },
  { label: "Security", title: "Enterprise Security, Identity & Authorization", href: "/security", phase: "Phase 15", icon: ShieldCheck },
  { label: "Mobile", title: "Mobile Applications", href: "/mobile", phase: "Phase 16", icon: Smartphone },
  { label: "Integrations", title: "External Integrations", href: "/integrations", phase: "Phase 17", icon: PackageCheck },
];

export const settingsNavigation: ModuleDefinition = {
  label: "Settings", title: "Settings", href: "/settings", phase: "Phase 1A", icon: Settings,
};

export const quickAccessHrefs = ["/employees", "/configuration", "/crm", "/sales", "/inventory", "/purchase", "/production", "/finance"];

export function getModuleByHref(href: string) {
  return primaryNavigation.find((item) => item.href === href);
}
