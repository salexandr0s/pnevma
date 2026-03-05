-- Rollback for 0009_error_signatures.sql

DROP INDEX IF EXISTS idx_error_sig_daily;
DROP INDEX IF EXISTS idx_error_sig_project;
DROP TABLE IF EXISTS error_signature_daily;
DROP TABLE IF EXISTS error_signatures;
