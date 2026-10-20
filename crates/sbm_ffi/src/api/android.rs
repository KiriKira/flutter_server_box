//! Android commands and parsing. JSON keeps platform-specific optional fields
//! out of the generic server status protocol.
use std::collections::HashMap;

#[flutter_rust_bridge::frb(sync)]
pub fn android_exec_command(script: String, entry: Option<String>, env: HashMap<String, String>) -> Result<String, String> {
    sbm_parser::android::exec_command(&script, entry.as_deref(), &env)
}
#[flutter_rust_bridge::frb(sync)]
pub fn android_command(action: String, argument: String, root: bool) -> Result<String, String> {
    sbm_parser::android::command(&action, &argument, root)
}
pub fn parse_android_status_json(raw: String) -> String {
    sbm_parser::android::parse_status(&raw).to_string()
}
pub fn parse_android_apps_json(raw: String) -> String {
    serde_json::to_string(&sbm_parser::android::parse_apps(&raw)).unwrap()
}
