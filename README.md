# Bigcapital unofficial iOS app

An **unofficial**, community iPhone app for [Bigcapital](https://github.com/bigcapitalhq/bigcapital) (open-source
accounting). It does the bookkeeping jobs that make sense on a phone. It isn't made or endorsed by Bigcapital
Technologies. It talks to **your own** Bigcapital through its REST API (checked against v0.25.42), using your Bigcapital
address and an API key stored in the iPhone Keychain. This repo contains no data, keys or server addresses.

| Tab | What it does |
|---|---|
| **Glance** | Bank and card balances (books vs bank feed), who owes you, stale feeds, and the count of items needing you. |
| **Needs you** | Bank-feed transactions not yet categorized, with Bigcapital's bank-rule suggestions. Book each as an expense, a distribution/draw, income, a payment of an open invoice (amounts must match), a reimbursable expense (optional), or exclude it with a reason. |
| **Receipt** | Take a photo or pick a PDF, pick the charge, and the receipt is attached in Bigcapital. Meals ask who and the business purpose. |
| **Payroll** *(optional)* | For [openpayroll](#payroll-optional) users: prepare and approve pay runs, mark tax deposits scheduled, view pay stubs. |

### How it books things (and why)

Bigcapital has a few limits the app works around:

- **Receipts can't attach to a categorized bank transaction**, only to Expenses and Manual Journals. So "Expense"
  creates a Bigcapital **Expense** on the bank/card account and matches the bank transaction to it. If a
  bank rule already categorized the charge, attaching a receipt undoes that and rebooks it as an Expense to the same
  account. The categorization is restored if anything fails.
- **A bank transaction can't be categorized to an asset account.** The optional *reimbursable* account (costs you
  re-bill to clients) is booked with a manual journal `BF-<transaction id>`, and the bank line is excluded as handled.
- **Optional "don't write anything before" date.** Handy during a migration: earlier transactions show read-only.

## Get it on your iPhone (TestFlight, built by GitHub Actions)

The same approach as [Trio](https://github.com/nightscout/Trio)'s browser build: GitHub Actions builds it, fastlane match
holds the signing certificates, and it uploads to your own TestFlight. You need an Apple Developer account
($99/year). Public forks get GitHub Actions minutes free.

1. **Fork this repo.** Create an empty **private** repo named `bigcapital-ios-match` under the same owner; fastlane
   stores your encrypted certificates there. To use another name, set it as the repository variable `MATCH_REPO`.
2. **App Store Connect API key:** App Store Connect → Users and Access → Integrations → App Store Connect API →
   Team Keys → "+" with the **App Manager** role. Note the **Issuer ID** and **Key ID** and download the `.p8`.
3. **GitHub token:** a classic personal access token with the `repo` scope.
4. **Secrets:** your fork → Settings → Secrets and variables → Actions → New repository secret:
   - `TEAMID`: your 10-character Apple team ID (developer.apple.com → Membership)
   - `FASTLANE_ISSUER_ID`, `FASTLANE_KEY_ID`: from step 2
   - `FASTLANE_KEY`: the full text of the `.p8`, including the BEGIN and END lines
   - `GH_PAT`: from step 3
   - `MATCH_PASSWORD`: a password you choose; it encrypts the certificates
5. **Actions → "1. Add identifiers" → Run workflow.** This registers `com.<TEAMID>.bigcapital-ios`.
6. **App Store Connect → Apps → "+" → New App:** iOS, bundle ID `com.<TEAMID>.bigcapital-ios`, SKU of your choice,
   and a name that's unique on the App Store (e.g. "Bigcapital unofficial iOS app").
7. **Actions → "2. Create certificates" → Run workflow.** If Apple says you've reached the certificate limit, revoke
   an unused distribution certificate at developer.apple.com → Certificates and run it again.
8. **Actions → "3. Build" → Run workflow.** About 15 minutes later the build is in TestFlight. Add yourself as an
   internal tester and install it with the TestFlight app.

Pushes that change the app rebuild it automatically. A build also runs on the 1st of each month, so a TestFlight build
(valid for 90 days) is always available. "0. Compile check" runs on every push and needs no secrets.

## First launch

1. In Bigcapital: **Preferences → API keys → generate** a key for the phone. It can be revoked any time.
2. In the app: enter your Bigcapital address (e.g. `https://books.example.com`) and the key, then tap **Connect**.
3. Optional settings: the "don't write before" date, a reimbursable-expenses account, and a payroll server.

If Bigcapital is only reachable on a private network (recommended), connect the phone to it first, for example with
the Tailscale app.

## Payroll (optional)

The Payroll tab appears when a payroll server is set. It talks to an **openpayroll** server (a US payroll engine by
the same author, not yet published) over its HTTP API: `/api/payruns`, `/api/payruns/<date>/approve`, `/api/deposits`,
`/api/deposits/<id>/scheduled`. openpayroll has no login of its own, so keep it on a private network. A
"live from" date makes earlier pay runs dry-run previews that can't be approved.

## License

MIT, see `LICENSE`. Bigcapital is a trademark of its owners. This project is independent.
