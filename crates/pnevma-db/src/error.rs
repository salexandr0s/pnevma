use thiserror::Error;

#[derive(Debug, Error)]
pub enum DbError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("database error: {0}")]
    Sql(#[from] sqlx::Error),

    #[error("migration error: {0}")]
    Migration(#[from] sqlx::migrate::MigrateError),

    #[error("serialization error: {0}")]
    Serde(#[from] serde_json::Error),

    #[error("config error: {0}")]
    Config(String),
}
