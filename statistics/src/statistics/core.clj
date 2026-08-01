(ns statistics.core
  (:require [statistics.mathematics.basics :as basic]))

(defn factorial
  "nの階乗"
  [n]
  (cond
    (not (integer? n))
    {:ok false
     :error "n must be an integer"
     :data {:n n}}

    (neg? n)
    {:ok false
     :error "n must be non-negative"
     :data {:n n}}

    :else
    {:ok true
     :value (reduce * (range 1 (inc n)))}))


(defn permutation
  "順列"
  [n r]
  (cond
    (not (and (integer? n) (integer? r)))
    {:ok false
     :error "n and r must be integers"
     :data {:n n :r r}}

    (or (neg? n) (neg? r))
    {:ok false
     :error "n and r must be non-negative"
     :data {:n n :r r}}

    (> r n)
    {:ok false
     :error "r must be less than or equal to n"
     :data {:n n :r r}}

    (zero? r)
    {:ok true
     :value 1}

    :else
    (let [n-factorial (:value (factorial n))
          n-r-factorial (:value (factorial (- n r)))]
      {:ok true
       :value (/ n-factorial n-r-factorial)})))

(defn combination
  "組み合わせ"
  [n r]
  (cond
    (not (and (integer? n) (integer? r)))
    {:ok false
     :error "n and r must be integers"
     :data {:n n :r r}}
    
    (or (neg? n) (neg? r))
    {:ok false
     :error "n and r must be non-negative"
     :data {:n n :r r}}
    
    (zero? r)
    {:ok true
     :value 1}
    
    (= n r)
    {:ok true
     :value 1}
    
    :else
    (let [n-factorial (:value (factorial n))
          n-r-factorial (:value (factorial (- n r)))
          r-factorial (:value (factorial r))]
      {:ok true
       :value (/ n-factorial (* n-r-factorial r-factorial))})))

(def sample_list '(1 2 3 4 5 6 7 8 9 10 11 12 13 14))

(defn -main [& args]
  (println (basic/average sample_list))
  (println (basic/unbiased_variance 
            sample_list
            (count sample_list)
            (basic/average sample_list))))
