# 短変数宣言の再宣言エラー検出バグの修正

## 概要

`code-short-decl-error` テストが失敗していた問題を修正しました。このテストは、同じスコープで既に宣言された変数を短変数宣言（`:=`）で再宣言しようとした際にエラーを検出するためのものです。

**修正日**: 2025-10-30

## 問題の詳細

### 期待される動作

以下のGoコードはエラーになるべきです：

```go
func main() {
  var x int;    // x を宣言
  x := x + 1;   // エラー: x は既に宣言されている
}
```

Go言語の仕様では、短変数宣言（`:=`）は「少なくとも1つの新しい変数」を宣言する必要があります。上記のコードでは、左辺の `x` は既に宣言されているため、以下のエラーになるべきです：

```
no new variables on left side of :=
```

### 実際の動作（修正前）

K-Goの実装では、このコードが**エラーにならずに正常に実行されていました**。これは、エラー検出ルールが正しく機能していなかったためです。

### テスト結果（修正前）

```
[ERROR_TEST_FAILED] code-short-decl-error (3s) - Should have failed but passed
```

## 原因の分析

### 実装の構造

K-Goでは、短変数宣言のエラーチェックを以下のルールで行っていました：

```k
// 修正前のエラールール
rule <k> X:Id := V => shortDeclError ... </k>
     <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
  requires X in_keys(ScopeMap) andBool isKResult(V)
```

そして、正常な短変数宣言のルールは以下の通り：

```k
// 正常な宣言ルール（Int の場合）
rule <k> X:Id := I:Int => .K ... </k>
     <tenv> R => R [ X <- int ] </tenv>
     <env> Env => Env [ X <- L ] </env>
     <store> Store => Store [ L <- I ] </store>
     <nextLoc> L:Int => L +Int 1 </nextLoc>
     <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>
  requires notBool (X in_keys(ScopeMap))
```

### 問題点

1. **パターンマッチの具体性**: エラールールは汎用的な `V` 変数を使用していましたが、正常なルールは具体的な型（`Int`, `Bool`, `FuncVal`）を指定していました。

2. **K Framework の動作**: K Framework では、より具体的なパターンが優先される傾向があります。つまり、`X:Id := I:Int` というパターンは `X:Id := V` よりも具体的なので、先にマッチする可能性があります。

3. **優先度の欠如**: エラールールに優先度が指定されていなかったため、正常なルールとの実行順序が不定でした。

### なぜエラーが検出されなかったのか

実行の流れ：

```
1. var x int         → scopeDecls に x が登録される
2. x := x + 1        → 右辺を評価
3. x := 1            → この状態でルールをマッチング
4. 正常なルール X:Id := I:Int がマッチ判定
5. requires notBool (X in_keys(ScopeMap)) → false なのでマッチしない
6. エラールール X:Id := V がマッチ判定されるべき
7. しかし、何らかの理由でエラールールが適用されない
```

推測される原因：
- エラールールの `V` が具体的な型 `Int` とマッチしない
- または、優先度の問題で別のルールが先に試される

## 解決策

### 修正内容

各型ごとに明示的なエラールールを追加し、高い優先度を設定しました。

#### core.k での修正

```k
syntax KItem ::= "shortDeclError"

// Error rules for short declaration of already declared variable
// These have higher priority to be checked before normal declaration rules

rule <k> X:Id := _I:Int => shortDeclError ... </k>
     <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
  requires X in_keys(ScopeMap)
  [priority(10)]

rule <k> X:Id := _B:Bool => shortDeclError ... </k>
     <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
  requires X in_keys(ScopeMap)
  [priority(10)]

rule <k> X:Id := _FV:FuncVal => shortDeclError ... </k>
     <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
  requires X in_keys(ScopeMap)
  [priority(10)]
```

#### concurrent.k での修正

チャネル値に対しても同様のエラールールを追加：

```k
// Error rule: check for redeclaration first (higher priority)
rule <k> X:Id := _CV:ChanVal => shortDeclError ... </k>
     <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
  requires X in_keys(ScopeMap)
  [priority(10)]
```

### 修正のポイント

1. **具体的な型パターン**: `Int`, `Bool`, `FuncVal`, `ChanVal` ごとにエラールールを定義

2. **高い優先度**: `[priority(10)]` を設定（デフォルトは50なので、これにより先に評価される）

3. **変数名のプレフィックス**: `_I`, `_B`, `_FV`, `_CV` のように `_` をつけることで、「使用しない変数」であることを明示

## 修正結果

### テスト実行結果（修正後）

```bash
./test-all.sh --pattern "error"
```

```
Expected error tests:   2
  Passed:               2/2  ✅
  Failed:               0/2

All tests passed!
```

### 詳細

**code-const-error**: ✅ EXPECTED_ERROR（修正前から正常）
- 定数への代入エラーを正しく検出

**code-short-decl-error**: ✅ EXPECTED_ERROR（修正により正常化）
- 短変数宣言の再宣言エラーを正しく検出

### 全体のテスト結果

```
Total tests run:        56
Normal tests:           53/54 passed (98.1%)
Expected error tests:   2/2 passed (100% ✅)
Failed:                 1/54 (code-close-test のみ - 既存の問題)
Duration:               117秒
```

## 技術的な教訓

### 1. K Framework のパターンマッチング

K Framework では、ルールのマッチングに以下の特性があります：

- **具体性**: より具体的なパターン（`Int`）は汎用的なパターン（`V`）よりも優先される可能性がある
- **優先度**: `[priority(N)]` 属性で明示的に優先順位を制御できる（数字が小さいほど優先）
- **曖昧性**: 同じ優先度の複数のルールがマッチする場合、順序は不定

### 2. エラーチェックのベストプラクティス

エラー検出ルールは以下のように実装すべきです：

```k
// ❌ 悪い例：汎用的すぎる
rule <k> X:Id := V => shortDeclError ... </k>
  requires X in_keys(ScopeMap) andBool isKResult(V)

// ✅ 良い例：具体的な型ごとに定義、優先度を明示
rule <k> X:Id := _I:Int => shortDeclError ... </k>
  requires X in_keys(ScopeMap)
  [priority(10)]
```

### 3. 優先度の重要性

K Framework での優先度：
- **priority(10)**: 非常に高い優先度（エラーチェックなど）
- **priority(20)**: 高い優先度（変数のルックアップなど）
- **priority(50)**: デフォルト（通常のルール）
- **priority(60)**: 低い優先度（フォールバックルール）

エラーチェックは**優先度10**で、正常なルール（優先度50）より先に実行されるようにします。

### 4. scopeDecls の仕組み

K-Goの `scopeDecls` は、スコープごとの変数宣言を追跡します：

```k
<scopeDecls> SD ListItem(ScopeMap) </scopeDecls>
```

- `ListItem(ScopeMap)` が現在のスコープ
- `ScopeMap` は `Map`（変数名 → true）
- `X in_keys(ScopeMap)` で変数が既に宣言されているかをチェック

## 影響範囲

### 修正したファイル

1. **src/go/semantics/core.k**:
   - Int, Bool, FuncVal の短変数宣言エラールールを追加

2. **src/go/semantics/concurrent.k**:
   - ChanVal の短変数宣言エラールールを追加

### 影響を受けるテスト

- ✅ `code-short-decl-error`: 修正により正常化
- ✅ 他の53個の正常テスト: 影響なし（すべて引き続きPASS）

## まとめ

この修正により、K-Goは Go言語の短変数宣言の再宣言エラーを正しく検出できるようになりました。エラーテストの成功率が 50% → 100% に向上し、より正確な Go言語のセマンティクスを実装できました。

**修正の要点**:
- 型ごとの明示的なエラールール
- 高い優先度の設定（priority(10)）
- K Framework のパターンマッチングの理解

**テスト結果**:
- エラーテスト: 2/2 passed (100% ✅)
- 全体: 55/56 passed (98.2%)
