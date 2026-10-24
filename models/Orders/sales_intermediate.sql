
{{ config(materialized='table') }}

WITH source_sales AS (
    SELECT *
    FROM {{ source('bigquery_source', 'retail_sales') }}
),

-- 1, 2, 3: Calculate sales, clean names, standardize status
cleaned_sales AS (
    SELECT
        sale_id,
        sale_date,
        INITCAP(TRIM(customer_name)) AS customer_name,
        INITCAP(TRIM(city)) AS city,
        product_name,
        category,
        quantity,
        unit_price,
        COALESCE(discount, 0) AS discount,
        LOWER(TRIM(payment_method)) AS payment_method,
        LOWER(TRIM(sales_status)) AS sales_status
    FROM source_sales
    WHERE sales_status IS NOT NULL
),

calculated_sales AS (
    SELECT
        *,
        quantity * unit_price AS gross_amount,
        quantity * unit_price - discount AS net_amount
    FROM cleaned_sales
),

-- 4: Sales category
categorized_sales AS (
    SELECT
        *,
        CASE
            WHEN net_amount > 1000 THEN 'High'
            WHEN net_amount > 500 THEN 'Medium'
            ELSE 'Low'
        END AS sales_category
    FROM calculated_sales
),

-- 11: Keep latest record for each sale_id
deduplicated_sales AS (
    SELECT * EXCEPT (row_num)
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY sale_id
                ORDER BY sale_date DESC
            ) AS row_num
        FROM categorized_sales
    )
    WHERE row_num = 1
),

-- 5: Monthly sales summary
monthly_sales AS (
    SELECT
        CAST(EXTRACT(YEAR FROM sale_date) AS STRING) AS record_key,
        EXTRACT(YEAR FROM sale_date) AS sales_year,
        EXTRACT(MONTH FROM sale_date) AS sales_month,
        SUM(net_amount) AS total_net_sales,
        COUNT(*) AS total_transactions
    FROM deduplicated_sales
    GROUP BY 1, 2, 3
),

-- 6: City-wise sales
city_sales AS (
    SELECT
        city AS record_key,
        SUM(net_amount) AS total_net_sales,
        COUNT(*) AS total_transactions
    FROM deduplicated_sales
    GROUP BY city
),

-- 7: Category performance
category_performance AS (
    SELECT
        category AS record_key,
        SUM(quantity) AS total_quantity,
        SUM(net_amount) AS total_revenue,
        AVG(unit_price) AS average_unit_price
    FROM deduplicated_sales
    GROUP BY category
),

-- 8: Payment method analysis
payment_analysis AS (
    SELECT
        payment_method AS record_key,
        COUNT(*) AS total_transactions,
        SUM(net_amount) AS total_net_sales
    FROM deduplicated_sales
    GROUP BY payment_method
),

-- 9: Product revenue ranking
product_ranking AS (
    SELECT
        product_name AS record_key,
        SUM(net_amount) AS total_revenue,
        RANK() OVER (ORDER BY SUM(net_amount) DESC) AS revenue_rank
    FROM deduplicated_sales
    GROUP BY product_name
),

-- 10: Duplicate sale IDs
duplicate_sales AS (
    SELECT
        CAST(sale_id AS STRING) AS record_key,
        COUNT(*) AS duplicate_count
    FROM categorized_sales
    GROUP BY sale_id
    HAVING COUNT(*) > 1
),

-- 12: Sales above average
above_average_sales AS (
    SELECT *
    FROM deduplicated_sales
    WHERE net_amount > (
        SELECT AVG(net_amount)
        FROM deduplicated_sales
    )
),

-- 13: Running sales total
running_sales AS (
    SELECT
        *,
        SUM(net_amount) OVER (
            ORDER BY sale_date, sale_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS running_net_sales
    FROM deduplicated_sales
),

-- 14: Customer spending summary
customer_spending AS (
    SELECT
        customer_name AS record_key,
        SUM(net_amount) AS total_net_spending,
        COUNT(*) AS total_transactions
    FROM deduplicated_sales
    GROUP BY customer_name
),

-- 15: Data quality flags
quality_flags AS (
    SELECT
        *,
        CASE
            WHEN customer_name IS NULL
                 OR TRIM(customer_name) = ''
                THEN 'Missing customer'
            WHEN quantity <= 0
                THEN 'Non-positive quantity'
            WHEN unit_price < 0
                THEN 'Negative unit price'
            WHEN net_amount < 0
                THEN 'Negative net sales'
            ELSE 'Valid'
        END AS data_quality_flag
    FROM categorized_sales
)

-- Final output: row-level sales records
SELECT
    'DETAIL' AS result_type,
    CAST(sale_id AS STRING) AS record_key,
    sale_date,
    city,
    customer_name,
    product_name,
    category,
    payment_method,
    sales_status,
    quantity,
    gross_amount,
    discount,
    net_amount,
    sales_category,
    CAST(NULL AS FLOAT64) AS aggregate_value,
    CAST(NULL AS INT64) AS transaction_count,
    CAST(NULL AS INT64) AS revenue_rank,
    CAST(NULL AS STRING) AS quality_flag
FROM quality_flags

UNION ALL

-- Monthly summary
SELECT
    'MONTHLY',
    CONCAT(CAST(sales_year AS STRING), '-',
           LPAD(CAST(sales_month AS STRING), 2, '0')),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, total_net_sales, NULL,
    total_net_sales, total_transactions, NULL, NULL
FROM monthly_sales

UNION ALL

-- City summary
SELECT
    'CITY', record_key,
    NULL, record_key, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, total_net_sales, NULL,
    total_net_sales, total_transactions, NULL, NULL
FROM city_sales

UNION ALL

-- Category summary
SELECT
    'CATEGORY', record_key,
    NULL, NULL, NULL, NULL, record_key, NULL, NULL,
    total_quantity, NULL, NULL, total_revenue, NULL,
    average_unit_price, NULL, NULL, NULL
FROM category_performance

UNION ALL

-- Payment method summary
SELECT
    'PAYMENT', record_key,
    NULL, NULL, NULL, NULL, NULL, record_key, NULL,
    NULL, NULL, NULL, total_net_sales, NULL,
    total_net_sales, total_transactions, NULL, NULL
FROM payment_analysis

UNION ALL

-- Product ranking
SELECT
    'PRODUCT_RANK', record_key,
    NULL, NULL, NULL, record_key, NULL, NULL, NULL,
    NULL, NULL, NULL, total_revenue, NULL,
    total_revenue, NULL, revenue_rank, NULL
FROM product_ranking

UNION ALL

-- Duplicate detection
SELECT
    'DUPLICATE', record_key,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL,
    CAST(duplicate_count AS FLOAT64), NULL, NULL, NULL
FROM duplicate_sales

UNION ALL

-- Sales above average
SELECT
    'ABOVE_AVERAGE', CAST(sale_id AS STRING),
    sale_date, city, customer_name, product_name,
    category, payment_method, sales_status,
    quantity, gross_amount, discount, net_amount,
    sales_category, net_amount, NULL, NULL, NULL
FROM above_average_sales

UNION ALL

-- Running sales total
SELECT
    'RUNNING_TOTAL', CAST(sale_id AS STRING),
    sale_date, city, customer_name, product_name,
    category, payment_method, sales_status,
    quantity, gross_amount, discount, net_amount,
    sales_category, running_net_sales, NULL, NULL, NULL
FROM running_sales

UNION ALL

-- Customer spending
SELECT
    'CUSTOMER', record_key,
    NULL, NULL, record_key, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, total_net_spending, NULL,
    total_net_spending, total_transactions, NULL, NULL
FROM customer_spending

UNION ALL

-- Data quality exceptions
SELECT
    'QUALITY', CAST(sale_id AS STRING),
    sale_date, city, customer_name, product_name,
    category, payment_method, sales_status,
    quantity, gross_amount, discount, net_amount,
    sales_category, NULL, NULL, NULL, data_quality_flag
FROM quality_flags
WHERE data_quality_flag <> 'Valid'
