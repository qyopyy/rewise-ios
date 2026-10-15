# Rewise for iOS

SwiftUI app for sending money between Hungary and the US. It talks to the Rewise backend on your Supabase project (source in `backend/`, details in [BACKEND.md](BACKEND.md)). It opens in demo mode with sample data until you save an access token in Settings.

**Screens**: Home (balances, USD/HUF rate with a chart, recent activity) · Send (amount with two-way quote, Standard or Instant, recipient, review with a 30-minute rate lock, Face ID confirm, live status) · Activity (search and filters) · Recipients (Hungarian IBAN and US routing checks) · Settings (demo mode, backend address, access token).

## What you need

- A Mac with Xcode 16 or later (free on the Mac App Store). Open it once after installing so it can finish setting up. Installing and setting up Xcode needs an administrator account on the Mac.
  No Xcode? GitHub can build the .ipa for Sideloadly instead (see **.ipa from GitHub** below).
- An Apple ID. A free one installs the app on your own iPhone for 7 days at a time; the paid Apple Developer Program ($99 a year) makes it last a year and is needed for TestFlight and the App Store. For the App Store, use an organization account: Apple requires finance apps to come from the company that provides the service.

## Put it on your iPhone

### Easiest: straight from Xcode

1. Unzip the project and double-click `Rewise.xcodeproj`.
2. **Xcode → Settings → Accounts → +** and sign in with your Apple ID.
3. Click the blue **Rewise** project icon → target **Rewise** → **Signing & Capabilities**. Leave **Automatically manage signing** on, set **Team** to your name (Personal Team), and check **Bundle Identifier** (`com.martincsattos.rewise`). If Xcode says it isn't available, change it to something else only you use.
4. Plug in your iPhone with a cable, unlock it and tap **Trust**.
5. Pick your iPhone at the top of the Xcode window and press **Run** (▶ or ⌘R).
6. The first time, the iPhone asks for two things:
   - **Developer Mode**: Settings → Privacy & Security → Developer Mode → on. The iPhone restarts; confirm with **Turn On**.
   - **Trust the developer**: Settings → General → VPN & Device Management → your Apple ID → **Trust**.

   Then press Run again.

With a free Apple ID the app stops opening after 7 days. Plug the iPhone in and press Run again to renew it.

### With Sideloadly

1. In Terminal, go to the unzipped folder and build the .ipa:

   ```sh
   cd ~/Downloads/Rewise-iOS
   bash make-ipa.sh
   ```

   It makes `Rewise.ipa` (unsigned; Sideloadly signs it) with the bundle ID `com.martincsattos.rewise`. To pick another, run `BUNDLE_ID=com.yourname.rewise bash make-ipa.sh`.
2. Install Sideloadly from sideloadly.io and open it.
3. Plug in your iPhone, unlock it and tap **Trust**.
4. Drag `Rewise.ipa` into Sideloadly, type your Apple ID and click **Start**. Enter your Apple ID password and the two-factor code when asked.
5. On the iPhone, turn on **Developer Mode** and **trust the developer** as in step 6 above.

Free Apple ID installs last 7 days. Sideloadly can re-sign the app before then: open it with the iPhone connected and click **Start** again (or turn on its automatic refresh).

### .ipa from GitHub (no Xcode needed)

Every push to `main` builds an unsigned `Rewise.ipa` on GitHub's Macs, with no Apple account needed.

1. Put this project in a GitHub repository, including the hidden `.github` folder (in Finder, ⌘⇧. shows hidden files).
2. Open the repository's **Actions** tab → **iOS build** → the latest run, and download **Rewise-unsigned-ipa** at the bottom of the page.
3. Unzip it and drag `Rewise.ipa` into Sideloadly as in steps 2 to 5 above.

## Connect to your backend

The backend address is already set (`AppConfig.defaultBaseURL`). In the app, open **Settings**, paste the access token into **Access token**, and tap **Save connection**. Demo mode switches off and Home loads your accounts from Supabase.

Make a new token with `select public.rw_create_demo_customer('Name');` in the Supabase SQL editor. How the backend works, and how to turn on real Airwallex payouts, is in [BACKEND.md](BACKEND.md).

## Make a signed .ipa and ship to TestFlight

Needs the paid Apple Developer Program.

1. Set the run destination to **Any iOS Device (arm64)**.
2. **Product → Archive**.
3. In the Organizer window, click **Distribute App**:
   - **App Store Connect** uploads the build for TestFlight and App Review.
   - **Release Testing** exports a signed `.ipa` for iPhones registered in your developer account.

## Build the .ipa on GitHub (no Mac needed)

`.github/workflows/ios.yml` runs on GitHub's Macs. The **Compile check** job runs on every push with no Apple account. The **Signed .ipa** job runs when you start it from the Actions tab, once these one-time steps are done. It needs the paid Apple Developer Program.

**1. Apple Developer account** (developer.apple.com → Certificates, Identifiers & Profiles)

- **Identifiers**: register an App ID with your bundle ID, for example `com.yourcompany.rewise`.
- **Certificates**: create an **Apple Distribution** certificate. Without a Mac, make the signing request with OpenSSL (Linux, Windows Git Bash or WSL):

  ```sh
  openssl genrsa -out rewise.key 2048
  openssl req -new -key rewise.key -out rewise.csr -subj "/emailAddress=you@example.com/CN=Your Name/C=HU"
  # upload rewise.csr, download distribution.cer, then:
  openssl x509 -inform DER -in distribution.cer -out distribution.pem
  openssl pkcs12 -export -legacy -inkey rewise.key -in distribution.pem -out distribution.p12
  ```

  Pick a password when asked; that's `P12_PASSWORD`. Drop `-legacy` on OpenSSL 1.x. Keep `rewise.key` private.
- **Devices**: register the iPhones that should install test builds (needs each phone's UDID).
- **Profiles**: create an **Ad Hoc** profile (for `release-testing`) or an **App Store** profile (for `app-store-connect`) with your App ID and certificate. Download the `.mobileprovision` and note its name.

**2. GitHub repo → Settings → Secrets and variables → Actions**

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `APPLE_TEAM_ID` | 10-character Team ID from your Apple account page |
| Secret | `BUILD_CERTIFICATE_BASE64` | `distribution.p12` as base64 |
| Secret | `P12_PASSWORD` | the .p12 password |
| Secret | `BUILD_PROVISION_PROFILE_BASE64` | the `.mobileprovision` as base64 |
| Secret | `PROVISION_PROFILE_NAME` | the profile's name in the Apple portal |
| Variable | `BUNDLE_ID` | the same bundle ID as the App ID |

Base64 a file: `base64 -w0 file` (Linux), `base64 -i file | pbcopy` (Mac), or in PowerShell `[Convert]::ToBase64String([IO.File]::ReadAllBytes("file")) | Set-Clipboard`.

**3. Build**: Actions → **iOS build** → **Run workflow** → pick the signing method. When it finishes, download **Rewise-N-ipa** from the run page.

**4. Install**: a `release-testing` build installs on the registered iPhones, for example through an install-link service such as Diawi. An `app-store-connect` build is for uploading to TestFlight.

## Project layout

```
Rewise/
  App/          RewiseApp, AppConfig (backend URL, fee constants)
  Models/       Models, money formatting, IBAN and ABA validation
  Networking/   RewiseAPI contract, LiveAPI (your backend), MockAPI (demo), Keychain
  Store/        AppStore: shared state and actions
  Design/       Theme colors and type, shared components, Face ID
  Views/        Home, Activity, Recipients, Settings
  Views/Send/   The four transfer steps
backend/supabase/
  migrations/   Database tables and functions
  functions/api Edge Function the app calls
make-ipa.sh     Unsigned .ipa for Sideloadly
```

New Swift files you add under `Rewise/` join the target automatically.

## Not in this version

- Sign-up, identity checks and login. The app uses a pasted access token for now.
- Push notifications for delivered transfers.
- Crypto. Airwallex doesn't move crypto, and Apple only allows crypto exchange features where the app holds the licenses.
