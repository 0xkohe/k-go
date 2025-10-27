# Go定数（const）宣言の実装

## 概要

このドキュメントでは、K FrameworkにおけるGo言語の定数（const）宣言機能の実装について説明します。

## Go言語の定数仕様

### 定数とは

Go仕様より：
> Constants are values that are known at compile time and do not change during program execution.

定数は以下の特徴を持ちます：

1. **コンパイル時に値が確定**: 定数の値はコンパイル時に決定され、実行時に変更されません
2. **型推論または明示的型指定**: `const x = 10`（型推論）または`const x int = 10`（明示的型）
3. **代入禁止**: 一度宣言された定数に再代入することはできません
4. **メモリ不使用**: 定数は実行時のメモリを消費せず、コンパイル時定数として扱われます

### 構文

```go
// 型推論
const x = 10
const flag = true

// 明示的型指定
const max int = 100
const enabled bool = false
```

## 実装の設計判断

### なぜ新しいセル（constEnv）が必要か

既存の`env`/`store`セルとは別に`constEnv`セルを追加した理由：

1. **セマンティクスの違い**:
   - 変数（var）: 実行時にメモリ（store）を消費し、値が変更可能
   - 定数（const）: コンパイル時定数として直接値を保持、変更不可

2. **効率性**:
   - 定数は`env`→`store`の2段階参照が不要
   - `constEnv`から直接値を取得できる

3. **明確な区別**:
   - 識別子が定数か変数かを明確に区別できる
   - 代入禁止ルールの実装が容易

### 設計アーキテクチャ

```
変数（var）:
  tenv: x |-> int
  env:  x |-> Loc(0)
  store: 0 |-> 42

定数（const）:
  tenv: x |-> int
  constEnv: x |-> 42
  (env, storeは使用しない)
```

## 実装の詳細

### 1. 構文定義（syntax/core.k）

```k
syntax ConstDecl ::= "const" Id "=" Exp     [strict(2)]  // 型推論
                   | "const" Id Type "=" Exp [strict(3)]  // 明示的型

syntax Statement ::= ... | VarDecl | ConstDecl
```

**strict属性の説明**:
- `strict(2)`: `const x = Exp`の場合、Exp（位置2）を評価してから宣言
- `strict(3)`: `const x int = Exp`の場合、Exp（位置3）を評価してから宣言

### 2. 設定セルの追加（semantics/core.k）

```k
configuration
  <T>
    ...
    <constEnv> .Map </constEnv>  // Id -> ConstValue
    ...
  </T>
```

### 3. 定数宣言の意味規則

#### 型推論版

```k
// const x = 10
rule <k> const X:Id = I:Int => .K ... </k>
     <tenv> R => R [ X <- int ] </tenv>
     <constEnv> CE => CE [ X <- I ] </constEnv>

// const flag = true
rule <k> const X:Id = B:Bool => .K ... </k>
     <tenv> R => R [ X <- bool ] </tenv>
     <constEnv> CE => CE [ X <- B ] </constEnv>
```

**ポイント**:
- 値の型から自動的に型を推論し、`tenv`に登録
- 値を直接`constEnv`に格納（env/storeは使用しない）

#### 明示的型指定版

```k
// const x int = 10
rule <k> const X:Id int = I:Int => .K ... </k>
     <tenv> R => R [ X <- int ] </tenv>
     <constEnv> CE => CE [ X <- I ] </constEnv>

// const flag bool = true
rule <k> const X:Id bool = B:Bool => .K ... </k>
     <tenv> R => R [ X <- bool ] </tenv>
     <constEnv> CE => CE [ X <- B ] </constEnv>
```

### 4. 識別子の参照ルール

定数と変数の両方が存在する場合、**定数を優先**します：

```k
// 定数の参照（優先度10 = 高優先度）
rule <k> X:Id => V ... </k>
     <constEnv> ... X |-> V ... </constEnv>
  [priority(10)]

// 変数の参照（優先度20 = 低優先度）
rule <k> X:Id => V ... </k>
     <env> ... X |-> L:Int ... </env>
     <store> ... L |-> V ... </store>
  [priority(20)]
```

**priority属性**:
- 数値が**小さいほど優先度が高い**
- `priority(10)`の定数参照が`priority(20)`の変数参照より先に試行される
- 同じ名前で定数と変数が共存した場合、定数が優先されます

### 5. 定数への代入禁止

#### エラールール（高優先度）

```k
syntax KItem ::= "constAssignmentError"

// int型定数への代入禁止
rule <k> X:Id = I:Int => constAssignmentError ... </k>
     <constEnv> ... X |-> _ ... </constEnv>
  [priority(10)]

// bool型定数への代入禁止
rule <k> X:Id = B:Bool => constAssignmentError ... </k>
     <constEnv> ... X |-> _ ... </constEnv>
  [priority(10)]

// 関数型定数への代入禁止
rule <k> X:Id = FV:FuncVal => constAssignmentError ... </k>
     <constEnv> ... X |-> _ ... </constEnv>
  [priority(10)]
```

**重要ポイント**:
- `[priority(10)]`により、通常の代入ルールより先に試行される
- `constEnv`にXが存在する場合、即座にエラーとなる
- パターン`... X |-> _ ...`により、値に関係なく定数かどうかだけを判定

#### 通常の代入ルール（低優先度）

```k
// 変数への代入（定数でない場合のみ）
rule <k> X:Id = I:Int => .K ... </k>
     <tenv> ... X |-> int ... </tenv>
     <env> ... X |-> L:Int ... </env>
     <store> Store => Store [ L <- I ] </store>
     <constEnv> CE </constEnv>
  requires notBool (X in_keys(CE))
```

**requires条件**:
- `notBool (X in_keys(CE))`: Xがconstenvに存在しない場合のみマッチ
- これにより、定数への代入を確実にブロック

## ルール適用の優先順序

### なぜpriorityが必要か

K Frameworkでは、複数のルールがマッチ可能な場合、どのルールを適用するかを決定する必要があります。priority属性がない場合：

1. Kは全てのマッチ可能なルールを試行
2. 非決定的な動作が発生する可能性
3. エラー検出が正しく機能しない

priority属性により：
1. **明示的な優先順序**を定義
2. **決定的な動作**を保証
3. **エラーチェックを先に実行**できる

### 優先順序の例

```
代入文 x = 20 に対して：

1. priority(10): constEnvをチェック
   ↓
   X が constEnv に存在?
   ├─ YES → constAssignmentError（終了）
   └─ NO  → 次のルールへ
            ↓
2. priority(なし): 通常の代入ルール
   ↓
   X が env に存在 かつ X が constEnv に存在しない?
   └─ YES → 代入実行
```

## 実装の課題と解決策

### 課題1: ルールのマッチング失敗

**問題**: 初期実装では、定数への代入がスタックして進まない状況が発生

**原因**: constエラールールと通常の代入ルールが同じ優先度で競合

**解決策**: constエラールールに`[priority(10)]`を追加し、通常の代入ルールより先に評価されるようにした

### 課題2: requires条件の配置

**問題**: 通常の代入ルールで`requires notBool (X in_keys(CE))`を追加したが、CEが未定義

**解決策**: `<constEnv> CE </constEnv>`セルを明示的にルールに追加し、requires条件でCEを参照できるようにした

## テストケース

### 1. 基本的な定数宣言（code-const-basic）

```go
package main

func main() {
	const x = 10;
	const y = 20;
	print(x);        // 10
	print(y);        // 20
	print(x + y);    // 30
}
```

**期待される出力**: `10, 20, 30`

**検証ポイント**:
- 定数の宣言と初期化
- 定数の参照
- 定数を使った式評価

### 2. 型付き定数宣言（code-const-typed）

```go
package main

func main() {
	const x int = 100;
	const y bool = true;
	print(x);        // 100
	if y {
		print(x + 50);  // 150
	}
}
```

**期待される出力**: `100, 150`

**検証ポイント**:
- 明示的型指定の定数宣言
- bool型定数
- 条件分岐での定数使用

### 3. 定数への代入エラー（code-const-error）

```go
package main

func main() {
	const x = 10;
	x = 20;          // エラー！
	print(x);
}
```

**期待される出力**: `constAssignmentError`

**検証ポイント**:
- 定数への代入が禁止されていること
- エラーが適切に検出されること

### 4. 定数と変数の混在（code-const-var-mix）

```go
package main

func main() {
	const max = 100;
	var x int;
	x = 10;
	x = x + max;     // 変数xに定数maxを加算
	print(x);        // 110
	if x < max {
		print(max - x);
	}
}
```

**期待される出力**: `110`

**検証ポイント**:
- 定数と変数の共存
- 定数と変数の演算
- 変数は変更可能だが定数は変更不可

## 実行結果の確認

### テスト実行コマンド

```bash
# 再コンパイル
docker compose exec k bash -c "cd go && kompile main.k"

# 各テストケースの実行
docker compose exec k bash -c "cd go && krun codes/code-const-basic --definition main-kompiled/"
docker compose exec k bash -c "cd go && krun codes/code-const-typed --definition main-kompiled/"
docker compose exec k bash -c "cd go && krun codes/code-const-error --definition main-kompiled/"
docker compose exec k bash -c "cd go && krun codes/code-const-var-mix --definition main-kompiled/"
```

### 設定の最終状態例（code-const-var-mix）

```
<k> .K </k>
<out> ListItem(110) </out>
<tenv> .Map </tenv>
<env> .Map </env>
<store> 0 |-> 110 </store>      // 変数xの最終値
<nextLoc> 1 </nextLoc>
<constEnv> max |-> 100 </constEnv>  // 定数maxは実行後も残る
```

**観察ポイント**:
- 定数`max`は`constEnv`に残っている
- 変数`x`は`store`の位置0に最終値110が格納
- スコープ終了後、envとtenvはクリア

## まとめ

### 実装のポイント

1. **独立したconstEnvセル**: 定数専用のセルにより、変数との明確な分離
2. **priority属性**: ルールの適用順序を制御し、エラー検出を優先
3. **直接値格納**: 定数は実行時メモリ（store）を使わず、constEnvに直接格納
4. **型推論と明示的型**: 両方の構文をサポート

### Go仕様との整合性

- ✅ コンパイル時定数の概念を実現
- ✅ 定数への再代入を禁止
- ✅ 型推論と明示的型指定の両方をサポート
- ✅ 定数と変数の共存

### 今後の拡張可能性

- [ ] 複数定数の一括宣言（`const (...)` ブロック）
- [ ] 定数式の評価（`const x = 1 + 2`など）
- [ ] iota（連続した定数値）
- [ ] 型なし定数（untyped constants）と型あり定数の区別
