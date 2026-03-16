use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrStatus {
    Draft,
    Open,
    ReviewRequested,
    Approved,
    Merged,
    Closed,
}

impl fmt::Display for PrStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            Self::Draft => "draft",
            Self::Open => "open",
            Self::ReviewRequested => "review_requested",
            Self::Approved => "approved",
            Self::Merged => "merged",
            Self::Closed => "closed",
        };
        f.write_str(s)
    }
}

impl FromStr for PrStatus {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "draft" => Ok(Self::Draft),
            "open" => Ok(Self::Open),
            "review_requested" => Ok(Self::ReviewRequested),
            "approved" => Ok(Self::Approved),
            "merged" => Ok(Self::Merged),
            "closed" => Ok(Self::Closed),
            other => Err(format!("unknown PR status: {other}")),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChecksStatus {
    Pending,
    Running,
    Success,
    Failure,
    Neutral,
}

impl fmt::Display for ChecksStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            Self::Pending => "pending",
            Self::Running => "running",
            Self::Success => "success",
            Self::Failure => "failure",
            Self::Neutral => "neutral",
        };
        f.write_str(s)
    }
}

impl FromStr for ChecksStatus {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "pending" => Ok(Self::Pending),
            "running" => Ok(Self::Running),
            "success" => Ok(Self::Success),
            "failure" => Ok(Self::Failure),
            "neutral" => Ok(Self::Neutral),
            other => Err(format!("unknown checks status: {other}")),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mergeable {
    Yes,
    No,
    Unknown,
}

impl fmt::Display for Mergeable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            Self::Yes => "yes",
            Self::No => "no",
            Self::Unknown => "unknown",
        };
        f.write_str(s)
    }
}

impl FromStr for Mergeable {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "yes" | "true" => Ok(Self::Yes),
            "no" | "false" => Ok(Self::No),
            "unknown" => Ok(Self::Unknown),
            other => Err(format!("unknown mergeable value: {other}")),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewStatus {
    Pending,
    Approved,
    ChangesRequested,
    Commented,
    Dismissed,
}

impl fmt::Display for ReviewStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            Self::Pending => "pending",
            Self::Approved => "approved",
            Self::ChangesRequested => "changes_requested",
            Self::Commented => "commented",
            Self::Dismissed => "dismissed",
        };
        f.write_str(s)
    }
}

impl FromStr for ReviewStatus {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "pending" => Ok(Self::Pending),
            "approved" | "APPROVED" => Ok(Self::Approved),
            "changes_requested" | "CHANGES_REQUESTED" => Ok(Self::ChangesRequested),
            "commented" | "COMMENTED" => Ok(Self::Commented),
            "dismissed" | "DISMISSED" => Ok(Self::Dismissed),
            other => Err(format!("unknown review status: {other}")),
        }
    }
}
