"use client";
import { AlertTriangle } from "lucide-react";
export default function ErrorPage({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return <main className="flex min-h-screen items-center justify-center p-6"><div className="card max-w-md p-8 text-center"><AlertTriangle className="mx-auto mb-4 text-amber-600"/><h1 className="text-xl font-semibold">Something went wrong</h1><p className="mt-2 text-sm text-slate-600">The page could not be loaded. Please try again.</p><button className="button-primary mt-5" onClick={reset}>Try again</button></div></main>;
}
