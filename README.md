# data-analitics-clj

Clojureでデータ分析を学習するためのリポジトリです。

## 必要なツール

ローカル品質チェックでは、GitHub Actionsと同じツールを使用します。

| ツール | CIのバージョン | 用途 |
| --- | --- | --- |
| Java | 25 | Clojureの実行 |
| Clojure CLI | 1.12.3.1577 | 依存関係の解決、テスト、namespaceの読み込み |
| clj-kondo | 2026.07.24 | Clojureコードと`deps.edn`のlint |
| cljfmt | 0.16.4 | Clojureコードのformat検査 |
| actionlint | 1.7.12 | GitHub Actions Workflowのlint |
| zizmor | 1.28.0 | GitHub Actions Workflowのセキュリティ検査 |
| Make | OS付属バージョン | 品質チェックの一括実行 |

ツールは各配布元の手順でインストールし、CIのバージョンに合わせてください。Makefileからパッケージマネージャーやインストーラーは実行しません。

インストール後、必要なコマンドが利用できることを確認します。

```bash
make doctor
```

利用中のバージョンを確認する場合は、次のコマンドを実行します。

```bash
make versions
```

## 品質チェック

GitHub Actionsと同等の品質チェックをまとめて実行します。

```bash
make check
```

用途別に実行する場合は、次のターゲットを使用します。

| コマンド | 実行内容 |
| --- | --- |
| `make check-workflows` | `actionlint`と`zizmor`を実行 |
| `make check-clojure` | 依存関係、lint、format、テスト、namespace読み込みを検査 |
| `make lint` | `clj-kondo`を実行 |
| `make format-check` | `cljfmt`でformatを検査 |
| `make test` | 単体テストを実行 |
| `make smoke` | アプリケーションのnamespaceを読み込み |

formatを修正する場合は、次のコマンドを実行します。このコマンドは対象ファイルを変更します。

```bash
make format
```

## アプリケーションの実行

メインのnamespaceを実行します。

```bash
clojure -M -m core
```

統計学習用のnamespaceを実行します。

```bash
clojure -M -m statistics.core
```
