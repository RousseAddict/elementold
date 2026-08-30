<p align="center">
  <img src="assets/elementold_icon_1024.png" width="120" alt="elementold">
</p>

<h1 align="center">elementold</h1>

<p align="center">
  A Matrix chat client for <b>iOS 6, 7, 8 and 9</b>.<br>
  Written in Swift, from scratch, against the Matrix Client-Server API.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-GPL--3.0-blue.svg" alt="GPL-3.0">
  <img src="https://img.shields.io/badge/iOS-6.0%2B-lightgrey.svg" alt="iOS 6.0+">
  <img src="https://img.shields.io/badge/Swift-5-orange.svg" alt="Swift 5">
</p>

---

## Philosophy

- **Your homeserver, your rules.** Point it at whatever server you already use.
  There is no elementold service, no account to create, no middleman.
- **No SDK.** elementold speaks the [Matrix Client-Server API](https://spec.matrix.org)
  directly over HTTPS. No `matrix-ios-sdk`, no Rust SDK, no `libolm` — none of them
  build for, or run on, hardware this old.
- **No tracking.** No analytics, no crash reporter, no telemetry, no phone-home.
  The only server the app ever contacts is the one you typed in.
- **Your data stays on your device.** Room list, message history, media and
  restored message keys live in the app sandbox. Nothing is ever uploaded anywhere
  except to your homeserver, as ordinary Matrix traffic.
- **Bridges are first-class.** If your homeserver bridges WhatsApp, Messenger,
  Signal or Discord, those conversations show up here, grouped by network.
- **Old hardware deserves good software.** An iPhone 4S is a perfectly capable
  chat device. The only thing that stopped working was the software.

> elementold is an independent project. It is not affiliated with, endorsed by, or
> connected to The Matrix.org Foundation C.I.C., Element (New Vector Ltd), or any
> homeserver operator. "Matrix" and "Element" are trademarks of their respective
> owners and are used here only to describe protocol compatibility.

---

## Features

**Conversations**
- Room list with search, unread badges and age-aware timestamps
- Bridge / Space filtering — WhatsApp, Messenger, Discord and friends in their own buckets
- Invitations: accept or decline
- Start a DM or create a group from the user directory

**Timeline**
- Message grouping, date separators, sender avatars
- Swipe left to reveal timestamps
- Replies, edits, reactions, and deleting your own messages
- Typing indicators and read receipts
- Queued sending — messages leave the composer immediately and retry on their own

**Media**
- Photos: view full-screen with pinch zoom, save to the camera roll, send from library or camera
- Video: poster thumbnails, in-app playback, streaming upload with a progress bar
- Voice messages: record and play, including Ogg/Opus notes from bridged networks
- File attachments: download with progress, preview in place

**Room & account**
- Room settings: name, topic, photo, invite, leave
- Member list
- Account display name and avatar

**Beyond the app**
- Background notifications (opt-in), with an app-icon unread badge
- End-to-end encrypted rooms are **readable** — enter your recovery key and
  history decrypts on device

---

## Install

Prebuilt IPAs live in [`build/`](build/).

| File | Target | Notes |
|---|---|---|
| `build/elementold_ios6.ipa` | iOS 6 – 7 | The shipped build. |

An iOS 8/9 target exists in the build script (`./build.sh ios8`) but is not
currently published.

The IPA is **ad-hoc signed**, so it installs on a jailbroken device
(Filza, `ipainstaller`, AppSync) but not on a stock one. To run on a stock device
you must re-sign it with your own certificate.

On first launch, enter your homeserver URL, username and password. Only
`m.login.password` is supported — no SSO, no OIDC.

---

## Tested on

| Device | OS | Status |
|---|---|---|
| iPhone 4S | iOS 6 | Works |
| iPhone 5 | iOS 7 | Works, full 4-inch screen |

---

## Known limitations

These are real, current, and mostly not fixable from inside the app:

- **You can read encrypted rooms, but you cannot write to them.** Decryption is
  one-way: recovery key → key backup → plaintext. Sending would need a full Olm/Megolm
  implementation and device verification, which is out of scope.
- **No device verification and no cross-signing.** Your session will show as
  unverified to everyone else, and it will stay that way.
- **Restored message keys are stored in a plain file.** The Keychain is unusable
  in an ad-hoc signing pipeline (`SecItemAdd` fails silently without a
  `keychain-access-groups` entitlement), so message keys sit in `Documents/`
  alongside the access token in `UserDefaults`. Do not use this on a device you
  do not control. Both are wiped on sign-out.
- **Encrypted attachments do not render.** Images, audio and files inside
  encrypted rooms arrive as encrypted blobs rather than plain `mxc://` URLs, and
  those are not decrypted yet — the message text is, the attachment is not.
- **No real push notifications.** APNs requires a provisioning profile this
  pipeline does not have. Background delivery is a long-poll kept alive by the
  legacy VoIP background mode — best-effort, and iOS can still evict the app.
- **Search only matches room names**, and only locally. Matrix has no
  "search my rooms" endpoint, and full-text message search is not implemented.
- **No SSO or OIDC login**, no public room directory browsing, no threads,
  no spaces management (spaces are read, and used for grouping, but not edited).

---

## How it works

Four problems had to be solved to make a modern chat protocol work on a 2012 OS:

1. **TLS.** iOS 6 only negotiates CBC cipher suites; modern homeservers require
   AES-GCM, which arrived in iOS 7. Every HTTP request in the app therefore goes
   through a statically linked **libcurl 8.20 + OpenSSL 3.4**, bypassing the
   system TLS stack entirely. A bundled Mozilla CA bundle provides the trust store.

2. **Sync.** Matrix `/sync` is a long-poll: the server holds the request open
   until something happens. That is genuinely push, not polling — one idle socket.
   The whole app is driven off it, and the room list is persisted so a cold start
   resumes with an incremental sync instead of a full one.

3. **Voice notes.** Bridged voice messages arrive as Ogg/Opus, which iOS 6's
   `AVAudioPlayer` cannot decode. **libopus 1.4 and libogg 1.3.5** are vendored and
   compiled to fat static libraries; a small C bridge transcodes Opus to PCM WAV
   on device, once, and caches the result.

4. **Reading encrypted rooms.** No `libolm`, no Rust SDK. Instead a thin C bridge
   over the **OpenSSL EVP** primitives already linked for TLS — HKDF-SHA256,
   HMAC, AES-256-CTR/CBC, X25519 and Ed25519 — implements the read half of the
   stack by hand: recovery key → 4S secret storage → server-side Megolm key
   backup → Megolm ratchet → plaintext. Base64, Base58 and the Megolm ratchet are
   hand-rolled in pure Swift, because Foundation's own base64 is iOS 7+.

---

## Building

Building requires macOS with **Xcode 13.2.1** and both the **Swift 5.6.3** and
**Swift 5.1.5** toolchains installed side by side.

Both targets come from the same source tree, separated by a compile-time flag:

| Target | Flag | Deployment |
|---|---|---|
| iOS 6/7 | `-D IOS6_TARGET` | 7.0, version-min patched to 6.0 |
| iOS 8/9 | `-D IOS8_TARGET` | 8.0 |

```
./build.sh          # both targets
./build.sh ios6     # iOS 6/7 only
./build.sh ios8     # iOS 8/9 only
```

The pipeline compiles with **5.6.3** — the 5.1.5 compiler cannot parse modern SDK
headers — then swaps the bundled Swift runtime dylibs for the **5.1.5** ones, which
are the newest that still run on iOS 6. Swift's ABI stability is what makes that
combination work. The `libswiftMetal` dylib is dropped (Metal does not exist before
iOS 8, and A5/A6 chips never supported it), `LC_VERSION_MIN_IPHONEOS` and
`MinimumOSVersion` are patched down, `voip` is added to `UIBackgroundModes`, and
everything is ad-hoc signed before being zipped into an IPA.

Because the two targets share one DerivedData directory, always run a **clean**
build when switching flags — Swift's incremental compiler will otherwise silently
reuse objects built with the previous flag.

---

## License

elementold is free software, licensed under the **GNU General Public License v3.0**.
See [`LICENSE.txt`](LICENSE.txt) for the full text.

```
Copyright (C) 2026 RousseAddict

This program is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software Foundation,
either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.
```

**On Matrix and licensing.** elementold contains no code from any Matrix project.
It is an independent implementation written against the
[Matrix Specification](https://spec.matrix.org), which is published under
Apache-2.0; implementing a specification does not create a derivative work of it,
so no copyleft obligation flows from Matrix to this project. In particular,
Element's move to AGPL-3.0 does not apply here — no Element or `matrix-ios-sdk`
code is used. GPL-3.0 is chosen freely, and is compatible with every bundled
component below.

Bundled third-party components:

| Component | License | GPL-3.0 compatible |
|---|---|---|
| libcurl 8.20.0 | curl (MIT-like) | Yes |
| OpenSSL 3.4.6 | Apache-2.0 | Yes |
| libopus 1.4 | BSD-3-Clause | Yes |
| libogg 1.3.5 | BSD-3-Clause | Yes |
| Mozilla CA bundle (`cacert.pem`) | MPL-2.0 (data, not code) | Yes |

Note that Apache-2.0 is compatible with GPL **3**, but not with GPL 2 — which is
why this is GPL-3.0-or-later rather than GPL-2.0.
