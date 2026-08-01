(ns statistics.mathematics.basics)

(defn average
  [all_data]
  (double
   (/ (reduce + 0 all_data) (count all_data))))

(defn square
  [x]
  (* x x))

(defn sum-of-squared-deviations
  "偏差平方和"
  [all-data mean]
  (reduce + 0
          (map #(square (- % mean))
               all-data)))

(defn unbiased_variance
  "不偏分散"
  [all_data number_of_data average_n]
  (/
   (sum-of-squared-deviations all_data average_n)
   (double (- number_of_data 1))))

(defn standard_deviation
  "標準偏差"
  [number_of_data all_data mean]
  (Math/sqrt (/ (sum-of-squared-deviations all_data mean) number_of_data)))

(defn normal-exponent [x mu sigma]
  (Math/exp
   (- (/ (Math/pow (- x mu) 2)
         (* 2.0 sigma sigma)))))

(defn normal-pdf "正規分布"
  [x mu sigma]
  (let [coefficient (/ 1.0
                       (* sigma
                          (Math/sqrt (* 2.0 Math/PI))))
        exponent    (- (/ (Math/pow (- x mu) 2)
                          (* 2.0 sigma sigma)))]
    (* coefficient
       (Math/exp exponent))))