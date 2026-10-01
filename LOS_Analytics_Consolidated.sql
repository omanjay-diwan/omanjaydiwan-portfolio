/*
Loan Origination & Credit Performance Analytics
Oracle SQL reference script for schema LOS_ANALYTICS

IMPORTANT
- This is a reference/consolidation script, not a one-click rerun script.
- Your tables and synthetic data already exist. Do NOT rerun the CREATE TABLE
  sections against the existing schema unless you first handle existing objects.
- The original synthetic-data generation statements are not reproduced here
  because their exact SQL is not available in the current conversation context.
- All data is synthetic. SLA thresholds and KPI definitions are illustrative.
*/

-- =========================================================
-- 1. TABLE DDL (reference only; tables already exist)
-- =========================================================

CREATE TABLE loan_products (
    product_id           NUMBER PRIMARY KEY,
    product_name         VARCHAR2(100) NOT NULL,
    annual_interest_rate NUMBER(5,2),
    max_loan_amount      NUMBER(15,2)
);

CREATE TABLE customers (
    customer_id     NUMBER PRIMARY KEY,
    age             NUMBER,
    employment_type VARCHAR2(50),
    monthly_income  NUMBER(15,2),
    city            VARCHAR2(100),
    credit_score    NUMBER
);

CREATE TABLE loan_applications (
    application_id     NUMBER PRIMARY KEY,
    customer_id        NUMBER NOT NULL,
    product_id         NUMBER NOT NULL,
    application_date   DATE NOT NULL,
    requested_amount   NUMBER(15,2),
    application_status VARCHAR2(20) NOT NULL,
    channel            VARCHAR2(50),
    branch_code        VARCHAR2(30),
    decision_date      DATE,
    disbursal_date     DATE,
    loan_amount        NUMBER(15,2),
    interest_rate      NUMBER(5,2),
    risk_band          VARCHAR2(30),
    CONSTRAINT fk_la_customer FOREIGN KEY (customer_id)
        REFERENCES customers(customer_id),
    CONSTRAINT fk_la_product FOREIGN KEY (product_id)
        REFERENCES loan_products(product_id),
    CONSTRAINT chk_la_status CHECK (
        application_status IN
        ('SUBMITTED', 'IN_REVIEW', 'APPROVED', 'REJECTED', 'DISBURSED')
    )
);

CREATE TABLE application_status_history (
    history_id      NUMBER PRIMARY KEY,
    application_id  NUMBER NOT NULL,
    status          VARCHAR2(20) NOT NULL,
    status_timestamp DATE NOT NULL,
    changed_by      VARCHAR2(100),
    CONSTRAINT fk_ash_application FOREIGN KEY (application_id)
        REFERENCES loan_applications(application_id)
);

CREATE INDEX idx_la_customer ON loan_applications(customer_id);
CREATE INDEX idx_la_product ON loan_applications(product_id);
CREATE INDEX idx_ash_application ON application_status_history(application_id);


-- =========================================================
-- 2. DATA QUALITY / VALIDATION QUERIES
-- =========================================================

-- Row counts
SELECT 'LOAN_PRODUCTS' AS table_name, COUNT(*) AS row_count
FROM loan_products
UNION ALL
SELECT 'CUSTOMERS', COUNT(*) FROM customers
UNION ALL
SELECT 'LOAN_APPLICATIONS', COUNT(*) FROM loan_applications
UNION ALL
SELECT 'APPLICATION_STATUS_HISTORY', COUNT(*) FROM application_status_history;

-- Application status distribution
SELECT application_status, COUNT(*) AS application_count,
       ROUND(100 * COUNT(*) / (SELECT COUNT(*) FROM loan_applications), 2)
           AS pct_of_all_applications
FROM loan_applications
GROUP BY application_status
ORDER BY application_count DESC;

-- Date sanity check: decision cannot precede application;
-- disbursal cannot precede decision for disbursed applications.
SELECT COUNT(*) AS invalid_date_rows
FROM loan_applications
WHERE (decision_date IS NOT NULL AND decision_date < application_date)
   OR (application_status = 'DISBURSED'
       AND decision_date IS NOT NULL
       AND disbursal_date IS NOT NULL
       AND disbursal_date < decision_date);

-- If needed, this was the correction used for synthetic disbursed rows.
-- Run only if the data actually fails the validation above.
-- UPDATE loan_applications
-- SET disbursal_date = decision_date + 1 + MOD(application_id, 10)
-- WHERE application_status = 'DISBURSED'
--   AND decision_date IS NOT NULL
--   AND (disbursal_date IS NULL OR disbursal_date < decision_date);
-- COMMIT;


-- =========================================================
-- 3. POWER BI VIEWS
-- =========================================================

-- Product-level decision turnaround time (TAT), in calendar days.
CREATE OR REPLACE VIEW vw_los_product_tat AS
SELECT
    p.product_id,
    p.product_name,
    COUNT(*) AS decided_applications,
    ROUND(AVG(a.decision_date - a.application_date), 2) AS avg_tat_days,
    MEDIAN(a.decision_date - a.application_date) AS median_tat_days,
    ROUND(
        100 * SUM(
            CASE
                WHEN a.decision_date - a.application_date <= 7 THEN 1
                ELSE 0
            END
        ) / COUNT(*),
        2
    ) AS within_7_days_pct
FROM loan_applications a
JOIN loan_products p
    ON a.product_id = p.product_id
WHERE a.decision_date IS NOT NULL
  AND a.decision_date >= a.application_date
GROUP BY p.product_id, p.product_name;


-- Current application status distribution.
-- Note: this is a distribution of current statuses, not a sequential funnel.
CREATE OR REPLACE VIEW vw_los_application_funnel AS
SELECT
    application_status,
    COUNT(*) AS application_count,
    ROUND(
        100 * COUNT(*) / (SELECT COUNT(*) FROM loan_applications),
        2
    ) AS pct_of_all_applications
FROM loan_applications
GROUP BY application_status;


-- Monthly application trend.
-- Approved count includes APPROVED and DISBURSED statuses.
CREATE OR REPLACE VIEW vw_los_monthly_trend AS
SELECT
    TRUNC(application_date, 'MM') AS application_month,
    COUNT(*) AS total_applications,
    SUM(
        CASE
            WHEN application_status IN ('APPROVED', 'DISBURSED') THEN 1
            ELSE 0
        END
    ) AS approved_applications,
    SUM(
        CASE WHEN application_status = 'REJECTED' THEN 1 ELSE 0 END
    ) AS rejected_applications,
    SUM(
        CASE WHEN application_status = 'DISBURSED' THEN 1 ELSE 0 END
    ) AS disbursed_applications
FROM loan_applications
GROUP BY TRUNC(application_date, 'MM');


-- =========================================================
-- 4. VIEW CHECKS (run after creating/replacing the views)
-- =========================================================

SELECT *
FROM vw_los_product_tat
ORDER BY avg_tat_days;

SELECT *
FROM vw_los_application_funnel
ORDER BY application_count DESC;

SELECT *
FROM vw_los_monthly_trend
ORDER BY application_month;


-- =========================================================
-- 5. OVERALL KPI QUERIES
-- =========================================================

-- Overall application counts and project-defined approval rate.
-- "Decided" = APPROVED + DISBURSED + REJECTED.
-- "Approved" = APPROVED + DISBURSED, so disbursed is included.
SELECT
    COUNT(*) AS total_applications,
    SUM(CASE WHEN application_status IN
        ('APPROVED', 'DISBURSED', 'REJECTED') THEN 1 ELSE 0 END)
        AS decided_applications,
    SUM(CASE WHEN application_status IN
        ('APPROVED', 'DISBURSED') THEN 1 ELSE 0 END)
        AS approved_applications,
    SUM(CASE WHEN application_status = 'REJECTED' THEN 1 ELSE 0 END)
        AS rejected_applications,
    SUM(CASE WHEN application_status = 'DISBURSED' THEN 1 ELSE 0 END)
        AS disbursed_applications,
    ROUND(
        100 * SUM(CASE WHEN application_status IN
            ('APPROVED', 'DISBURSED') THEN 1 ELSE 0 END)
        / NULLIF(
            SUM(CASE WHEN application_status IN
                ('APPROVED', 'DISBURSED', 'REJECTED') THEN 1 ELSE 0 END),
            0
        ),
        2
    ) AS approval_rate_pct
FROM loan_applications;


-- Overall decision TAT: mean, median, mode, and percentage decided
-- within the illustrative 7-calendar-day threshold.
WITH tat_data AS (
    SELECT decision_date - application_date AS tat_days
    FROM loan_applications
    WHERE decision_date IS NOT NULL
      AND decision_date >= application_date
),
tat_frequency AS (
    SELECT tat_days, COUNT(*) AS frequency
    FROM tat_data
    GROUP BY tat_days
),
ranked_tat AS (
    SELECT
        tat_days,
        frequency,
        ROW_NUMBER() OVER (
            ORDER BY frequency DESC, tat_days ASC
        ) AS rn
    FROM tat_frequency
)
SELECT
    COUNT(*) AS decided_applications,
    ROUND(AVG(t.tat_days), 2) AS avg_tat_days,
    MEDIAN(t.tat_days) AS median_tat_days,
    MAX(CASE WHEN r.rn = 1 THEN r.tat_days END) AS mode_tat_days,
    MAX(CASE WHEN r.rn = 1 THEN r.frequency END) AS mode_frequency,
    ROUND(
        100 * SUM(CASE WHEN t.tat_days <= 7 THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0),
        2
    ) AS decided_within_7_days_pct
FROM tat_data t
CROSS JOIN ranked_tat r
WHERE r.rn = 1;


-- Product-level TAT report (same results as the Power BI view).
SELECT
    p.product_name,
    COUNT(*) AS decided_applications,
    ROUND(AVG(a.decision_date - a.application_date), 2) AS avg_tat_days,
    MEDIAN(a.decision_date - a.application_date) AS median_tat_days,
    ROUND(
        100 * SUM(
            CASE WHEN a.decision_date - a.application_date <= 7 THEN 1 ELSE 0 END
        ) / COUNT(*),
        2
    ) AS within_7_days_pct
FROM loan_applications a
JOIN loan_products p
    ON p.product_id = a.product_id
WHERE a.decision_date IS NOT NULL
  AND a.decision_date >= a.application_date
GROUP BY p.product_name
ORDER BY avg_tat_days;


-- =========================================================
-- 6. POWER BI CONNECTION NOTES
-- =========================================================
-- Oracle service used: FREEPDB1
-- Host/port for local Docker mapping: localhost:1521
-- Service connection string commonly entered in Power BI:
-- localhost:1521/FREEPDB1
-- Schema/user: LOS_ANALYTICS
--
-- Views to load into Power BI:
--   VW_LOS_PRODUCT_TAT
--   VW_LOS_APPLICATION_FUNNEL
--   VW_LOS_MONTHLY_TREND
--
-- All figures are synthetic and intended for portfolio demonstration.
