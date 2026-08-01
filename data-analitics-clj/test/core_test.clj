(ns core-test
  (:require [clojure.test :refer [deftest is testing]]
            [core :as sut]
            [tablecloth.api :as tc]))

(deftest average-test
  (testing "整数列の平均をRatioとして返す"
    (is (= 5/2 (sut/average [1 2 3 4])))))

(deftest add-sales-amount-test
  (testing "数量と単価から売上金額を追加する"
    (let [dataset (tc/dataset [{:quantity 2 :unit_price 10}
                               {:quantity 3 :unit_price 20}])
          result (sut/add-sales-amount dataset)]
      (is (= [20 60] (vec (:sales_amount result)))))))

(deftest pearson-correlation-test
  (testing "完全な正の相関を1として返す"
    (is (< (Math/abs
            (- 1.0
               (double
                (sut/pearson-correlation [1 2 3] [2 4 6]))))
           1.0e-12))))
