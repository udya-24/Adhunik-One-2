export class AiError extends Error {
 code:string; status:number;
 constructor(code: string, message: string, status = 400) { super(message);this.code=code;this.status=status; }
}
export function safeError(error: unknown): AiError {
 if (error instanceof AiError) return error;
 const status = typeof error === "object" && error !== null && "status" in error ? Number(error.status) : 0;
 if (status === 401 || status === 403) return new AiError("provider_auth", "OpenAI credentials or model access were rejected. Contact an administrator.", 502);
 if (status === 429) return new AiError("rate_limit", "OpenAI is temporarily rate limited or its quota is unavailable.", 429);
 if (status === 400 || status === 404) return new AiError("model_configuration", "The configured model or request format is unsupported.", 502);
 return new AiError("provider_unconfirmed", "AI request could not be confirmed. Its estimated cost remains reserved for review.", 502);
}
export function configurationError() { return new AiError("not_configured", "API key not configured. Ask an administrator to configure OPENAI_API_KEY on the server.", 503); }
