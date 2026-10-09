export const metadata = { title: "Not available — Payslice" };

export default function Blocked() {
  return (
    <main style={{ maxWidth: 640 }}>
      <h1>Not available in your region</h1>
      <p className="muted">
        This interface is not offered in your country or region. The smart contracts are public, but this website
        does not serve users from restricted jurisdictions.
      </p>
    </main>
  );
}
