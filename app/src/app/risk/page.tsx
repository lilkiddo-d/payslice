export const metadata = { title: "Risk disclosure — Payslice" };

export default function Risk() {
  return (
    <main className="prose" style={{ maxWidth: 820 }}>
      <h1>Risk disclosure</h1>
      <p>
        Payslice is experimental, non-custodial software. By using it you accept the risks below. Nothing in the app
        is investment, tax, legal or employment advice.
      </p>

      <h2>For employers: payroll obligations stay with you</h2>
      <ul>
        <li>
          Paying wages in stablecoins does <strong>not</strong> remove your legal duties as an employer: income-tax and
          social-security withholding, payroll filings, minimum-wage and overtime rules, pay-frequency and
          pay-statement requirements, contracts, benefits and termination rules all still apply and differ by country,
          state and city.
        </li>
        <li>
          Some jurisdictions restrict or prohibit paying wages in anything other than legal tender, or require the
          worker&apos;s written consent. Check with qualified counsel before streaming salaries.
        </li>
        <li>
          On-chain payslip events and CSV exports are informational; they are not a substitute for statutory pay
          statements unless your accountant confirms otherwise.
        </li>
        <li>
          If your payroll runs out of funds, streams auto-pause and workers do not accrue for the unfunded period.
          Under employment law you may still owe those wages.
        </li>
      </ul>

      <h2>For workers</h2>
      <ul>
        <li>Stablecoins can lose their peg, be frozen by their issuer, or be affected by regulation.</li>
        <li>
          Tokenized stocks are tokens issued by a third party that track a share price. They can carry issuer,
          custody and corporate-action risk, may not grant shareholder rights, can be paused, and may be unavailable
          to residents of some countries (including the United States).
        </li>
        <li>
          Stock slices are converted weekly at market prices during US market hours. Prices move; you may receive less
          value than you put in. Swaps are protected by a maximum slippage against Chainlink prices, so a batch may
          also be delayed if liquidity is thin. Unconverted slices can be refunded after the refund delay.
        </li>
        <li>Receiving pay or stock tokens may be taxable when received and again when sold. Keep your CSV payslips.</li>
      </ul>

      <h2>Smart-contract and operational risk</h2>
      <ul>
        <li>Contracts may contain bugs despite tests and static analysis. Audits reduce but don&apos;t remove risk.</li>
        <li>
          Admin changes go through a 48-hour timelock. A guardian can pause new deposits and conversions; it can never
          block withdrawals of earned pay.
        </li>
        <li>
          Price data comes from Chainlink; stock feeds update 24/5 and pause during corporate actions. Robinhood Chain
          currently has no sequencer-uptime feed.
        </li>
        <li>
          The network is an Ethereum layer 2 with a centralised sequencer; outages or censorship can delay
          transactions.
        </li>
      </ul>

      <h2>No affiliation</h2>
      <p>
        Payslice is independent and is not affiliated with, endorsed or sponsored by Robinhood, any token issuer,
        Chainlink, Uniswap or any exchange. Ticker symbols are used only to identify the tokens.
      </p>
    </main>
  );
}
