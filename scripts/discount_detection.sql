create or replace table `iowa-liquor-sales-498314.ild.temp_price_red_ep` as

with a as (
  --select relevant rows
  select
    item_number_updated,
    date,
    bottle_volume_ml,
    pack,
    any_value(item_desc_updated) as item_desc_updated,
    any_value(category_simple) as category_simple,
    any_value(state_bottle_cost) as state_bottle_cost,
    any_value(state_bottle_retail_upd) as state_bottle_retail_upd
  from `ild.simp_map_error_rem`
  group by item_number_updated, bottle_volume_ml, pack, date
),

b as (
  -- capture the next observed price
  select
    a.*,
    lead(a.state_bottle_retail_upd, 1) over (
      partition by item_number_updated, bottle_volume_ml, pack
      order by date asc
    ) as next_observed_price
  from a
),

c as (
  --capture candidate_price_drop_start and reference_price_candidate
  --candidate_price_drop_start is an indicator variable that take 1 everytime next price < current
  --reference_price_candidate takes the price of the item right before it drops
  select
    b.*,
    case
      when next_observed_price < state_bottle_retail_upd then 1
      else 0
    end as candidate_price_drop_start,
    case
      when next_observed_price < state_bottle_retail_upd then b.state_bottle_retail_upd
      else null
    end as reference_price_candidate
  from b
),

d as (
  --find min future date where an item-pack-bottle_size unit goes back up to
  --(or above) the price before sale.
  select
    min(future.date) as candidate_recovery,
    c.*
  from c
  left join a as future
    on c.item_number_updated = future.item_number_updated
    and c.bottle_volume_ml = future.bottle_volume_ml
    and c.pack = future.pack
    and future.date > c.date
    and future.state_bottle_retail_upd >= c.reference_price_candidate
  where candidate_price_drop_start = 1
  group by all
),

e as (
  -- here we are just merging all candidate price drop start dates which occur before
  --a given price drop start, and the earlier episode has not yet recovered when the
  --current candidate_pride_drop started
  --we then also count the number of earlier price drop episodes a price drop start
  --is contained within for a given item-bottle-pack
  select
    cur.*,
    count(earlier.date) as n_earlier_containing_episodes
  from d as cur
  left join d as earlier
    on cur.item_number_updated = earlier.item_number_updated
    and cur.bottle_volume_ml = earlier.bottle_volume_ml
    and cur.pack = earlier.pack
    and earlier.date < cur.date
    and cur.date < earlier.candidate_recovery
  group by all
),

f as (
  select
    e.*,
    case
      when e.n_earlier_containing_episodes = 0 and candidate_recovery is not null then 1
      else 0
    end as true_price_drop_episode_start
  from e
),

g as (
  --create an epsiode id that counts the # of discounts per item-bottle-pack
  select
    sum(f.true_price_drop_episode_start) over (
      partition by item_number_updated, bottle_volume_ml, pack
      order by date
      rows between unbounded preceding and current row
    ) as episode_id,
    f.item_number_updated,
    f.date as pre_drop_date,
    f.candidate_recovery as episode_end_date,
    f.bottle_volume_ml,
    f.pack,
    f.reference_price_candidate as reference_price,
    f.item_desc_updated,
    f.category_simple
  from f
  where f.true_price_drop_episode_start = 1
),

h as (
  select
    g.item_number_updated,
    g.item_desc_updated,
    g.pre_drop_date,
    min(a.date) as sale_start_date,
    g.episode_end_date,
    date_diff(g.episode_end_date, min(a.date), day) as length_of_discount_days,
    g.category_simple,
    g.bottle_volume_ml,
    g.pack,
    g.episode_id,
    g.reference_price,
    min(a.state_bottle_retail_upd) as min_price_during_episode,
    max(a.state_bottle_retail_upd) as max_price_during_episode,
    avg(a.state_bottle_retail_upd) as avg_price_during_episode,
    max(g.reference_price - a.state_bottle_retail_upd) as max_discount_dollars,
    min(g.reference_price - a.state_bottle_retail_upd) as min_discount_dollars,
    avg(g.reference_price - a.state_bottle_retail_upd) as avg_discount_dollars,
    max(100 * (g.reference_price - a.state_bottle_retail_upd) / g.reference_price) as max_discount_percent,
    min(100 * (g.reference_price - a.state_bottle_retail_upd) / g.reference_price) as min_discount_percent,
    avg(100 * (g.reference_price - a.state_bottle_retail_upd) / g.reference_price) as avg_discount_percent
  from g
  join a
    on g.item_number_updated = a.item_number_updated
    and g.bottle_volume_ml = a.bottle_volume_ml
    and g.pack = a.pack
    and a.date > g.pre_drop_date
    and a.date < g.episode_end_date
  group by
    item_number_updated,
    bottle_volume_ml,
    pack,
    episode_id,
    pre_drop_date,
    episode_end_date,
    reference_price,
    item_desc_updated,
    category_simple
)

select h.*
from h
order by item_number_updated, sale_start_date