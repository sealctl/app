//! The rows of the Activity log (SPEC.md 11.12), the same on both phones: what a usage entry
//! was about on the top line, the outcome beside it, and the details (project, agent,
//! repository, command, machine) on the line under it.
//!
//! Every value comes from a machine, so each part passes [`display_text`] (SPEC.md 11.7), and
//! long raw ids (UUIDs) are shortened to `9ac0…04` wherever they show.

use crate::cards::display_text;
use crate::model::{Machine, UsageEntry};

/// Longest name shown (a secret, volume or backup name, a project, a repository).
const MAX_NAME: u32 = 60;
/// Longest agent name shown.
const MAX_AGENT: u32 = 40;
/// Longest command shown.
const MAX_LINE: u32 = 80;

/// How the outcome is coloured.
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivityTone {
    /// Allowed or confirmed: the secondary ink.
    Normal,
    /// Denied: the declined (accent) colour.
    Declined,
    /// Expired: muted.
    Muted,
}

/// One row of the Activity log.
#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct ActivityRow {
    /// What was used: "web-relay-token", "Volume safe", "Secret store a7c3…42",
    /// "Seal volume safe".
    pub subject: String,
    /// "One tap", "In session", "Denied", …
    pub outcome: String,
    /// The outcome's colour.
    pub tone: ActivityTone,
    /// The second line, in order and without empty parts: the project (secrets), the agent,
    /// the repository, the command and the machine. The apps join them with " · ".
    pub details: Vec<String>,
}

/// The Activity row of `entry`; `machine` is the paired machine it came from, `None` when it
/// is not (or no longer) paired.
#[uniffi::export]
pub fn activity_row(entry: UsageEntry, machine: Option<Machine>) -> ActivityRow {
    let machine = machine.filter(|m| !m.deleted);
    let key = entry.key.trim();
    let command = entry
        .command
        .as_deref()
        .map(str::trim)
        .filter(|c| !c.is_empty());
    let (subject, project, command_used) = subject(key, entry.kind.as_deref(), &entry, command);

    let mut details = Vec::new();
    if let Some(p) = project {
        details.push(shown(p, MAX_NAME));
    }
    if let Some(a) = entry.agent.as_deref().filter(|a| !a.trim().is_empty()) {
        details.push(shown(a.trim(), MAX_AGENT));
    }
    let user = machine
        .as_ref()
        .and_then(|m| m.name.split_once('@'))
        .map(|(u, _)| u)
        .filter(|u| !u.is_empty());
    // A folder outside any git repository is sent as its path, so a command run in the home
    // folder names the user's own folder: that says nothing, so it is left out.
    if let Some(r) = entry
        .repo
        .as_deref()
        .map(str::trim)
        .filter(|r| !r.is_empty() && Some(*r) != user)
    {
        details.push(shown(r, MAX_NAME));
    }
    if let (Some(c), false) = (command, command_used) {
        details.push(shown(&with_sealctl(c), MAX_LINE));
    }
    details.push(machine_label(machine.as_ref(), &entry.machine));
    details.retain(|d| !d.is_empty());

    let (outcome, tone) = outcome(&entry.outcome);
    ActivityRow {
        subject,
        outcome,
        tone,
        details,
    }
}

/// The top line, the project of a secret, and whether the command was used up in the top line.
fn subject<'a>(
    key: &'a str,
    kind: Option<&str>,
    entry: &UsageEntry,
    command: Option<&str>,
) -> (String, Option<&'a str>, bool) {
    // `"<purpose> <id>"`: a request with only items (an unseal plan, a store key).
    if let Some((purpose, id)) = key.split_once(' ') {
        let named = match purpose {
            "secrets" => Some("Secret store"),
            "secret" => Some("Own-approval secret"),
            "volume" => Some("Volume"),
            "backup" => Some("Backup"),
            _ => None,
        };
        if let Some(named) = named
            .filter(|_| !id.is_empty() && !id.contains(' ') && kind.is_none_or(|k| k == purpose))
        {
            return (format!("{named} {}", short_id(id)), None, false);
        }
    }
    // A use a machine reports from its session names the command when no secret was named.
    if key.is_empty() || Some(key) == command {
        return match command {
            Some(c) => (shown(&with_sealctl(c), MAX_LINE), None, true),
            None => ("Request".into(), None, false),
        };
    }
    let verb = command.and_then(|c| words(c).next());
    let kind = kind.or(if entry.outcome == "in_session" || key.contains('/') {
        // a session's uses are always secret names; `project/name` is a secret's name
        Some("secret")
    } else if key == "seal" && verb == Some("seal") {
        // `sealctl seal` before the kind was recorded
        Some("machine")
    } else {
        None
    });
    match kind {
        Some("secret") => match key.rsplit_once('/') {
            Some((project, name)) if !project.is_empty() && !name.is_empty() => {
                (shown(name, MAX_NAME), Some(project), false)
            }
            _ => (shown(key, MAX_NAME), None, false),
        },
        Some("volume") => (format!("Volume {}", shown(key, MAX_NAME)), None, false),
        Some("backup") => (format!("Backup {}", shown(key, MAX_NAME)), None, false),
        Some("ssh") => (format!("SSH key {}", shown(key, MAX_NAME)), None, false),
        // An action of the CLI on the machine itself (`seal`, `rewrap`): "Seal volume safe"
        // from `seal volume safe <disk id>`, the verb with what it acts on.
        Some("machine") => {
            let action = capitalised(key);
            match command.filter(|_| verb == Some(key)) {
                Some(c) => {
                    let what: Vec<&str> = words(c)
                        .skip(1)
                        .take_while(|w| !w.starts_with('-'))
                        .take(2)
                        .collect();
                    let text = std::iter::once(action.as_str())
                        .chain(what)
                        .collect::<Vec<_>>()
                        .join(" ");
                    (shown(&text, MAX_LINE), None, true)
                }
                None => (shown(&action, MAX_NAME), None, false),
            }
        }
        _ => (shown(key, MAX_NAME), None, false),
    }
}

/// The words of a command without a leading `sealctl`.
fn words(command: &str) -> impl Iterator<Item = &str> {
    let mut w = command.split_whitespace().peekable();
    if w.peek() == Some(&"sealctl") {
        w.next();
    }
    w
}

/// The CLI sends its own arguments without the program name (`scan`, `run -- npm test`); they
/// read as the command typed. The SSH agent's signing request names no CLI command.
fn with_sealctl(command: &str) -> String {
    if command == "sealctl"
        || command.starts_with("sealctl ")
        || command.starts_with("ssh signature with ")
    {
        command.to_owned()
    } else {
        format!("sealctl {command}")
    }
}

fn capitalised(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().chain(c).collect(),
        None => String::new(),
    }
}

/// The machine on the second line: its nickname, else its host without `user@` and `.local`
/// (with the tag when another machine has the same name); "unpaired (<8 characters>)" when
/// it is not paired.
fn machine_label(machine: Option<&Machine>, key: &str) -> String {
    let Some(m) = machine else {
        let head: String = key.chars().take(8).collect();
        return format!("unpaired ({})", display_text(head, 0));
    };
    if let Some(n) = m.nickname.as_deref().filter(|n| !n.is_empty()) {
        return shown(n, MAX_NAME);
    }
    let host = m.name.rsplit_once('@').map_or(m.name.as_str(), |(_, h)| h);
    let host = match host.len().checked_sub(".local".len()) {
        Some(cut)
            if cut > 0
                && host.is_char_boundary(cut)
                && host[cut..].eq_ignore_ascii_case(".local") =>
        {
            &host[..cut]
        }
        _ => host,
    };
    let host = if host.is_empty() {
        m.name.as_str()
    } else {
        host
    };
    let name = shown(host, MAX_NAME);
    if m.tag_shown {
        if let Ok(tag) = sealctl_core::machine_tag(m.key.clone()) {
            return format!("{name} #{tag}");
        }
    }
    name
}

fn outcome(code: &str) -> (String, ActivityTone) {
    let text = match code {
        "one_tap" => "One tap",
        "automatic" => "Answered by itself",
        "in_session" => "In session",
        "once" => "Allowed once",
        "denied" => "Denied",
        "expired" => "Expired",
        "confirmed" => "Confirmed",
        other => return (shown(other, MAX_AGENT), ActivityTone::Normal),
    };
    let tone = match code {
        "denied" => ActivityTone::Declined,
        "expired" => ActivityTone::Muted,
        _ => ActivityTone::Normal,
    };
    (text.to_owned(), tone)
}

/// A machine's value made safe to show, with its UUIDs shortened.
fn shown(text: &str, max: u32) -> String {
    display_text(short_uuids(text), max)
}

/// An object id as Inventory shows it: `a7c3…42`.
fn short_id(id: &str) -> String {
    let chars: Vec<char> = id.chars().collect();
    if chars.len() <= 8 {
        return display_text(id.to_owned(), 0);
    }
    let head: String = chars[..4].iter().collect();
    let tail: String = chars[chars.len() - 2..].iter().collect();
    display_text(format!("{head}…{tail}"), 0)
}

/// Every UUID (`8-4-4-4-12` hex digits, standing alone) becomes its first four and last two
/// characters: `5D1E7B2A-94C3-4F60-8A1B-3C2D4E5F6071` → `5D1E…71`.
pub(crate) fn short_uuids(text: &str) -> String {
    const LEN: usize = 36;
    let b = text.as_bytes();
    let is_uuid = |s: &[u8]| {
        s.iter().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => *c == b'-',
            _ => c.is_ascii_hexdigit(),
        })
    };
    let word = |c: u8| c.is_ascii_alphanumeric() || c == b'-' || c == b'_';
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    let mut copied = 0;
    while i + LEN <= b.len() {
        let alone = (i == 0 || !word(b[i - 1])) && (i + LEN == b.len() || !word(b[i + LEN]));
        if alone && is_uuid(&b[i..i + LEN]) {
            out.push_str(&text[copied..i]);
            out.push_str(&text[i..i + 4]);
            out.push('…');
            out.push_str(&text[i + LEN - 2..i + LEN]);
            i += LEN;
            copied = i;
        } else {
            i += 1;
        }
    }
    out.push_str(&text[copied..]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOUR: u64 = 3_600_000;

    fn mac_mini() -> Machine {
        Machine {
            key: "A".repeat(43), // a valid key (`machine_tag`)
            name: "dev@Devs-Mac-mini.local".into(),
            os: "macOS 26.1".into(),
            ..Machine::default()
        }
    }

    fn entry(key: &str, outcome: &str) -> UsageEntry {
        UsageEntry {
            time: 9 * HOUR,
            machine: mac_mini().key,
            key: key.into(),
            outcome: outcome.into(),
            ..UsageEntry::default()
        }
    }

    fn row(subject: &str, outcome: &str, tone: ActivityTone, details: &[&str]) -> ActivityRow {
        ActivityRow {
            subject: subject.into(),
            outcome: outcome.into(),
            tone,
            details: details.iter().map(|d| (*d).to_owned()).collect(),
        }
    }

    // The rows of SPEC.md 11.12, as the old one-line log showed them:
    //   web-relay/web-relay-token · dev · scan · dev@Devs-Mac-mini.local · In session
    #[test]
    fn a_session_use_names_the_secret_and_its_project() {
        let e = UsageEntry {
            repo: Some("dev".into()), // run in the home folder (`/Users/dev`): no repository
            command: Some("scan".into()),
            ..entry("web-relay/web-relay-token", "in_session")
        };
        assert_eq!(
            activity_row(e, Some(mac_mini())),
            row(
                "web-relay-token",
                "In session",
                ActivityTone::Normal,
                &["web-relay", "sealctl scan", "Devs-Mac-mini"]
            )
        );
    }

    //   agent-lib-1.4.0/ubuntu-packages · dev@Devs-Mac-mini.local · One tap
    #[test]
    fn a_secret_asked_for_once() {
        let e = UsageEntry {
            kind: Some("secret".into()),
            ..entry("agent-lib-1.4.0/ubuntu-packages", "one_tap")
        };
        assert_eq!(
            activity_row(e, Some(mac_mini())),
            row(
                "ubuntu-packages",
                "One tap",
                ActivityTone::Normal,
                &["agent-lib-1.4.0", "Devs-Mac-mini"]
            )
        );
    }

    //   safe · dev@Devs-Mac-mini.local · Allowed once
    #[test]
    fn volumes_and_backups_say_what_they_are() {
        let e = UsageEntry {
            kind: Some("volume".into()),
            ..entry("safe", "once")
        };
        assert_eq!(
            activity_row(e, Some(mac_mini())),
            row(
                "Volume safe",
                "Allowed once",
                ActivityTone::Normal,
                &["Devs-Mac-mini"]
            )
        );
        let e = UsageEntry {
            kind: Some("backup".into()),
            ..entry("r2:acme-backups", "denied")
        };
        let r = activity_row(e, Some(mac_mini()));
        assert_eq!(r.subject, "Backup r2:acme-backups");
        assert_eq!(
            (r.outcome.as_str(), r.tone),
            ("Denied", ActivityTone::Declined)
        );
        let e = UsageEntry {
            kind: Some("ssh".into()),
            ..entry("github", "expired")
        };
        let r = activity_row(e, Some(mac_mini()));
        assert_eq!(r.subject, "SSH key github");
        assert_eq!(
            (r.outcome.as_str(), r.tone),
            ("Expired", ActivityTone::Muted)
        );
    }

    //   seal · seal volume safe 5D1E7B2A-… · dev@Devs-Mac-mini.local · Confirmed
    #[test]
    fn a_seal_reads_as_the_action() {
        let seal = |kind: Option<&str>| UsageEntry {
            kind: kind.map(str::to_owned),
            command: Some("seal volume safe 5D1E7B2A-94C3-4F60-8A1B-3C2D4E5F6071".into()),
            ..entry("seal", "confirmed")
        };
        let want = row(
            "Seal volume safe",
            "Confirmed",
            ActivityTone::Normal,
            &["Devs-Mac-mini"],
        );
        assert_eq!(activity_row(seal(Some("machine")), Some(mac_mini())), want);
        // recorded before the kind was: the command says it was `sealctl seal`
        assert_eq!(activity_row(seal(None), Some(mac_mini())), want);
        // `sealctl migrate` asks with the subject "rewrap"
        let e = UsageEntry {
            kind: Some("machine".into()),
            command: Some("sealctl migrate".into()),
            ..entry("rewrap", "confirmed")
        };
        let r = activity_row(e, Some(mac_mini()));
        assert_eq!(r.subject, "Rewrap");
        assert_eq!(r.details, ["sealctl migrate", "Devs-Mac-mini"]);
    }

    //   secrets a7c3e9f1-… · sealctl unseal · Zq7Lr2Xa · Confirmed (machine since unpaired)
    #[test]
    fn an_item_and_an_unpaired_machine() {
        let e = UsageEntry {
            machine: "Zq7Lr2Xaq0r1s2t3u4v5w6x7y8z9A0B1C2D3E4F5G6H".into(),
            command: Some("sealctl unseal".into()),
            kind: Some("secrets".into()),
            ..entry("secrets a7c3e9f1-2b4d-4e6f-8a0c-1d3e5f7a9b42", "confirmed")
        };
        let want = row(
            "Secret store a7c3…42",
            "Confirmed",
            ActivityTone::Normal,
            &["sealctl unseal", "unpaired (Zq7Lr2Xa)"],
        );
        assert_eq!(activity_row(e.clone(), None), want);
        // recorded before the kind was
        assert_eq!(
            activity_row(
                UsageEntry {
                    kind: None,
                    ..e.clone()
                },
                None
            ),
            want
        );
        // a removed machine is no longer paired
        let gone = Machine {
            deleted: true,
            ..mac_mini()
        };
        assert_eq!(activity_row(e, Some(gone)), want);
    }

    #[test]
    fn the_second_line_keeps_its_order_and_drops_empty_parts() {
        let e = UsageEntry {
            agent: Some("claude".into()),
            repo: Some("shop".into()),
            command: Some("run -- npm test".into()),
            ..entry("shop/STRIPE_KEY", "automatic")
        };
        let r = activity_row(e, Some(mac_mini()));
        assert_eq!(r.subject, "STRIPE_KEY");
        assert_eq!(r.outcome, "Answered by itself");
        assert_eq!(
            r.details,
            [
                "shop",
                "claude",
                "shop",
                "sealctl run -- npm test",
                "Devs-Mac-mini"
            ]
        );
        let e = UsageEntry {
            agent: Some(" ".into()),
            repo: Some(String::new()),
            command: Some(String::new()),
            ..entry("OPENAI_API_KEY", "one_tap")
        };
        assert_eq!(activity_row(e, Some(mac_mini())).details, ["Devs-Mac-mini"]);
    }

    #[test]
    fn the_machine_is_its_nickname_or_its_short_host() {
        let e = entry("API", "one_tap");
        let nick = Machine {
            nickname: Some("Work laptop".into()),
            ..mac_mini()
        };
        assert_eq!(activity_row(e.clone(), Some(nick)).details, ["Work laptop"]);
        let plain = Machine {
            name: "dev@mbp.example.com".into(),
            ..mac_mini()
        };
        assert_eq!(
            activity_row(e.clone(), Some(plain)).details,
            ["mbp.example.com"]
        );
        let bare = Machine {
            name: "build-box.LOCAL".into(),
            ..mac_mini()
        };
        assert_eq!(activity_row(e.clone(), Some(bare)).details, ["build-box"]);
        let tagged = Machine {
            tag_shown: true,
            ..mac_mini()
        };
        let tag = sealctl_core::machine_tag(mac_mini().key).unwrap();
        assert_eq!(
            activity_row(e, Some(tagged)).details,
            [format!("Devs-Mac-mini #{tag}")]
        );
    }

    #[test]
    fn a_repository_is_dropped_only_when_it_is_the_user_s_own_folder() {
        let e = |repo: &str| UsageEntry {
            repo: Some(repo.into()),
            ..entry("API", "one_tap")
        };
        assert_eq!(
            activity_row(e("dev"), Some(mac_mini())).details,
            ["Devs-Mac-mini"]
        );
        assert_eq!(
            activity_row(e("devtools"), Some(mac_mini())).details,
            ["devtools", "Devs-Mac-mini"]
        );
        // with no machine to compare with, it stays
        assert_eq!(activity_row(e("dev"), None).details[0], "dev");
    }

    #[test]
    fn commands_read_as_typed() {
        assert_eq!(with_sealctl("scan"), "sealctl scan");
        assert_eq!(with_sealctl("sealctl unseal"), "sealctl unseal");
        assert_eq!(
            with_sealctl("ssh signature with github"),
            "ssh signature with github"
        );
        let e = UsageEntry {
            command: Some("volume open 5D1E7B2A-94C3-4F60-8A1B-3C2D4E5F6071".into()),
            ..entry("x", "one_tap")
        };
        assert_eq!(
            activity_row(e, Some(mac_mini())).details[0],
            "sealctl volume open 5D1E…71"
        );
    }

    #[test]
    fn uuids_are_shortened_only_where_they_stand_alone() {
        assert_eq!(
            short_uuids(
                "a 5D1E7B2A-94C3-4F60-8A1B-3C2D4E5F6071 b a7c3e9f1-2b4d-4e6f-8a0c-1d3e5f7a9b42"
            ),
            "a 5D1E…71 b a7c3…42"
        );
        assert_eq!(
            short_uuids("/Volumes/a7c3e9f1-2b4d-4e6f-8a0c-1d3e5f7a9b42/x"),
            "/Volumes/a7c3…42/x"
        );
        let glued = "xa7c3e9f1-2b4d-4e6f-8a0c-1d3e5f7a9b42";
        assert_eq!(short_uuids(glued), glued);
        assert_eq!(short_uuids("ünïcode — fine"), "ünïcode — fine");
        assert_eq!(short_id("abc"), "abc");
    }

    #[test]
    fn machine_text_is_made_safe() {
        let e = UsageEntry {
            kind: Some("volume".into()),
            ..entry("safe\u{202E}gpj", "one_tap")
        };
        assert_eq!(activity_row(e, None).subject, "Volume safe\u{FFFD}gpj");
        let e = entry("", "denied");
        assert_eq!(activity_row(e, None).subject, "Request");
        let e = UsageEntry {
            outcome: "later".into(),
            ..entry("API", "")
        };
        assert_eq!(activity_row(e, None).outcome, "later");
    }
}
