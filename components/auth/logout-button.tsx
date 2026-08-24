"use client";
import { LogOut } from "lucide-react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
export function LogoutButton({ compact = false }: { compact?: boolean }) {
  const router = useRouter();
  async function logout() { await createClient().auth.signOut(); router.replace("/login"); router.refresh(); }
  return <button onClick={logout} className="flex w-full items-center gap-3 rounded-lg px-3 py-2 text-sm text-slate-500 hover:bg-red-50 hover:text-red-700" title="Sign out"><LogOut size={18}/>{!compact && <span>Logout</span>}</button>;
}
