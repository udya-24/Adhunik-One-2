"use client";
import { Bell, Menu, Search } from "lucide-react";
import { usePathname } from "next/navigation";
import { getModuleByHref, settingsNavigation } from "@/lib/modules";
import { UserMenu } from "./user-menu";
export function TopHeader({ email, onMenu }: { email: string; onMenu: () => void }) {
  const pathname = usePathname();
  const title = pathname === "/settings" ? settingsNavigation.title : (getModuleByHref(pathname) ?? getModuleByHref(`/${pathname.split("/")[1]}`))?.label ?? "Adhunik ERP";
  return <header className="sticky top-0 z-30 flex h-16 items-center gap-3 border-b border-slate-200 bg-white/95 px-4 backdrop-blur sm:px-6"><button className="p-2 text-slate-600 lg:hidden" onClick={onMenu} aria-label="Open navigation"><Menu size={21}/></button><h1 className="min-w-0 truncate text-base font-semibold text-slate-800">{title}</h1><div className="ml-auto hidden w-full max-w-xs items-center rounded-lg border border-slate-200 bg-slate-50 px-3 sm:flex"><Search size={16} className="text-slate-400"/><input className="w-full bg-transparent px-2 py-2 text-sm outline-none" placeholder="Search (coming soon)" aria-label="Search (coming soon)" disabled/></div><button className="rounded-lg p-2 text-slate-400" title="Notifications coming soon" aria-label="Notifications coming soon" disabled><Bell size={19}/></button><UserMenu email={email}/></header>;
}
