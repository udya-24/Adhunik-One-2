import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({ request });
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
        },
      },
    },
  );

  const { data: { user } } = await supabase.auth.getUser();
  const isLogin = request.nextUrl.pathname === "/login";
  const isAuthFlow = request.nextUrl.pathname === "/auth/callback" || request.nextUrl.pathname === "/set-password" || request.nextUrl.pathname === "/access-denied";
  const isPublic = isLogin || isAuthFlow || request.nextUrl.pathname.startsWith("/_next") || request.nextUrl.pathname === "/favicon.ico";

  if (!user && !isPublic) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("redirectTo", request.nextUrl.pathname);
    return NextResponse.redirect(url);
  }
  if (user && !isAuthFlow) {
    const { data: hasAccess, error: accessError } = await supabase.rpc("has_active_erp_access");
    if (!accessError && !hasAccess) return NextResponse.redirect(new URL("/access-denied", request.url));
  }
  if (user && isLogin) {
    const { data: hasAccess, error: accessError } = await supabase.rpc("has_active_erp_access");
    return NextResponse.redirect(new URL(!accessError && !hasAccess ? "/access-denied" : "/dashboard", request.url));
  }
  return response;
}
