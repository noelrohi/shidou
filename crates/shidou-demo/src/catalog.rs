//! Answers for the settings surfaces: skills, usage history, plan meters, and
//! provider probes.
//!
//! The real daemon derives these from the host — installed CLIs, `~/.claude`,
//! JSONL usage logs. The demo derives them from nothing, so the settings slice
//! has populated screens to build against and a reviewer sees a configured
//! app rather than a column of empty states.

use std::path::PathBuf;
use std::time::Duration;

use chrono::NaiveDate;
use shidou_protocol::computer_use::ComputerPermissions;
use shidou_protocol::model::{ProviderKind, ProviderProbe};
use shidou_protocol::settings::DaemonSettings;
use shidou_protocol::skills::{SkillEntry, SkillInstall, SkillScope, SkillSource, SkillsCatalog};
use shidou_protocol::usage::{PlanUsage, PlanWindow};
use shidou_protocol::usage_history::{
    CostQuality, DaySlice, ModelSlice, MonthSlice, PricingStatus, ProjectSlice, ProviderDay,
    ProviderSlice, TokenTotals, UsageHistory, UsageProvider, UsageWindow, enumerate_days,
    enumerate_months, first_of_month,
};

use crate::sessions;
use crate::tree;

/// Providers the demo reports as installed. Everything else probes as absent,
/// which is the honest answer for a host with no agent CLIs on it at all.
const INSTALLED: [ProviderKind; 2] = [ProviderKind::Claude, ProviderKind::Codex];

pub fn settings() -> DaemonSettings {
    DaemonSettings {
        conventional_commit_messages: true,
        ..DaemonSettings::default()
    }
}

pub fn provider_probe(provider: ProviderKind) -> ProviderProbe {
    let installed = INSTALLED.contains(&provider);
    ProviderProbe {
        provider,
        installed,
        path: installed.then(|| PathBuf::from(format!("/opt/homebrew/bin/{}", provider.id()))),
        models: shidou_protocol::model_catalog::fallback_models(provider),
        agent_presets: shidou_protocol::model_catalog::fallback_agent_presets(provider),
    }
}

/// Both plan meters read part-used, so the panel shows a filled bar and a
/// reset time rather than the "no usage yet" state.
pub fn plan_usage(provider: ProviderKind) -> Option<PlanUsage> {
    if !INSTALLED.contains(&provider) {
        return None;
    }
    let resets = sessions::epoch() as i64;
    Some(PlanUsage {
        plan_label: Some("Demo".into()),
        windows: vec![
            PlanWindow {
                label: "5-hour".into(),
                percent: 34.0,
                resets_at: Some(resets + 2 * 60 * 60),
            },
            PlanWindow {
                label: "Weekly".into(),
                percent: 61.0,
                resets_at: Some(resets + 3 * 24 * 60 * 60),
            },
        ],
    })
}

/// Screen recording and accessibility are both denied. The demo host has no
/// display, and computer use would be a side effect — which the fixture has
/// none of by construction.
pub fn computer_permissions() -> ComputerPermissions {
    ComputerPermissions {
        screen_recording: false,
        accessibility: false,
    }
}

pub fn skills() -> SkillsCatalog {
    let user_root = PathBuf::from(tree::HOME).join(".claude/skills");
    let project_root = PathBuf::from(tree::WORKSPACE_ROOT).join(".claude/skills");
    SkillsCatalog {
        skills: vec![
            skill(
                "tdd",
                "Drive the change test-first: one failing test, then the code that passes it.",
                SkillScope::User,
                None,
                &user_root,
                true,
            ),
            skill(
                "code-review",
                "Review a branch against the repository's documented standards and its originating issue.",
                SkillScope::User,
                None,
                &user_root,
                true,
            ),
            skill(
                "release-notes",
                "Turn a range of commits into user-facing release notes.",
                SkillScope::Project,
                Some("shidou"),
                &project_root,
                false,
            ),
        ],
    }
}

fn skill(
    name: &str,
    description: &str,
    scope: SkillScope,
    project: Option<&str>,
    root: &std::path::Path,
    enabled: bool,
) -> SkillEntry {
    let dir = root.join(name);
    SkillEntry {
        name: name.to_owned(),
        description: description.to_owned(),
        scope,
        project: project.map(str::to_owned),
        installs: vec![SkillInstall {
            source: SkillSource::Shared,
            skill_file: dir.join(shidou_protocol::skills::SKILL_FILE),
            dir,
            enabled,
        }],
        enabled,
        allowed_tools: None,
        body: format!("# {name}\n\n{description}\n"),
        supporting_files: 0,
        total_bytes: description.len() as u64 + 64,
        modified_at: Some(sessions::epoch().saturating_sub(7 * 24 * 60 * 60)),
        duplicates: 0,
        row_key: u64::from(name.len() as u32),
    }
}

/// A synthetic spend history: a weekday rhythm across two providers, with the
/// shares and totals derived from the days so every panel agrees with itself.
pub fn usage_history(window: UsageWindow, project_roots: &[PathBuf]) -> UsageHistory {
    let today = today();
    let (since_day, until_day) = window.bounds(today);
    let days = enumerate_days(since_day, until_day);

    let mut daily = Vec::with_capacity(days.len());
    let mut totals = TokenTotals::default();
    let mut by_provider = [ProviderDay::default(); 2];
    for (index, day) in days.iter().enumerate() {
        let mut slice = DaySlice {
            day: *day,
            cost_usd: 0.0,
            total_tokens: 0,
            by_provider: [ProviderDay::default(); 2],
        };
        for provider in UsageProvider::ALL {
            let (cost, tokens) = day_spend(index, provider);
            slice.by_provider[provider.index()] = ProviderDay {
                cost_usd: cost,
                total_tokens: tokens,
            };
            slice.cost_usd += cost;
            slice.total_tokens += tokens;
            by_provider[provider.index()].cost_usd += cost;
            by_provider[provider.index()].total_tokens += tokens;
            totals.add(&TokenTotals {
                uncached_input: tokens / 10,
                cached_input: tokens / 2,
                cache_creation: tokens / 10,
                output: tokens - tokens / 10 - tokens / 2 - tokens / 10,
                reasoning: tokens / 20,
            });
        }
        daily.push(slice);
    }

    let cost_usd = daily.iter().map(|day| day.cost_usd).sum::<f64>();
    let total_tokens = daily.iter().map(|day| day.total_tokens).sum::<u64>();
    let share = |value: f64| {
        if cost_usd > 0.0 {
            value / cost_usd
        } else {
            0.0
        }
    };
    let token_share = |value: u64| {
        if total_tokens > 0 {
            value as f64 / total_tokens as f64
        } else {
            0.0
        }
    };

    let providers = UsageProvider::ALL
        .into_iter()
        .map(|provider| {
            let day = by_provider[provider.index()];
            ProviderSlice {
                provider,
                cost_usd: day.cost_usd,
                total_tokens: day.total_tokens,
                cost_share: share(day.cost_usd),
                token_share: token_share(day.total_tokens),
            }
        })
        .collect::<Vec<_>>();

    let models = MODELS
        .iter()
        .map(|(provider, model, weight)| {
            let cost = cost_usd * weight;
            ModelSlice {
                provider: *provider,
                model: (*model).to_owned(),
                cost_usd: cost,
                total_tokens: (total_tokens as f64 * weight) as u64,
                cost_share: share(cost),
            }
        })
        .collect::<Vec<_>>();

    let top_models = models
        .iter()
        .map(|model| (model.model.clone(), model.cost_usd))
        .take(3)
        .collect::<Vec<_>>();

    let months = enumerate_months(since_day, until_day)
        .into_iter()
        .map(|first_day| {
            let month: Vec<&DaySlice> = daily
                .iter()
                .filter(|slice| first_of_month(slice.day) == first_day)
                .collect();
            MonthSlice {
                first_day,
                cost_usd: month.iter().map(|slice| slice.cost_usd).sum(),
                total_tokens: month.iter().map(|slice| slice.total_tokens).sum(),
                by_provider: [0, 1].map(|index| ProviderDay {
                    cost_usd: month
                        .iter()
                        .map(|slice| slice.by_provider[index].cost_usd)
                        .sum(),
                    total_tokens: month
                        .iter()
                        .map(|slice| slice.by_provider[index].total_tokens)
                        .sum(),
                }),
                sessions: month.len() as u64 * 3,
                active_days: month.iter().filter(|slice| slice.total_tokens > 0).count() as u32,
                top_models: top_models.clone(),
            }
        })
        .collect();

    let roots = if project_roots.is_empty() {
        vec![
            PathBuf::from(tree::WORKSPACE_ROOT),
            PathBuf::from(tree::NOTES_ROOT),
        ]
    } else {
        project_roots.to_vec()
    };
    let projects = roots
        .iter()
        .enumerate()
        .map(|(index, root)| {
            // The first project carries most of the spend; the rest split the
            // remainder evenly, so the bar chart is never a flat row.
            let weight = if index == 0 {
                0.7
            } else {
                0.3 / (roots.len().saturating_sub(1).max(1)) as f64
            };
            ProjectSlice {
                path: root.display().to_string(),
                cost_usd: cost_usd * weight,
                total_tokens: (total_tokens as f64 * weight) as u64,
                by_provider: [0, 1].map(|provider| ProviderDay {
                    cost_usd: by_provider[provider].cost_usd * weight,
                    total_tokens: (by_provider[provider].total_tokens as f64 * weight) as u64,
                }),
                sessions: (daily.len() as f64 * weight).round() as u64,
                cost_share: weight,
                last_day: daily.last().map(|slice| slice.day),
                top_models: top_models.clone(),
            }
        })
        .collect();

    UsageHistory {
        window,
        since_day,
        until_day,
        totals,
        total_tokens,
        cost_usd,
        records: daily.len() as u64 * 18,
        sessions: daily.len() as u64 * 3,
        providers,
        models,
        daily,
        months,
        projects,
        quality: CostQuality {
            provider_reported_share: 0.82,
            model_priced_share: 0.18,
            unpriced_share: 0.0,
            cache_savings_usd: cost_usd * 0.44,
        },
        pricing: PricingStatus::Cached,
        scanned_files: 42,
        skipped_files: 0,
        errors: Vec::new(),
        scan_duration: Duration::from_millis(37),
    }
}

const MODELS: [(UsageProvider, &str, f64); 4] = [
    (UsageProvider::Claude, "claude-opus-5", 0.46),
    (UsageProvider::Codex, "gpt-5.6-sol", 0.31),
    (UsageProvider::Claude, "claude-sonnet-5", 0.15),
    (UsageProvider::Codex, "gpt-5.6-luna", 0.08),
];

/// Weekday-shaped spend: quiet at weekends, and each provider on its own
/// rhythm so the stacked chart has two distinguishable series.
fn day_spend(index: usize, provider: UsageProvider) -> (f64, u64) {
    let weekday = index % 7;
    let weekend = weekday >= 5;
    let base = match provider {
        UsageProvider::Claude => 4.20,
        UsageProvider::Codex => 2.60,
    };
    let wave = 1.0 + ((index * 7 + provider.index() * 3) % 5) as f64 / 10.0;
    let cost = if weekend { base * 0.2 } else { base } * wave;
    (cost, (cost * 220_000.0) as u64)
}

fn today() -> NaiveDate {
    chrono::DateTime::from_timestamp(sessions::epoch() as i64, 0)
        .map(|moment| moment.date_naive())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_two_reported_providers_probe_as_installed() {
        assert!(provider_probe(ProviderKind::Claude).installed);
        assert!(!provider_probe(ProviderKind::Amp).installed);
        assert!(provider_probe(ProviderKind::Amp).path.is_none());
        assert!(!provider_probe(ProviderKind::Claude).models.is_empty());
    }

    #[test]
    fn the_models_the_fixture_sessions_name_are_offered_by_their_providers() {
        let claude = provider_probe(ProviderKind::Claude);
        let codex = provider_probe(ProviderKind::Codex);

        assert!(
            claude
                .models
                .iter()
                .any(|model| model.id == "claude-opus-5")
        );
        assert!(codex.models.iter().any(|model| model.id == "gpt-5.6-sol"));
    }

    #[test]
    fn plan_meters_are_reported_only_for_installed_providers() {
        assert!(plan_usage(ProviderKind::Claude).is_some());
        assert!(plan_usage(ProviderKind::Grok).is_none());
        let usage = plan_usage(ProviderKind::Codex).unwrap();
        assert!(usage.windows.iter().all(|window| window.percent > 0.0));
        assert!(
            usage
                .windows
                .iter()
                .all(|window| window.resets_at.is_some())
        );
    }

    #[test]
    fn the_skills_catalog_has_an_enabled_and_a_disabled_entry() {
        let catalog = skills();

        assert_eq!(catalog.skills.len(), 3);
        assert_eq!(catalog.disabled_count(), 1);
        assert!(
            catalog
                .skills
                .iter()
                .any(|skill| skill.scope == SkillScope::Project)
        );
    }

    #[test]
    fn usage_totals_agree_with_the_days_they_are_summed_from() {
        let history = usage_history(UsageWindow::TrailingDays(30), &[]);

        assert_eq!(history.daily.len(), 30);
        let daily_cost = history.daily.iter().map(|day| day.cost_usd).sum::<f64>();
        assert!((history.cost_usd - daily_cost).abs() < 1e-9);
        assert_eq!(
            history.total_tokens,
            history
                .daily
                .iter()
                .map(|day| day.total_tokens)
                .sum::<u64>()
        );
        let provider_cost = history
            .providers
            .iter()
            .map(|slice| slice.cost_usd)
            .sum::<f64>();
        assert!((history.cost_usd - provider_cost).abs() < 1e-9);
        assert!(
            (history
                .providers
                .iter()
                .map(|slice| slice.cost_share)
                .sum::<f64>()
                - 1.0)
                .abs()
                < 1e-9
        );
    }

    #[test]
    fn every_window_choice_produces_a_populated_history() {
        for window in shidou_protocol::usage_history::WINDOW_CHOICES {
            let history = usage_history(window, &[]);

            assert!(history.cost_usd > 0.0, "{window:?} produced no spend");
            assert!(!history.daily.is_empty(), "{window:?} produced no days");
            assert!(!history.months.is_empty(), "{window:?} produced no months");
            assert_eq!(history.window, window);
        }
    }

    #[test]
    fn usage_projects_follow_the_roots_the_client_asked_about() {
        let root = PathBuf::from("/Users/demo/Developer/other");
        let history = usage_history(UsageWindow::ThisMonth, std::slice::from_ref(&root));

        assert_eq!(history.projects.len(), 1);
        assert_eq!(history.projects[0].path, root.display().to_string());
    }
}
