"use client";
import { useState } from "react";
import Link from "next/link";
import { ChevronDown, UserRound } from "lucide-react";
import { LogoutButton } from "@/components/auth/logout-button";
export function UserMenu({ email }: { email: string }) {
  const [open, setOpen] = useState(false);
  return <div className="relative"><button onClick={() => setOpen((value) => !value)} className="flex items-center gap-2 rounded-lg p-1.5 hover:bg-slate-50" aria-expanded={open} aria-haspopup="menu"><span className="grid size-8 place-items-center rounded-full bg-cyan-100 text-cyan-800"><UserRound size={16}/></span><span className="hidden max-w-40 truncate text-left text-xs text-slate-600 md:block">{email}</span><ChevronDown size={14} className="text-slate-400"/></button>{open && <div className="absolute right-0 mt-2 w-60 rounded-xl border border-slate-200 bg-white p-2 shadow-lg" role="menu"><p className="truncate border-b border-slate-100 px-3 py-2 text-xs text-slate-500">{email}</p><Link href="/profile" onClick={() => setOpen(false)} className="block rounded-lg px-3 py-2 text-sm text-slate-600 hover:bg-slate-50">Profile</Link><Link href="/settings" onClick={() => setOpen(false)} className="block rounded-lg px-3 py-2 text-sm text-slate-600 hover:bg-slate-50">Settings</Link><LogoutButton/></div>}</div>;
}
