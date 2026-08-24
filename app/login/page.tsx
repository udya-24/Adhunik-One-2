import { redirect } from "next/navigation";
import { LoginForm } from "@/components/auth/login-form";
import { branding } from "@/lib/branding";
import { createClient } from "@/lib/supabase/server";
import { Suspense } from "react";

export default async function LoginPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (user) redirect("/dashboard");
  return <main className="grid min-h-screen place-items-center bg-slate-100 p-5"><section className="w-full max-w-sm"><div className="mb-7 text-center"><div className="mx-auto mb-4 grid size-12 place-items-center rounded-xl bg-cyan-800 text-lg font-bold text-white">A</div><h1 className="text-2xl font-bold tracking-tight text-slate-900">{branding.shortName}</h1><p className="mt-1 text-sm text-slate-500">{branding.description}</p></div><div className="card p-6 sm:p-7"><h2 className="text-lg font-semibold">Sign in</h2><p className="mt-1 text-sm text-slate-500">Use your company account to continue.</p><Suspense fallback={<p className="mt-6 text-sm text-slate-500">Loading sign in…</p>}><LoginForm /></Suspense></div><p className="mt-5 text-center text-xs text-slate-400">Internal access only</p></section></main>;
}
