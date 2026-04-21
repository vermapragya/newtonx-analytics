WITH rejected_experts AS (
  SELECT DISTINCT expert_id FROM funnel_events WHERE event_name = 'verification_rejected'
),
 
first_activation AS (
  SELECT expert_id, MIN(event_timestamp) AS activated_at
  FROM funnel_events
  WHERE event_name = 'first_engagement_completed'
  GROUP BY expert_id
),
 
expert_base AS (
  SELECT
    e.expert_id,
    DATE_TRUNC('quarter', e.signup_date::TIMESTAMP)        AS signup_quarter,
    'Q' || TO_CHAR(e.signup_date::TIMESTAMP, 'Q')
      || ' ' || TO_CHAR(e.signup_date::TIMESTAMP, 'YYYY') AS quarter_label,
    CASE
      WHEN fa.expert_id IS NOT NULL
       AND e.expert_id NOT IN (SELECT expert_id FROM rejected_experts)
      THEN 1 ELSE 0
    END AS is_activated,
    CASE
      WHEN fa.expert_id IS NOT NULL
       AND e.expert_id NOT IN (SELECT expert_id FROM rejected_experts)
      THEN EXTRACT(EPOCH FROM (fa.activated_at::TIMESTAMP - e.signup_date::TIMESTAMP)) / 86400
    END AS days_to_activate
  FROM experts e
  LEFT JOIN first_activation fa ON e.expert_id = fa.expert_id
),
 
-- Attach time_period: each expert appears under 'All' + their quarter
expert_with_period AS (
  SELECT eb.*, p.time_period
  FROM expert_base eb
  CROSS JOIN (
    VALUES ('All'), ('Q1 2024'), ('Q2 2024'), ('Q3 2024'), ('Q4 2024')
  ) AS p(time_period)
  WHERE p.time_period = 'All'
     OR p.time_period = eb.quarter_label
),
 
period_stats AS (
  SELECT
    time_period,
    -- signup_quarter is NULL for 'All' row (spans whole year)
    CASE WHEN time_period = 'All' THEN NULL ELSE signup_quarter END AS signup_quarter,
    CASE WHEN time_period = 'All' THEN 'All' ELSE quarter_label END AS quarter_label,
    COUNT(*)                                                                   AS total_signups,
    SUM(is_activated)                                                          AS total_activated,
    ROUND((100.0 * SUM(is_activated) / COUNT(*))::NUMERIC, 2)                 AS activation_rate_pct,
    ROUND(AVG(days_to_activate) FILTER (WHERE is_activated = 1)::NUMERIC, 1)  AS avg_days_to_activate
  FROM expert_with_period
  GROUP BY time_period, signup_quarter, quarter_label
),
 
pool AS (
  -- Pool rate computed across quarterly rows only (excludes 'All')
  SELECT SUM(total_activated)::NUMERIC / NULLIF(SUM(total_signups), 0) AS p_pool
  FROM period_stats
  WHERE time_period != 'All'
)
 
SELECT
  ps.time_period,
  ps.signup_quarter,
  ps.quarter_label,
  ps.total_signups,
  ps.total_activated,
  ps.activation_rate_pct,
  ps.avg_days_to_activate,
  ROUND((
    100.0 * (ps.total_signups - LAG(ps.total_signups) OVER (ORDER BY ps.time_period))
          / NULLIF(LAG(ps.total_signups) OVER (ORDER BY ps.time_period), 0)
  )::NUMERIC, 1)                                                               AS signups_pct_change,
  ROUND((
    ps.activation_rate_pct
    - LAG(ps.activation_rate_pct) OVER (ORDER BY ps.time_period)
  )::NUMERIC, 2)                                                               AS activation_rate_ppt_change,
  ROUND((
    ps.avg_days_to_activate
    - LAG(ps.avg_days_to_activate) OVER (ORDER BY ps.time_period)
  )::NUMERIC, 1)                                                               AS avg_days_change,
  -- Two-proportion z-test: |z| > 1.96 = significant at 95% CI
  ROUND((
    (ps.activation_rate_pct / 100.0
      - LAG(ps.activation_rate_pct / 100.0) OVER (ORDER BY ps.time_period))
    / NULLIF(SQRT(
        pool.p_pool * (1 - pool.p_pool) *
        (1.0 / ps.total_signups
         + 1.0 / NULLIF(LAG(ps.total_signups) OVER (ORDER BY ps.time_period), 0))
      ), 0)
  )::NUMERIC, 2)                                                               AS z_score,
  CASE
    WHEN ABS((
      (ps.activation_rate_pct / 100.0
        - LAG(ps.activation_rate_pct / 100.0) OVER (ORDER BY ps.time_period))
      / NULLIF(SQRT(
          pool.p_pool * (1 - pool.p_pool) *
          (1.0 / ps.total_signups
           + 1.0 / NULLIF(LAG(ps.total_signups) OVER (ORDER BY ps.time_period), 0))
        ), 0)
    )) > 1.96
    THEN 'Significant (95% CI)'
    ELSE 'Not significant'
  END                                                                          AS significance_flag
FROM period_stats ps, pool
ORDER BY
  CASE ps.time_period WHEN 'All' THEN 0 ELSE 1 END,
  ps.time_period