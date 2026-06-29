(ns core
  (:require [basics.statistics :as sts]
            [sales-forecast-practice.forecast-plot :as fp]
            [tablecloth.api :as tc]))

(def data
  (-> "data/sample.csv"
      tc/dataset
      (tc/rename-columns keyword)))

(defn load_statistics 
  [data]
  (println "=== unit_price > 500 ===")
  (sts/show-over-500-price data)
  (println)
  (println "=== dataset info ===")
  (sts/show-dataset-info data)
  (println)
  (println "=== quantity stats ===")
  (sts/show-basic-stats data)
  (println)
  (println "=== data with sales_amount ===")
  (println (tc/head (sts/add-sales-amount data) 10))
  (println)
  (println "=== category summary ===")
  (println (sts/summarize-by-category data))
  (println
   "quantity と unit_price の相関:"
   (double
    (sts/pearson-correlation
     (:quantity data)
     (:unit_price data))))
  (println)
  (println "=== top 5 sales ===")
  (println (sts/top-sales data 5))
  (println)
  (println "=== daily sales ===")
  (println (tc/head (sts/daily-sales data) 10))
  (println)
  (println "=== moving average backtest ===")
  (let [backtest-result (sts/backtest-moving-average data 7 7)]
    (println backtest-result)
    (println "MAE:" (fp/mean-absolute-error backtest-result)))
  (println)
  (println "=== next 7 days sales forecast ===")
  (println (sts/forecast-next-days data 7 7)))

(defn -main [& args]
  (if (= (first args) "basic")
    (load_statistics data)
    "")
  (println "=== データ全件出力 ===")
  (fp/put_all_data fp/all_data)
  (println "=== 商品別売上個数合計 ===")
  (fp/put_product_summary fp/sales_forecast_practice)
  (println "=== 曜日別の平均販売数量 ===")
  (println fp/average_sales_volume_by_day_of_the_week ))
