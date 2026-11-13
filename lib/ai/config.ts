import "server-only";
import {configurationError} from "./errors";
export function keyConfigured() { return Boolean(process.env.OPENAI_API_KEY?.trim()); }
export function requireApiKey() { const key=process.env.OPENAI_API_KEY?.trim(); if(!key) throw configurationError(); return key; }

export async function keyFingerprint(){ const {createHash}=await import("node:crypto");return createHash("sha256").update(requireApiKey()).digest("hex"); }
