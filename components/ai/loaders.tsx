"use client";
import dynamic from "next/dynamic";
const Configuration=dynamic(()=>import("./configuration"),{loading:()=> <p className="card p-6">Loading AI configuration…</p>});
const Assistant=dynamic(()=>import("./assistant"),{loading:()=> <p className="card p-6">Loading AI assistant…</p>});
export const AiConfigurationLoader=Configuration;
export const AiAssistantLoader=Assistant;
