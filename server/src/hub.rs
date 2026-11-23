use dashmap::DashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::mpsc;
use uuid::Uuid;

pub type Outbox = mpsc::Sender<String>;

#[derive(Default)]
pub struct Hub {
    next_id: AtomicU64,
    devices: DashMap<Uuid, Vec<(u64, Outbox)>>,
    users: DashMap<Uuid, Vec<Uuid>>,
}

impl Hub {
    pub fn register(&self, user_id: Uuid, device_id: Uuid, tx: Outbox) -> (u64, bool) {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.devices.entry(device_id).or_default().push((id, tx));
        let mut devices = self.users.entry(user_id).or_default();
        let first = devices.is_empty();
        if !devices.contains(&device_id) {
            devices.push(device_id);
        }
        (id, first)
    }

    pub fn unregister(&self, user_id: Uuid, device_id: Uuid, conn_id: u64) -> bool {
        let mut device_empty = false;
        if let Some(mut conns) = self.devices.get_mut(&device_id) {
            conns.retain(|(id, _)| *id != conn_id);
            device_empty = conns.is_empty();
        }
        if device_empty {
            self.devices.remove_if(&device_id, |_, conns| conns.is_empty());
        }
        let mut last = false;
        if device_empty {
            if let Some(mut devices) = self.users.get_mut(&user_id) {
                devices.retain(|d| *d != device_id);
                last = devices.is_empty();
            }
            if last {
                self.users.remove_if(&user_id, |_, devices| devices.is_empty());
            }
        }
        last
    }

    pub fn is_online(&self, user_id: Uuid) -> bool {
        self.users.get(&user_id).map(|d| !d.is_empty()).unwrap_or(false)
    }

    pub fn send_device(&self, device_id: Uuid, payload: &str) {
        if let Some(conns) = self.devices.get(&device_id) {
            for (_, tx) in conns.iter() {
                let _ = tx.try_send(payload.to_string());
            }
        }
    }

    pub fn send_user(&self, user_id: Uuid, payload: &str) {
        let devices: Vec<Uuid> = self.users.get(&user_id).map(|d| d.clone()).unwrap_or_default();
        for device in devices {
            self.send_device(device, payload);
        }
    }

    pub fn disconnect_device(&self, device_id: Uuid) {
        self.devices.remove(&device_id);
        for mut devices in self.users.iter_mut() {
            devices.retain(|d| *d != device_id);
        }
    }
}
