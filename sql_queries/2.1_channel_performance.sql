WITH rejected_experts AS (
  SELECT DISTINCT expert_id FROM funnel_events WHERE event_name = 'verification_rejected'
),

activated_experts AS (
  SELECT DISTINCT expert_id 
  FROM funnel_events 
  WHERE event_name = 'first_engagement_completed'
    AND expert_id NOT IN (SELECT expert_id FROM rejected_experts WHERE expert_id IS NOT NULL)
),

expert_ltv AS (
  SELECT expert_id, SUM(payout_amount) AS total_payout_12m
  FROM engagements
  GROUP BY expert_id
),

-- Step 1: Create the Time Period Rows
-- This cross join creates two rows for every expert: one for their specific quarter and one for 'All'
expert_periods AS (
  SELECT
    e.expert_id,
    e.signup_source,
    e.signup_date,
    'Q' || TO_CHAR(e.signup_date::TIMESTAMP, 'Q') || ' ' || TO_CHAR(e.signup_date::TIMESTAMP, 'YYYY') AS quarter_label,
    p.time_period
  FROM experts e
  CROSS JOIN (
    VALUES ('All'), ('Q1 2024'), ('Q2 2024'), ('Q3 2024'), ('Q4 2024')
  ) AS p(time_period)
  WHERE p.time_period = 'All'
     OR p.time_period = ('Q' || TO_CHAR(e.signup_date::TIMESTAMP, 'Q') || ' ' || TO_CHAR(e.signup_date::TIMESTAMP, 'YYYY'))
),

-- Step 2: Aggregate Experts and Payouts by Period
channel_base AS (
  SELECT
    ep.time_period,
    ep.signup_source,
    COUNT(DISTINCT ep.expert_id) AS total_signups,
    COUNT(DISTINCT ae.expert_id) AS activated_count,
    COALESCE(SUM(el.total_payout_12m), 0) AS total_expert_payouts
  FROM expert_periods ep
  LEFT JOIN activated_experts ae ON ep.expert_id = ae.expert_id
  LEFT JOIN expert_ltv el ON ep.expert_id = el.expert_id
  GROUP BY 1, 2
),

-- Step 3: Aggregate Spend by Period
channel_spend AS (
  SELECT 
    channel,
    'Q' || TO_CHAR(date::TIMESTAMP, 'Q') || ' ' || TO_CHAR(date::TIMESTAMP, 'YYYY') AS time_period,
    SUM(spend_usd) AS total_spend_usd
  FROM daily_channel_spend
  GROUP BY 1, 2
  UNION ALL
  SELECT channel, 'All', SUM(spend_usd) FROM daily_channel_spend GROUP BY 1
),

-- Step 4: Final Combined Logic
channel_combined AS (
  SELECT
    cb.time_period,
    cb.signup_source,
    cb.total_signups,
    cb.activated_count,
    (cb.activated_count::NUMERIC / NULLIF(cb.total_signups, 0))::NUMERIC AS activation_rate_pct,
    cb.total_expert_payouts,
    ROUND((cb.total_expert_payouts / NULLIF(cb.activated_count, 0))::NUMERIC, 2) AS avg_payout_per_activated_expert,
    COALESCE(cs.total_spend_usd, 0) AS total_spend_usd
  FROM channel_base cb
  LEFT JOIN channel_spend cs 
    ON cb.signup_source = cs.channel 
    AND cb.time_period = cs.time_period
)

SELECT
  time_period,
  signup_source,
  total_signups,
  activated_count,
  activation_rate_pct,
  total_expert_payouts,
  avg_payout_per_activated_expert,
  total_spend_usd,
  -- CAC and LTV Metrics
  CASE WHEN total_spend_usd > 0 THEN ROUND((total_spend_usd / NULLIF(total_signups, 0))::NUMERIC, 2) END AS cost_per_signup,
  CASE WHEN total_spend_usd > 0 THEN ROUND((total_spend_usd / NULLIF(activated_count, 0))::NUMERIC, 2) END AS cost_per_activated_expert,
  CASE WHEN total_spend_usd > 0 AND activated_count > 0 
       THEN ROUND((avg_payout_per_activated_expert / (total_spend_usd / activated_count))::NUMERIC, 2) 
  END AS ltv_cac_ratio,
  -- Category labeling
  CASE
    WHEN signup_source IN ('paid_search','paid_social','linkedin_outreach') THEN 'Paid'
    WHEN signup_source IN ('organic','referral') THEN 'Organic/Earned'
    ELSE 'Unknown / Untracked'
  END AS channel_category
FROM channel_combined
ORDER BY 
  (time_period != 'All'),
  time_period ASC, 
  total_signups DESC