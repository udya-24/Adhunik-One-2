import { cleanJson } from "@/lib/formatting/text";

/** Keep UTF-8 JSON consistent across database/API, browser, server, imports and documents. */
export const utf8Fetch: typeof fetch = async (input, init) => {
  // JSON writes are repaired before persistence; uploads and other binary bodies are untouched.
  let options = init;
  if (typeof init?.body === "string") {
    try { options = { ...init, body: JSON.stringify(cleanJson(JSON.parse(init.body))) }; }
    catch { /* Non-JSON bodies keep their original encoding. */ }
  }
  const response = await fetch(input, options);
  if (!response.headers.get("content-type")?.includes("application/json")) return response;
  const body = await response.clone().text();
  if (!body) return response;
  try {
    const headers = new Headers(response.headers);
    headers.set("content-type", "application/json; charset=utf-8");
    headers.delete("content-length");
    headers.delete("content-encoding");
    return new Response(JSON.stringify(cleanJson(JSON.parse(body))), {
      status: response.status, statusText: response.statusText, headers,
    });
  } catch {
    return new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers });
  }
};
