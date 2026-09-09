# Constructing the Store x Product x Date Panel

## Background

The regression analysis required a daily panel that records how many bottles of each product each store purchased, including days with no purchases. I organized the construction into two stages: first, building the zero-filled panel and adding store characteristics; second, adding discount timing and event-study variables.

## 1. [Build the zero-filled panel and classify store size](../scripts/build_panel_w_zero_rows.sql)

``` sql
create or replace table `pnl.store_item_date_panel`
partition by date_trunc(date, month)
cluster by store_number, item_number_updated, pack, bottle_volume_ml
as

with transactions as (
  select *
  from `pnl.store_item_date`
),

-- Collapse multiple purchases of the same product by the same store on one day.
daily_purchases as (
  select
    date,
    store_number,
    store_name,
    item_number_updated,
    item_desc_updated,
    bottle_volume_ml,
    pack,
    vendor_name_updated,
    category_simple,

    array_agg(
      transactions
      order by invoice_and_item_number
      limit 1
    )[safe_offset(0)] as representative_row,

    sum(bottles_sold) as bottles_sold,
    sum(volume_sold_liters) as volume_sold_liters,
    sum(volume_sold_gallons) as volume_sold_gallons,
    sum(sale_dollars_upd) as sale_dollars_upd

  from transactions
  group by
    date,
    store_number,
    store_name,
    item_number_updated,
    item_desc_updated,
    bottle_volume_ml,
    pack,
    vendor_name_updated,
    category_simple
),

daily_purchases_clean as (
  select
    representative_row.* except (
      invoice_and_item_number,
      bottles_sold,
      volume_sold_liters,
      volume_sold_gallons,
      sale_dollars_upd
    ),
    cast(null as string) as invoice_and_item_number,
    bottles_sold,
    volume_sold_liters,
    volume_sold_gallons,
    sale_dollars_upd
  from daily_purchases
),

-- Identify the observed lifespan of each store-product combination.
store_products as (
  select
    store_number,
    store_name,
    item_number_updated,
    item_desc_updated,
    bottle_volume_ml,
    pack,
    vendor_name_updated,
    category_simple,
    min(date) as min_date_observed,
    max(date) as max_date_observed
  from daily_purchases_clean
  group by
    store_number,
    store_name,
    item_number_updated,
    item_desc_updated,
    bottle_volume_ml,
    pack,
    vendor_name_updated,
    category_simple
),

-- Generate one row per date between the first and last observed purchase.
panel_spine as (
  select
    store_products.*,
    date
  from store_products,
  unnest(
    generate_date_array(min_date_observed, max_date_observed)
  ) as date
),

panel_joined as (
  select
    spine.date,
    spine.min_date_observed,
    spine.max_date_observed,
    spine.store_number,
    spine.store_name,
    spine.item_number_updated,
    spine.item_desc_updated,
    spine.bottle_volume_ml,
    spine.pack,
    spine.vendor_name_updated,
    spine.category_simple,

    purchases.* except (
      date,
      store_number,
      store_name,
      item_number_updated,
      item_number,
      item_desc_updated,
      bottle_volume_ml,
      pack,
      vendor_name_updated,
      vendor_number_updated,
      category_simple,
      category,
      category_name,
      store_location
    )
  from panel_spine as spine
  left join daily_purchases_clean as purchases
  using (
    date,
    store_number,
    store_name,
    item_number_updated,
    item_desc_updated,
    bottle_volume_ml,
    pack,
    vendor_name_updated,
    category_simple
  )
),

-- Use the most recent non-null location recorded for each store.
store_locations as (
  select
    store_number,
    array_agg(address ignore nulls order by date desc limit 1)[safe_offset(0)]
      as address,
    array_agg(city ignore nulls order by date desc limit 1)[safe_offset(0)]
      as city,
    array_agg(zip_code ignore nulls order by date desc limit 1)[safe_offset(0)]
      as zip_code,
    array_agg(county ignore nulls order by date desc limit 1)[safe_offset(0)]
      as county
  from daily_purchases_clean
  group by store_number
),

-- Measure store size using average daily purchasing over its observed lifespan.
store_purchase_volume as (
  select
    store_number,
    store_name,
    safe_divide(
      sum(sale_dollars_upd),
      nullif(date_diff(max(date), min(date), day), 0)
    ) as avg_daily_purchases_lifetime
  from `ild.simp_map_error_rem`
  group by store_number, store_name
),

store_sizes as (
  select
    store_number,
    store_name,
    avg_daily_purchases_lifetime,
    case ntile(3) over (order by avg_daily_purchases_lifetime)
      when 1 then 'Small'
      when 2 then 'Medium'
      when 3 then 'Large'
    end as store_size
  from store_purchase_volume
  where avg_daily_purchases_lifetime > 0
),

final_panel as (
  select
    farm_fingerprint(
      to_json_string(
        struct(
          panel.date,
          panel.store_number,
          panel.store_name,
          panel.item_number_updated,
          panel.item_desc_updated,
          panel.bottle_volume_ml,
          panel.pack,
          panel.vendor_name_updated,
          panel.category_simple
        )
      )
    ) as panel_row_id,

    panel.* except (
      address,
      city,
      zip_code,
      county,
      bottles_sold,
      volume_sold_liters,
      volume_sold_gallons,
      state_bottle_retail_upd,
      sale_dollars_upd
    ),

    -- Dates without a purchase become explicit zero-outcome observations.
    coalesce(panel.bottles_sold, 0) as bottles_sold,
    coalesce(panel.volume_sold_liters, 0) as volume_sold_liters,
    coalesce(panel.volume_sold_gallons, 0) as volume_sold_gallons,
    coalesce(panel.state_bottle_retail_upd, 0) as state_bottle_retail_upd,
    coalesce(panel.sale_dollars_upd, 0) as sale_dollars_upd,

    coalesce(panel.address, locations.address) as address,
    coalesce(panel.city, locations.city) as city,
    coalesce(panel.zip_code, locations.zip_code) as zip_code,
    coalesce(panel.county, locations.county) as county,

    sizes.avg_daily_purchases_lifetime,
    sizes.store_size

  from panel_joined as panel
  left join store_locations as locations
    using (store_number)
  left join store_sizes as sizes
    using (store_number, store_name)
)

select *
from final_panel;
```

This query converts the transaction-level data into a `store x product x date` panel. It first aggregates legitimate same-day purchases, retaining one transaction as the source for store and zip code information, and summing bottles, volume, and sales.

For each store-product combination, `generate_date_array` creates a continuous date array from its first through last observed purchase. The left join to observed purchases creates zero rows for dates with no transaction. Store location fields are filled using the most recent available record.

Store size is based on average daily dollar purchases over each store's observed lifespan. `ntile(3)` divides stores with positive purchasing volume into small, medium, and large terciles.

## 2. [Add discount timing and event-study variables](../scripts/discount_timing_event_stud_panel.sql)

``` sql
create or replace table `pnl.store_item_date_panel_final`
partition by date_trunc(date, month)
cluster by store_number, item_number_updated, pack, bottle_volume_ml
as

with panel as (
  select *
  from `pnl.store_item_date_panel`
),

discount_episodes as (
  select *
  from `ild.temp_price_red_ep`
),

-- Match each panel row to current, previous, and upcoming discount episodes.
discount_matches as (
  select
    panel.panel_row_id,

    array_agg(
      if(
        panel.date >= episode.sale_start_date
          and panel.date < episode.episode_end_date,
        struct(
          episode.episode_id,
          episode.sale_start_date,
          episode.episode_end_date,
          episode.length_of_discount_days,
          episode.max_discount_dollars,
          episode.max_discount_percent
        ),
        null
      )
      ignore nulls
      order by episode.sale_start_date desc, episode.episode_id desc
      limit 1
    )[safe_offset(0)] as current_episode,

    array_agg(
      if(
        episode.sale_start_date <= panel.date,
        struct(episode.episode_id, episode.sale_start_date),
        null
      )
      ignore nulls
      order by episode.sale_start_date desc, episode.episode_id desc
      limit 1
    )[safe_offset(0)] as most_recent_start,

    array_agg(
      if(
        episode.sale_start_date > panel.date,
        struct(episode.episode_id, episode.sale_start_date),
        null
      )
      ignore nulls
      order by episode.sale_start_date, episode.episode_id
      limit 1
    )[safe_offset(0)] as next_start,

    array_agg(
      if(
        episode.episode_end_date <= panel.date,
        struct(episode.episode_id, episode.episode_end_date),
        null
      )
      ignore nulls
      order by episode.episode_end_date desc, episode.episode_id desc
      limit 1
    )[safe_offset(0)] as most_recent_end

  from panel
  left join discount_episodes as episode
    on episode.item_number_updated = panel.item_number_updated
    and episode.pack = panel.pack
    and episode.bottle_volume_ml = panel.bottle_volume_ml
  group by panel.panel_row_id
),

panel_with_timing as (
  select
    case
      when matches.current_episode.episode_id is not null then 1
      else 0
    end as in_discount_window,

    matches.current_episode.max_discount_dollars as discount_amount_abs,
    matches.current_episode.max_discount_percent as discount_amount_percent,
    matches.current_episode.episode_id as current_episode_id,
    matches.current_episode.length_of_discount_days
      as length_of_this_episode_days,
    matches.current_episode.sale_start_date as current_sale_start_date,
    matches.current_episode.episode_end_date as current_episode_end_date,

    matches.most_recent_start.episode_id as most_recent_episode_id,
    matches.next_start.episode_id as next_episode_id,

    date_diff(
      panel.date,
      matches.most_recent_start.sale_start_date,
      day
    ) as days_since_most_recent_discount_start,

    case
      when matches.current_episode.episode_id is not null
      then date_diff(
        matches.current_episode.episode_end_date,
        panel.date,
        day
      )
      else null
    end as days_until_discount_end,

    date_diff(
      panel.date,
      matches.most_recent_end.episode_end_date,
      day
    ) as days_since_most_recent_discount_end,

    date_diff(
      matches.next_start.sale_start_date,
      panel.date,
      day
    ) as days_until_next_discount_start,

    panel.*

  from panel
  left join discount_matches as matches
    using (panel_row_id)
),

-- Determine whether each episode is isolated from other discounts.
episode_isolation as (
  select
    episode.*,

    countif(
      other.sale_start_date < episode.sale_start_date
      and other.episode_end_date
        > date_sub(episode.sale_start_date, interval 30 day)
    ) = 0 as isolated_30day_pre_episode,

    countif(
      other.sale_start_date
        < date_add(episode.episode_end_date, interval 30 day)
      and other.episode_end_date > episode.episode_end_date
    ) = 0 as isolated_30day_post_episode

  from discount_episodes as episode
  left join discount_episodes as other
    on other.item_number_updated = episode.item_number_updated
    and other.pack = episode.pack
    and other.bottle_volume_ml = episode.bottle_volume_ml
  group by all
),

store_products as (
  select distinct
    store_number,
    store_name,
    item_number_updated,
    item_desc_updated,
    bottle_volume_ml,
    pack,
    vendor_name_updated,
    category_simple,
    min_date_observed,
    max_date_observed
  from panel
),

-- Combine discount isolation with store-product coverage requirements.
episode_checks as (
  select
    products.store_number,
    products.store_name,
    products.item_number_updated,
    products.item_desc_updated,
    products.bottle_volume_ml,
    products.pack,
    products.vendor_name_updated,
    products.category_simple,
    episode.*,

    case
      when products.min_date_observed
          <= date_sub(episode.sale_start_date, interval 30 day)
        and episode.isolated_30day_pre_episode
      then 1
      else 0
    end as clean_30day_pre_episode,

    case
      when products.max_date_observed
          >= date_add(episode.episode_end_date, interval 29 day)
        and episode.isolated_30day_post_episode
      then 1
      else 0
    end as clean_30day_post_episode

  from store_products as products
  inner join episode_isolation as episode
    using (item_number_updated, pack, bottle_volume_ml)
),

episodes_clean as (
  select
    *,
    case
      when clean_30day_pre_episode = 1
        and clean_30day_post_episode = 1
      then 1
      else 0
    end as clean_30day_episode
  from episode_checks
),

-- Assign each row to a current, 30-day pre-, or 30-day post-event window.
panel_with_event_id as (
  select
    case
      when current_episode_id is not null
        then current_episode_id
      when days_until_next_discount_start between 1 and 30
        then next_episode_id
      when days_since_most_recent_discount_end between 0 and 29
        then most_recent_episode_id
      else null
    end as event_episode_id,
    panel_with_timing.*
  from panel_with_timing
)

select
  main.event_episode_id,
  episode.sale_start_date as event_sale_start_date,
  episode.episode_end_date as event_episode_end_date,

  case
    when main.event_episode_id is not null
    then date_diff(main.date, episode.sale_start_date, day)
    else null
  end as event_day_relative_to_start,

  case
    when main.event_episode_id is not null
    then date_diff(main.date, episode.episode_end_date, day)
    else null
  end as event_day_relative_to_end,

  episode.clean_30day_pre_episode,
  episode.clean_30day_post_episode,
  episode.clean_30day_episode,
  episode.reference_price as event_reference_price,
  episode.min_price_during_episode as event_min_price_during_episode,
  episode.max_price_during_episode as event_max_price_during_episode,
  episode.avg_price_during_episode as event_avg_price_during_episode,
  episode.max_discount_dollars as event_max_discount_dollars,
  episode.min_discount_dollars as event_min_discount_dollars,
  episode.avg_discount_dollars as event_avg_discount_dollars,
  episode.max_discount_percent as event_max_discount_percent,
  episode.min_discount_percent as event_min_discount_percent,
  episode.avg_discount_percent as event_avg_discount_percent,
  main.* except (event_episode_id)

from panel_with_event_id as main
left join episodes_clean as episode
  on episode.episode_id = main.event_episode_id
  and episode.store_number = main.store_number
  and episode.store_name = main.store_name
  and episode.item_number_updated = main.item_number_updated
  and episode.item_desc_updated = main.item_desc_updated
  and episode.bottle_volume_ml = main.bottle_volume_ml
  and episode.pack = main.pack
  and episode.vendor_name_updated = main.vendor_name_updated
  and episode.category_simple = main.category_simple;
```

This query joins each panel row to the product's discount history and calculates distances to the nearest relevant discount starts and ends. It uses a single grouped join to identify the current episode, most recent start, next start, and most recent completed episode for every panel row.

The episode checks enforce the sample restrictions used in the event-study regressions. A clean pre-period requires 30 days of panel coverage before the sale and no overlapping discount in that window. A clean post-period also requires 30 days of coverage after the episode and no subsequent discount overlap. `clean_30day_episode` identifies episodes satisfying both conditions.

Finally, each observation within a discount or its 30-day pre/post windows receives an `event_episode_id`, relative-day measures, episode prices, and discount magnitudes. These variables allow the final panel to be filtered and used directly in fixed-effects event-study regressions.
