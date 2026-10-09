import Link from "next/link";

export default function Home() {
  return (
    <main>
      <section className="hero">
        <h1>
          Salaries that stream every second.
          <br />
          <span style={{ color: "var(--accent-2)" }}>A slice that buys stocks.</span>
        </h1>
        <p>
          Payslice lets employers stream stablecoin pay by the second on Robinhood Chain. Workers withdraw whenever
          they want, and can route a slice of every paycheck into tokenized stocks, bought once a week in a batch
          during US market hours.
        </p>
        <div className="row" style={{ marginTop: 20 }}>
          <Link className="btn" href="/employer">
            I&apos;m an employer
          </Link>
          <Link className="btn secondary" href="/worker">
            I get paid
          </Link>
        </div>
      </section>
      <div className="grid cols-3">
        <Feature title="Per-second streams" body="Set a monthly salary, start, end and cliff. Pay accrues every second and is always withdrawable. Earned pay can never be clawed back." />
        <Feature title="Stock slices" body="Choose e.g. 70% stablecoin / 30% stocks across up to five tickers. Slices are pooled weekly and swapped in one batch with Chainlink-bounded slippage." />
        <Feature title="Runway guard" body="Dashboards show burn rate and runway. If a payroll runs dry, streams auto-pause instead of going negative; top up to resume." />
        <Feature title="Equity-style bonuses" body="Grant stock-token bonuses with a cliff and linear vesting. Revoking only returns the unvested part." />
        <Feature title="Payslips" body="Monthly on-chain payslip events, plus a CSV export per worker built straight from chain data." />
        <Feature title="Safety rails" body="48h timelock on every admin change, guardian pause that never blocks withdrawals, oracle staleness + peg checks, bounded loops." />
      </div>
      <div className="alert warn" style={{ marginTop: 24 }}>
        Tokenized stocks are risky and may not be available in your jurisdiction. Payroll creates tax and labour-law
        obligations for employers. Read the <Link href="/risk">risk disclosure</Link> before using Payslice.
      </div>
    </main>
  );
}

function Feature({ title, body }: { title: string; body: string }) {
  return (
    <div className="card">
      <h3>{title}</h3>
      <p className="muted small" style={{ margin: 0 }}>
        {body}
      </p>
    </div>
  );
}
