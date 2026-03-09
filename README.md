# Supplier Invoice Ingest Pipeline
### n8n · PostgreSQL (Supabase) · Gmail · Google Drive

An automated end-to-end supplier invoice ingestion pipeline built with n8n. Ingests CSV invoices from Gmail and Google Drive, validates each row against business rules, persists valid invoices to PostgreSQL, and sends an HTML email summary after every run.

---

## Features

Dual trigger sources — Instead of only one way to send invoices in, the pipeline accepts files from two places: Gmail (someone emails a CSV attachment) and Google Drive (someone drops a file into a watched folder). This means different team members can use whichever method suits them without any manual intervention.
File-level idempotency — Before doing anything with a file, the pipeline computes a SHA-256 fingerprint of its contents and checks it against the processed_files table. If the exact same file has been sent before, it gets skipped entirely and a notification email is sent. This prevents double-processing if someone accidentally sends the same CSV twice.
Row-wise validation — Every individual row in the CSV is checked against business rules before anything is written to the database. Required fields must be present, the VAT math must add up, and the invoice date cannot be in the future. Rows that fail are flagged with a specific reason rather than silently dropped.
Automatic VAT calculation — If a row doesn't include a VAT amount or rate, the pipeline automatically applies South Africa's standard 15% VAT rate and computes the missing values. This reduces the burden on whoever is generating the CSV.
Deduplication — Even if a file passes the file-level check, individual rows are checked against the database using the unique combination of supplier_number and invoice_number. If that invoice already exists, the row is marked as a duplicate and skipped rather than inserted twice.
Dry-run mode — A single DRY_RUN = true flag in the validation node redirects all inserts to a staging table instead of production. This lets you test with real data without affecting live records.
Execution traceability — Every row that gets inserted is tagged with the n8n execution_id and its row number within the CSV. This means you can query the database later and see exactly which run inserted which rows, making debugging and auditing straightforward.
HTML email alerts — After every run, a formatted email is sent showing how many rows were inserted, duplicated, and failed. If there were failures, the email includes a table with the row number, invoice number, supplier, and the specific reason each row failed — so whoever receives it knows exactly what to fix.
Failures table — Rows that fail validation aren't just discarded. They're written to a separate supplier_invoices_failures table with the full row data, the failure reason, and a retry_count starting at zero. A separate retry workflow can query this table and re-attempt rows after they've been manually corrected.

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
                         Check File Hash in DB
                         (queries processed_files)
                                    │
                                    ▼
                         Code in JavaScript
                         (merge hash + DB result,
                          forward binary)
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
                                │ Mark  Insert to DB      │
                                │ Dup        │            │
                                │  │    Write to          │
                                │  │  processed_files     │
                                │  │         │            │
                                └──┴─────────┴────────────┘
                                              │
                                           Merge
                                              │
                                     Aggregate Metrics
                                     & Build Email
                                              │
                                      Send Email Alert
```

### Workflow Canvas

<img width="1366" height="599" alt="Workflow Automation - n8n (1)" src="https://github.com/user-attachments/assets/e2eed040-7fdc-4bfb-a28c-bdd5ffe268a5" />



*Gmail trigger active:*
<img width="1366" height="599" alt="Workflow Automation - n8n" src="https://github.com/user-attachments/assets/2dbb3080-42cb-4e58-a698-e87095b15476" />
<img width="1366" height="599" alt="▶️ supplier-ingest - n8n" src="https://github.com/user-attachments/assets/649d47c6-65ae-49eb-9035-64590e044b6e" />



*Google Drive trigger active:*
<img width="1366" height="599" alt="▶️ supplier-ingest - n8n (1)" src="https://github.com/user-attachments/assets/fa97bfb6-e155-4e13-a0bc-05ef9972ba81" />
<img width="1366" height="599" alt="▶️ supplier-ingest - n8n (2)" src="https://github.com/user-attachments/assets/8ea24093-f4af-4329-904e-12b6b7c1960f" />




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
Supplier Ingest: 3 ok, 0 dup, 0 failed
```

### Successful Insert Run

<img width="1366" height="739" alt="Supplier-Ingest-3-ok-0-dup-0-failed-seiphemokatlego-gmail-com-Gmail-03-06-2026_01_41_AM" src="https://github.com/user-attachments/assets/13740c76-011e-49e5-b597-ad81783f7f8c" />

**Subject format:**
```
Supplier Ingest: File already processed — skipped
```

### File-already-processed-—-skipped Run

<img width="1366" height="744" alt="Supplier-Ingest-File-already-processed-—-skipped-seiphemokatlego-gmail-com-Gmail-03-06-2026_09_23_AM" src="https://github.com/user-attachments/assets/4ba0ff06-23de-4d3b-9f27-cb3e5804b1cb" />


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
<img width="1366" height="599" alt="Database _ supplier-invoices _ KatlegoSeiphemo&#39;s Org _ Supabase" src="https://github.com/user-attachments/assets/0c2bf38b-9a57-4d28-ad4f-fe5b3317bc44" />

### processed_files
<img width="1366" height="599" alt="Table Editor _ supplier-invoices _ KatlegoSeiphemo&#39;s Org _ Supabase (1)" src="https://github.com/user-attachments/assets/8674391e-ced5-449f-809f-d59baf79e641" />


### supplier_invoices Table



<img width="1366" height="599" alt="supplier-invoices-KatlegoSeiphemo-s-Org-Supabase-03-06-2026_09_51_AM" src="https://github.com/user-attachments/assets/2a64a0d0-8483-41cb-a45a-ecfb543da003" />

<img width="1366" height="599" alt="supplier-invoices-KatlegoSeiphemo-s-Org-Supabase-03-06-2026_09_51_AM (1)" src="https://github.com/user-attachments/assets/e2864c6e-728c-4827-88a6-97df45848c09" />





### supplier_invoices_failures Table
<img width="1366" height="599" alt="supplier-invoices-KatlegoSeiphemo-s-Org-Supabase-03-06-2026_09_53_AM" src="https://github.com/user-attachments/assets/2375b6db-4451-43c7-9003-dce0f6850343" />

<img width="1366" height="599" alt="supplier-invoices-KatlegoSeiphemo-s-Org-Supabase-03-06-2026_09_53_AM (1)" src="https://github.com/user-attachments/assets/462ec4e3-41ed-4316-a546-1e9f6cc5b50d" />

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
├── supplier-ingest.json         ← import into n8n
├── schema-final.sql             ← run in Supabase SQL Editor
├── results.csv                  ← expected output for sample CSV
├── bad_invoices.csv             ← expected output for sample CSV
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
