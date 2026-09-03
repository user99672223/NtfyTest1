# NtfyTest

A tiny SwiftUI test app: it registers the `ntfytest://` URL scheme so tapping an
ntfy notification opens it, and shows network / app / device information.

1. Push to `main` → **Actions** → open the run → download the artifact → unzip it
   to get `NtfyTest-unsigned.ipa`.
2. Install with AltStore or Sideloadly using a free Apple ID. The build expires
   after 7 days; reinstall to renew. AltStore may rewrite the bundle id; the URL
   scheme is unaffected.
3. Install the ntfy app from the App Store and subscribe to the topic shown on
   the Test tab.
4. Tap **Send test notification**, wait for the notification, tap it → the app
   opens and the Test tab shows the URL and the latency.
5. Manual test from any machine:

   ```
   curl -H "Click: ntfytest://open?id=x&t=$(date +%s000)" -d "hi" https://ntfy.sh/<topic>
   ```
