-- ============================================================
-- Supplier Invoice Ingest — Complete Database Schema (Final)
-- Run this in Supabase SQL Editor
-- PostgreSQL 14+  |  Timezone: Africa/Johannesburg
-- ============================================================

-- Main invoices table
CREATE TABLE IF NOT EXISTS supplier_invoices (
    id               UUID          DEFAULT gen_random_uuid() PRIMARY KEY,
    invoice_number   TEXT          NOT NULL,
    supplier_number  TEXT          NOT NULL,
    supplier_name    TEXT          NOT NULL,
    department       TEXT          NOT NULL,
    amount_excl_vat  NUMERIC(12,2) NOT NULL,
    vat              NUMERIC(12,2) NOT NULL,
    amount_incl_vat  NUMERIC(12,2) NOT NULL,
    invoice_date     DATE          NOT NULL,
    source_file_name TEXT,
    source_hash      TEXT,
    ingest_timestamp TIMESTAMPTZ   DEFAULT now(),
    status           TEXT          NOT NULL CHECK (status IN ('inserted','duplicate','failed')),
    validation_notes TEXT,
    execution_id     TEXT,
    row_number       INTEGER,
    UNIQUE (supplier_number, invoice_number)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_si_supplier_number ON supplier_invoices (supplier_number);
CREATE INDEX IF NOT EXISTS idx_si_invoice_number  ON supplier_invoices (invoice_number);
CREATE INDEX IF NOT EXISTS idx_si_invoice_date    ON supplier_invoices (invoice_date);
CREATE INDEX IF NOT EXISTS idx_si_status          ON supplier_invoices (status);
CREATE INDEX IF NOT EXISTS idx_si_source_hash     ON supplier_invoices (source_hash);
CREATE INDEX IF NOT EXISTS idx_si_execution_id    ON supplier_invoices (execution_id);

-- ============================================================
-- Failures table (bonus — retry logic)
-- ============================================================
CREATE TABLE IF NOT EXISTS supplier_invoices_failures (
    id               UUID         DEFAULT gen_random_uuid() PRIMARY KEY,
    invoice_number   TEXT,
    supplier_number  TEXT,
    supplier_name    TEXT,
    raw_payload      TEXT,
    failure_reason   TEXT,
    source_file_name TEXT,
    retry_count      INTEGER      DEFAULT 0,
    created_at       TIMESTAMPTZ  DEFAULT now(),
    last_retry_at    TIMESTAMPTZ
);

-- ============================================================
-- Staging table (bonus — dry-run mode)
-- Identical structure to supplier_invoices
-- ============================================================
CREATE TABLE IF NOT EXISTS supplier_invoices_staging (
    id               UUID          DEFAULT gen_random_uuid() PRIMARY KEY,
    invoice_number   TEXT          NOT NULL,
    supplier_number  TEXT          NOT NULL,
    supplier_name    TEXT          NOT NULL,
    department       TEXT          NOT NULL,
    amount_excl_vat  NUMERIC(12,2) NOT NULL,
    vat              NUMERIC(12,2) NOT NULL,
    amount_incl_vat  NUMERIC(12,2) NOT NULL,
    invoice_date     DATE          NOT NULL,
    source_file_name TEXT,
    source_hash      TEXT,
    ingest_timestamp TIMESTAMPTZ   DEFAULT now(),
    status           TEXT          NOT NULL CHECK (status IN ('inserted','duplicate','failed')),
    validation_notes TEXT,
    execution_id     TEXT,
    row_number       INTEGER,
    UNIQUE (supplier_number, invoice_number)
);

-- ============================================================
-- Processed files table (file-level idempotency)
-- One row per successfully processed file.
-- Checked at the start of every run — if the hash exists,
-- the entire file is skipped without touching supplier_invoices.
-- ============================================================
CREATE TABLE IF NOT EXISTS processed_files (
    id               SERIAL       PRIMARY KEY,
    source_hash      TEXT         NOT NULL UNIQUE,
    source_file_name TEXT,
    processed_at     TIMESTAMPTZ  DEFAULT now()
);

-- ============================================================
-- Add new columns to existing table (if upgrading from v1)
-- Safe to run even if columns already exist
-- ============================================================
ALTER TABLE supplier_invoices ADD COLUMN IF NOT EXISTS execution_id TEXT;
ALTER TABLE supplier_invoices ADD COLUMN IF NOT EXISTS row_number   INTEGER;

-- ============================================================
-- Useful queries for traceability
-- ============================================================
-- All invoices from a specific execution:
--   SELECT * FROM supplier_invoices WHERE execution_id = 'your-id';

-- Summary by execution:
--   SELECT execution_id, status, COUNT(*) 
--   FROM supplier_invoices 
--   GROUP BY execution_id, status 
--   ORDER BY MIN(ingest_timestamp) DESC;

-- View staging (dry-run results):
--   SELECT * FROM supplier_invoices_staging ORDER BY ingest_timestamp DESC;

-- Pending retries:
--   SELECT * FROM supplier_invoices_failures WHERE retry_count < 3;

-- Check processed files:
--   SELECT * FROM processed_files ORDER BY processed_at DESC;
