# ytwchat

End-to-end encrypted messaging: texts, voice notes, photos, files, groups and calls.

- `app/`: Flutter app (Android, iOS) with the Rust encryption core in `app/rust`
- `server/`: Rust backend (Axum, Postgres)
- `site/`: ytwchat.com website (static, no third-party requests)

## Run the server locally

```
cp .env.example .env
docker compose up -d
```

The API listens on `127.0.0.1:8101`.

## Run the app

The app talks to the address in `YTWCHAT_API_URL`. The Android emulator reaches your computer at `10.0.2.2`, which is the default.

```
cd app
flutter run
flutter run --dart-define=YTWCHAT_API_URL=http://192.168.1.20:8101
flutter build apk --release --dart-define=YTWCHAT_API_URL=https://api.example.com
```

Release builds refuse to start with an address that is not `https`.

After changing anything in `app/rust/src/api`, regenerate the bridge:

```
cd app
flutter_rust_bridge_codegen generate
```

## Tests

```
cd server && cargo test
cd app/rust && cargo test --release
cd app && flutter test
```

The end to end test in `app/test/e2e` runs real clients against a running server:

```
cd app/rust && cargo build --release
cd app && flutter test test/e2e --dart-define=YTWCHAT_E2E_SERVER=http://127.0.0.1:8101 --dart-define=YTWCHAT_E2E_LIB=$PWD/rust/target/release/libytwchat_core.so
```

## How encryption works

Every device has its own MLS identity (RFC 9420, OpenMLS). Each chat is an MLS group of all its members' devices. The server only ever sees ciphertext, and stores it until each device has collected it. Photos, voice notes and files are encrypted on the phone with a fresh key per file, and that key travels inside the encrypted message.

On the phone, messages are kept in a SQLCipher database and the MLS key store is encrypted with AES-SIV. Both keys live in the phone's secure keystore, and Android backups are turned off so keys never leave the device.
