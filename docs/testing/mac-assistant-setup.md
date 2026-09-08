# Astra service setup

The Mac relays images to Astra. Astra selects, labels, outlines and reacquires the object; Apple supplies camera/depth and advances the model's pixels between observations.

## Run

Set `OPENAI_API_KEY` in the server environment, then run from the repository root:

```sh
swift run --package-path server RealityGitServer --lan
```

Without `--lan`, the service listens only on localhost. The LAN option listens on port 8080 on all IPv4 interfaces. Keep this unauthenticated hackathon service on a trusted local network.

```sh
curl http://127.0.0.1:8080/health
```

Expected response: `{"status":"ok"}`. Health checks transport; actual model access is exercised by an observation.

## Connect

1. Open the app's Settings button, enter `http://YOUR-MAC.local:8080` or the Mac's private IPv4 address, and connect.
2. Allow local network and camera access if prompted. Camera images go through the Mac to OpenAI for Astra perception.
3. Tap an object or draw around it. The selection's exact source image and LiDAR snapshot stay paired while Astra identifies its outline.
4. Once remembered, move the object about 20–30 cm. Red marks its old place and green follows its current position.
5. Test leaving the frame and returning, then restoring its original position. Record actual results separately from build/test success.

The connection is restored on app launch. Disconnect clears the saved address. Reconnecting clears the selection; reselect after a service restart.

Current images have a 960-pixel long edge. At most one request is active, with a 0.5-second minimum sampling interval. Provider requests use `gpt-6-astra` with `reasoning.effort=low`; the phone allows 25 seconds for transport and retains the exact request source for up to 30 seconds. An old response can build the original reference from its own depth; it can never be drawn directly as a fresh screen overlay. Local tracking advances through a bounded camera history and expires without renewed Astra authority after 10 seconds from the last confirmed source.

If the phone cannot reach `/health`, check the network first. Shared Wi-Fi filtered client traffic in earlier testing; connecting the Mac to the iPhone's Personal Hotspot worked. Reconnect with the Mac's new address after changing networks.
