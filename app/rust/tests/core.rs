use tempfile::TempDir;
use ytwchat_core::api::chat::{ChatCore, DeviceKeyPackage, DeviceRef, Incoming, IncomingKind};
use ytwchat_core::api::media::{decrypt_media, encrypt_media};

struct Phone {
    core: ChatCore,
    user: String,
    device: String,
    path: String,
}

fn phone(dir: &TempDir, user: &str, device: &str) -> Phone {
    let path = dir.path().join(format!("{user}-{device}.db")).to_string_lossy().to_string();
    Phone { core: ChatCore::open(path.clone(), user.into(), device.into()).unwrap(), user: user.into(), device: device.into(), path }
}

fn kp(p: &Phone) -> DeviceKeyPackage {
    DeviceKeyPackage { user_id: p.user.clone(), device_id: p.device.clone(), key_package: p.core.generate_key_packages(1).unwrap().remove(0) }
}

fn text(incoming: Incoming) -> (String, String, String) {
    assert_eq!(incoming.kind, IncomingKind::Application);
    (incoming.sender_user_id.unwrap(), incoming.sender_device_id.unwrap(), String::from_utf8(incoming.plaintext.unwrap()).unwrap())
}

#[test]
fn group_messaging_across_users_and_devices() {
    let dir = TempDir::new().unwrap();
    let alice = phone(&dir, "alice", "phone");
    let alice_laptop = phone(&dir, "alice", "laptop");
    let bob = phone(&dir, "bob", "phone");
    let conv = "0193-conv-1".to_string();

    assert_eq!(alice.core.create_group(conv.clone()).unwrap(), 0);
    let bundle = alice.core.add_members(conv.clone(), vec![kp(&bob), kp(&alice_laptop)]).unwrap();
    assert_eq!(bundle.epoch, 0, "commit applies to epoch 0");
    assert_eq!(bundle.welcome_device_ids, vec!["phone", "laptop"]);
    assert!(alice.core.add_members(conv.clone(), vec![kp(&bob)]).is_err(), "no second change while one is pending");
    assert_eq!(alice.core.confirm_commit(conv.clone()).unwrap(), 1);

    let welcome = bundle.welcome.unwrap();
    assert_eq!(bob.core.join_from_welcome(welcome.clone()).unwrap(), conv);
    assert_eq!(alice_laptop.core.join_from_welcome(welcome).unwrap(), conv);
    assert_eq!(bob.core.group_epoch(conv.clone()).unwrap(), 1);
    assert_eq!(bob.core.members(conv.clone()).unwrap().len(), 3);

    let ct = alice.core.encrypt(conv.clone(), b"Are we still on for Saturday?".to_vec()).unwrap();
    assert!(!ct.windows(8).any(|w| w == b"Saturday"), "ciphertext must not contain plaintext");
    assert_eq!(text(bob.core.process(conv.clone(), ct.clone()).unwrap()), ("alice".into(), "phone".into(), "Are we still on for Saturday?".into()));
    assert_eq!(text(alice_laptop.core.process(conv.clone(), ct).unwrap()).2, "Are we still on for Saturday?");

    let reply = bob.core.encrypt(conv.clone(), b"Yes. I'm bringing the cake.".to_vec()).unwrap();
    assert_eq!(text(alice.core.process(conv.clone(), reply.clone()).unwrap()).0, "bob");
    assert_eq!(text(alice_laptop.core.process(conv.clone(), reply).unwrap()).1, "phone");

    let fp = bob.core.fingerprint().unwrap();
    let seen = alice.core.members(conv.clone()).unwrap().into_iter().find(|m| m.user_id == "bob").unwrap();
    assert_eq!(seen.fingerprint, fp, "members show the same fingerprint the device reports");
}

#[test]
fn server_cannot_swap_devices_in_key_packages() {
    let dir = TempDir::new().unwrap();
    let alice = phone(&dir, "alice", "phone");
    let mallory = phone(&dir, "mallory", "phone");
    let conv = "conv-swap".to_string();
    alice.core.create_group(conv.clone()).unwrap();
    let forged = DeviceKeyPackage { user_id: "bob".into(), device_id: "phone".into(), key_package: mallory.core.generate_key_packages(1).unwrap().remove(0) };
    let err = alice.core.add_members(conv.clone(), vec![forged]).err().unwrap();
    assert!(err.to_string().contains("does not belong"));

    let mut tampered = mallory.core.generate_key_packages(1).unwrap().remove(0);
    let last = tampered.len() - 1;
    tampered[last] ^= 0xff;
    let bad = DeviceKeyPackage { user_id: "mallory".into(), device_id: "phone".into(), key_package: tampered };
    assert!(alice.core.add_members(conv, vec![bad]).is_err(), "tampered key packages are rejected");
}

#[test]
fn concurrent_commits_resolve_by_server_order() {
    let dir = TempDir::new().unwrap();
    let alice = phone(&dir, "alice", "phone");
    let bob = phone(&dir, "bob", "phone");
    let conv = "conv-race".to_string();
    alice.core.create_group(conv.clone()).unwrap();
    let b = alice.core.add_members(conv.clone(), vec![kp(&bob)]).unwrap();
    alice.core.confirm_commit(conv.clone()).unwrap();
    bob.core.join_from_welcome(b.welcome.unwrap()).unwrap();

    let alice_commit = alice.core.self_update(conv.clone()).unwrap();
    let bob_commit = bob.core.self_update(conv.clone()).unwrap();
    assert_eq!(alice_commit.epoch, 1);
    assert_eq!(bob_commit.epoch, 1);

    alice.core.confirm_commit(conv.clone()).unwrap();
    bob.core.discard_commit(conv.clone()).unwrap();
    let c = bob.core.process(conv.clone(), alice_commit.commit).unwrap();
    assert_eq!(c.kind, IncomingKind::Commit);
    assert_eq!(c.epoch, 2);
    assert!(!c.removed_self);
    let msg = bob.core.encrypt(conv.clone(), b"after the race".to_vec()).unwrap();
    assert_eq!(text(alice.core.process(conv, msg).unwrap()).2, "after the race");
}

#[test]
fn state_survives_restart_and_rejects_other_accounts() {
    let dir = TempDir::new().unwrap();
    let alice = phone(&dir, "alice", "phone");
    let bob = phone(&dir, "bob", "phone");
    let conv = "conv-persist".to_string();
    alice.core.create_group(conv.clone()).unwrap();
    let b = alice.core.add_members(conv.clone(), vec![kp(&bob)]).unwrap();
    alice.core.confirm_commit(conv.clone()).unwrap();
    bob.core.join_from_welcome(b.welcome.unwrap()).unwrap();
    let fp = bob.core.fingerprint().unwrap();

    let bob_path = bob.path.clone();
    drop(bob);
    let bob = ChatCore::open(bob_path.clone(), "bob".into(), "phone".into()).unwrap();
    assert_eq!(bob.fingerprint().unwrap(), fp, "same identity after restart");
    assert!(bob.has_group(conv.clone()).unwrap());
    let ct = alice.core.encrypt(conv.clone(), b"still there?".to_vec()).unwrap();
    assert_eq!(text(bob.process(conv, ct).unwrap()).2, "still there?");

    assert!(ChatCore::open(bob_path, "eve".into(), "phone".into()).is_err(), "database is bound to one device");
}

#[test]
fn removed_members_cannot_read_new_messages() {
    let dir = TempDir::new().unwrap();
    let alice = phone(&dir, "alice", "phone");
    let bob = phone(&dir, "bob", "phone");
    let cara = phone(&dir, "cara", "phone");
    let conv = "conv-remove".to_string();
    alice.core.create_group(conv.clone()).unwrap();
    let b = alice.core.add_members(conv.clone(), vec![kp(&bob), kp(&cara)]).unwrap();
    alice.core.confirm_commit(conv.clone()).unwrap();
    let w = b.welcome.unwrap();
    bob.core.join_from_welcome(w.clone()).unwrap();
    cara.core.join_from_welcome(w).unwrap();

    let removal = alice.core.remove_members(conv.clone(), vec![DeviceRef { user_id: "bob".into(), device_id: "phone".into() }]).unwrap();
    alice.core.confirm_commit(conv.clone()).unwrap();
    let c = bob.core.process(conv.clone(), removal.commit.clone()).unwrap();
    assert_eq!(c.kind, IncomingKind::Commit);
    assert!(c.removed_self);
    cara.core.process(conv.clone(), removal.commit).unwrap();
    let secret = alice.core.encrypt(conv.clone(), b"bob is gone".to_vec()).unwrap();
    assert_eq!(text(cara.core.process(conv.clone(), secret.clone()).unwrap()).2, "bob is gone");
    assert!(bob.core.process(conv, secret).is_err(), "removed member cannot decrypt");
}

#[test]
fn last_resort_key_package_is_reusable() {
    let dir = TempDir::new().unwrap();
    let bob = phone(&dir, "bob", "phone");
    let lr = bob.core.last_resort_key_package().unwrap();
    for n in 0..2 {
        let alice = phone(&dir, &format!("a{n}"), "phone");
        let conv = format!("conv-lr-{n}");
        alice.core.create_group(conv.clone()).unwrap();
        let b = alice.core.add_members(conv.clone(), vec![DeviceKeyPackage { user_id: "bob".into(), device_id: "phone".into(), key_package: lr.clone() }]).unwrap();
        alice.core.confirm_commit(conv.clone()).unwrap();
        assert_eq!(bob.core.join_from_welcome(b.welcome.unwrap()).unwrap(), conv);
    }
}

#[test]
fn media_encryption_detects_tampering() {
    let data = vec![42u8; 100_000];
    let enc = encrypt_media(data.clone()).unwrap();
    assert_ne!(enc.ciphertext[..32], data[..32]);
    assert_eq!(decrypt_media(enc.ciphertext.clone(), enc.key.clone(), enc.nonce.clone(), enc.sha256.clone()).unwrap(), data);
    let mut bad = enc.ciphertext.clone();
    bad[10] ^= 1;
    assert!(decrypt_media(bad, enc.key.clone(), enc.nonce.clone(), enc.sha256.clone()).is_err());
    let other = encrypt_media(data).unwrap();
    assert!(decrypt_media(enc.ciphertext, other.key, enc.nonce, enc.sha256).is_err());
}
