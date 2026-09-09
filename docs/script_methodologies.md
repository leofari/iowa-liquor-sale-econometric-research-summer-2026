# Scripts and Methodology

Here are detailed descriptions of the scripts and methodologies used to complete the panel construction, discount detection, and data cleaning for the project.

### Discounts

[Identifying Temporary Price Reductions](../script_methodologies/temp_price_red.md)

This SQL script identifies all instances of product level temporary price discounts across the [Iowa Liquor Sales](https://data.iowa.gov/catalog/dataset/1051) dataset. In addition to recording size and date variables for each discount, it also distinguishes between temporary price discounts, and other changes in price.

### Panel Construction

[Constructing Daily Product Sales Panel](../script_methodologies/daily_sales_panel.md)

This SQL script aggregates the 34 million [Iowa Liquor Sales](https://data.iowa.gov/catalog/dataset/1051) observations into a panel of statewide sales per product per day. In addition to total daily sales and bottles sold per product, this panel also includes variables to capture the current price, a discount indicator, and characteristics of the current discount (if applicable)

This panel was primarily used for seasonal analysis and event-study visualizations.

[Constructing Store x Product x Date Panel](../script_methodologies/constructing_store_product_date_panel.md)

The second panel records purchases for each store, product, and date. It also includes zero rows for dates where stores purchased zero units of a product, allowing for time series and regression analysis. The panel also includes the size of each store, discount and product characteristics, and an indicator variable for discounts.

This panel was used for the fixed-effects regression analysis.

### Cleaning

[Simplifying Alcohol Categories](../script_methodologies/simplifying_alcohol_categories.md)

The source variable `category_name` contained 104 detailed categories. In addition to being overly granular, many of these categories (such as `IMPORTED DISTILLED SPIRITS SPECIALTY`) grouped multiple unlike alcohol types (eg. Tequila and Rum) into one homogenous category.

-   Grouped 15,633 products into 10 mutually exclusive liquor categories for analysis

-   Recovered missing category tags by matching transactions to prior transactions with the same item number

-   Collapsed categories grouping unlike alcohol types with manual and AI-assisted classification
