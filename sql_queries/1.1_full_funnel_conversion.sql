WITH expert_details AS (
  SELECT 
    expert_id, 
    signup_source, 
    country, 
    industry 
  FROM experts
),

expert_periods AS (
  SELECT
    ed.expert_id,
    ed.signup_source,
    ed.country,
    ed.industry,
    'Q' || TO_CHAR(e.signup_date::TIMESTAMP, 'Q') || ' ' || TO_CHAR(e.signup_date::TIMESTAMP, 'YYYY') AS quarter_label,
    p.time_period
  FROM experts e
  JOIN expert_details ed ON e.expert_id = ed.expert_id
  CROSS JOIN (
    VALUES ('All'), ('Q1 2024'), ('Q2 2024'), ('Q3 2024'), ('Q4 2024')
  ) AS p(time_period)
  WHERE p.time_period = 'All'
     OR p.time_period = 'Q' || TO_CHAR(e.signup_date::TIMESTAMP, 'Q') || ' ' || TO_CHAR(e.signup_date::TIMESTAMP, 'YYYY')
),

stage_flags AS (
  SELECT
    ep.expert_id,
    ep.time_period,
    ep.signup_source,
    ep.country,
    ep.industry,
    MAX(CASE WHEN fe.event_name = 'signup' THEN 1 ELSE 0 END) AS reached_signup,
    MAX(CASE WHEN fe.event_name = 'profile_started' THEN 1 ELSE 0 END) AS reached_profile_started,
    MAX(CASE WHEN fe.event_name = 'profile_completed' THEN 1 ELSE 0 END) AS reached_profile_completed,
    MAX(CASE WHEN fe.event_name = 'verification_submitted' THEN 1 ELSE 0 END) AS reached_verification_submitted,
    MAX(CASE WHEN fe.event_name = 'verification_approved' THEN 1 ELSE 0 END) AS reached_verified,
    MAX(CASE WHEN fe.event_name = 'first_engagement_completed' THEN 1 ELSE 0 END) AS reached_activated,
    MAX(CASE WHEN fe.event_name = 'verification_rejected' THEN 1 ELSE 0 END) AS was_rejected
  FROM expert_periods ep
  LEFT JOIN funnel_events fe ON ep.expert_id = fe.expert_id
  GROUP BY 1, 2, 3, 4, 5
),

stage_counts AS (
  SELECT
    time_period,
    signup_source,
    country,
    industry,
    SUM(reached_signup) AS signup_count,
    SUM(reached_profile_started) AS profile_started_count,
    SUM(reached_profile_completed) AS profile_completed_count,
    SUM(reached_verification_submitted) AS verification_submitted_count,
    SUM(CASE WHEN was_rejected = 0 THEN reached_verified ELSE 0 END) AS verified_count,
    SUM(CASE WHEN was_rejected = 0 THEN reached_activated ELSE 0 END) AS activated_count
  FROM stage_flags
  GROUP BY 1, 2, 3, 4
),

funnel_unpivoted AS (
  SELECT time_period, signup_source, country, industry, 1 AS sort_order, 'Signup' AS stage, signup_count AS experts_reached FROM stage_counts
  UNION ALL
  SELECT time_period, signup_source, country, industry, 2, 'Profile Started', profile_started_count FROM stage_counts
  UNION ALL
  SELECT time_period, signup_source, country, industry, 3, 'Profile Completed', profile_completed_count FROM stage_counts
  UNION ALL
  SELECT time_period, signup_source, country, industry, 4, 'Verification Submitted', verification_submitted_count FROM stage_counts
  UNION ALL
  SELECT time_period, signup_source, country, industry, 5, 'Verified', verified_count FROM stage_counts
  UNION ALL
  SELECT time_period, signup_source, country, industry, 6, 'Activated', activated_count FROM stage_counts
)

SELECT
  *,
  -- Window functions now PARTITION BY the extra dimensions to keep conversion rates accurate when filtered
  LAG(experts_reached) OVER (PARTITION BY time_period, signup_source, country, industry ORDER BY sort_order) AS prev_stage_count,
  FIRST_VALUE(experts_reached) OVER (PARTITION BY time_period, signup_source, country, industry ORDER BY sort_order) AS signup_total
FROM funnel_unpivoted