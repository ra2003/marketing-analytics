-- Pulls together data from Fetch, GA, Corpmetrics and Telemetry to tell the
-- story of Spend, downloads, installs, LTV
WITH
  -- sum of dau and installs by ad content
  dau_installs_by_content AS (
    SELECT
      PARSE_DATE('%Y%m%d', submission_date_s3) as date,
      REPLACE(REPLACE(REPLACE(REPLACE(contentCleaned,'%2528','('),'%2529',')'),'%2B',' '),'%257C','|') AS content,
      SUM(installs) AS sum_installs,
      SUM(dau) AS sum_dau
    FROM
      `telemetry.corpMetrics`
    GROUP BY
      date,
      content
  ),

  -- Limit Fetch data to 1) Non-branded Search in 2) top countries, 3) specific
  -- vendors, and within 4) the current quarter
  nonbranded_search_spend AS (
  SELECT
    date,
    vendor,
    adname,
    country,
    targeting,
    vendornetspend,
    downloadsGA
  FROM
    `fetch.fetch_deduped`
  WHERE
    vendor IN ('Adwords', 'Bing')
    AND country IN ('United States', 'Canada', 'Germany', 'United Kingdom', 'France', 'Poland')
    AND targeting = 'Nonbrand Search'
    AND vendornetspend > 0
    AND date BETWEEN DATE(2018, 9, 1) AND DATE(2018, 12, 31)
  ),

  -- Joins with LTV data set based on source, medium, campaign, and content
  ltv_attribution AS (
  SELECT
    PARSE_DATE('%Y%m%d', _TABLE_SUFFIX) AS date_of_job,
    f.country,
    f.targeting,
    -- NOTE: this is only used for what seems to be an optional grouping
    -- CASE
    --   WHEN REGEXP_EXTRACT(f.socialstring, r'(.*)_') LIKE '%Competitor%' THEN 'Competitor'
    --   WHEN REGEXP_EXTRACT(f.socialstring, r'(.*)_') LIKE '%Browser%' THEN 'Browser'
    -- END AS AGroup,
    COUNT(DISTINCT(ltv.client_ID)) AS n,
    AVG(ltv.total_clv) AS avg_tLTV
  FROM
    `ltv.v1_clients_*` AS ltv
  LEFT JOIN
    `fetch.fetch_deduped` AS f
  ON
    ltv.content = f.adname
  WHERE
    f.targeting IS NOT NULL
    AND _TABLE_SUFFIX NOT IN ('20180608', '20180917', '20181002', '20181017')
    AND ltv.historical_searches < (
      SELECT
        STDDEV(historical_searches) * 5
      FROM
        `ltv.v1_clients_*`
    ) + (
      SELECT
        AVG(historical_searches)
      FROM
        `ltv.v1_clients_*`
    )
  GROUP BY
    date_of_job,
    f.country,
    f.targeting
    -- AGroup
  ),

  ltv_attribution_by_month AS (
    SELECT
      EXTRACT(MONTH FROM date_of_job) AS month_num,
      country,
      targeting,
      MIN(n) AS min_n,
      MAX(n) AS max_n,
      AVG(avg_tLTV) AS avg_avg_tLTV
    FROM
      ltv_attribution
    GROUP BY
      month_num,
      country,
      targeting
  )


-- Pulls whole table
SELECT
  spending.country,
  spending.targeting,
  spending.month_num,
  spending.sum_vendornetspend,
  spending.sum_fetchdownloads,
  spending.proj_installs,
  spending.CPD,
  spending.proj_cpi,
  ltv_attribution_by_month.min_n,
  ltv_attribution_by_month.max_n,
  ltv_attribution_by_month.avg_avg_tLTV,
  ltv_attribution_by_month.avg_avg_tLTV * spending.proj_installs AS revenue,
  (ltv_attribution_by_month.avg_avg_tLTV * spending.proj_installs) - spending.sum_vendornetspend AS profit,
  (ltv_attribution_by_month.avg_avg_tLTV * spending.proj_installs) / spending.sum_vendornetspend AS ltv_mcac,
  CASE
    WHEN (ltv_attribution_by_month.avg_avg_tLTV * spending.proj_installs) = 0 THEN 0
    ELSE spending.sum_vendornetspend / (ltv_attribution_by_month.avg_avg_tLTV * spending.proj_installs)
  END AS mcac_ltv
FROM (
  SELECT
    EXTRACT(month FROM f.date) AS month_num,
    f.country,
    f.targeting,

    SUM(vendorNetSpend) AS sum_vendornetspend,
    -- sum(downloads) sum_downloads,
    SUM(downloadsGA) AS sum_fetchdownloads,
    SUM(downloadsGA) * .66 AS proj_installs,
    CASE
    WHEN SUM(f.downloadsGA) = 0 THEN 0
      ELSE SUM(f.vendornetspend) / SUM(f.downloadsGA)
      END AS CPD,
    CASE
      WHEN SUM(f.downloadsGA) = 0 THEN 0
      ELSE SUM(f.vendornetspend) / (SUM(f.downloadsGA) * .66)
    END AS proj_CPI
  FROM
    nonbranded_search_spend AS f
  LEFT JOIN
    -- NOTE: nothing is projected from this table at the moment
    dau_installs_by_content AS t
  ON
    f.date = t.date
    AND f.adname = t.content
  GROUP BY
    month_num,
    f.country,
    f.targeting
) AS spending
LEFT JOIN
  ltv_attribution_by_month
ON
  spending.month_num = ltv_attribution_by_month.month_num
  AND spending.country = ltv_attribution_by_month.country
  AND spending.targeting = ltv_attribution_by_month.targeting
ORDER BY
  spending.country,
  spending.month_num,
  spending.sum_vendornetspend ASC
