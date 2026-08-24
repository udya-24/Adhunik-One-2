"use client";
import { useState } from "react";
import { Sidebar } from "./sidebar";
import { TopHeader } from "./top-header";
export function AppShell({ children, email }: { children: React.ReactNode; email: string }) {
  const [menuOpen, setMenuOpen] = useState(false);
  return <div className="min-h-screen"><Sidebar open={menuOpen} onClose={() => setMenuOpen(false)}/><div className="lg:pl-64"><TopHeader email={email} onMenu={() => setMenuOpen(true)}/><main className="p-4 sm:p-6 lg:p-7">{children}</main></div></div>;
}
