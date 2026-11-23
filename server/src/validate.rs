use crate::error::AppError;

pub fn username(raw: &str) -> Result<String, AppError> {
    let v = raw.trim().to_lowercase();
    let ok = (3..=30).contains(&v.len()) && v.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
    if !ok {
        return Err(AppError::bad("invalid_username", "Usernames are 3 to 30 characters: letters, numbers and underscores."));
    }
    Ok(v)
}

pub fn display_name(raw: &str) -> Result<String, AppError> {
    let v: String = raw.trim().chars().filter(|c| !c.is_control()).collect();
    let len = v.chars().count();
    if !(1..=60).contains(&len) {
        return Err(AppError::bad("invalid_display_name", "Enter a name between 1 and 60 characters."));
    }
    Ok(v)
}

pub fn email(raw: &str) -> Result<String, AppError> {
    let v = raw.trim().to_string();
    let parts: Vec<&str> = v.split('@').collect();
    let ok = (3..=254).contains(&v.len())
        && parts.len() == 2
        && !parts[0].is_empty()
        && parts[1].contains('.')
        && !parts[1].starts_with('.')
        && !parts[1].ends_with('.')
        && !v.chars().any(|c| c.is_whitespace() || c.is_control());
    if !ok {
        return Err(AppError::bad("invalid_email", "Enter a valid email address."));
    }
    Ok(v)
}

pub fn password(raw: &str) -> Result<(), AppError> {
    let len = raw.chars().count();
    if len < 10 {
        return Err(AppError::bad("weak_password", "Use a password of at least 10 characters."));
    }
    if len > 256 {
        return Err(AppError::bad("invalid_password", "Passwords can be at most 256 characters."));
    }
    Ok(())
}

pub fn device_name(raw: &str) -> Result<String, AppError> {
    let v: String = raw.trim().chars().filter(|c| !c.is_control()).take(60).collect();
    if v.is_empty() {
        return Err(AppError::bad("invalid_device", "Device name is required."));
    }
    Ok(v)
}

pub fn platform(raw: &str) -> Result<String, AppError> {
    match raw {
        "android" | "ios" | "web" | "desktop" => Ok(raw.to_string()),
        _ => Err(AppError::bad("invalid_platform", "Platform must be android, ios, web or desktop.")),
    }
}

pub fn phone(raw: &str) -> Option<String> {
    let mut out = String::new();
    for (i, c) in raw.trim().chars().enumerate() {
        if (c == '+' && i == 0) || c.is_ascii_digit() {
            out.push(c);
        } else if !matches!(c, ' ' | '-' | '(' | ')' | '.') {
            return None;
        }
    }
    let digits = out.trim_start_matches('+');
    let ok = out.starts_with('+') && (7..=15).contains(&digits.len()) && !digits.starts_with('0');
    ok.then_some(out)
}
