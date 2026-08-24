"use client"; import { useRouter } from "next/navigation"; import { createClient } from "@/lib/supabase/client";
export function AccessDeniedActions(){const router=useRouter();return <button className="button-primary mt-5" onClick={async()=>{await createClient().auth.signOut();router.replace("/login");router.refresh()}}>Return to Sign In</button>}
