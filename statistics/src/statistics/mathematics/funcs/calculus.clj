(ns statistics.mathematics.funcs.calculus)

(defn constant-derivative
  "定数関数 f(x) = c の導関数 f'(x) = 0 を返す。"
  [_constant]
  (constantly 0))

(defn identity-derivative
  "一次関数 f(x) = x の導関数 f'(x) = 1 を返す。"
  []
  (constantly 1))

(defn monomial-derivative
  "単項式 f(x) = a*x^n の導関数 f'(x) = a*n*x^(n-1) を返す。"
  [coefficient exponent]
  (if (zero? exponent)
    (constant-derivative coefficient)
    (fn [x]
      (* coefficient exponent (Math/pow x (dec exponent))))))

(defn add-derivatives
  "和の公式 (f + g)' = f' + g' を適用する。"
  [f-derivative g-derivative]
  (fn [x]
    (+ (f-derivative x) (g-derivative x))))

(comment
  ;; f(x) = 3x^2 + 4x - 5 の導関数 f'(x) = 6x + 4
  (def f-prime
    (add-derivatives
     (add-derivatives
      (monomial-derivative 3 2)
      (monomial-derivative 4 1))
     (constant-derivative -5)))

  (f-prime 2) ;=> 16.0
  )
