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
from final_panel