(ns sales-forecast-practice.forecast-plot
  (:require [scicloj.clay.v2.api :as clay] 
            [scicloj.kindly.v4.kind :as kind] 
            [tablecloth.api :as tc]))

(defn load-sales-data
  [path]
  (-> path
      tc/dataset
      (tc/rename-columns keyword)))

(def all_data
  (load-sales-data "data/sales_forecast_practice.csv"))

(defn put_all_data
  [all_data ]
  (println all_data))

(def sales_forecast_practice
  (-> (load-sales-data "data/sales_forecast_practice.csv")
      (tc/group-by :product_name)
      (tc/aggregate {:total-sales #(reduce + (:sales_amount %))
                     :total-quantity #(reduce + (:quantity_sold %))})
      (tc/order-by [:total-quantity] :desc)))

(def product_summary
  (tc/rename-columns sales_forecast_practice {:$group-name :product-name}))

(defn put_product_summary
  [product_summary]
  (println product_summary))

(defn mean-absolute-error
  [backtest-result]
  (let [errors (:absolute-error backtest-result)]
    (double (/ (reduce + errors) (count errors)))))

(defn weekday-order [weekday]
  (case weekday
    "Mon" 1
    "Tue" 2
    "Wed" 3
    "Thu" 4
    "Fri" 5
    "Sat" 6
    "Sun" 7))

(defn average [xs]
  (/ (reduce + xs) (count xs)))

(def average_sales_volume_by_day_of_the_week
  (-> all_data
      (tc/group-by :weekday)
      (tc/aggregate {:avg-quantity #(double (average (:quantity_sold %)))
                     :total-quantity #(reduce + (:quantity_sold %))})
      (tc/map-columns :weekday-order [:$group-name] weekday-order)
      (tc/order-by [:weekday-order])))

(def weekday_summary
  (tc/rename-columns average_sales_volume_by_day_of_the_week {:$group-name :weekday}))

(def product_quantity_bar_chart
  (kind/vega-lite
   {:$schema "https://vega.github.io/schema/vega-lite/v5.json"
    :description "商品別の合計販売数量"
    :data {:values (mapv #(update-keys % name)
                          (tc/rows product_summary :as-maps))}
    :mark {:type "bar" :tooltip true}
    :encoding {:x {:field "product-name"
                   :type "nominal"
                   :sort "-y"
                   :title "商品"}
               :y {:field "total-quantity"
                   :type "quantitative"
                   :title "合計販売数量"}
               :tooltip [{:field "product-name" :type "nominal" :title "商品"}
                         {:field "total-quantity" :type "quantitative" :title "合計販売数量"}
                         {:field "total-sales" :type "quantitative" :title "合計売上"}]}
    :width 520
    :height 320
    :title "商品別の合計販売数量"}))

(def weekday_avg_quantity_bar_chart
  (kind/vega-lite
   {:$schema "https://vega.github.io/schema/vega-lite/v5.json"
    :description "曜日別の平均販売数量"
    :data {:values (mapv #(update-keys % name)
                          (tc/rows weekday_summary :as-maps))}
    :mark {:type "bar" :tooltip true}
    :encoding {:x {:field "weekday"
                   :type "ordinal"
                   :sort ["Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"]
                   :title "曜日"}
               :y {:field "avg-quantity"
                   :type "quantitative"
                   :title "平均販売数量"}
               :tooltip [{:field "weekday" :type "ordinal" :title "曜日"}
                         {:field "avg-quantity" :type "quantitative" :title "平均販売数量"}
                         {:field "total-quantity" :type "quantitative" :title "合計販売数量"}]}
    :width 520
    :height 320
    :title "曜日別の平均販売数量"}))



(def quantity-sold-histogram
  (kind/vega-lite
   {:data {:values (mapv #(update-keys % name)
                         (tc/rows all_data :as-maps))}
    :mark {:type "bar" :tooltip true}
    :encoding {:x {:field "quantity_sold"
                   :type "quantitative"
                   :bin true
                   :title "販売数量"}
               :y {:aggregate "count"
                   :type "quantitative"
                   :title "件数"}}
    :width 520
    :height 320
    :title "販売数量のヒストグラム"}))

(def sales-amount-histogram
  (kind/vega-lite
   {:data {:values (mapv #(update-keys % name)
                         (tc/rows all_data :as-maps))}
    :mark {:type "bar" :tooltip true}
    :encoding {:x {:field "sales_amount"
                   :type "quantitative"
                   :bin true
                   :title "売上金額"}
               :y {:aggregate "count"
                   :type "quantitative"
                   :title "件数"}}
    :width 520
    :height 320
    :title "売上金額のヒストグラム"}))

(defn plot_diagram
  [data output_path]
  (clay/make! {:single-value data
               :base-target-path output_path
               :show false
               :browse false}))

(defn -main
  [& args]
  (println "=== 商品別の合計販売数量の ===")
  (plot_diagram product_quantity_bar_chart "docs/product_quantity_bar_chart.html")
  (plot_diagram weekday_avg_quantity_bar_chart "docs/weekday_avg_quantity_bar_chart.html")
  (plot_diagram quantity-sold-histogram "docs/quantity-sold-histogram.html")
  (plot_diagram sales-amount-histogram"docs/sales-amount-histogram.html"))
