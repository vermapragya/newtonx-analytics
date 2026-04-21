# NewtonX — Expert Supply Analytics

---

## Start here

There are three deliverables. Read them in this order:

| Step | What | Where |
|---|---|---|
| 1 | dashboard | [Open in pdf](tableau_view/NewtonX - Expert Analytics.pdf) |
| 2 | Written findings & recommendations | [`Expert Growth Pod Memo.pdf`](Expert Growth Pod Memo.pdf) |
| 3 | SQL queries | [`sql/`](./sql_queries/) |

---

## 1. Dashboard

The dashboard was built in Tableau Desktop and is available in [`tableau_view/`](./tableau_view/) in three formats:
 
| File | What it is |
|---|---|
| `.twb` | Tableau workbook — open in Tableau Desktop to interact with filters and drill-downs |
| `.pdf` | PDF export of all four dashboard views — the quickest way to see the full analysis |
| Presentation view | Static screenshots of the dashboard laid out as a presentation |
 
**To view without Tableau:** open the PDF — it walks through all four views in order.
 
**To interact with the dashboard:** open the `.twb` file in Tableau Desktop
 
The dashboard has four views:
 
- **Funnel health** — where experts drop off, stage-by-stage conversion rates, biggest bottleneck callout
- **Channel performance** — activation rate, CAC, and LTV:CAC by acquisition channel
- **Cohort trends** — weekly signup-to-activation rate over time, Q4 decline highlighted
- **Campaign deep dive** — paid campaign rankings by volume, activation rate, and LTV:CAC efficiency

Use the **Time Period** filter (top right of each view) to switch between full-year and individual quarters.

---

## 2. Memo

[`Expert Growth Pod Memo.pdf`](Expert Growth Pod Memo.pdf) is a 2–3 page brief written for the Growth PM, Marketing Lead, and VP Product. It covers:

1. **Executive summary** — the two funnel bottlenecks and the budget reallocation case, in five sentences
2. **Funnel insights** — where experts are lost and what hypotheses explain each drop-off
3. **Channel recommendations** — where to increase and decrease investment, with specific numbers
4. **Data quality flags** — five issues found in the data, how each was handled, and what to fix in instrumentation
5. **Suggested experiments** — three A/B tests with hypotheses, metrics, guardrails, and sample sizes

---

## 3. SQL

All queries are in [`sql/`](./sql_queries/). Each file is self-contained and annotated.

| File | What it answers |
|---|---|
| [`1.1_full_funnel_conversion.sql`](./sql_queries/1.1_full_funnel_conversion.sql) | Stage-by-stage conversion rates with drop-off counts |
| [`1.2_cohort_weekly_analysis.sql`](./sql_queries/1.2_cohort_weekly_analysis.sql) | Weekly cohort activation rates, median and P75/P90 days to activate |
| [`1.3_period_over_period.sql`](./sql_queries/1.3_period_over_period.sql) | Quarter-over-quarter comparison with statistical significance test |
| [`2.1_channel_performance.sql`](./sql_queries/2.1_channel_performance.sql) | Signups, activation rate, CAC, LTV:CAC by channel |
| [`2.2_campaign_deep_dive.sql`](./sql_queries/2.2_campaign_deep_dive.sql) | Campaign rankings by volume, activation rate, and LTV:CAC |

Every query includes a `time_period` column (`'All'` or `'Q1 2024'`–`'Q4 2024'`) so results can be filtered by quarter without rewriting SQL.

To run the queries locally, see **Setup** below.

---

## Key findings

The numbers that drive everything else:

- **11.2%** of signups complete a first paid engagement — 1,348 out of 12,000
- **Biggest bottleneck:** Profile Completed → Verification Submitted. Only 62% of experts who finish their profile ever submit for verification. This single step loses ~2,300 experts per year.
- **Second bottleneck:** Verified → Activated. 42% of verified experts never complete an engagement — a supply-demand matching problem, not a funnel problem.
- **Only one paid channel is profitable:** LinkedIn outreach at LTV:CAC 1.17×. Paid search (0.15×) and paid social (0.10×) together spend $1.07M/year to generate roughly $150K in expert lifetime value.
- **Q4 activation rate dropped 3.7 percentage points** vs Q3. Statistically significant (z = 2.1, p < 0.05). Root cause unknown from this data — warrants product audit.
- **Referral is the best channel nobody is investing in:** 23.5% activation rate, zero spend.

---

## Assumptions and tradeoffs

Things that are worth knowing before reviewing the analysis:

**Attribution is last-touch.** `signup_source` records the channel at account creation. Experts influenced by paid ads who signed up organically are attributed to organic. Multi-touch attribution would require cross-session tracking data that isn't in the provided tables.

**LTV proxy is 12-month payouts.** The `engagements` table covers all of 2024. This understates true LTV for recent signups (Q4 experts have had fewer months to earn) and overstates it for churned experts. With more time I'd weight by tenure.

**`unknown` channel is kept separate, not redistributed.** 15.3% of signups have `signup_source = 'unknown'` due to UTM tracking gaps. Redistributing them proportionally to known channels would introduce false precision. The right fix is upstream — enforce UTM capture at every signup entry point.

**Spend join is a soft join with no foreign key.** `daily_channel_spend` joins to `experts` on `signup_source = channel AND utm_campaign = campaign_name`. Experts with NULL `utm_campaign` don't match any spend row. These are bucketed as `[untagged]` in campaign analysis.

**Verification rejection excluded from Verified and Activated counts.** 528 experts (14.1% of those who submitted) were rejected. They remain in the denominator at all earlier stages since rejection is a real outcome of submitting — removing them would inflate the verified conversion rate artificially.

---

## What I'd do differently with more time

- **Proper data model as the backend.** From an analytics engineering / data engineering perspective, the right foundation would be a thoroughly built-out data model — staging layers, intermediate models, and clean mart tables — rather than reusing the ad-hoc SQL queries (1.1 through 2.2) directly as the Tableau data source. The current approach repurposes analytical queries as a data layer, which works for a submission but wouldn't scale in production. With more time I'd build this in dbt: `stg_experts`, `stg_funnel_events`, `int_expert_funnel_flags`, and a final `mart_expert_acquisition` model that `2.3_tableau_flat_export.sql` would simply `SELECT *` from.
- **Expert quality segmentation beyond binary activation.** An expert who completed one $50 survey is counted the same as one who did twelve interviews. Segmenting by engagement frequency and payout decile would separate channels that produce one-and-done experts from those that produce repeat earners.
- **Cohort survival curves.** The 60-day activation window is a clean metric but loses information. A survival curve would show whether some channels are just slower to activate (still valuable) vs genuinely lower quality.
- **UTM completeness audit.** Before making budget decisions based on channel attribution, I'd want to understand what's hiding in the 15% `unknown` bucket. If paid social has high unknown leakage, its LTV:CAC is even worse than measured.

---

## Repo structure

```
newtonx-analytics/
├── README.md                         ← you are here
├── Expert Growth Pod Memo.pdf        ← written findings (start here after the dashboard)
├── .gitignore                        ← excludes data/
└── sql/
    ├── 1.1_full_funnel_conversion.sql
    ├── 1.2_cohort_weekly_analysis.sql
    ├── 1.3_period_over_period.sql
    ├── 2.1_channel_performance.sql
    ├── 2.2_campaign_deep_dive.sql
```

