"use client";
import { useState, type FormEvent } from "react";
import { Eye, EyeOff, LoaderCircle, LogIn } from "lucide-react";
import { useRouter, useSearchParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export function LoginForm() {
  const [showPassword, setShowPassword] = useState(false);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const router = useRouter();
  const searchParams = useSearchParams();
  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setLoading(true); setError("");
    const form = new FormData(event.currentTarget);
    const supabase = createClient();
    const { error: authError } = await supabase.auth.signInWithPassword({ email: String(form.get("email")), password: String(form.get("password")) });
    if (authError) { setError("The email or password is incorrect. Please try again."); setLoading(false); return; }
    const { data: hasAccess, error: accessError } = await supabase.rpc("has_active_erp_access");
    if (!accessError && !hasAccess) { router.replace("/access-denied"); router.refresh(); return; }
    if (!accessError) await supabase.rpc("record_erp_login");
    const requestedPath = searchParams.get("redirectTo");
    router.replace(requestedPath?.startsWith("/") && !requestedPath.startsWith("//") ? requestedPath : "/dashboard");
    router.refresh();
  }
  return <form className="mt-6 space-y-4" onSubmit={handleSubmit}>
    <div><label className="mb-1.5 block text-sm font-medium" htmlFor="email">Email</label><input className="field" id="email" name="email" type="email" autoComplete="email" required placeholder="name@company.com" disabled={loading}/></div>
    <div><label className="mb-1.5 block text-sm font-medium" htmlFor="password">Password</label><div className="relative"><input className="field pr-11" id="password" name="password" type={showPassword ? "text" : "password"} autoComplete="current-password" required disabled={loading}/><button type="button" className="absolute inset-y-0 right-0 grid w-11 place-items-center text-slate-500 hover:text-slate-800" onClick={() => setShowPassword((value) => !value)} aria-label={showPassword ? "Hide password" : "Show password"}>{showPassword ? <EyeOff size={18}/> : <Eye size={18}/>}</button></div></div>
    {error && <p className="rounded-lg bg-red-50 p-3 text-sm text-red-700" role="alert">{error}</p>}
    <button className="button-primary w-full" disabled={loading}>{loading ? <><LoaderCircle size={17} className="animate-spin"/>Signing in…</> : <><LogIn size={17}/>Sign In</>}</button>
  </form>;
}
