(ns plot
  (:require [scicloj.clay.v2.api :as clay]
            [scicloj.kindly.v4.kind :as kind]
            [tablecloth.api :as tc]))

(def sales
  (-> "data/sample.csv"
      tc/dataset
      (tc/rename-columns keyword)
      (tc/map-columns :sales_amount
                      [:quantity :unit_price]
                      (fn [quantity unit-price]
                        (* quantity unit-price)))))

(def category-summary
  (-> sales
      (tc/group-by :category)
      (tc/aggregate {:total-sales #(reduce + (:sales_amount %))
                     :total-quantity #(reduce + (:quantity %))})
      (tc/rename-columns {:$group-name :category})
      (tc/order-by [:total-sales] :desc)))

(def sales-by-category-chart
  (kind/vega-lite
   {:data {:values (mapv #(update-keys % name)
                         (tc/rows category-summary :as-maps))}
    :mark {:type "bar" :tooltip true}
    :encoding {:x {:field "category"
                   :type "nominal"
                   :sort "-y"
                   :title "Category"}
               :y {:field "total-sales"
                   :type "quantitative"
                   :title "Total sales"}
               :color {:field "category"
                       :type "nominal"
                       :legend nil}}
    :width 520
    :height 320
    :title "Sales by category"}))

(defn -main
  [& _args]
  (println "Rendering docs/.clay.html with Clay...")
  (clay/make! {:single-value sales-by-category-chart
               :base-target-path "docs"
               :show false
               :browse false}))
