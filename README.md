# Supplier Invoice Ingest Pipeline
### n8n · PostgreSQL (Supabase) · Gmail · Google Drive

An automated end-to-end supplier invoice ingestion pipeline built with n8n. Ingests CSV invoices from Gmail and Google Drive, validates each row against business rules, persists valid invoices to PostgreSQL, and sends an HTML email summary after every run.

---

## Features

- **Dual trigger sources** — Gmail (email attachments) and Google Drive (folder watch)
- **File-level idempotency** — SHA-256 hash computed on every file; duplicate files are skipped before any processing
- **Row-wise validation** — 4 business rules enforced on every row
- **Automatic VAT calculation** — defaults to 15% (South Africa) if no rate provided
- **Deduplication** — unique key `(supplier_number, invoice_number)` enforced at DB level
- **Dry-run mode** — single flag to route inserts to a staging table instead of production
- **Execution traceability** — every row tagged with `execution_id` and `row_number`
- **HTML email alerts** — summary after every run with metrics and error table
- **Failures table** — invalid rows persisted with `retry_count` for retry workflows

---

## Workflow Architecture

```
Gmail Trigger ──────────────────────┐
                                    ▼
Google Drive Trigger ──► Get/Download File
                                    │
                                    ▼
                         Extract CSV Attachment
                                    │
                                    ▼
                         Compute SHA-256 Hash
                                    │
                                    ▼
                         Check File Hash (Code)
                                    │
                         File Already Processed?
                         ┌──────────┴──────────┐
                       YES                     NO
                         │                     │
                   Build Skip Email    Parse CSV → JSON Rows
                         │                     │
                         └──────┐              ▼
                                │    Attach File Metadata
                                │              │
                                │              ▼
                                │    Validate & Normalise Rows
                                │    (DRY_RUN flag here)
                                │              │
                                │    Split Valid / Invalid
                                │    ┌─────────┴─────────┐
                                │  VALID              INVALID
                                │    │                    │
                                │  Dedup Check        Mark as Failed
                                │    │                    │
                                │  Is Duplicate?    Write to Failures
                                │  ┌──┴──┐               │
                                │ YES   NO                │
                                │  │    │                 │
                                │ Mark  Insert            │
                                │ Dup   to DB             │
                                │  │    │                 │
                                └──┴────┴─────────────────┘
                                              │
                                     Aggregate Metrics
                                     & Build Email
                                              │
                                      Send Email Alert
```

### Workflow Canvas

![Workflow Canvas]<img width="1366" height="599" alt="Workflow-Automation-n8n-03-06-2026_08_48_AM" src="https://github.com/user-attachments/assets/44ee339a-02df-40b5-a1f1-84f918b33e79" />


*Gmail trigger active:*
![Workflow Canvas Gmail] <img width="1366" height="768" alt="supplier-ingest-n8n-03-06-2026_01_17_AM" src="https://github.com/user-attachments/assets/13851f18-453c-4f1b-af89-eff94c16b947" />


*Google Drive trigger active:*
![Workflow Canvas Drive]<img width="1366" height="599" alt="supplier-ingest-n8n-03-06-2026_08_52_AM" src="https://github.com/user-attachments/assets/e8b36a84-47a2-4a87-a22a-10ca72b04fdf" />


---

## Database Schema

Three tables are created:

**`supplier_invoices`** — main production table

| Column | Type | Notes |
|--------|------|-------|
| id | UUID | Auto-generated primary key |
| invoice_number | TEXT | Required, indexed |
| supplier_number | TEXT | Required, indexed |
| supplier_name | TEXT | Required |
| department | TEXT | Required |
| amount_excl_vat | NUMERIC(12,2) | Required |
| vat | NUMERIC(12,2) | Required |
| amount_incl_vat | NUMERIC(12,2) | Required |
| invoice_date | DATE | Required, Africa/Johannesburg |
| source_file_name | TEXT | CSV filename |
| source_hash | TEXT | SHA-256 of file contents |
| ingest_timestamp | TIMESTAMPTZ | Auto, default now() |
| status | TEXT | `inserted` \| `duplicate` \| `failed` |
| validation_notes | TEXT | Error reasons |
| execution_id | TEXT | n8n execution ID for traceability |
| row_number | INTEGER | CSV row number for debugging |

**Unique key:** `(supplier_number, invoice_number)`

**`supplier_invoices_failures`** — failed rows with retry support

**`supplier_invoices_staging`** — dry-run table (identical structure)

### Setup

Run `schema-final.sql` in your Supabase SQL Editor.

---

## CSV Format

### Required Headers

```
supplier_number, supplier_name, invoice_number, department, invoice_date, amount_excl
```

### Optional Headers

```
vat, vat_rate, amount_incl
```

### Sample CSV

```csv
supplier_number,supplier_name,invoice_number,department,invoice_date,amount_excl,vat_rate
S009,OfficeCo,OC-22119,Ops,2025-10-28,2175.00,15
S009,OfficeCo,OC-22120,Sales,2025-10-29,450.00,15
S011,PaperMart,PM-77891,Ops,2025-11-01,1020.00,15
S011,PaperMart,PM-77891,Ops,2025-11-01,1020.00,15
```

Row 4 is an intentional duplicate — it will be caught and skipped.

### Field Mapping

| CSV Column | DB Column | Notes |
|-----------|-----------|-------|
| `amount_excl` | `amount_excl_vat` | Required |
| `vat` | `vat` | Optional — derived if missing |
| `vat_rate` | *(used to compute vat)* | Optional — defaults to 15% |
| `amount_incl` | `amount_incl_vat` | Optional — computed if missing |

### VAT Computation Order

```
1. vat present            → use as-is, validate against vat_rate if also present
2. vat absent, rate present → vat = round(amount_excl × vat_rate / 100, 2)
3. both absent            → vat = round(amount_excl × 0.15, 2)  [ZA 15% default]
4. amount_incl absent     → amount_incl_vat = round(amount_excl_vat + vat, 2)
```

**Rounding method:** `Math.round(x * 100) / 100` — 2 decimal places

---

## Validation Rules

| Rule | Description | Error Note |
|------|-------------|------------|
| R1 | Required fields present | `MISSING: <field_name>` |
| R2 | `amount_incl_vat = amount_excl_vat + vat` (±0.01) | `MATH_ERROR: ...` |
| R3 | VAT rate matches derived VAT (±0.01) | `VAT_MISMATCH: ...` |
| R4 | `invoice_date` not in the future (Africa/Johannesburg) | `FUTURE_DATE: ...` |
| R5 | No duplicate `(supplier_number, invoice_number)` | `Duplicate: ...` |

---

## Dry-Run Mode

To test without writing to production, open the **Validate & Normalise Rows** node and change the flag at the top:

```javascript
const DRY_RUN = true; // change to false for production
```

All inserts will go to `supplier_invoices_staging` instead of `supplier_invoices`.

---

## Triggers

### Gmail (Primary)

1. Create a Gmail label: `InvoiceIngest`
2. Create a filter: `has:attachment filename:.csv` → apply label
3. In the Gmail Trigger node, set `labelIds` to `InvoiceIngest`
4. Activate the workflow — polls every minute

### Google Drive (Bonus)

1. Create a folder in Google Drive: `InvoiceIngest`
2. In the Google Drive Trigger node, set the folder ID from the URL
3. Drop CSV files into the folder to trigger the workflow

---

## n8n Credential Setup

| Credential | Type | Used By |
|-----------|------|---------|
| Gmail account | Gmail OAuth2 | Gmail Trigger, Get a message, Send Email Alert |
| Google Drive account | Google Drive OAuth2 | Google Drive Trigger, Download file |
| Postgres account | PostgreSQL | Dedup Check, Insert to DB, Write to Failures |

---

## Email Alert

**Subject format:**
```
Supplier Ingest: 3 ok, 1 dup, 0 failed
```

### Successful Insert Run

<img width="1366" height="739" alt="Supplier-Ingest-3-ok-0-dup-0-failed-seiphemokatlego-gmail-com-Gmail-03-06-2026_01_41_AM" src="https://github.com/user-attachments/assets/13740c76-011e-49e5-b597-ad81783f7f8c" />

**Subject format:**
```
Supplier Ingest: File already processed — skipped
```

### Successful Insert Run
![Uploading Supplier-Ingest-File-already-processed-—-skipped-seiphemokatlego-gmail-com-Gmail-03-06-2026_09_23_AM.png…]()


**Subject format:**
```
Supplier Ingest: 0 ok, 0 dup, 2 failed
```
### Failed Rows Run

<img width="1366" height="841" alt="Supplier-Ingest-0-ok-0-dup-2-failed-seiphemokatlego-gmail-com-Gmail-03-06-2026_01_40_AM" src="https://github.com/user-attachments/assets/cdb07df0-3ece-44b1-9dc8-2ea4e4e8cf72" /> 

**Subject format:**
```
Supplier Ingest: 0 ok, 1 dup, 0 failed
```
### Duplicate Detection
<img width="1366" height="599" alt="Supplier-Ingest-0-ok-1-dup-0-failed-seiphemokatlego-gmail-com-Gmail-03-06-2026_09_13_AM" src="https://github.com/user-attachments/assets/30fdf324-93b0-4b77-836a-92fc8f003c78" />


**Subject format:**
```
Supplier Ingest: 0 ok, 4 dup, 0 failed
```

### Bulk Duplicate Detection

<img width="1366" height="739" alt="Supplier-Ingest-0-ok-4-dup-0-failed-seiphemokatlego-gmail-com-Gmail-03-06-2026_01_42_AM" src="https://github.com/user-attachments/assets/617ed05e-f486-4ffc-9be0-4720d0dc81e3" />


---

## Database Evidence

### supplier_invoices Table

![Supabase Invoices]

<img width="1366" height="599" alt="supplier-invoices-KatlegoSeiphemo-s-Org-Supabase-03-06-2026_08_10_AM" src="https://github.com/user-attachments/assets/4e6a54bc-79d6-4d93-a2ac-60a1362afd12" />


### supplier_invoices_failures Table

![Supabase Failures]<img width="1366" height="599" alt="supplier-invoices-KatlegoSeiphemo-s-Org-Supabase-03-06-2026_08_07_AM" src="https://github.com/user-attachments/assets/2a633697-d3ea-42ad-bd15-2040d2f538fc" />
<img width="1366" height="599" alt="supplier-invoices-KatlegoSeiphemo-s-Org-Supabase-03-06-2026_08_08_AM" src="https://github.com/user-attachments/assets/9320bbbf-da2d-40b1-9bc6-38e6584e5948" />
<img width="1366" height="599" alt="supplier-invoices-KatlegoSeiphemo-s-Org-Supabase-03-06-2026_08_09_AM" src="https://github.com/user-attachments/assets/9ec9df36-9679-4b42-8901-1be7efc5bf24" />


---

## Execution Traceability

Every row inserted includes:
- `execution_id` — the n8n execution ID for that run
- `row_number` — the row's position in the source CSV

Query all invoices from a specific run:
```sql
SELECT * FROM supplier_invoices WHERE execution_id = '174';
```

Summary by execution:
```sql
SELECT execution_id, status, COUNT(*)
FROM supplier_invoices
GROUP BY execution_id, status
ORDER BY MIN(ingest_timestamp) DESC;
```

---

## Expected Results — Sample CSV

| Row | invoice_number | supplier_number | status | validation_notes |
|-----|---------------|-----------------|--------|-----------------|
| 1 | OC-22119 | S009 | `inserted` | VAT_DEFAULTED: applied 15% ZA default rate |
| 2 | OC-22120 | S009 | `inserted` | VAT_DEFAULTED: applied 15% ZA default rate |
| 3 | PM-77891 | S011 | `inserted` | VAT_DEFAULTED: applied 15% ZA default rate |
| 4 | PM-77891 | S011 | `duplicate` | Duplicate: (supplier_number, invoice_number) already exists |

---

## Repository Structure

```
supplier-invoice-ingest/
├── supplier-ingest-final.json   ← import into n8n
├── schema-final.sql             ← run in Supabase SQL Editor
├── results.csv                  ← expected output for sample CSV
├── README.md                    ← this file
└── screenshots/
    ├── workflow_canvas.png
    ├── workflow_canvas_gmail.png
    ├── workflow_canvas_drive.png
    ├── email_success.png
    ├── email_failed.png
    ├── email_duplicate.png
    ├── email_duplicate_bulk.png
    ├── supabase_invoices.png
    └── supabase_failures.png
```

---

## Bonus Features Implemented

- ✅ Second trigger source (Google Drive)
- ✅ `supplier_invoices_failures` table with `retry_count`
- ✅ Dry-run mode (`DRY_RUN` flag → staging table)
- ✅ File-level idempotency (SHA-256 hash check)
- ✅ Execution ID traceability
- ✅ Row numbers in validation errors

---

## Tech Stack

- **n8n** — workflow automation
- **PostgreSQL** via Supabase — data persistence
- **Gmail OAuth2** — trigger + email alerts
- **Google Drive OAuth2** — second trigger source
- **Node.js** (n8n Code nodes) — validation, hashing, email building

---

*Rounding: `Math.round(x * 100) / 100` — 2 decimal places*
*Timezone: `Africa/Johannesburg` (UTC+2, no daylight saving)*
