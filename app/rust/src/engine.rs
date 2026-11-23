use anyhow::{anyhow, bail, Context, Result};
use openmls::prelude::tls_codec::Deserialize as _;
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::RustCrypto;
use openmls_sqlite_storage::{Codec, Connection, SqliteStorageProvider};
use sha2::{Digest, Sha256};

use crate::api::chat::{CommitBundle, DeviceKeyPackage};

pub(crate) const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
pub(crate) const MAX_KEY_PACKAGES_PER_CALL: u32 = 100;
pub(crate) const MAX_PLAINTEXT: usize = 200 * 1024;

#[derive(Default)]
pub(crate) struct JsonCodec;

impl Codec for JsonCodec {
    type Error = serde_json::Error;

    fn to_vec<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, Self::Error> {
        serde_json::to_vec(value)
    }

    fn from_slice<T: serde::de::DeserializeOwned>(slice: &[u8]) -> Result<T, Self::Error> {
        serde_json::from_slice(slice)
    }
}

pub(crate) struct Provider {
    pub(crate) crypto: RustCrypto,
    pub(crate) storage: SqliteStorageProvider<JsonCodec, Connection>,
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
        .sender_ratchet_configuration(SenderRatchetConfiguration::new(32, 1000))
        .build()
}

pub(crate) fn join_config() -> MlsGroupJoinConfig {
    MlsGroupJoinConfig::builder()
        .use_ratchet_tree_extension(true)
        .max_past_epochs(5)
        .padding_size(256)
        .sender_ratchet_configuration(SenderRatchetConfiguration::new(32, 1000))
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

    pub(crate) fn validated_key_packages(&self, packages: &[DeviceKeyPackage]) -> Result<(Vec<KeyPackage>, Vec<String>)> {
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
