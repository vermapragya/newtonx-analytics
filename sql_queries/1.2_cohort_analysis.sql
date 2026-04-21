WITH rejected_experts AS (
  SELECT DISTINCT expert_id FROM funnel_events WHERE event_name = 'verification_rejected'
),

first_activation AS (
  SELECT expert_id, MIN(event_timestamp) AS activated_at
  FROM funnel_events
  WHERE event_name = 'first_engagement_completed'
  GROUP BY expert_id
),

cohort_base AS (
  SELECT
    e.expert_id,
    DATE_TRUNC('week', e.signup_date::TIMESTAMP)            AS signup_week,
    fa.activated_at,
    EXTRACT(EPOCH FROM (fa.activated_at::TIMESTAMP - e.signup_date::TIMESTAMP))
      / 86400                                               AS days_to_activate_raw,
    CASE
      WHEN fa.activated_at IS NOT NULL
       AND EXTRACT(EPOCH FROM (fa.activated_at::TIMESTAMP - e.signup_date::TIMESTAMP)) / 86400
           BETWEEN 0 AND 60
       AND e.expert_id NOT IN (SELECT expert_id FROM rejected_experts)
      THEN 1 ELSE 0
    END                                                     AS activated_within_60d
  FROM experts e
  LEFT JOIN first_activation fa ON e.expert_id = fa.expert_id
),

weekly_summary AS (
  SELECT
    signup_week,
    COUNT(expert_id)                                                           AS cohort_size,
    SUM(activated_within_60d)                                                  AS activated_count,
    ROUND(AVG(days_to_activate_raw) FILTER (WHERE activated_within_60d = 1)::NUMERIC, 1) 
                                                                               AS avg_days_to_activate,
    ROUND((100.0 * SUM(activated_within_60d) / COUNT(expert_id))::NUMERIC, 2) AS activation_rate_pct,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (
      ORDER BY days_to_activate_raw) FILTER (WHERE activated_within_60d = 1)::NUMERIC, 1)
                                                                               AS median_days_to_activate,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (
      ORDER BY days_to_activate_raw) FILTER (WHERE activated_within_60d = 1)::NUMERIC, 1)
                                                                               AS p75_days_to_activate,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (
      ORDER BY days_to_activate_raw) FILTER (WHERE activated_within_60d = 1)::NUMERIC, 1)
                                                                               AS p90_days_to_activate
  FROM cohort_base
  GROUP BY signup_week
)

SELECT
  signup_week,
  cohort_size,
  activated_count,
  avg_days_to_activate,
  activation_rate_pct,
  median_days_to_activate,
  p75_days_to_activate,
  p90_days_to_activate,
  ROUND((activation_rate_pct - LAG(activation_rate_pct) OVER (ORDER BY signup_week))::NUMERIC, 2)
    AS wow_activation_rate_change_ppt
FROM weekly_summary
ORDER BY signup_week