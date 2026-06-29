(ns basics.statistics
  (:require [tablecloth.api :as tc]))

(defn add-sales-amount
  [data]
  (tc/map-columns data
                  :sales_amount
                  [:quantity :unit_price]
                  (fn [quantity unit-price]
                    (* quantity unit-price))))

(defn show-over-500-price
  [data]
  (println
   (-> data
       (tc/select-rows #(> (:unit_price %) 500))
       (tc/head 10))))

(defn average
  [xs]
  (/ (reduce + xs) (count xs)))

(defn show-dataset-info
  [data]
  (println (tc/info data)))

(defn summarize-by-category
  [data]
  (-> data
      add-sales-amount
      (tc/group-by :category)
      (tc/aggregate {:total-sales #(reduce + (:sales_amount %))
                     :total-quantity #(reduce + (:quantity %))})))

(defn top-sales
  [data n]
  (-> data
      add-sales-amount
      (tc/order-by [:sales_amount] :desc)
      (tc/head n)))

(defn daily-sales
  [data]
  (->> (tc/rows (add-sales-amount data) :as-maps)
       (group-by :date)
       (map (fn [[date rows]]
              {:date date
               :actual-sales (reduce + (map :sales_amount rows))}))
       (sort-by :date)
       tc/dataset))

(defn forecast-next-days
  [data days window-size]
  (let [history (daily-sales data)
        last-date (last (sort (:date history)))
        recent-sales (take-last window-size (:actual-sales history))
        predicted-sales (double (average recent-sales))]
    (tc/dataset
     (for [offset (range 1 (inc days))]
       {:date (.plusDays last-date offset)
        :predicted-sales predicted-sales
        :model (str window-size "-day moving average")}))))

(defn backtest-moving-average
  [data test-days window-size]
  (let [history (vec (tc/rows (daily-sales data) :as-maps))
        start-index (- (count history) test-days)]
    (tc/dataset
     (for [index (range start-index (count history))
           :let [row (history index)
                 previous-rows (subvec history
                                       (max 0 (- index window-size))
                                       index)
                 predicted-sales (double
                                  (average
                                   (map :actual-sales previous-rows)))
                 error (- (:actual-sales row) predicted-sales)]]
       {:date (:date row)
        :actual-sales (:actual-sales row)
        :predicted-sales predicted-sales
        :error error
        :absolute-error (Math/abs (double error))}))))

(defn mean-absolute-error
  [backtest-result]
  (double (average (:absolute-error backtest-result))))

(defn show-basic-stats
  [data]
  (let [quantities (:quantity data)]
    (println "合計:" (reduce + quantities))
    (println "平均:" (double (average quantities)))
    (println "最小:" (apply min quantities))
    (println "最大:" (apply max quantities))
    (println "件数:" (count quantities))))

(defn pearson-correlation
  [xs ys]
  (let [x-avg (average xs)
        y-avg (average ys)
        x-diffs (map #(- % x-avg) xs)
        y-diffs (map #(- % y-avg) ys)
        numerator (reduce + (map * x-diffs y-diffs))
        x-sum-squares (reduce + (map #(* % %) x-diffs))
        y-sum-squares (reduce + (map #(* % %) y-diffs))]
    (/ numerator
       (Math/sqrt (* x-sum-squares y-sum-squares)))))