# YES Books (iOS)

A small iPhone app for the bookkeeping jobs that make sense on a phone, for a self-hosted
[Bigcapital](https://github.com/bigcapitalhq/bigcapital) + payroll setup. It talks to a private phone API
(`mobile/` in the owner's private repo). That API is reachable only over Tailscale and holds the Bigcapital key.
**This repo contains no data, keys or server addresses.** You enter the server address in the app on first launch.

- **Glance:** bank and card balances (books vs bank), who owes what, the next payday, tax deposits due.
- **Needs you:** bank transactions the weekly review couldn't book. Book each as an expense, reimbursable travel, a distribution, income, an invoice payment, or exclude it.
- **Receipt:** photo or PDF, then pick the charge, and it's attached in the books. Meals ask who and the business purpose.
- **Payroll:** prepare and approve a pay run, mark tax deposits scheduled, view pay stubs.

Built and shipped to TestFlight by GitHub Actions, the same way as [Trio](https://github.com/nightscout/Trio)'s
browser build: XcodeGen generates the project, fastlane match holds the signing, and fastlane uploads to TestFlight.

## One-time setup

1. **Repos:** this one (public), plus a **private** repo named `yes-books-ios-match` under the same owner. Leave
   the private repo empty; fastlane stores the encrypted certificates there.
2. **App Store Connect API key:** App Store Connect → Users and Access → Integrations → App Store Connect API →
   Team Keys → "+" with the **App Manager** role. Note the **Issuer ID** and **Key ID**, and download the `.p8` (it
   can only be downloaded once).
3. **GitHub token:** a classic personal access token with the `repo` scope, so the build can read and write
   `yes-books-ios-match`.
4. **Secrets:** this repo → Settings → Secrets and variables → Actions → New repository secret:
   - `TEAMID`: your 10-character Apple team ID (developer.apple.com → Membership)
   - `FASTLANE_ISSUER_ID`, `FASTLANE_KEY_ID`: from step 2
   - `FASTLANE_KEY`: the full text of the `.p8` file, including the BEGIN and END lines
   - `GH_PAT`: from step 3
   - `MATCH_PASSWORD`: a password you choose; it encrypts the certificates (keep it in your password manager)
5. **Actions → "1. Add identifiers" → Run workflow.** This registers `com.yachtengineeringservices.yesbooks`.
6. **App Store Connect → Apps → "+" → New App:** iOS, name "YES Books" (any unique name works), bundle ID
   `com.yachtengineeringservices.yesbooks`, SKU `yesbooks`, Full Access.
7. **Actions → "2. Create certificates" → Run workflow.** If Apple says the certificate limit is reached, revoke an
   unused distribution certificate at developer.apple.com → Certificates, and run it again.
8. **Actions → "3. Build YES Books" → Run workflow.** About 15 minutes later the build appears in TestFlight
   (App Store Connect → TestFlight). Add yourself as an internal tester and install it with the TestFlight app.

After that, pushing app changes builds automatically, and a build also runs on the 1st of every month so a
TestFlight build (valid for 90 days) is always available.

## On the phone

Install **Tailscale** and sign in. Open YES Books and enter the server address (`https://<host>.<tailnet>.ts.net:8446`).
Add the app token only if the server has one.
