use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use anyhow::{anyhow, bail, Result};
use rand::rngs::OsRng;
use rand::RngCore;
use sha2::{Digest, Sha256};
use zeroize::Zeroize;

pub struct EncryptedMedia {
    pub ciphertext: Vec<u8>,
    pub key: Vec<u8>,
    pub nonce: Vec<u8>,
    pub sha256: Vec<u8>,
}

const MAX_MEDIA: usize = 64 * 1024 * 1024;

pub fn encrypt_media(data: Vec<u8>) -> Result<EncryptedMedia> {
    if data.is_empty() || data.len() > MAX_MEDIA {
        bail!("file must be between 1 byte and 64 MB");
    }
    let mut key = [0u8; 32];
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut key);
    OsRng.fill_bytes(&mut nonce);
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));
    let ciphertext = cipher.encrypt(Nonce::from_slice(&nonce), data.as_slice()).map_err(|_| anyhow!("could not encrypt the file"))?;
    let sha256 = Sha256::digest(&ciphertext).to_vec();
    let out = EncryptedMedia { ciphertext, key: key.to_vec(), nonce: nonce.to_vec(), sha256 };
    key.zeroize();
    Ok(out)
}

pub fn decrypt_media(ciphertext: Vec<u8>, key: Vec<u8>, nonce: Vec<u8>, sha256: Vec<u8>) -> Result<Vec<u8>> {
    if key.len() != 32 || nonce.len() != 12 || sha256.len() != 32 {
        bail!("file key details are not valid");
    }
    let actual = Sha256::digest(&ciphertext);
    if actual.as_slice() != sha256.as_slice() {
        bail!("the downloaded file has been changed or is incomplete");
    }
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));
    cipher.decrypt(Nonce::from_slice(&nonce), ciphertext.as_slice()).map_err(|_| anyhow!("could not decrypt the file"))
}
