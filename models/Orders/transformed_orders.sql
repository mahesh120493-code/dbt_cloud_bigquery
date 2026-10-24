{{ config(materialized = 'table') }}

SELECT
    order_id,
    customer_id,
    order_date,
    product_name,
    category,
    quantity,
    unit_price,
    COALESCE(total_amount, quantity * unit_price) AS total_amount,
    LOWER(TRIM(order_status)) AS order_status,
    LOWER(TRIM(payment_method)) AS payment_method

FROM {{ source('bigquery_source','orders') }}