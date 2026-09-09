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