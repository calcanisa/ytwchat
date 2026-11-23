use anyhow::{anyhow, bail, Context, Result};
use openmls::prelude::tls_codec::Deserialize as _;
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::RustCrypto;
use openmls_sqlite_storage::{Codec, Connection, SqliteStorageProvider};
use aes_siv::aead::generic_array::GenericArray;
use aes_siv::siv::Aes256Siv;
use aes_siv::KeyInit;
use sha2::{Digest, Sha256};
use std::sync::RwLock;
use zeroize::Zeroizing;

use crate::api::chat::{CommitBundle, DeviceKeyPackage};

pub(crate) const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
pub(crate) const MAX_KEY_PACKAGES_PER_CALL: u32 = 100;
pub(crate) const MAX_PLAINTEXT: usize = 200 * 1024;
pub(crate) const KEY_CHECK: &[u8] = b"ytwchat-key-check";

static STORAGE_KEY: RwLock<Option<Zeroizing<[u8; 64]>>> = RwLock::new(None);
const STORAGE_AAD: &[u8] = b"ytwchat-storage-v1";

#[derive(Debug)]
pub(crate) enum SealError {
    NoKey,
    Crypto,
    Json(serde_json::Error),
}

impl std::fmt::Display for SealError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoKey => write!(f, "storage key is not set"),
            Self::Crypto => write!(f, "stored data could not be decrypted"),
            Self::Json(e) => write!(f, "stored data is not valid: {e}"),
        }
    }
}

impl std::error::Error for SealError {}

pub(crate) fn set_storage_key(key: &[u8]) -> Result<()> {
    if key.len() != 64 {
        bail!("storage key must be 64 bytes");
    }
    let mut fixed = Zeroizing::new([0u8; 64]);
    fixed.copy_from_slice(key);
    *STORAGE_KEY.write().map_err(|_| anyhow!("storage key is unavailable"))? = Some(fixed);
    Ok(())
}

pub(crate) fn unseal_with(key: &[u8], sealed: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    if key.len() != 64 {
        return None;
    }
    let mut cipher = Aes256Siv::new(GenericArray::from_slice(key));
    cipher.decrypt([STORAGE_AAD], sealed).ok().map(Zeroizing::new)
}

fn with_cipher<R>(f: impl FnOnce(&mut Aes256Siv) -> R) -> Result<R, SealError> {
    let guard = STORAGE_KEY.read().map_err(|_| SealError::NoKey)?;
    let key = guard.as_ref().ok_or(SealError::NoKey)?;
    let mut cipher = Aes256Siv::new(GenericArray::from_slice(&key[..]));
    Ok(f(&mut cipher))
}

pub(crate) fn seal(plain: &[u8]) -> Result<Vec<u8>, SealError> {
    with_cipher(|c| c.encrypt([STORAGE_AAD], plain).map_err(|_| SealError::Crypto))?
}

pub(crate) fn unseal(sealed: &[u8]) -> Result<Zeroizing<Vec<u8>>, SealError> {
    with_cipher(|c| c.decrypt([STORAGE_AAD], sealed).map(Zeroizing::new).map_err(|_| SealError::Crypto))?
}

#[derive(Default)]
pub(crate) struct SealedCodec;

impl Codec for SealedCodec {
    type Error = SealError;

    fn to_vec<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, Self::Error> {
        let plain = Zeroizing::new(serde_json::to_vec(value).map_err(SealError::Json)?);
        seal(&plain)
    }

    fn from_slice<T: serde::de::DeserializeOwned>(slice: &[u8]) -> Result<T, Self::Error> {
        let plain = unseal(slice)?;
        serde_json::from_slice(&plain).map_err(SealError::Json)
    }
}

pub(crate) struct Provider {
    pub(crate) crypto: RustCrypto,
    pub(crate) storage: SqliteStorageProvider<SealedCodec, Connection>,
}

impl OpenMlsProvider for Provider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = SqliteStorageProvider<SealedCodec, Connection>;

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

pub(crate) struct Inner {
    pub(crate) provider: Provider,
    pub(crate) signer: SignatureKeyPair,
    pub(crate) credential: CredentialWithKey,
    pub(crate) user_id: String,
    pub(crate) device_id: String,
}

pub(crate) fn identity_string(user_id: &str, device_id: &str) -> String {
    format!("{user_id}:{device_id}")
}

pub(crate) fn parse_identity(credential: &Credential) -> Result<(String, String)> {
    let basic = BasicCredential::try_from(credential.clone()).map_err(|_| anyhow!("unsupported credential type"))?;
    let raw = std::str::from_utf8(basic.identity()).context("credential identity is not text")?;
    let (user, device) = raw.split_once(':').ok_or_else(|| anyhow!("credential identity is malformed"))?;
    if user.is_empty() || device.is_empty() || device.contains(':') {
        bail!("credential identity is malformed");
    }
    Ok((user.to_string(), device.to_string()))
}

pub(crate) fn fingerprint_of(public_key: &[u8]) -> String {
    let digest = Sha256::digest(public_key);
    hex::encode(&digest[..16])
        .as_bytes()
        .chunks(4)
        .map(|c| std::str::from_utf8(c).unwrap_or(""))
        .collect::<Vec<_>>()
        .join(" ")
}

pub(crate) fn group_id(conversation_id: &str) -> Result<GroupId> {
    if conversation_id.is_empty() || conversation_id.len() > 64 {
        bail!("invalid conversation id");
    }
    Ok(GroupId::from_slice(conversation_id.as_bytes()))
}

pub(crate) fn capabilities() -> Capabilities {
    Capabilities::new(None, Some(&[CIPHERSUITE]), Some(&[ExtensionType::LastResort]), None, Some(&[CredentialType::Basic]))
}

pub(crate) fn create_config() -> MlsGroupCreateConfig {
    MlsGroupCreateConfig::builder()
        .ciphersuite(CIPHERSUITE)
        .capabilities(capabilities())
        .use_ratchet_tree_extension(true)
        .max_past_epochs(5)
        .padding_size(256)
        .sender_ratchet_configuration(SenderRatchetConfiguration::new(100, 1000))
        .build()
}

pub(crate) fn join_config() -> MlsGroupJoinConfig {
    MlsGroupJoinConfig::builder()
        .use_ratchet_tree_extension(true)
        .max_past_epochs(5)
        .padding_size(256)
        .sender_ratchet_configuration(SenderRatchetConfiguration::new(100, 1000))
        .build()
}

pub(crate) fn read_message(bytes: &[u8]) -> Result<MlsMessageBodyIn> {
    let message = MlsMessageIn::tls_deserialize_exact(bytes).map_err(|_| anyhow!("message is not valid MLS"))?;
    Ok(message.extract())
}

impl Inner {
    pub(crate) fn load_group(&self, conversation_id: &str) -> Result<MlsGroup> {
        MlsGroup::load(self.provider.storage(), &group_id(conversation_id)?)
            .map_err(|e| anyhow!("storage error: {e}"))?
            .ok_or_else(|| anyhow!("no encryption group for this conversation"))
    }

    pub(crate) fn bundle(&self, group: &MlsGroup, commit: MlsMessageOut, welcome: Option<MlsMessageOut>, welcome_device_ids: Vec<String>) -> Result<CommitBundle> {
        Ok(CommitBundle {
            commit: commit.to_bytes().map_err(|_| anyhow!("could not serialise commit"))?,
            epoch: group.epoch().as_u64() as i64,
            welcome: welcome.map(|w| w.to_bytes()).transpose().map_err(|_| anyhow!("could not serialise welcome"))?,
            welcome_device_ids,
        })
    }

    fn validate_key_package(&self, item: &DeviceKeyPackage) -> Result<KeyPackage> {
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
        Ok(kp)
    }

    pub(crate) fn validated_key_packages(&self, packages: &[DeviceKeyPackage]) -> Result<(Vec<KeyPackage>, Vec<String>)> {
        let mut out = Vec::with_capacity(packages.len());
        let mut devices = Vec::with_capacity(packages.len());
        let mut seen = std::collections::HashSet::new();
        for item in packages {
            if let Ok(kp) = self.validate_key_package(item) {
                if !seen.insert((item.user_id.clone(), item.device_id.clone())) {
                    continue;
                }
                out.push(kp);
                devices.push(item.device_id.clone());
            }
        }
        if out.is_empty() {
            bail!("none of the key packages could be verified");
        }
        Ok((out, devices))
    }
}
