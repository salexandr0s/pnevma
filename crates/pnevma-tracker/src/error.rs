use thiserror::Error;

#[derive(Debug, Error)]
pub enum TrackerError {
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),

    #[error("graphql error: {0}")]
    GraphQL(String),

    #[error("not found: {0}")]
    NotFound(String),

    #[error("configuration error: {0}")]
    Config(String),

    #[error("serialization error: {0}")]
    Serialization(String),
}
