import type { Metadata } from "next";
import type { ReactNode } from "react";
import "./globals.css";
import { Providers } from "./providers";
import { Nav } from "@/components/Nav";

export const metadata: Metadata = {
  title: "Payslice — streaming payroll with stock slices",
  description: "Stream stablecoin salaries per second and auto-convert a slice into tokenized stocks.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <div className="container">
            <Nav />
            {children}
            <footer className="footer">
              Payslice is independent software and is not affiliated with, endorsed by, or sponsored by any broker,
              exchange or chain operator. Not investment, tax or legal advice. <a href="/risk">Risk disclosure</a>.
            </footer>
          </div>
        </Providers>
      </body>
    </html>
  );
}
