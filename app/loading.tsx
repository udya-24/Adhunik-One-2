import { LoaderCircle } from "lucide-react";
export default function Loading() { return <div className="flex min-h-screen items-center justify-center" role="status"><LoaderCircle className="animate-spin text-cyan-700" aria-hidden="true"/><span className="sr-only">Loading application</span></div>; }
