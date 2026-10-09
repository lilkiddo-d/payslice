import { NextResponse, type NextRequest } from "next/server";

/**
 * Optional geoblock (off unless BLOCKED_COUNTRIES is set), e.g. BLOCKED_COUNTRIES="US,CU,IR,KP,SY".
 * Uses Vercel's x-vercel-ip-country header; on other hosts set an equivalent header at the edge/CDN.
 */
const blocked = (process.env.BLOCKED_COUNTRIES || "")
  .split(",")
  .map((c) => c.trim().toUpperCase())
  .filter(Boolean);

export function proxy(req: NextRequest) {
  if (blocked.length === 0) return NextResponse.next();
  const country = (req.headers.get("x-vercel-ip-country") || "").toUpperCase();
  if (country && blocked.includes(country) && !req.nextUrl.pathname.startsWith("/blocked")) {
    const url = req.nextUrl.clone();
    url.pathname = "/blocked";
    return NextResponse.rewrite(url);
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/|favicon.ico|blocked).*)"],
};
