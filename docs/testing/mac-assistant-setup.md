# Mac assistant setup

The Mac service assists localization; it does not yet drive confirmed movement diffs or call Astra.

## Run

From the repository root with the selected Xcode toolchain:

```sh
swift run --package-path server RealityGitServer
```

This binds to localhost on port 8080. For the phone on the same trusted local network, launch explicitly with:

```sh
swift run --package-path server RealityGitServer --lan
```

The LAN option listens on all IPv4 interfaces. This is a local hackathon service without authentication; do not expose it to the Internet. The phone sends sampled camera JPEGs only after you enable the connection. Frames/reference appearance are held in memory, not written to image files by this milestone. Stop the process to clear server state.

Check the service locally:

```sh
curl http://127.0.0.1:8080/health
```

Expected response: `{"status":"ok"}`.

## Connect the phone

1. Open Reality Git and tap **Mac assistance**.
2. Enter `http://YOUR-MAC.local:8080` or the Mac's private IPv4 address with port 8080. You can find the local name with `scutil --get LocalHostName`.
3. Connect and allow local network access if prompted.
4. Select an object. The app sends the selection's exact source frame to initialize the Mac reference, then current sampled observations. A candidate match remains unconfirmed.
5. Stop the server while tracking. Local tracking should continue; record the actual outcome in device validation.

Default sampling is two observations per second with a 640-pixel long edge, not a promised processing rate. Older queued samples are replaced, requests time out after three seconds, and source geometry expires after five seconds. An expired reply cannot supply current geometry. Native camera image axes are preserved across the wire.

If the server restarts and loses the reference, reselect the object explicitly. Physical phone connection, disconnect/recovery and tracker quality must be recorded separately from automated route tests.

If Safari on the phone cannot open the Mac's `/health` URL, troubleshoot network reachability before the tracker. In the device test, shared Wi-Fi filtered traffic between clients despite both devices using the same network. Connecting the Mac to the iPhone's Personal Hotspot allowed observations through. Use the Mac's new address after switching networks, reconnect in the app, and reselect the object. A “Mac tracking active” status currently reports server tracking; it does not prove the phone has recovered its local box.
