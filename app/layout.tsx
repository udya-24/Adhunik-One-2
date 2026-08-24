import type { Metadata } from "next";
import { branding } from "@/lib/branding";
import "./globals.css";

export const metadata: Metadata = { title: { default: branding.name, template: `%s | ${branding.name}` }, description: branding.description };

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
