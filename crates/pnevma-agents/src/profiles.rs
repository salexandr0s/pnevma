use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentProfile {
    pub name: String,
    pub provider: String,
    pub model: String,
    pub token_budget: i64,
    pub timeout_minutes: i64,
    pub max_concurrent: i64,
    pub stations: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DispatchRecommendation {
    pub profile_name: String,
    pub score: i32,
    pub reason: String,
}

/// Score profiles for a task based on scope affinity and availability.
pub fn recommend_profile(
    task_scope: &[String],
    task_priority: &str,
    profiles: &[AgentProfile],
) -> Vec<DispatchRecommendation> {
    let mut recommendations: Vec<DispatchRecommendation> = profiles
        .iter()
        .map(|p| {
            let mut score: i32 = 0;
            let mut reasons = Vec::new();

            // Station affinity: +10 per matching scope
            for scope in task_scope {
                if p.stations.iter().any(|s| s == scope) {
                    score += 10;
                    reasons.push(format!("station match: {scope}"));
                }
            }

            // Capability preference based on priority
            match task_priority {
                "P0" | "P1" => {
                    if p.model.contains("opus") || p.model.contains("sonnet") {
                        score += 5;
                        reasons.push("capable model for high-priority".to_string());
                    }
                }
                "P2" | "P3" => {
                    if p.model.contains("haiku") {
                        score += 5;
                        reasons.push("cost-efficient model for low-priority".to_string());
                    }
                }
                _ => {}
            }

            // Base score for being active
            score += 1;

            let reason = if reasons.is_empty() {
                "default profile".to_string()
            } else {
                reasons.join(", ")
            };

            DispatchRecommendation {
                profile_name: p.name.clone(),
                score,
                reason,
            }
        })
        .collect();

    recommendations.sort_by(|a, b| b.score.cmp(&a.score));
    recommendations
}
