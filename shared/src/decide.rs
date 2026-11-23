//! When the phone asks, and how (SPEC.md 9.3 levels of asking, 9.6 confirmation levels).
//!
//! `decide` is the one place both apps take these answers from. It never sees a key: it reads
//! the opened request's public fields and the phone's context.

use std::sync::Arc;

use sealctl_core::{Decision, Place as PlaceKind, RefuseReason, Request, RequestKind};

use crate::day::day_end;
use crate::model::{DayRecord, Hold, PlanApprovalRecord, RememberedAnswer, TrustedPlace};

/// Two hours, the level 3 delay away from a trusted place.
pub const DELAY_SECS: u32 = 7200;
/// How long after `not_before` an approved plan hands out keys.
pub const PLAN_WINDOW_MS: u64 = 30 * 60 * 1000;
/// How long a wrong number holds a machine's sensitive requests.
pub const HOLD_MS: u64 = 60 * 60 * 1000;

/// How the phone answers.
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum Asking {
    /// Answered with no tap (`automatic_decision`).
    Automatic,
    /// A notification with actions, or the approval card in the foreground.
    OneTap,
    /// A notification that opens the app: levels 2 and 3, `old_words`, unknown kinds.
    InApp,
    /// `report`: answered with `seal_report_reply`, never shown.
    Silent,
    /// Answered at once with `refuse` and no notification (`held`), or with a notice
    /// (`not_near`, `no_biometrics`).
    Refused,
    /// A later part of an approved plan: answered with `seal_plan_keys_reply`.
    PlanKeys,
}

/// The buttons the card and the notification offer, in order.
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplyOption {
    /// "Allow for this session" (`Session`, or `Remember` when an agent's first use is merged).
    AllowSession,
    /// "Allow" for `agent` (`Remember`) and `keys` (`Session`).
    Allow,
    /// "Allow once" (`Once`).
    AllowOnce,
    /// "Deny".
    Deny,
    /// Level 2 and 3: confirm with biometrics (and the number, plan, delay before it).
    Confirm,
}

/// What biometrics can do on this phone right now.
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum Biometrics {
    /// Strong biometrics enrolled and usable.
    Available,
    /// No hardware, none enrolled, or only weak (class 2).
    Unavailable,
    /// Locked out after failed tries.
    LockedOut,
    /// Enrolment changed: the gate key was invalidated.
    Changed,
}

/// The phone's context for one request (SPEC.md 9.1 step 4).
#[derive(uniffi::Record, Debug, Clone)]
pub struct DecideContext {
    /// Unix ms.
    pub now: u64,
    /// The phone's UTC offset now.
    pub utc_offset_secs: i32,
    /// The root can be read (device unlocked).
    pub phone_unlocked: bool,
    /// The relay's `near` flag.
    pub near: bool,
    /// The phone is on Wi-Fi or Ethernet.
    pub on_wifi: bool,
    /// Location permission given (places on).
    pub places_on: bool,
    /// The trusted place the phone is inside.
    pub current_place: Option<String>,
    /// That place also lifts the level 3 delay ([`place_settled`]).
    pub current_place_settled: bool,
    /// This machine's day record.
    pub day: Option<DayRecord>,
    /// Live answers.
    pub answers: Vec<RememberedAnswer>,
    /// The machine's session is Open by its last status.
    pub session_open: bool,
    /// A hold on this machine.
    pub hold: Option<Hold>,
    /// Biometrics on this phone.
    pub biometrics: Biometrics,
    /// An approved plan of this machine.
    pub plan: Option<PlanApprovalRecord>,
}

/// The outcome of `decide`.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct Verdict {
    /// How the phone answers.
    pub asking: Asking,
    /// Confirmation level 1 to 3.
    pub level: u8,
    /// The request kind.
    pub kind: RequestKind,
    /// Buttons, in order.
    pub options: Vec<ReplyOption>,
    /// The decision to seal when `asking` is `Automatic`.
    pub automatic: Option<Decision>,
    /// The refusal when `asking` is `Refused`.
    pub refuse: Option<RefuseReason>,
    /// Where the phone is, for the reply.
    pub place: PlaceKind,
    /// Level 2 and 3: the number match comes first.
    pub needs_number: bool,
    /// Level 2 and 3: biometrics (strong, no device credential).
    pub needs_biometrics: bool,
    /// Level 2 without usable biometrics (or after an enrolment change): two words from the card.
    pub needs_card_words: bool,
    /// The plan or object list is shown.
    pub shows_plan: bool,
    /// Seconds the approval waits (level 3 away from a trusted place).
    pub delay_secs: u32,
    /// An `open` from an agent with no answer: "Allow for this session" also remembers.
    pub agent_first_use: bool,
    /// `open` would answer by itself at the current place (the card's last line).
    pub answers_by_itself_here: bool,
}

/// What `decide` reads from a request; the opened `Request` or a test's own.
#[derive(Debug, Clone, Default)]
pub struct RequestFacts {
    /// Kind.
    pub kind: Option<RequestKind>,
    /// `Request::level()`.
    pub level: u8,
    /// `match` was set.
    pub has_match: bool,
    /// Machine key.
    pub machine: String,
    /// Agent uses: (agent, repository id, names).
    pub uses: Vec<(String, String, Vec<String>)>,
    /// Plan hash of an `unseal`.
    pub plan_hash: Option<String>,
    /// The request is part `i` of `n` with `i < n` (acknowledged without asking).
    pub plan_part_pending: bool,
    /// The request asks for keys.
    pub has_keys: bool,
}

impl RequestFacts {
    /// Facts of an opened request.
    pub fn of(request: &Request) -> Self {
        let plan = request.plan();
        Self {
            kind: Some(request.kind()),
            level: request.level(),
            has_match: request.has_match(),
            machine: request.machine(),
            uses: request
                .uses()
                .into_iter()
                .map(|u| (u.agent, u.repository, u.names))
                .collect(),
            plan_hash: plan.as_ref().map(|p| p.hash.clone()),
            plan_part_pending: plan
                .as_ref()
                .is_some_and(|p| !p.complete && p.part.zip(p.parts).is_some_and(|(i, n)| i < n)),
            has_keys: !request.items().is_empty(),
        }
    }
}

/// The place kind for a reply (SPEC.md 9.4).
#[uniffi::export]
pub fn place_kind(places_on: bool, current_place: Option<String>) -> PlaceKind {
    match (places_on, current_place) {
        (false, _) => PlaceKind::NoLocation,
        (true, Some(_)) => PlaceKind::Trusted,
        (true, None) => PlaceKind::Other,
    }
}

/// A place added by hand lifts the level 3 delay only this long after it was added (SPEC.md 9.6):
/// someone holding the unlocked phone cannot trust "here" and skip the hour.
pub const MANUAL_PLACE_SETTLE_MS: u64 = 24 * 3_600_000;

/// Whether a trusted place also lifts the level 3 delay at `now`: a learned place at once, a place
/// added by hand 24 hours after it was added. Every other comfort of a place starts at once.
#[uniffi::export]
pub fn place_settled(place: TrustedPlace, now: u64) -> bool {
    !place.deleted && (!place.manual || now >= place.created.saturating_add(MANUAL_PLACE_SETTLE_MS))
}

/// Whether every agent use has a live answer. A use that names no key has none.
fn uses_answered(uses: &[(String, String, Vec<String>)], answers: &[RememberedAnswer]) -> bool {
    uses.iter().all(|(agent, repo, names)| {
        !names.is_empty()
            && names.iter().all(|n| {
                answers.iter().any(|a| {
                    !a.deleted && &a.agent == agent && &a.repo_id == repo && &a.key_name == n
                })
            })
    })
}

/// The day record is current: not ended.
pub fn day_active(day: &DayRecord, now: u64, utc_offset_secs: i32) -> bool {
    let ends = if day.ends > 0 {
        day.ends
    } else {
        day_end(day.first_approval, utc_offset_secs)
    };
    now < ends
}

/// Decides one opened request.
#[uniffi::export]
pub fn decide(request: Arc<Request>, ctx: DecideContext) -> Verdict {
    decide_facts(&RequestFacts::of(&request), &ctx)
}

fn verdict(kind: RequestKind, level: u8, place: PlaceKind) -> Verdict {
    Verdict {
        asking: Asking::OneTap,
        level,
        kind,
        options: Vec::new(),
        automatic: None,
        refuse: None,
        place,
        needs_number: false,
        needs_biometrics: false,
        needs_card_words: false,
        shows_plan: false,
        delay_secs: 0,
        agent_first_use: false,
        answers_by_itself_here: false,
    }
}

/// [`decide`] on facts; the rules of SPEC.md 9.3 and 9.6.
pub fn decide_facts(f: &RequestFacts, ctx: &DecideContext) -> Verdict {
    use ReplyOption::*;
    let kind = f.kind.unwrap_or(RequestKind::Unknown);
    let place = place_kind(ctx.places_on, ctx.current_place.clone());
    let level = f.level.clamp(1, 3);
    let mut v = verdict(kind, level, place);
    let near = ctx.near && ctx.on_wifi;

    if kind == RequestKind::Report {
        v.asking = Asking::Silent;
        v.level = 1;
        return v;
    }
    if kind == RequestKind::Unknown {
        v.asking = Asking::InApp;
        v.level = 3;
        v.options = vec![Deny];
        return v;
    }

    // A later request of an approved plan (same machine and hash) is answered without asking.
    if kind == RequestKind::Unseal {
        if let (Some(plan), Some(hash)) = (&ctx.plan, &f.plan_hash) {
            if plan.machine == f.machine
                && &plan.plan_hash == hash
                && plan.state != "cancelled"
                && ctx.now >= plan.not_before
                && ctx.now <= plan.not_before + PLAN_WINDOW_MS
            {
                v.asking = Asking::PlanKeys;
                return v;
            }
        }
        if f.plan_part_pending {
            // A part other than the last: acknowledged, the whole plan is shown with the last part.
            v.asking = Asking::Silent;
            return v;
        }
    }

    if level == 1 {
        match kind {
            RequestKind::Open => {
                v.options = vec![AllowSession, AllowOnce, Deny];
                let answered = uses_answered(&f.uses, &ctx.answers);
                v.agent_first_use = !answered;
                let day_here = ctx.day.as_ref().is_some_and(|d| {
                    day_active(d, ctx.now, ctx.utc_offset_secs)
                        && d.place_id.is_some()
                        && d.place_id == ctx.current_place
                });
                let auto = day_here && near && ctx.phone_unlocked && answered;
                v.answers_by_itself_here = ctx.current_place.is_some() && answered;
                if auto {
                    v.asking = Asking::Automatic;
                    v.automatic = Some(Decision::Session { place });
                }
            }
            RequestKind::Agent => {
                v.options = vec![Allow, AllowOnce, Deny];
                v.agent_first_use = true;
                // An answer covers the named keys only; any other keys follow the `keys` rule.
                if uses_answered(&f.uses, &ctx.answers)
                    && !f.uses.is_empty()
                    && (!f.has_keys || ctx.session_open)
                {
                    v.asking = Asking::Automatic;
                    v.agent_first_use = false;
                    v.automatic = Some(Decision::Session { place });
                }
            }
            RequestKind::Own => v.options = vec![AllowOnce, Deny],
            RequestKind::Keys => {
                v.options = vec![Allow, Deny];
                if ctx.phone_unlocked && ctx.session_open {
                    v.asking = Asking::Automatic;
                    v.automatic = Some(Decision::Session { place });
                }
            }
            // A machine cannot lower a level; these kinds are level 2 by the core.
            _ => {
                v.level = 2;
                return sensitive(v, f, ctx, near);
            }
        }
        // The phone must be unlocked to hand out keys automatically; a locked phone asks.
        if v.asking == Asking::Automatic && f.has_keys && !ctx.phone_unlocked {
            v.asking = Asking::OneTap;
            v.automatic = None;
        }
        return v;
    }
    sensitive(v, f, ctx, near)
}

/// Levels 2 and 3 (SPEC.md 9.6).
fn sensitive(mut v: Verdict, f: &RequestFacts, ctx: &DecideContext, near: bool) -> Verdict {
    v.asking = Asking::InApp;
    v.options = vec![ReplyOption::Confirm, ReplyOption::Deny];
    v.shows_plan = true;
    v.needs_biometrics = true;
    if ctx.hold.as_ref().is_some_and(|h| ctx.now < h.until) {
        return refuse(v, RefuseReason::Held);
    }
    if v.kind == RequestKind::OldWords {
        // The old words are typed (11.15): Face ID or the passcode first, as for restore.
        v.needs_biometrics = false;
        return v;
    }
    match ctx.biometrics {
        Biometrics::Available => {}
        Biometrics::Changed => v.needs_card_words = true,
        Biometrics::Unavailable | Biometrics::LockedOut => {
            if v.level >= 3 {
                return refuse(v, RefuseReason::NoBiometrics);
            }
            v.needs_card_words = true;
            v.needs_biometrics = false;
        }
    }
    if v.level >= 3 {
        if !f.has_match {
            return refuse(v, RefuseReason::NotNear);
        }
        v.needs_number = true;
        if v.place != PlaceKind::Trusted || !ctx.current_place_settled {
            v.delay_secs = DELAY_SECS;
        }
    } else if !near {
        if f.has_match {
            v.needs_number = true;
        } else {
            return refuse(v, RefuseReason::NotNear);
        }
    }
    v
}

fn refuse(mut v: Verdict, err: RefuseReason) -> Verdict {
    v.asking = Asking::Refused;
    v.refuse = Some(err);
    v.options = Vec::new();
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_795_251_720_000;

    fn ctx() -> DecideContext {
        DecideContext {
            now: NOW,
            utc_offset_secs: 0,
            phone_unlocked: true,
            near: true,
            on_wifi: true,
            places_on: true,
            current_place: Some("desk".into()),
            current_place_settled: true,
            day: Some(DayRecord {
                machine: "m".into(),
                first_approval: NOW - 3_600_000,
                place_id: Some("desk".into()),
                ends: 0,
            }),
            answers: vec![answer("claude", "OPENAI_API_KEY", "github.com/acme/shop")],
            session_open: true,
            hold: None,
            biometrics: Biometrics::Available,
            plan: None,
        }
    }

    fn answer(agent: &str, key: &str, repo: &str) -> RememberedAnswer {
        RememberedAnswer {
            agent: agent.into(),
            key_name: key.into(),
            repo_id: repo.into(),
            ..RememberedAnswer::default()
        }
    }

    fn facts(kind: RequestKind, level: u8) -> RequestFacts {
        RequestFacts {
            kind: Some(kind),
            level,
            machine: "m".into(),
            has_keys: true,
            ..RequestFacts::default()
        }
    }

    fn with_use(mut f: RequestFacts, key: &str) -> RequestFacts {
        f.uses = vec![(
            "claude".into(),
            "github.com/acme/shop".into(),
            vec![key.into()],
        )];
        f
    }

    #[test]
    fn open_automatic_only_when_every_condition_holds() {
        let f = with_use(facts(RequestKind::Open, 1), "OPENAI_API_KEY");
        let v = decide_facts(&f, &ctx());
        assert_eq!(v.asking, Asking::Automatic);
        assert_eq!(
            v.automatic,
            Some(Decision::Session {
                place: PlaceKind::Trusted
            })
        );

        type Breaker = Box<dyn Fn(&mut DecideContext)>;
        let breakers: Vec<Breaker> = vec![
            Box::new(|c| c.day = None),
            Box::new(|c| c.day.as_mut().unwrap().place_id = Some("home".into())),
            Box::new(|c| c.day.as_mut().unwrap().first_approval = NOW - 15 * 3_600_000),
            Box::new(|c| c.current_place = None),
            Box::new(|c| c.near = false),
            Box::new(|c| c.on_wifi = false),
            Box::new(|c| c.phone_unlocked = false),
            Box::new(|c| c.answers.clear()),
        ];
        for b in breakers {
            let mut c = ctx();
            b(&mut c);
            let v = decide_facts(&f, &c);
            assert_eq!(v.asking, Asking::OneTap);
            assert_eq!(
                v.options,
                vec![
                    ReplyOption::AllowSession,
                    ReplyOption::AllowOnce,
                    ReplyOption::Deny
                ]
            );
        }
    }

    #[test]
    fn open_from_agent_without_answer_is_first_use() {
        let f = with_use(facts(RequestKind::Open, 1), "AWS_KEY");
        let v = decide_facts(&f, &ctx());
        assert_eq!(v.asking, Asking::OneTap);
        assert!(v.agent_first_use);
    }

    #[test]
    fn agent_own_keys() {
        let v = decide_facts(
            &with_use(facts(RequestKind::Agent, 1), "OPENAI_API_KEY"),
            &ctx(),
        );
        assert_eq!(v.asking, Asking::Automatic);
        let v = decide_facts(&with_use(facts(RequestKind::Agent, 1), "OTHER"), &ctx());
        assert_eq!((v.asking, v.agent_first_use), (Asking::OneTap, true));
        // A use that names no key is not an answered one.
        let mut f = facts(RequestKind::Agent, 1);
        f.uses = vec![("claude".into(), "github.com/acme/shop".into(), vec![])];
        assert_eq!(decide_facts(&f, &ctx()).asking, Asking::OneTap);
        f.has_keys = false;
        assert_eq!(decide_facts(&f, &ctx()).asking, Asking::OneTap);
        // Keys on an answered `agent` need an Open session, as `keys` does.
        let mut c = ctx();
        c.session_open = false;
        let f = with_use(facts(RequestKind::Agent, 1), "OPENAI_API_KEY");
        assert_eq!(decide_facts(&f, &c).asking, Asking::OneTap);
        let mut f = f;
        f.has_keys = false;
        assert_eq!(decide_facts(&f, &c).asking, Asking::Automatic);
        assert_eq!(
            v.options,
            vec![
                ReplyOption::Allow,
                ReplyOption::AllowOnce,
                ReplyOption::Deny
            ]
        );

        let v = decide_facts(&facts(RequestKind::Own, 1), &ctx());
        assert_eq!(
            (v.asking, v.options.clone()),
            (
                Asking::OneTap,
                vec![ReplyOption::AllowOnce, ReplyOption::Deny]
            )
        );

        let v = decide_facts(&facts(RequestKind::Keys, 1), &ctx());
        assert_eq!(v.asking, Asking::Automatic);
        let mut c = ctx();
        c.session_open = false;
        assert_eq!(
            decide_facts(&facts(RequestKind::Keys, 1), &c).asking,
            Asking::OneTap
        );
        let mut c = ctx();
        c.phone_unlocked = false;
        assert_eq!(
            decide_facts(&facts(RequestKind::Keys, 1), &c).asking,
            Asking::OneTap
        );
    }

    #[test]
    fn report_unknown_and_place_kinds() {
        assert_eq!(
            decide_facts(&facts(RequestKind::Report, 1), &ctx()).asking,
            Asking::Silent
        );
        let v = decide_facts(&facts(RequestKind::Unknown, 1), &ctx());
        assert_eq!(
            (v.asking, v.level, v.options.clone()),
            (Asking::InApp, 3, vec![ReplyOption::Deny])
        );
        assert_eq!(place_kind(false, Some("x".into())), PlaceKind::NoLocation);
        assert_eq!(place_kind(true, None), PlaceKind::Other);
        assert_eq!(place_kind(true, Some("x".into())), PlaceKind::Trusted);
    }

    #[test]
    fn level_two_proximity() {
        let f = facts(RequestKind::Unseal, 2);
        let v = decide_facts(&f, &ctx());
        assert_eq!(v.asking, Asking::InApp);
        assert!(v.needs_biometrics && !v.needs_number && v.shows_plan);
        assert_eq!(v.delay_secs, 0);

        // Near only counts on Wi-Fi.
        let mut c = ctx();
        c.on_wifi = false;
        let v = decide_facts(&f, &c);
        assert_eq!(v.refuse, Some(RefuseReason::NotNear));
        let mut fm = f.clone();
        fm.has_match = true;
        let v = decide_facts(&fm, &c);
        assert!(v.needs_number);
        assert_eq!(v.asking, Asking::InApp);
    }

    #[test]
    fn hand_added_places_settle_after_a_day() {
        let learned = TrustedPlace { id: "p".into(), created: NOW, ..TrustedPlace::default() };
        assert!(place_settled(learned.clone(), NOW));
        let manual = TrustedPlace { manual: true, ..learned };
        assert!(!place_settled(manual.clone(), NOW));
        assert!(!place_settled(manual.clone(), NOW + MANUAL_PLACE_SETTLE_MS - 1));
        assert!(place_settled(manual.clone(), NOW + MANUAL_PLACE_SETTLE_MS));
        assert!(!place_settled(TrustedPlace { deleted: true, ..manual }, NOW + 2 * MANUAL_PLACE_SETTLE_MS));
    }

    #[test]
    fn rewrap_and_seal_are_level_two() {
        // The core reports these as level 2; a level 1 fact for rewrap is raised.
        let v = decide_facts(&facts(RequestKind::Rewrap, 1), &ctx());
        assert_eq!((v.asking, v.level), (Asking::InApp, 2));
        let v = decide_facts(&facts(RequestKind::Keys, 2), &ctx());
        assert_eq!((v.asking, v.level), (Asking::InApp, 2));
    }

    #[test]
    fn level_three_number_delay_biometrics() {
        let mut f = facts(RequestKind::Unseal, 3);
        // No number: refused not_near even when near.
        assert_eq!(decide_facts(&f, &ctx()).refuse, Some(RefuseReason::NotNear));
        f.has_match = true;
        let v = decide_facts(&f, &ctx());
        assert!(v.needs_number && v.needs_biometrics);
        assert_eq!(v.delay_secs, 0);
        let mut c = ctx();
        c.current_place = None;
        assert_eq!(decide_facts(&f, &c).delay_secs, DELAY_SECS);
        c.places_on = false;
        let v = decide_facts(&f, &c);
        assert_eq!((v.delay_secs, v.place), (DELAY_SECS, PlaceKind::NoLocation));
        // a trusted place that has not settled yet (added by hand under 24 hours ago): the place
        // stays trusted for comfort, the delay stays
        let mut c = ctx();
        c.current_place_settled = false;
        let v = decide_facts(&f, &c);
        assert_eq!((v.delay_secs, v.place), (DELAY_SECS, PlaceKind::Trusted));

        for b in [Biometrics::Unavailable, Biometrics::LockedOut] {
            let mut c = ctx();
            c.biometrics = b;
            assert_eq!(
                decide_facts(&f, &c).refuse,
                Some(RefuseReason::NoBiometrics)
            );
            let v2 = decide_facts(&facts(RequestKind::Unseal, 2), &c);
            assert!(v2.needs_card_words && !v2.needs_biometrics && v2.refuse.is_none());
        }
        let mut c = ctx();
        c.biometrics = Biometrics::Changed;
        let v = decide_facts(&f, &c);
        assert!(v.needs_card_words && v.needs_biometrics);
    }

    #[test]
    fn holds_refuse_quietly() {
        let mut c = ctx();
        c.hold = Some(Hold {
            machine: "m".into(),
            until: NOW + 1,
        });
        let v = decide_facts(&facts(RequestKind::Unseal, 2), &c);
        assert_eq!(
            (v.asking, v.refuse),
            (Asking::Refused, Some(RefuseReason::Held))
        );
        // Level 1 is not held.
        assert_eq!(
            decide_facts(&facts(RequestKind::Own, 1), &c).asking,
            Asking::OneTap
        );
        c.hold.as_mut().unwrap().until = NOW;
        assert_eq!(
            decide_facts(&facts(RequestKind::Unseal, 2), &c).asking,
            Asking::InApp
        );
    }

    #[test]
    fn plan_window() {
        let mut f = facts(RequestKind::Unseal, 3);
        f.has_match = true;
        f.plan_hash = Some("h".into());
        let mut c = ctx();
        c.plan = Some(PlanApprovalRecord {
            machine: "m".into(),
            plan_hash: "h".into(),
            not_before: NOW - 1000,
            state: "approved".into(),
            ..PlanApprovalRecord::default()
        });
        assert_eq!(decide_facts(&f, &c).asking, Asking::PlanKeys);
        c.plan.as_mut().unwrap().not_before = NOW - PLAN_WINDOW_MS - 1;
        assert_eq!(decide_facts(&f, &c).asking, Asking::InApp);
        c.plan.as_mut().unwrap().not_before = NOW + 1;
        assert_eq!(decide_facts(&f, &c).asking, Asking::InApp);
        c.plan.as_mut().unwrap().not_before = NOW;
        c.plan.as_mut().unwrap().plan_hash = "other".into();
        assert_eq!(decide_facts(&f, &c).asking, Asking::InApp);
        f.plan_part_pending = true;
        assert_eq!(decide_facts(&f, &c).asking, Asking::Silent);
    }
}
