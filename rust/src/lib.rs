use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct FeedbackEvent {
    pub id: String,
    pub pubkey: String,
    pub created_at: i64,
    pub kind: i64,
    pub tags: Vec<Vec<String>>,
    pub content: String,
    #[serde(default)]
    pub sig: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct FeedbackMetadata {
    pub root_id: String,
    pub title: Option<String>,
    pub summary: Option<String>,
    pub status_label: Option<String>,
    pub current_activity: Option<String>,
    pub created_at: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct FeedbackThread {
    pub root: FeedbackEvent,
    pub replies: Vec<FeedbackEvent>,
    pub metadata: Option<FeedbackMetadata>,
    pub title: String,
    pub summary: String,
    pub status_label: Option<String>,
    pub last_activity: i64,
    pub is_mine: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct GeneratedProfile {
    pub name: String,
    pub display_name: String,
    pub about: String,
    pub picture: String,
}

#[derive(Clone, Debug, Deserialize)]
struct ReduceInput {
    events: Vec<FeedbackEvent>,
    project_a_tag: String,
    local_pubkey: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct ThreadInput {
    events: Vec<FeedbackEvent>,
    root_event_id: String,
}

#[derive(Clone, Debug, Serialize)]
struct ErrorOutput {
    error: String,
}

#[no_mangle]
pub extern "C" fn sf_reduce_threads_json(input: *const c_char) -> *mut c_char {
    ffi_json(input, |text| {
        let input: ReduceInput = serde_json::from_str(text)?;
        let threads = reduce_threads(&input.events, &input.project_a_tag, input.local_pubkey.as_deref());
        serde_json::to_string(&threads)
    })
}

#[no_mangle]
pub extern "C" fn sf_thread_messages_json(input: *const c_char) -> *mut c_char {
    ffi_json(input, |text| {
        let input: ThreadInput = serde_json::from_str(text)?;
        let messages = thread_messages(&input.events, &input.root_event_id);
        serde_json::to_string(&messages)
    })
}

#[no_mangle]
pub extern "C" fn sf_generated_profile_json(pubkey: *const c_char, app_name: *const c_char) -> *mut c_char {
    let pubkey = match c_string(pubkey) {
        Ok(value) => value,
        Err(err) => return error_json(err),
    };
    let app_name = match c_string(app_name) {
        Ok(value) => value,
        Err(err) => return error_json(err),
    };
    match serde_json::to_string(&generated_profile(&pubkey, &app_name)) {
        Ok(json) => into_c_string(json),
        Err(err) => error_json(err.to_string()),
    }
}

#[no_mangle]
pub extern "C" fn sf_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(ptr);
    }
}

pub fn reduce_threads(events: &[FeedbackEvent], project_a_tag: &str, local_pubkey: Option<&str>) -> Vec<FeedbackThread> {
    let mut roots: BTreeMap<String, FeedbackEvent> = BTreeMap::new();
    let mut replies_by_root: HashMap<String, Vec<FeedbackEvent>> = HashMap::new();
    let mut latest_meta_by_root: HashMap<String, FeedbackMetadata> = HashMap::new();

    for event in events {
        match event.kind {
            1 => {
                if !has_tag_value(event, "a", project_a_tag) {
                    continue;
                }
                if let Some(root_id) = root_event_id(event) {
                    replies_by_root.entry(root_id).or_default().push(event.clone());
                } else {
                    roots.insert(event.id.clone(), event.clone());
                }
            }
            513 => {
                if !has_tag_value(event, "a", project_a_tag) {
                    continue;
                }
                let Some(root_id) = first_tag_value(event, "e") else {
                    continue;
                };
                let metadata = parse_metadata(event, root_id);
                if latest_meta_by_root
                    .get(&metadata.root_id)
                    .map(|existing| existing.created_at >= metadata.created_at)
                    .unwrap_or(false)
                {
                    continue;
                }
                latest_meta_by_root.insert(metadata.root_id.clone(), metadata);
            }
            _ => {}
        }
    }

    let mut threads: Vec<FeedbackThread> = roots
        .into_values()
        .map(|root| {
            let mut replies = replies_by_root.remove(&root.id).unwrap_or_default();
            replies.sort_by(|a, b| a.created_at.cmp(&b.created_at).then_with(|| a.id.cmp(&b.id)));
            let metadata = latest_meta_by_root.remove(&root.id);
            let latest_message_time = replies
                .iter()
                .map(|event| event.created_at)
                .max()
                .unwrap_or(root.created_at);
            let last_activity = latest_message_time.max(metadata.as_ref().map(|m| m.created_at).unwrap_or(0));
            let title = metadata
                .as_ref()
                .and_then(|m| m.title.as_deref().and_then(clean_opt))
                .unwrap_or_else(|| preview(&root.content, "Feedback"));
            let summary = metadata
                .as_ref()
                .and_then(|m| m.summary.as_deref().and_then(clean_opt))
                .unwrap_or_else(|| {
                    let source = replies.last().map(|e| e.content.as_str()).unwrap_or(root.content.as_str());
                    preview(source, "No messages yet")
                });
            let status_label = metadata
                .as_ref()
                .and_then(|m| m.status_label.as_deref().and_then(clean_opt));
            let is_mine = local_pubkey.map(|p| p == root.pubkey).unwrap_or(false);
            FeedbackThread {
                root,
                replies,
                metadata,
                title,
                summary,
                status_label,
                last_activity,
                is_mine,
            }
        })
        .collect();

    threads.sort_by(|a, b| {
        b.last_activity
            .cmp(&a.last_activity)
            .then_with(|| a.root.id.cmp(&b.root.id))
    });
    threads
}

pub fn thread_messages(events: &[FeedbackEvent], root_event_id: &str) -> Vec<FeedbackEvent> {
    let mut seen = HashSet::new();
    let mut out: Vec<FeedbackEvent> = events
        .iter()
        .filter(|event| {
            event.id == root_event_id || root_event_id_of_any_marker(event).as_deref() == Some(root_event_id)
        })
        .filter(|event| seen.insert(event.id.clone()))
        .cloned()
        .collect();
    out.sort_by(|a, b| a.created_at.cmp(&b.created_at).then_with(|| a.id.cmp(&b.id)));
    out
}

pub fn generated_profile(pubkey: &str, app_name: &str) -> GeneratedProfile {
    let seed = pubkey.chars().take(16).collect::<String>();
    let adjectives = ["Bright", "Quiet", "Swift", "Clear", "North", "Steady", "Fresh", "Calm"];
    let nouns = ["Signal", "Notebook", "Harbor", "Lantern", "Thread", "Field", "Marker", "Anchor"];
    let adjective = adjectives[stable_index(&(seed.clone() + "-a"), adjectives.len())];
    let noun = nouns[stable_index(&(seed.clone() + "-n"), nouns.len())];
    let suffix = pubkey.chars().take(4).collect::<String>();
    GeneratedProfile {
        name: format!("{}-{}-{}", adjective.to_lowercase(), noun.to_lowercase(), suffix),
        display_name: format!("{adjective} {noun}"),
        about: format!("Feedback identity generated by {app_name}."),
        picture: format!("https://api.dicebear.com/9.x/personas/svg?seed={seed}"),
    }
}

fn parse_metadata(event: &FeedbackEvent, root_id: &str) -> FeedbackMetadata {
    let mut title = tag_value_owned(event, "title");
    let mut summary = tag_value_owned(event, "summary");
    let mut status_label = tag_value_owned(event, "status-label")
        .or_else(|| tag_value_owned(event, "status_label"))
        .or_else(|| tag_value_owned(event, "status"));
    let current_activity = tag_value_owned(event, "status-current-activity");

    if (title.is_none() || summary.is_none() || status_label.is_none()) && !event.content.trim().is_empty() {
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(&event.content) {
            title = title.or_else(|| json_string(&value, "title"));
            summary = summary.or_else(|| json_string(&value, "summary"));
            status_label = status_label
                .or_else(|| json_string(&value, "status_label"))
                .or_else(|| json_string(&value, "status"));
        }
    }

    FeedbackMetadata {
        root_id: root_id.to_string(),
        title,
        summary,
        status_label,
        current_activity,
        created_at: event.created_at,
    }
}

fn root_event_id(event: &FeedbackEvent) -> Option<String> {
    event.tags.iter().find_map(|tag| {
        if tag.first().map(String::as_str) == Some("e")
            && tag.get(3).map(String::as_str) == Some("root")
        {
            tag.get(1).cloned()
        } else {
            None
        }
    })
}

fn root_event_id_of_any_marker(event: &FeedbackEvent) -> Option<String> {
    root_event_id(event).or_else(|| first_tag_value(event, "e").map(str::to_string))
}

fn has_tag_value(event: &FeedbackEvent, tag_name: &str, value: &str) -> bool {
    event
        .tags
        .iter()
        .any(|tag| tag.first().map(String::as_str) == Some(tag_name) && tag.get(1).map(String::as_str) == Some(value))
}

fn first_tag_value<'a>(event: &'a FeedbackEvent, tag_name: &str) -> Option<&'a str> {
    event
        .tags
        .iter()
        .find(|tag| tag.first().map(String::as_str) == Some(tag_name))
        .and_then(|tag| tag.get(1).map(String::as_str))
}

fn tag_value_owned(event: &FeedbackEvent, tag_name: &str) -> Option<String> {
    first_tag_value(event, tag_name).and_then(clean_opt)
}

fn json_string(value: &serde_json::Value, key: &str) -> Option<String> {
    value.get(key).and_then(|v| v.as_str()).and_then(clean_opt)
}

fn clean_opt(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn preview(value: &str, fallback: &str) -> String {
    let collapsed = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.is_empty() {
        fallback.to_string()
    } else {
        collapsed.chars().take(90).collect()
    }
}

fn stable_index(value: &str, count: usize) -> usize {
    let hash = Sha256::digest(value.as_bytes());
    let mut bytes = [0_u8; 8];
    bytes.copy_from_slice(&hash[0..8]);
    (u64::from_be_bytes(bytes) as usize) % count
}

fn ffi_json<F>(input: *const c_char, f: F) -> *mut c_char
where
    F: FnOnce(&str) -> Result<String, serde_json::Error>,
{
    let text = match c_string(input) {
        Ok(value) => value,
        Err(err) => return error_json(err),
    };
    match f(&text) {
        Ok(json) => into_c_string(json),
        Err(err) => error_json(err.to_string()),
    }
}

fn c_string(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("null string pointer".to_string());
    }
    unsafe {
        CStr::from_ptr(ptr)
            .to_str()
            .map(str::to_string)
            .map_err(|err| err.to_string())
    }
}

fn into_c_string(value: String) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| CString::new("{\"error\":\"string contained nul byte\"}").unwrap())
        .into_raw()
}

fn error_json(error: String) -> *mut c_char {
    let json = serde_json::to_string(&ErrorOutput { error })
        .unwrap_or_else(|_| "{\"error\":\"unknown error\"}".to_string());
    into_c_string(json)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(id: &str, kind: i64, tags: Vec<Vec<&str>>, content: &str, created_at: i64) -> FeedbackEvent {
        FeedbackEvent {
            id: id.to_string(),
            pubkey: format!("pk-{id}"),
            created_at,
            kind,
            tags: tags
                .into_iter()
                .map(|tag| tag.into_iter().map(str::to_string).collect())
                .collect(),
            content: content.to_string(),
            sig: String::new(),
        }
    }

    #[test]
    fn reduces_threads_with_latest_metadata() {
        let coordinate = "31933:abc:test";
        let events = vec![
            event("root", 1, vec![vec!["a", coordinate]], "hello world", 1),
            event("reply", 1, vec![vec!["a", coordinate], vec!["e", "root", "", "root"]], "answer", 2),
            event("meta1", 513, vec![vec!["a", coordinate], vec!["e", "root"], vec!["title", "Old"]], "", 3),
            event("meta2", 513, vec![vec!["a", coordinate], vec!["e", "root"], vec!["title", "New"], vec!["status-label", "Open"]], "", 4),
        ];

        let threads = reduce_threads(&events, coordinate, Some("pk-root"));
        assert_eq!(threads.len(), 1);
        assert_eq!(threads[0].title, "New");
        assert_eq!(threads[0].status_label.as_deref(), Some("Open"));
        assert_eq!(threads[0].replies.len(), 1);
        assert!(threads[0].is_mine);
    }

    #[test]
    fn generated_profile_is_stable() {
        let a = generated_profile("abcdef0123456789abcdef", "Example");
        let b = generated_profile("abcdef0123456789abcdef", "Example");
        assert_eq!(a.name, b.name);
        assert!(a.about.contains("Example"));
    }
}
