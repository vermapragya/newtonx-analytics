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

-- Paid experts cross joined with time_period
expert_periods AS (
  SELECT
    e.expert_id,
    e.signup_source,
    COALESCE(e.utm_campaign, '[untagged]') AS campaign_name,
    'Q' || TO_CHAR(e.signup_date::TIMESTAMP, 'Q') || ' ' || TO_CHAR(e.signup_date::TIMESTAMP, 'YYYY') AS signup_quarter_label,
    DATE_TRUNC('quarter', e.signup_date::TIMESTAMP) AS signup_quarter,
    p.time_period
  FROM experts e
  CROSS JOIN (
    VALUES ('All'), ('Q1 2024'), ('Q2 2024'), ('Q3 2024'), ('Q4 2024')
  ) AS p(time_period)
  WHERE e.signup_source IN ('paid_search', 'paid_social', 'linkedin_outreach')
    AND (p.time_period = 'All'
         OR p.time_period = 'Q' || TO_CHAR(e.signup_date::TIMESTAMP, 'Q') || ' ' || TO_CHAR(e.signup_date::TIMESTAMP, 'YYYY'))
),

campaign_base AS (
  SELECT
    ep.signup_source AS channel,
    ep.campaign_name,
    ep.time_period,
    CASE WHEN ep.time_period = 'All' THEN NULL ELSE ep.signup_quarter END AS signup_quarter,
    CASE WHEN ep.time_period = 'All' THEN 'All' ELSE ep.signup_quarter_label END AS quarter_label,
    COUNT(DISTINCT ep.expert_id) AS total_signups,
    COUNT(DISTINCT ae.expert_id) AS activated_count,
    ROUND((100.0 * COUNT(DISTINCT ae.expert_id) / NULLIF(COUNT(DISTINCT ep.expert_id), 0))::NUMERIC, 2) AS activation_rate_pct,
    ROUND(COALESCE(SUM(el.total_payout_12m), 0)::NUMERIC, 2) AS total_payouts,
    ROUND((COALESCE(SUM(el.total_payout_12m), 0) / NULLIF(COUNT(DISTINCT ae.expert_id), 0))::NUMERIC, 2) AS avg_ltv_per_activated
  FROM expert_periods ep
  LEFT JOIN activated_experts ae ON ep.expert_id = ae.expert_id
  LEFT JOIN expert_ltv el ON ep.expert_id = el.expert_id
  GROUP BY 1, 2, 3, 4, 5
),

spend_by_quarter AS (
  SELECT campaign_name,
    'Q' || TO_CHAR(date::TIMESTAMP, 'Q') || ' ' || TO_CHAR(date::TIMESTAMP, 'YYYY') AS time_period,
    SUM(spend_usd) AS total_spend,
    SUM(impressions) AS total_impressions,
    SUM(clicks) AS total_clicks
  FROM daily_channel_spend
  GROUP BY 1, 2
),

spend_full_year AS (
  SELECT campaign_name, 'All' AS time_period,
    SUM(spend_usd) AS total_spend,
    SUM(impressions) AS total_impressions,
    SUM(clicks) AS total_clicks
  FROM daily_channel_spend 
  GROUP BY 1, 2
),

spend_lookup AS (
  SELECT * FROM spend_by_quarter
  UNION ALL
  SELECT * FROM spend_full_year
),

campaign_combined AS (
  SELECT
    cb.*,
    COALESCE(sl.total_spend, 0) AS total_spend,
    COALESCE(sl.total_impressions, 0) AS total_impressions,
    COALESCE(sl.total_clicks, 0) AS total_clicks,
    ROUND((100.0 * COALESCE(sl.total_clicks, 0) / NULLIF(COALESCE(sl.total_impressions, 0), 0))::NUMERIC, 2) AS ctr_pct,
    -- Ranking logic (Partitions by time_period to ensure 'All' has its own Top 3 and each Quarter has its own Top 3)
    ROW_NUMBER() OVER (PARTITION BY cb.time_period ORDER BY cb.total_signups DESC) AS rank_by_volume,
    ROW_NUMBER() OVER (PARTITION BY cb.time_period ORDER BY CASE WHEN cb.total_signups >= 100 THEN cb.activation_rate_pct ELSE -1 END DESC) AS rank_by_activation_rate,
    ROW_NUMBER() OVER (PARTITION BY cb.time_period ORDER BY CASE WHEN COALESCE(sl.total_spend, 0) > 0 AND cb.activated_count > 0 
                                                               THEN (cb.total_payouts / NULLIF(sl.total_spend, 0)) ELSE -1 END DESC) AS rank_by_ltv_cac
  FROM campaign_base cb
  LEFT JOIN spend_lookup sl ON cb.campaign_name = sl.campaign_name AND cb.time_period = sl.time_period
)

SELECT
  time_period,
  signup_quarter,
  quarter_label,
  channel,
  campaign_name,
  total_signups,
  activated_count,
  activation_rate_pct,
  total_spend,
  -- Re-calculating final metrics with proper casting
  ROUND((total_spend / NULLIF(total_signups, 0))::NUMERIC, 2) AS cost_per_signup,
  ROUND((total_spend / NULLIF(activated_count, 0))::NUMERIC, 2) AS cost_per_activated,
  avg_ltv_per_activated,
  ROUND((avg_ltv_per_activated / NULLIF((total_spend / NULLIF(activated_count, 0)), 0))::NUMERIC, 2) AS ltv_cac_ratio,
  total_impressions,
  total_clicks,
  ctr_pct,
  rank_by_volume,
  rank_by_activation_rate,
  rank_by_ltv_cac,
  CASE
    WHEN rank_by_volume <= 3 THEN 'Top 3 by volume'
    WHEN rank_by_activation_rate <= 3 AND total_signups >= 100 THEN 'Top 3 by activation rate'
    WHEN rank_by_ltv_cac <= 3 THEN 'Top 3 by LTV:CAC'
  END AS top_campaign_flag
FROM campaign_combined
ORDER BY
  CASE time_period WHEN 'All' THEN 0 ELSE 1 END,
  time_period,
  rank_by_volume