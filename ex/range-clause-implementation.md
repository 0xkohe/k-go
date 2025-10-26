# RangeClause実装（Go 1.22+）

## 概要

このドキュメントでは、Goの`for`ループにおける`RangeClause`の実装について説明します。特に、Go 1.22で導入された整数rangeの機能に焦点を当てています。この実装により、`for i := range n`構文を使った整数範囲の反復がサポートされます。

## 背景

### Go 1.22仕様

Go言語仕様より：

> 整数値nに対して、nが整数型または型なし整数定数の場合、反復値0からn-1までが昇順に生成されます。n <= 0の場合、ループは一度も実行されません。

### 構文

```
RangeClause = [ ExpressionList "=" | IdentifierList ":=" ] "range" Expression .
```

整数range（現在の実装）：
- `for i := range n` - 反復変数`i`を使って0からn-1まで反復
- `for range n` - 反復変数を公開せずにn回実行

## 実装の詳細

### 1. 構文定義（src/go/syntax/core.k）

```k
// Go specification: ForStmt = "for" [ Condition | ForClause | RangeClause ] Block .
syntax ForStmt ::= "for" Block                      // 無限ループ
                 | "for" Condition Block            // 条件のみのループ
                 | "for" ForClause Block            // init;condition;postを持つforループ
                 | "for" RangeClause Block          // range句（Go 1.22+）

// Go specification: RangeClause = [ ExpressionList "=" | IdentifierList ":=" ] "range" Expression .
// Current implementation: integer range only (Go 1.22+)
// Future: arrays, slices, maps, strings, channels
syntax RangeClause ::= IdentifierList ":=" "range" Exp [strict(2)]  // for i := range n（またはコレクション用のi, v）
                     | "range" Exp                     [strict(1)]  // for range n（反復変数なし）
```

**設計上の決定：**
- パース時の曖昧性を避けるため、個別の`Id`生成規則ではなく`IdentifierList`を使用
- `strict`アノテーションにより、ループ開始前にrange式が評価されることを保証
- 単一の生成規則で、単一の識別子と将来の複数識別子のケースの両方に対応

### 2. 意味規則（src/go/semantics/core.k）

#### 式評価のためのContextルール

```k
// range式を評価するためのcontextルール
context for ((_ , .IdentifierList) := range HOLE:Exp) _
context for range HOLE:Exp _
```

これらのcontextルールにより、脱糖化ルールを適用する前にrange式が値に評価されることを保証します。

**なぜcontextルールが必要か？**
- 構文上の`strict`アノテーションは、`ForStmt`内部では自動的に機能しない
- Contextルールは、式を最初に評価するようにK Frameworkに明示的に指示する
- これにより、変数や複雑な式が使用可能になる：`for i := range n+1`

#### 反復変数ありの場合

```k
// 単一識別子のケース - パース形式 "X , .IdentifierList" を処理
rule <k> for ((X:Id , .IdentifierList) := range N:Int) B:Block
      => enterScope(X := 0 ~> loop(X < N, X ++, B)) ... </k>
  requires N >Int 0

rule <k> for ((_X:Id , .IdentifierList) := range N:Int) _B:Block => .K ... </k>
  requires N <=Int 0

// 直接Idでパースされた場合のフォールバック
rule <k> for (X:Id := range N:Int) B:Block
      => enterScope(X := 0 ~> loop(X < N, X ++, B)) ... </k>
  requires N >Int 0

rule <k> for (_X:Id := range N:Int) _B:Block => .K ... </k>
  requires N <=Int 0
```

**脱糖化戦略：**
- `for i := range n`は次のように脱糖化される：`enterScope(i := 0 ~> loop(i < n, i++, body))`
- 新しいスコープを作成（Go 1.22の要件：各反復が独自の変数を持つ）
- ForClause実装の既存の`loop`構造を再利用
- エッジケースの処理：`n <= 0`の場合は反復なし

**パースに関する注意：**
- パーサーは単一の`Id`をASTで`X , .IdentifierList`として表現
- 両方の形式に対応：直接の`Id`とリスト形式
- K Frameworkのリスト表現との互換性を確保

#### 反復変数なしの場合

```k
// 反復変数なしのrange：for range n
// Go仕様：反復変数を公開せずにn回ループを実行
syntax KItem ::= rangeLoop(Int, Int, Block)  // rangeLoop(現在値, 上限, 本体)

rule <k> for range N:Int B:Block => enterScope(rangeLoop(0, N, B)) ... </k>
  requires N >Int 0

rule <k> for range N:Int _B:Block => .K ... </k>
  requires N <=Int 0

rule <k> rangeLoop(I:Int, N:Int, B:Block) => B ~> rangeLoop(I +Int 1, N, B) ... </k>
  requires I <Int N

rule <k> rangeLoop(I:Int, N:Int, _B:Block) => .K ... </k>
  requires I >=Int N
```

**設計上の決定：**
- 新しい`rangeLoop(現在値, 上限, 本体)`構造を導入
- 反復変数がないため`loop(condition, post, body)`は使用できない
- 隠し変数を使うと環境を不必要に汚染する
- 反復回数を内部的に追跡する方が効率的
- 関心の分離がより明確

#### Break/Continueのサポート

```k
// rangeループでbreak/continueを処理
rule <k> breakSignal ~> rangeLoop(_I, _N, _B) => .K ... </k>

rule <k> continueSignal ~> rangeLoop(I, N, B) => rangeLoop(I +Int 1, N, B) ... </k>
```

**既存の制御フローとの統合：**
- Break：rangeループを即座に終了
- Continue：カウンターをインクリメントして次の反復にスキップ
- ForClauseのbreak/continue意味規則と一貫性を保つ

## 例とテストケース

### 例1：基本的な整数Range

```go
package main

func main() {
	for i := range 5 {
		print(i);
	};
}
```

**出力：** `0 1 2 3 4`

**実行トレース：**
1. `5`が`Int(5)`に評価される
2. 次のように脱糖化：`enterScope(i := 0 ~> loop(i < 5, i++, {print(i);}))`
3. `scopeDecls`追跡を伴う新しいスコープを作成
4. 反復：0, 1, 2, 3, 4

### 例2：反復変数なしのRange

```go
package main

func main() {
	var x int;
	x = 0;
	for range 3 {
		x = x + 1;
		print(x);
	};
}
```

**出力：** `1 2 3`

**実行トレース：**
1. 次のように脱糖化：`enterScope(rangeLoop(0, 3, {x = x + 1; print(x);}))`
2. 内部カウンターで本体を3回実行
3. ユーザーコードには反復変数が公開されない

### 例3：Break文

```go
package main

func main() {
	for i := range 10 {
		if i == 3 {
			break;
		};
		print(i);
	};
}
```

**出力：** `0 1 2`

**実行トレース：**
1. `i == 3`まで通常通り反復
2. `break`が`breakSignal`を生成
3. シグナルがバブルアップしてループを終了
4. 0, 1, 2のみが出力される

### 例4：Continue文

```go
package main

func main() {
	for i := range 5 {
		if i == 2 {
			continue;
		};
		print(i);
	};
}
```

**出力：** `0 1 3 4`

**実行トレース：**
1. `i == 2`のとき、`continue`が`continueSignal`を生成
2. シグナルが`print(i)`をスキップして`i++`へ
3. ループが次の反復で継続
4. 値2がスキップされる

### 例5：ゼロと負の値

```go
// ゼロ回の反復
for i := range 0 {
	print(i);
};
print(42);  // 出力：42

// 負の値の反復（これもゼロ回）
for i := range -5 {
	print(i);
};
print(99);  // 出力：99
```

**Go仕様：** `n <= 0`の場合、ループは一度も実行されません。

### 例6：式の評価

```go
package main

func main() {
	var n int;
	n = 3;
	for i := range n {
		print(i);
	};
}
```

**出力：** `0 1 2`

**実行トレース：**
1. Contextルールが`n`の評価をトリガー
2. 変数ルックアップ：`n` → `Loc(0)` → `3`
3. 次のように脱糖化：`enterScope(i := 0 ~> loop(i < 3, i++, body))`
4. 任意の式で動作：`range n+1`、`range f()`など

## スコープ管理と`scopeDecls`

### Go 1.22の反復変数スコープ

Go 1.22では重要な変更が導入されました：**各反復が独自の反復変数のセットを持つ**。

```go
// Go 1.22以前：すべての反復が同じ'i'を共有
// Go 1.22以降：各反復が新しい'i'を取得
for i := range 3 {
    // 'i'は各反復で新しい変数
}
```

### `scopeDecls`を使った実装

```k
rule <k> for ((X:Id , .IdentifierList) := range N:Int) B:Block
      => enterScope(X := 0 ~> loop(X < N, X ++, B)) ... </k>
```

**`scopeDecls`の使用方法：**
1. `enterScope`が新しいスコープを作成し、空のMapを`scopeDecls`スタックに追加
2. `X := 0`が反復変数を宣言し、現在のスコープのMapで追跡
3. `scopeDecls`が同じスコープ内での再宣言を防止
4. ループ後、`exitScope`がスコープをクリーンアップ

**スコープ追跡の例：**

```go
x := 1        // scopeDecls: [{x -> true}]
for i := range 3 {
    // scopeDecls: [{x -> true}, {i -> true}]
    //                           ↑ 現在のスコープ
    print(i);
}
// scopeDecls: [{x -> true}]
```

## 設計上の考慮事項

### なぜ既存の`loop`構造に脱糖化するのか？

**利点：**
- コードの再利用：既存のForClauseインフラを活用
- 一貫した意味規則：break/continueで同じ動作
- よりシンプルな実装：ループロジックを重複させる必要がない
- 保守が容易：ループ処理の変更がForClauseとRangeClauseの両方に恩恵をもたらす

**検討された代替案：**
- 両方のケースで別個の`rangeLoop`
- **却下理由：** コードの重複が多く、一貫性の維持が困難

### なぜ変数なしの場合に別の`rangeLoop`を使うのか？

**理由：**
- 反復変数なしでは`loop(condition, post, body)`を使用できない
- 隠し変数を使うと環境を不必要に汚染する
- 反復回数を内部的に追跡する方が効率的
- 関心の分離がより明確

### ContextルールとStrictアノテーション

**なぜ両方必要か？**
- 構文上の`strict`アノテーション：意図を文書化し、基本的な評価を提供
- Contextルール：ForStmt構文内の式に必要
- K Frameworkの制限：`strict`は複雑な構文内に自動的に伝播しない

**利点：**
- 任意の式を許可：変数、関数呼び出し、算術演算
- Go意味規則との一貫性：range式はループ前に一度評価される

## 将来の拡張

### 配列とスライス

```go
for i := range arr {        // i: インデックス
for i, v := range arr {     // i: インデックス、v: 値
```

**必要なもの：**
1. 型システムに配列/スライス型
2. 長さ演算子：`len(arr)`
3. インデックス演算子：`arr[i]`
4. 2変数宣言のサポート

**実装スケッチ：**
```k
rule <k> for ((I:Id , V:Id , .IdentifierList) := range Arr:Array) B:Block
      => enterScope(I := 0 ~> loopArray(I, V, Arr, len(Arr), B)) ... </k>

syntax KItem ::= loopArray(Id, Id, Array, Int, Block)
```

### マップ

```go
for k, v := range m {       // k: キー、v: 値
```

**必要なもの：**
1. マップ型と操作
2. キーの反復（順不同）
3. 2変数の処理

### 文字列

```go
for i, r := range s {       // i: バイトインデックス、r: rune
```

**必要なもの：**
1. 文字列型
2. rune型
3. UTF-8デコードロジック

### チャンネル

```go
for v := range ch {         // v: 受信した値
```

**必要なもの：**
1. チャンネル型
2. 受信操作
3. クローズ検出

## テスト

### テストファイル

`src/go/codes/`に配置：
- `code-range-basic` - 基本的な整数range（0からn-1）
- `code-range-no-var` - 反復変数なしのrange
- `code-range-break` - rangeループでのbreak文
- `code-range-continue` - rangeループでのcontinue文
- `code-range-zero` - ゼロ回の反復（n = 0）
- `code-range-negative` - 負の値（n < 0）
- `code-range-expr` - range上限として変数式

### テストの実行

```bash
# 定義をコンパイル
docker compose exec k bash -c "cd go && kompile main.k"

# 個別のテストを実行
docker compose exec k bash -c "cd go && krun codes/code-range-basic --definition main-kompiled/"

# 期待される出力：
# <out> ListItem(0) ListItem(1) ListItem(2) ListItem(3) ListItem(4) </out>
```

### テストカバレッジ

✅ 基本的な反復（0からn-1）
✅ 反復変数なし
✅ Break文
✅ Continue文
✅ ゼロ回の反復（n = 0）
✅ 負の値の反復（n < 0）
✅ 式の評価（変数）
✅ `scopeDecls`を使ったスコープ管理

## 既知の制限事項

### 1. コレクションはサポートされていない

配列、スライス、マップ、文字列、チャンネルはまだ実装されていません。

**回避策：** 現時点では整数rangeを使用してください。

### 2. 2変数の反復

```go
for i, v := range collection  // まだサポートされていない
```

**ステータス：** 構文は定義済みだが、意味規則は単一変数のみ。

**今後の作業：** まずコレクション型が必要。

### 3. 代入形式

```go
i = 0
for i = range 10 { ... }  // まだサポートされていない
```

**ステータス：** 現在は短い宣言（`:=`）のみサポート。

**今後の作業：** `ExpressionList "=" "range" Exp`のバリアントを追加。

## まとめ

この実装は、Goのrangeループの堅実な基盤を提供します：

✅ **完全な整数rangeサポート**（Go 1.22+）
✅ **適切なスコープ管理**（`scopeDecls`を使用）
✅ **Break/continueの統合**
✅ **式の評価**（リテラルだけでなく変数も）
✅ **エッジケースの処理**（ゼロ、負の値）

**次のステップ：**
1. 配列/スライス型の実装
2. 配列/スライスに対するrangeの追加
3. マップとマップに対するrangeの実装
4. 文字列型とUTF-8サポートの追加
5. チャンネルとチャンネルに対するrangeの実装

モジュラー設計により、既存の機能を壊すことなく段階的にこれらの機能を追加できます。

## 参考資料

- [Go言語仕様 - range句を持つFor文](https://go.dev/ref/spec#For_statements)
- Go 1.22リリースノート：「forループ反復変数のスコープ」
- Go 1.22リリースノート：「整数に対するrange」
- K Frameworkドキュメント：`K_framework_documentation.md`
