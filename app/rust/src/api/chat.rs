use anyhow::{anyhow, bail, Context, Result};
use flutter_rust_bridge::frb;
use openmls::prelude::tls_codec::Deserialize as _;
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::RustCrypto;
use openmls_sqlite_storage::{Codec, Connection, SqliteStorageProvider};
use sha2::{Digest, Sha256};
use std::sync::Mutex;

const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
const MAX_KEY_PACKAGES_PER_CALL: u32 = 100;
const MAX_PLAINTEXT: usize = 200 * 1024;

#[derive(Default)]
struct JsonCodec;

impl Codec for JsonCodec {
    type Error = serde_json::Error;

    fn to_vec<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, Self::Error> {
        serde_json::to_vec(value)
    }

    fn from_slice<T: serde::de::DeserializeOwned>(slice: &[u8]) -> Result<T, Self::Error> {
        serde_json::from_slice(slice)
    }
}

struct Provider {
    crypto: RustCrypto,
    storage: SqliteStorageProvider<JsonCodec, Connection>,
}

impl OpenMlsProvider for Provider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = SqliteStorageProvider<JsonCodec, Connection>;

    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }

    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }

    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}

struct Inner {
    provider: Provider,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
    user_id: String,
    device_id: String,
}

#[frb(opaque)]
pub struct ChatCore {
    inner: Mutex<Inner>,
}

pub struct DeviceKeyPackage {
    pub user_id: String,
    pub device_id: String,
    pub key_package: Vec<u8>,
}

pub struct DeviceRef {
    pub user_id: String,
    pub device_id: String,
}

pub struct CommitBundle {
    pub commit: Vec<u8>,
    pub epoch: i64,
    pub welcome: Option<Vec<u8>>,
    pub welcome_device_ids: Vec<String>,
}

pub struct MemberInfo {
    pub user_id: String,
    pub device_id: String,
    pub fingerprint: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IncomingKind {
    Application,
    Commit,
    Proposal,
    Ignored,
}

pub struct Incoming {
    pub kind: IncomingKind,
    pub sender_user_id: Option<String>,
    pub sender_device_id: Option<String>,
    pub plaintext: Option<Vec<u8>>,
    pub epoch: i64,
    pub removed_self: bool,
}

impl Incoming {
    fn bare(kind: IncomingKind, epoch: i64) -> Self {
        Self { kind, sender_user_id: None, sender_device_id: None, plaintext: None, epoch, removed_self: false }
    }
}

fn identity_string(user_id: &str, device_id: &str) -> String {
    format!("{user_id}:{device_id}")
}

fn parse_identity(credential: &Credential) -> Result<(String, String)> {
    let basic = BasicCredential::try_from(credential.clone()).map_err(|_| anyhow!("unsupported credential type"))?;
    let raw = std::str::from_utf8(basic.identity()).context("credential identity is not text")?;
    let (user, device) = raw.split_once(':').ok_or_else(|| anyhow!("credential identity is malformed"))?;
    if user.is_empty() || device.is_empty() || device.contains(':') {
        bail!("credential identity is malformed");
    }
    Ok((user.to_string(), device.to_string()))
}

fn fingerprint_of(public_key: &[u8]) -> String {
    let digest = Sha256::digest(public_key);
    hex::encode(&digest[..16])
        .as_bytes()
        .chunks(4)
        .map(|c| std::str::from_utf8(c).unwrap_or(""))
        .collect::<Vec<_>>()
        .join(" ")
}

fn group_id(conversation_id: &str) -> Result<GroupId> {
    if conversation_id.is_empty() || conversation_id.len() > 64 {
        bail!("invalid conversation id");
    }
    Ok(GroupId::from_slice(conversation_id.as_bytes()))
}

fn capabilities() -> Capabilities {
    Capabilities::new(None, Some(&[CIPHERSUITE]), Some(&[ExtensionType::LastResort]), None, Some(&[CredentialType::Basic]))
}

fn create_config() -> MlsGroupCreateConfig {
    MlsGroupCreateConfig::builder()
        .ciphersuite(CIPHERSUITE)
        .capabilities(capabilities())
        .use_ratchet_tree_extension(true)
        .max_past_epochs(5)
        .padding_size(256)
        .sender_ratchet_configuration(SenderRatchetConfiguration::new(32, 1000))
        .build()
}

fn join_config() -> MlsGroupJoinConfig {
    MlsGroupJoinConfig::builder()
        .use_ratchet_tree_extension(true)
        .max_past_epochs(5)
        .padding_size(256)
        .sender_ratchet_configuration(SenderRatchetConfiguration::new(32, 1000))
        .build()
}

fn read_message(bytes: &[u8]) -> Result<MlsMessageBodyIn> {
    let message = MlsMessageIn::tls_deserialize_exact(bytes).map_err(|_| anyhow!("message is not valid MLS"))?;
    Ok(message.extract())
}

impl Inner {
    fn load_group(&self, conversation_id: &str) -> Result<MlsGroup> {
        MlsGroup::load(self.provider.storage(), &group_id(conversation_id)?)
            .map_err(|e| anyhow!("storage error: {e}"))?
            .ok_or_else(|| anyhow!("no encryption group for this conversation"))
    }

    fn bundle(&self, group: &MlsGroup, commit: MlsMessageOut, welcome: Option<MlsMessageOut>, welcome_device_ids: Vec<String>) -> Result<CommitBundle> {
        Ok(CommitBundle {
            commit: commit.to_bytes().map_err(|_| anyhow!("could not serialise commit"))?,
            epoch: group.epoch().as_u64() as i64,
            welcome: welcome.map(|w| w.to_bytes()).transpose().map_err(|_| anyhow!("could not serialise welcome"))?,
            welcome_device_ids,
        })
    }

    fn validated_key_packages(&self, packages: &[DeviceKeyPackage]) -> Result<(Vec<KeyPackage>, Vec<String>)> {
        let mut out = Vec::with_capacity(packages.len());
        let mut devices = Vec::with_capacity(packages.len());
        for item in packages {
            let body = read_message(&item.key_package)?;
            let MlsMessageBodyIn::KeyPackage(kp_in) = body else {
                bail!("expected a key package");
            };
            let kp = kp_in
                .validate(self.provider.crypto(), ProtocolVersion::Mls10)
                .map_err(|_| anyhow!("key package signature is not valid"))?;
            if kp.ciphersuite() != CIPHERSUITE {
                bail!("key package uses an unsupported ciphersuite");
            }
            let (user, device) = parse_identity(kp.leaf_node().credential())?;
            if user != item.user_id || device != item.device_id {
                bail!("key package does not belong to the device the server named");
            }
            out.push(kp);
            devices.push(device);
        }
        Ok((out, devices))
    }
}

impl ChatCore {
    #[frb(sync)]
    pub fn open(db_path: String, user_id: String, device_id: String) -> Result<ChatCore> {
        if user_id.is_empty() || device_id.is_empty() || user_id.contains(':') || device_id.contains(':') {
            bail!("invalid user or device id");
        }
        let connection = Connection::open(&db_path).context("could not open the encryption database")?;
        connection
            .execute_batch(
                "PRAGMA journal_mode = WAL;
                 PRAGMA synchronous = FULL;
                 PRAGMA secure_delete = ON;
                 CREATE TABLE IF NOT EXISTS ytw_identity (
                     id INTEGER PRIMARY KEY CHECK (id = 1),
                     user_id TEXT NOT NULL,
                     device_id TEXT NOT NULL,
                     public_key BLOB NOT NULL
                 );",
            )
            .context("could not prepare the encryption database")?;
        let existing: Option<(String, String, Vec<u8>)> = connection
            .query_row("SELECT user_id, device_id, public_key FROM ytw_identity WHERE id = 1", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .ok();
        if let Some((u, d, _)) = &existing {
            if *u != user_id || *d != device_id {
                bail!("this encryption database belongs to another device");
            }
        }

        let new_signer = match &existing {
            Some(_) => None,
            None => {
                let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).map_err(|_| anyhow!("could not create a signing key"))?;
                connection
                    .execute(
                        "INSERT INTO ytw_identity (id, user_id, device_id, public_key) VALUES (1, ?1, ?2, ?3)",
                        (&user_id, &device_id, &signer.to_public_vec()),
                    )
                    .context("could not save the device identity")?;
                Some(signer)
            }
        };

        let mut storage = SqliteStorageProvider::<JsonCodec, Connection>::new(connection);
        storage.run_migrations().map_err(|e| anyhow!("could not migrate the encryption database: {e}"))?;
        let provider = Provider { crypto: RustCrypto::default(), storage };

        let signer = match (new_signer, &existing) {
            (Some(signer), _) => {
                signer.store(provider.storage()).map_err(|e| anyhow!("could not store the signing key: {e}"))?;
                signer
            }
            (None, Some((_, _, public_key))) => SignatureKeyPair::read(provider.storage(), public_key, CIPHERSUITE.signature_algorithm())
                .ok_or_else(|| anyhow!("the device signing key is missing"))?,
            (None, None) => bail!("device identity could not be loaded"),
        };

        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity_string(&user_id, &device_id).into_bytes()).into(),
            signature_key: signer.to_public_vec().into(),
        };
        Ok(ChatCore { inner: Mutex::new(Inner { provider, signer, credential, user_id, device_id }) })
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Inner>> {
        self.inner.lock().map_err(|_| anyhow!("encryption state is unavailable"))
    }

    #[frb(sync)]
    pub fn identity(&self) -> Result<DeviceRef> {
        let inner = self.lock()?;
        Ok(DeviceRef { user_id: inner.user_id.clone(), device_id: inner.device_id.clone() })
    }

    #[frb(sync)]
    pub fn fingerprint(&self) -> Result<String> {
        Ok(fingerprint_of(&self.lock()?.signer.to_public_vec()))
    }

    pub fn generate_key_packages(&self, count: u32) -> Result<Vec<Vec<u8>>> {
        if count == 0 || count > MAX_KEY_PACKAGES_PER_CALL {
            bail!("key package count must be between 1 and {MAX_KEY_PACKAGES_PER_CALL}");
        }
        let inner = self.lock()?;
        (0..count)
            .map(|_| {
                let bundle = KeyPackage::builder()
                    .leaf_node_capabilities(capabilities())
                    .build(CIPHERSUITE, &inner.provider, &inner.signer, inner.credential.clone())
                    .map_err(|e| anyhow!("could not create key package: {e}"))?;
                MlsMessageOut::from(bundle.key_package().clone()).to_bytes().map_err(|_| anyhow!("could not serialise key package"))
            })
            .collect()
    }

    pub fn last_resort_key_package(&self) -> Result<Vec<u8>> {
        let inner = self.lock()?;
        let bundle = KeyPackage::builder()
            .leaf_node_capabilities(capabilities())
            .mark_as_last_resort()
            .build(CIPHERSUITE, &inner.provider, &inner.signer, inner.credential.clone())
            .map_err(|e| anyhow!("could not create key package: {e}"))?;
        MlsMessageOut::from(bundle.key_package().clone()).to_bytes().map_err(|_| anyhow!("could not serialise key package"))
    }

    pub fn create_group(&self, conversation_id: String) -> Result<i64> {
        let inner = self.lock()?;
        let id = group_id(&conversation_id)?;
        if MlsGroup::load(inner.provider.storage(), &id).map_err(|e| anyhow!("storage error: {e}"))?.is_some() {
            bail!("this conversation already has an encryption group");
        }
        let group = MlsGroup::new_with_group_id(&inner.provider, &inner.signer, &create_config(), id, inner.credential.clone())
            .map_err(|e| anyhow!("could not create encryption group: {e}"))?;
        Ok(group.epoch().as_u64() as i64)
    }

    #[frb(sync)]
    pub fn has_group(&self, conversation_id: String) -> Result<bool> {
        let inner = self.lock()?;
        Ok(MlsGroup::load(inner.provider.storage(), &group_id(&conversation_id)?)
            .map_err(|e| anyhow!("storage error: {e}"))?
            .is_some_and(|g| g.is_active()))
    }

    #[frb(sync)]
    pub fn group_epoch(&self, conversation_id: String) -> Result<i64> {
        Ok(self.lock()?.load_group(&conversation_id)?.epoch().as_u64() as i64)
    }

    pub fn add_members(&self, conversation_id: String, key_packages: Vec<DeviceKeyPackage>) -> Result<CommitBundle> {
        if key_packages.is_empty() {
            bail!("no devices to add");
        }
        let inner = self.lock()?;
        let mut group = inner.load_group(&conversation_id)?;
        if group.pending_commit().is_some() {
            bail!("a change to this conversation is still waiting for the server");
        }
        let (packages, devices) = inner.validated_key_packages(&key_packages)?;
        let epoch = group.epoch().as_u64() as i64;
        let (commit, welcome, _) = group
            .add_members(&inner.provider, &inner.signer, &packages)
            .map_err(|e| anyhow!("could not add members: {e}"))?;
        let mut bundle = inner.bundle(&group, commit, Some(welcome), devices)?;
        bundle.epoch = epoch;
        Ok(bundle)
    }

    pub fn remove_members(&self, conversation_id: String, devices: Vec<DeviceRef>) -> Result<CommitBundle> {
        let inner = self.lock()?;
        let mut group = inner.load_group(&conversation_id)?;
        if group.pending_commit().is_some() {
            bail!("a change to this conversation is still waiting for the server");
        }
        let mut indices = Vec::new();
        for member in group.members() {
            let (user, device) = parse_identity(&member.credential)?;
            if devices.iter().any(|d| d.user_id == user && d.device_id == device) {
                indices.push(member.index);
            }
        }
        if indices.is_empty() {
            bail!("none of those devices are in this conversation");
        }
        let epoch = group.epoch().as_u64() as i64;
        let (commit, welcome, _) = group
            .remove_members(&inner.provider, &inner.signer, &indices)
            .map_err(|e| anyhow!("could not remove members: {e}"))?;
        let mut bundle = inner.bundle(&group, commit, welcome, vec![])?;
        bundle.epoch = epoch;
        Ok(bundle)
    }

    pub fn self_update(&self, conversation_id: String) -> Result<CommitBundle> {
        let inner = self.lock()?;
        let mut group = inner.load_group(&conversation_id)?;
        if group.pending_commit().is_some() {
            bail!("a change to this conversation is still waiting for the server");
        }
        let epoch = group.epoch().as_u64() as i64;
        let (commit, welcome, _) = group
            .self_update(&inner.provider, &inner.signer, LeafNodeParameters::default())
            .map_err(|e| anyhow!("could not rotate keys: {e}"))?
            .into_contents();
        if welcome.is_some() {
            bail!("unexpected invitation from a key rotation");
        }
        let mut bundle = inner.bundle(&group, commit, None, vec![])?;
        bundle.epoch = epoch;
        Ok(bundle)
    }

    pub fn confirm_commit(&self, conversation_id: String) -> Result<i64> {
        let inner = self.lock()?;
        let mut group = inner.load_group(&conversation_id)?;
        if group.pending_commit().is_none() {
            bail!("there is no change waiting to be confirmed");
        }
        group.merge_pending_commit(&inner.provider).map_err(|e| anyhow!("could not apply the change: {e}"))?;
        Ok(group.epoch().as_u64() as i64)
    }

    pub fn discard_commit(&self, conversation_id: String) -> Result<()> {
        let inner = self.lock()?;
        let mut group = inner.load_group(&conversation_id)?;
        group.clear_pending_commit(inner.provider.storage()).map_err(|e| anyhow!("could not discard the change: {e}"))?;
        Ok(())
    }

    pub fn join_from_welcome(&self, welcome: Vec<u8>) -> Result<String> {
        let inner = self.lock()?;
        let MlsMessageBodyIn::Welcome(welcome) = read_message(&welcome)? else {
            bail!("expected a welcome message");
        };
        let staged = StagedWelcome::new_from_welcome(&inner.provider, &join_config(), welcome, None)
            .map_err(|e| anyhow!("could not read the invitation: {e}"))?;
        let group = staged.into_group(&inner.provider).map_err(|e| anyhow!("could not join the conversation: {e}"))?;
        let conversation_id = String::from_utf8(group.group_id().as_slice().to_vec()).context("group id is not a conversation id")?;
        Ok(conversation_id)
    }

    pub fn encrypt(&self, conversation_id: String, plaintext: Vec<u8>) -> Result<Vec<u8>> {
        if plaintext.len() > MAX_PLAINTEXT {
            bail!("message is too large");
        }
        let inner = self.lock()?;
        let mut group = inner.load_group(&conversation_id)?;
        let message = group
            .create_message(&inner.provider, &inner.signer, &plaintext)
            .map_err(|e| anyhow!("could not encrypt: {e}"))?;
        message.to_bytes().map_err(|_| anyhow!("could not serialise message"))
    }

    pub fn process(&self, conversation_id: String, message: Vec<u8>) -> Result<Incoming> {
        let inner = self.lock()?;
        let mut group = inner.load_group(&conversation_id)?;
        let protocol: ProtocolMessage = match read_message(&message)? {
            MlsMessageBodyIn::PrivateMessage(m) => m.into(),
            MlsMessageBodyIn::PublicMessage(m) => m.into(),
            _ => bail!("expected a conversation message"),
        };
        if protocol.group_id() != group.group_id() {
            bail!("message belongs to a different conversation");
        }
        let processed = group.process_message(&inner.provider, protocol).map_err(|e| anyhow!("could not decrypt: {e}"))?;
        let sender_credential = processed.credential().clone();
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app) => {
                let (user, device) = parse_identity(&sender_credential)?;
                Ok(Incoming {
                    kind: IncomingKind::Application,
                    sender_user_id: Some(user),
                    sender_device_id: Some(device),
                    plaintext: Some(app.into_bytes()),
                    epoch: group.epoch().as_u64() as i64,
                    removed_self: false,
                })
            }
            ProcessedMessageContent::StagedCommitMessage(staged) => {
                let own_index = group.own_leaf_index();
                let removed_self = staged.remove_proposals().any(|p| p.remove_proposal().removed() == own_index);
                group.merge_staged_commit(&inner.provider, *staged).map_err(|e| anyhow!("could not apply the change: {e}"))?;
                Ok(Incoming { removed_self, ..Incoming::bare(IncomingKind::Commit, group.epoch().as_u64() as i64) })
            }
            ProcessedMessageContent::ProposalMessage(proposal) => {
                group.store_pending_proposal(inner.provider.storage(), *proposal).map_err(|e| anyhow!("storage error: {e}"))?;
                Ok(Incoming::bare(IncomingKind::Proposal, group.epoch().as_u64() as i64))
            }
            ProcessedMessageContent::ExternalJoinProposalMessage(_) => bail!("external joins are not allowed"),
            _ => Ok(Incoming::bare(IncomingKind::Ignored, group.epoch().as_u64() as i64)),
        }
    }

    #[frb(sync)]
    pub fn members(&self, conversation_id: String) -> Result<Vec<MemberInfo>> {
        let inner = self.lock()?;
        let group = inner.load_group(&conversation_id)?;
        group
            .members()
            .map(|m| {
                let (user_id, device_id) = parse_identity(&m.credential)?;
                Ok(MemberInfo { user_id, device_id, fingerprint: fingerprint_of(&m.signature_key) })
            })
            .collect()
    }

    pub fn delete_group(&self, conversation_id: String) -> Result<()> {
        let inner = self.lock()?;
        let id = group_id(&conversation_id)?;
        if let Some(mut group) = MlsGroup::load(inner.provider.storage(), &id).map_err(|e| anyhow!("storage error: {e}"))? {
            group.delete(inner.provider.storage()).map_err(|e| anyhow!("could not delete the group: {e}"))?;
        }
        Ok(())
    }
}
