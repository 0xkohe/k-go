# K-Go Compatibility Test Suite

自動化されたテストスイートで、全てのテストファイルを実行し結果をレポートします。

## 概要

このテストスクリプトは、`src/go/codes/` ディレクトリ内のすべてのGoテストファイルを自動的に実行し、互換性と正常性を検証します。

- **テストファイル総数**: 56個
- **正常実行テスト**: 54個
- **期待されるエラーテスト**: 2個（ファイル名に `error` を含むテスト）

**エラーテストの判定**: ファイル名に "error" が含まれるテストは、自動的にエラーが発生することを期待するテストとして扱われます。

## 使用方法

### 基本実行

```bash
# すべてのテストを実行
./test-all.sh

# 再コンパイルなしで実行（開発中に便利）
./test-all.sh --no-compile

# 詳細な出力を表示
./test-all.sh --verbose
```

### パターンマッチング

特定のテストのみを実行:

```bash
# チャネル関連のテストのみ
./test-all.sh --pattern "channel"

# 特定のプレフィックスで始まるテスト
./test-all.sh --pattern "^code-const"

# 複数値受信のテスト
./test-all.sh --pattern "recv-ok"
```

### オプション

| オプション | 短縮形 | 説明 |
|-----------|--------|------|
| `--verbose` | `-v` | テスト出力を詳細に表示 |
| `--no-compile` | `-n` | main.k の再コンパイルをスキップ |
| `--pattern PATTERN` | `-p` | 指定パターンに一致するテストのみ実行 |
| `--timeout SECONDS` | `-t` | テストごとのタイムアウト（デフォルト: 30秒） |
| `--help` | `-h` | ヘルプメッセージを表示 |

### 使用例

```bash
# 開発ワークフロー: 再コンパイルなしで特定のテストを実行
./test-all.sh --no-compile --pattern "channel" --verbose

# CI/CD: すべてのテストを実行
./test-all.sh

# デバッグ: タイムアウトを延長して詳細出力
./test-all.sh --timeout 60 --verbose --pattern "goroutine"
```

## 出力の見方

### テスト結果の表示

```
[PASS] code-simple-call (2s)           # 正常に実行完了
[FAIL] code-channel-basic (1.2s)       # 実行失敗
[TIMEOUT] code-slow-test (>30s)        # タイムアウト
[EXPECTED_ERROR] code-const-error (0.4s)  # 期待されるエラー（正常）
[ERROR_TEST_FAILED] code-xxx (0.5s)    # エラーが期待されるのに成功した
```

### サマリーレポート

```
============================================
   Test Results Summary
============================================

Total tests run:        56

Normal tests:           54
  Passed:               53/54
  Failed:               1/54

Expected error tests:   2
  Passed:               1/2
  Failed:               1/2

Success rate:           98.1%
Total duration:         119s

Failed tests:
  ✗ code-close-test
    [Error] Parse error: ...
```

## ログファイル

テスト実行ごとに詳細ログが保存されます:

```
test-logs/test-run-YYYYMMDD_HHMMSS.log
```

ログファイルには以下が含まれます:
- 各テストの標準出力
- エラーメッセージ
- 実行時間
- テストごとの詳細情報

## テストカテゴリ

### 基本機能
- `code-simple-call` - 基本的な関数呼び出し
- `code-bool-ops` - ブール演算
- `code-var-zero` - 変数のゼロ値初期化

### 関数とクロージャ
- `code-func-int-arg` - 関数引数
- `code-multi-return` - 多値返却
- `code-closure-simple` - クロージャ
- `code-first-class-basic` - 第一級関数

### 制御フロー
- `code-for-test` - forループ
- `code-if-no-simplestmt` - if文
- `code-range-basic` - rangeループ（Go 1.22+）

### 定数と変数
- `code-const-basic` - 定数宣言
- `code-const-typed` - 型付き定数
- `code-const-scope` - 定数のスコープ

### チャネルと並行性
- `code-channel-basic` - 基本的なチャネル操作
- `code-buffered-fifo` - バッファ付きチャネル
- `code-goroutine-simple` - ゴルーチン
- `code-close-ok` - チャネルのclose
- `code-recv-ok-*` - 多値受信操作（`v, ok := <-ch`）

### エラーテスト（ファイル名に "error" を含む）
- `code-const-error` - 定数への代入エラー（✅ 正しくエラーになる）
- `code-short-decl-error` - 短変数宣言の再宣言エラー（✅ 正しくエラーになる）

**現在のステータス**: 全エラーテストが正常に動作 (2/2, 100% ✅)

**注意**: ファイル名に "error" が含まれるテストは、自動的にエラーテストとして扱われます。新しいエラーテストを追加する場合は、ファイル名に "error" を含めてください（例: `code-xxx-error`）。

## トラブルシューティング

### Docker コンテナが起動していない

```bash
# コンテナを起動
docker compose up -d

# テストを実行
./test-all.sh
```

### コンパイルエラー

```bash
# 手動でコンパイルを確認
docker compose exec k bash -c "cd go && kompile main.k"

# エラーを修正後、テスト実行
./test-all.sh
```

### タイムアウトが発生する

```bash
# タイムアウトを延長
./test-all.sh --timeout 60
```

### 特定のテストがフリーズする

```bash
# デバッガで実行
docker compose exec k bash -c "cd go && krun codes/code-xxx --debugger"
```

## CI/CD 統合

### GitHub Actions の例

```yaml
name: K-Go Test Suite

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Start Docker containers
        run: docker compose up -d

      - name: Run test suite
        run: ./test-all.sh

      - name: Upload test logs
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: test-logs
          path: test-logs/
```

## 最新のテスト結果

最後の全体実行（2025-10-30 13:27）:

```
Total tests run:        56
Normal tests:           53/54 passed (98.1%)
Expected error tests:   2/2 passed (100% ✅)
Failed:                 1/54 (code-close-test のみ - パースエラー)
Duration:               117s
```

**改善点**:
- ✅ `code-short-decl-error` のバグを修正
- ✅ エラーテストが100%成功するようになった

### 既知の問題

1. **code-close-test**: パースエラー（既存の問題、優先度：低）
   - 複数のチャネル送信文の連続でパースエラーが発生
   - K Framework のパーサー側の問題の可能性

### 修正済みの問題

1. ~~**code-short-decl-error**: エラーテストが誤って成功していた~~ ✅ **修正完了**
   - **修正内容**: 型ごとの明示的なエラールールを追加し、優先度を高く設定
   - **修正日**: 2025-10-30
   - **詳細**: エラールールが汎用的な変数を使用していたため、具体的な型パターンを持つ正常なルールが優先されていた。各型（Int, Bool, FuncVal, ChanVal）ごとにエラールールを追加し、`[priority(10)]` を設定することで解決。

## 開発ワークフロー

### 新機能を実装した後

```bash
# 1. main.k を修正
vim src/go/semantics/concurrent.k

# 2. コンパイル
docker compose exec k bash -c "cd go && kompile main.k"

# 3. 関連テストを実行
./test-all.sh --pattern "recv-ok" --no-compile

# 4. すべてのテストで互換性を確認
./test-all.sh --no-compile
```

### 新しいテストケースを追加

```bash
# 1. テストファイルを作成
echo 'package main
func main() {
    // テストコード
}' > src/go/codes/code-new-feature

# 2. テストを実行
./test-all.sh --pattern "new-feature" --no-compile

# 3. 期待される結果を確認
cat test-logs/test-run-*.log
```

## テストの追加

### 通常のテストを追加

```bash
# 1. テストファイルを作成
echo 'package main
func main() {
    // テストコード
}' > src/go/codes/code-new-feature

# 2. テストを実行
./test-all.sh --pattern "new-feature" --no-compile
```

### エラーテストを追加

エラーが発生することを期待するテストは、**ファイル名に "error" を含める**だけで自動的に認識されます：

```bash
# ファイル名に "error" を含めるだけ
echo 'package main
func main() {
    const x = 10;
    x = 20;  // エラーになるべき
}' > src/go/codes/code-my-new-error

# 自動的にエラーテストとして扱われる
./test-all.sh --pattern "my-new-error" --no-compile
```

**命名規則**: `code-<feature>-error` の形式を推奨（例: `code-nil-pointer-error`, `code-type-mismatch-error`）

## 参考資料

- [K Framework Documentation](../K_framework_documentation.md)
- [CLAUDE.md](../CLAUDE.md) - プロジェクト概要と開発ガイド
- [多値受信実装](./023_multi-value-receive-implementation.md)
- [strict vs context 設計判断](./024_strict-vs-context-design-decision.md)
