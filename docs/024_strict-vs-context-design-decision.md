# strict vs context: 評価順序制御の設計判断

## 概要

多値受信操作 `v, ok := <-ch` の実装において、当初検討した `strict` 属性を削除し、代わりに `context` ルールを採用した設計判断について解説します。

この判断は、K Framework の評価戦略と Go 言語のセマンティクスを正確に実装するための重要な選択でした。

## 問題の背景

### 実装したい構文

```go
v, ok := <-ch
```

この構文では：
- **評価すべき**: `ch`（チャネル式）→ `channel(0, int)` または `nil` に評価
- **評価すべきでない**: `v`, `ok`（これから宣言する変数名）
- **保持すべき**: `<-` 演算子（構文の一部として）

### K Framework での選択肢

```k
// 選択肢1: strict 属性を使う
syntax ShortVarDecl ::= Id "," Id ":=" "<-" Exp [strict(?)]

// 選択肢2: context ルールを使う
syntax ShortVarDecl ::= Id "," Id ":=" "<-" Exp
context _:Id, _:Id := <-HOLE:Exp
```

## strict(2) の問題

### パラメータの数え方

K Framework では、構文定義のパラメータは**非終端記号（Id, Exp など）のみ**を数えます：

```k
Id "," Id ":=" "<-" Exp
↑1    ↑2              ↑3
```

最初の試み：

```k
syntax ShortVarDecl ::= Id "," Id ":=" "<-" Exp [strict(2)]
```

### 何が起きたか

```go
v, ok := <-ch
```

`strict(2)` は **2番目の `Id`（`ok` 変数）** を評価しようとします。

**問題点**:
1. `ok` はまだ宣言されていない識別子
2. 評価できないのでエラーまたは停止
3. 実際に `ch` を評価すべきなのに、間違った場所を評価している

### 実際のテスト実行結果

コンパイルは成功しますが、実行時に停止：

```xml
<k>
  ok1 ~> #freezer_,_:=<-__GO-SYNTAX-CONCURRENT_ShortVarDecl_Id_Id_Exp1_
    ( v1 ~> .K , ch ~> .K ) ~> print ( v1 ) ~> ...
</k>
```

`ok1` が評価されようとしている（freezer に入っている）状態で停止していました。

## strict(3) の問題

### 一見正しそうに見える

```k
syntax ShortVarDecl ::= Id "," Id ":=" "<-" Exp [strict(3)]
                                               ↑
                                               3番目のパラメータ（Exp）を評価
```

これなら `ch` が評価されそうですが、実は**2つの重大な問題**があります。

## 理由1: `<-` 演算子も含めて評価してしまう可能性

### 構文の曖昧性

関連する構文定義：

```k
// チャネル受信演算子の定義
syntax Exp ::= "<-" Exp [strict(1), symbol(chanRecv)]

// 多値受信の定義
syntax ShortVarDecl ::= Id "," Id ":=" "<-" Exp [strict(3)]
```

### パーサーの解釈の可能性

```go
v, ok := <-ch
```

この式に対して、パーサーは**2通りの解釈**をする可能性があります：

#### 解釈A: `<-` を ShortVarDecl の構文要素として認識

```
ShortVarDecl
├── Id: v
├── ","
├── Id: ok
├── ":="
├── "<-"          ← 構文のトークン
└── Exp: ch       ← 評価対象
```

この場合、`strict(3)` は `ch` だけを評価します（望ましい）。

#### 解釈B: `<-ch` を1つの Exp として先に認識

```
ShortVarDecl
├── Id: v
├── ","
├── Id: ok
├── ":="
└── Exp: (<-ch)        ← 評価対象（chanRecv 式全体）
         └── chanRecv(ch)
```

この場合、`strict(3)` は **`<-ch` という Exp 全体**を評価します（問題！）。

### なぜ解釈B になる可能性があるのか

K Framework のパーサーは、以下の順序で構文をマッチします：

1. **既存の演算子を優先**: `<-` は既に `Exp` の演算子として定義されている
2. **最長マッチ**: `<-ch` の方が `ch` より長いので優先される可能性
3. **曖昧性の解決**: 複数の解釈が可能な場合、より具体的な方を選ぶ

そのため、`<-ch` が **1つの `Exp`（`chanRecv` 式）** として認識される可能性が高いです。

### strict(3) による評価の流れ（問題のケース）

```go
v, ok := <-ch
```

**ステップ1**: `strict(3)` により3番目の非終端記号（Exp）を評価

```k
v, ok := <-ch
         ↑
         └─ この Exp 全体を評価しようとする
```

**ステップ2**: パーサーが `<-ch` を `chanRecv` として解釈

```k
v, ok := chanRecv(ch)
         ↑
         └─ chanRecv 式として評価
```

**ステップ3**: `ch` が評価される

```k
v, ok := chanRecv(channel(0, int))
```

**ステップ4**: `chanRecv` のセマンティクスルールが適用される

```k
// semantics/concurrent.k:236
rule <k> chanRecv(channel(CId, _T)) => V ... </k>
     <channels>...
       CId |-> (chanState(..., ListItem(V) BufRest:List, ...)
            => chanState(..., BufRest, ...))
     ...</channels>
```

**ステップ5**: 結果は単一の値になる

```k
v, ok := 42
         ↑
         └─ もう <-ch という構文形式がない！
```

**ステップ6**: 変換ルールが適用できない

```k
// 期待していたルール
rule <k> X:Id, Y:Id := <-Ch:ChanVal
      => (X, Y) := recvWithOk(Ch) ... </k>

// しかし、現在の形は：
v, ok := 42
         ↑
         └─ <-Ch という形がないのでマッチしない
```

**結果**: エラーまたは誤った解釈（単一値の代入として処理される）

### 図解: 評価のタイミング

```
┌─────────────────────────────────────┐
│ strict(3) の場合（問題）             │
└─────────────────────────────────────┘

v, ok := <-ch
         │
         └─ strict(3): Exp 全体を評価
         │
         ▼
v, ok := chanRecv(channel(0, int))
         │
         └─ chanRecv ルール適用
         │
         ▼
v, ok := 42
         │
         └─ 変換ルールがマッチしない
         │
         ▼
       ERROR!


┌─────────────────────────────────────┐
│ context の場合（正しい）             │
└─────────────────────────────────────┘

v, ok := <-ch
           │
           └─ context: ch だけを評価
           │
           ▼
v, ok := <-channel(0, int)
         │
         └─ 変換ルール適用
         │
         ▼
(v, ok) := recvWithOk(channel(0, int))
         │
         └─ recvWithOk 実行
         │
         ▼
   tuple(42, true)
```

## 理由2: チャネル式だけを評価したい（`<-` を保持する必要性）

### 評価したいもの vs 評価したくないもの

```go
v, ok := <-ch
         ↑  ↑
         │  └─ 評価したい: ch → channel(0, int) または nil
         │
         └─ 評価したくない: <- 演算子
            （これは構文の一部として残す必要がある）
```

### なぜ `<-` を保持する必要があるのか

**パターンマッチのため**: 変換ルールが `<-` を含む形式を期待している

```k
rule <k> X:Id, Y:Id := <-Ch:ChanVal
      => (X, Y) := recvWithOk(Ch) ... </k>
```

このルールのパターン `X, Y := <-Ch:ChanVal` は：
- **`<-`** が構文の一部として必要
- **`Ch`** がチャネル値であることを要求
- 両方が揃って初めてマッチする

もし `<-` が評価されて消えてしまうと：

```k
// 評価後
v, ok := 42

// 期待しているパターン
X, Y := <-Ch:ChanVal
        ↑
        └─ この部分がないのでマッチしない
```

### 多値受信として認識されない問題

`<-` が失われると、通常の代入文として解釈されてしまいます：

```k
// 多値受信として認識されるべき
v, ok := <-ch  → recvWithOk(ch) → tuple(value, true/false)

// しかし、<- が失われると...
v, ok := 42    → 単一値を2つの変数に代入？（エラー）
```

Go 言語では、以下は構文エラーです：

```go
v, ok := 42  // Error: assignment mismatch: 2 variables but 1 values
```

K Framework の実装でも同様に、この形式は処理できません。

### 具体例: 評価のタイミングによる違い

#### 望ましい評価順序（context を使用）

```k
// 【初期状態】
v, ok := <-ch

// 【Step 1】context ルールでチャネル式だけを評価
context _:Id, _:Id := <-HOLE:Exp
//                       ↑
//                       HOLE = ch を評価

// 【Step 2】ch が評価される（<- は残る）
v, ok := <-channel(0, int)
         ↑
         └─ <- が保持されている

// 【Step 3】変換ルール適用（パターンマッチ成功）
rule <k> X:Id, Y:Id := <-Ch:ChanVal
      => (X, Y) := recvWithOk(Ch) ... </k>

// 【Step 4】変換後
(v, ok) := recvWithOk(channel(0, int))

// 【Step 5】recvWithOk 実行（優先順位付きルール）
tuple(ListItem(42) ListItem(true))

// 【Step 6】タプル代入
v = 42, ok = true
```

#### 望ましくない評価順序（strict(3) の場合）

```k
// 【初期状態】
v, ok := <-ch

// 【Step 1】strict(3) で Exp 全体を評価
// パーサーが <-ch を chanRecv として解釈

// 【Step 2】<-ch が chanRecv(ch) として評価される
v, ok := chanRecv(channel(0, int))

// 【Step 3】chanRecv ルール適用
rule <k> chanRecv(channel(CId, _T)) => V ... </k>
     <channels>...
       CId |-> (chanState(SendQ, RecvQ, (ListItem(V) BufRest:List), Size, T, Closed)
            => chanState(SendQ, RecvQ, BufRest, Size, T, Closed))
     ...</channels>

// 【Step 4】評価後の形（値になってしまった）
v, ok := 42
         ↑
         └─ <- が失われている

// 【Step 5】変換ルールがマッチしない
rule <k> X:Id, Y:Id := <-Ch:ChanVal  // このパターンはマッチしない
         //                ↑
         //                └─ <- が必要だが、もうない

// 【Step 6】エラーまたは誤った解釈
// 通常の代入文として処理しようとするがエラー
```

### 通常の受信 vs 多値受信の違い

通常の受信では `<-` を評価しても問題ありません：

```go
v := <-ch  // 通常の受信
```

```k
// 通常の受信の処理
rule <k> X:Id := V:Int => .K ... </k>
     //      ↑
     //      └─ 値が来ることを期待（<- は評価されて良い）
```

しかし、多値受信では `<-` を構文要素として保持する必要があります：

```go
v, ok := <-ch  // 多値受信
```

```k
// 多値受信の処理
rule <k> X:Id, Y:Id := <-Ch:ChanVal => ... </k>
     //                ↑
     //                └─ <- がパターンの一部（保持する必要がある）
```

### K Framework の評価戦略

#### strict 属性の挙動

```k
syntax Exp ::= Exp "+" Exp [strict]
```

`strict` は **「すべてのサブ項を値に評価してから、ルールを適用する」** という意味です。

```k
// 例: (1 + 2) + (3 + 4)

【Step 1】左側のサブ項を評価
(1 + 2) + (3 + 4)
 ↓
3 + (3 + 4)

【Step 2】右側のサブ項を評価
3 + (3 + 4)
    ↓
3 + 7

【Step 3】すべてが値になったので演算ルール適用
3 + 7
 ↓
10
```

**特徴**:
- すべてのサブ項を **値** まで評価する
- 構文構造は失われる
- 演算ルールは値に対して適用される

#### context の挙動

```k
context HOLE:Exp "+" _:Exp
```

`context` は **「特定の位置（HOLE）だけを評価する」** という意味です。

```k
// 例: x + (y + z)

【Step 1】左側の context が適用
x + (y + z)
↓ (x を評価)
5 + (y + z)

【Step 2】右側の context が別途適用
5 + (y + z)
    ↓ (y + z を評価)
5 + 10

【Step 3】両方が値になったので演算ルール適用
5 + 10
 ↓
15
```

**特徴**:
- 特定の位置だけを評価する
- 構文構造は保持される
- 評価箇所を明示的に制御できる

### 多値受信における context の必要性

```k
context _:Id, _:Id := <-HOLE:Exp
```

この context ルールは3つのことを明示しています：

1. **評価する場所**: `HOLE` の位置（チャネル式 `ch`）だけ
2. **評価しない場所**: `<-`, `Id`, `:=` は触らない
3. **構文構造を保持**: `X, Y := <-...` という形を維持

これにより、以下が保証されます：

```k
v, ok := <-ch
         ↑ ↑
         │ └─ ここだけ評価（ch → channel(0, int)）
         │
         └─ この構造は保持（<- は残る）
```

### 変換ルールとの連携

```k
// Context ルールで ch を評価
context _:Id, _:Id := <-HOLE:Exp

// ↓ ch が channel(0, int) に評価される

// 変換ルールが適用可能になる
rule <k> X:Id, Y:Id := <-Ch:ChanVal
      => (X, Y) := recvWithOk(Ch) ... </k>

// ↓ recvWithOk に変換

// recvWithOk の優先順位付きルールが適用
rule <k> recvWithOk(channel(CId, T)) => tuple(...) ... </k>
```

この流れは、**`<-` が保持されているからこそ**実現できます。

## context による解決

### 実装内容

```k
// 構文定義（strict なし）
syntax ShortVarDecl ::= Id "," Id ":=" "<-" Exp

// セマンティクスで明示的に評価順序を制御
context _:Id, _:Id := <-HOLE:Exp
```

### context ルールの効果

```go
v, ok := <-ch
```

**ステップ1**: context ルールが適用される

```k
context _:Id, _:Id := <-HOLE:Exp
//                       ↑
//                       HOLE = 評価対象の位置
```

**ステップ2**: `ch` だけが評価される

```k
v, ok := <-ch
           ↓ (ch を評価)
v, ok := <-channel(0, int)
         ↑
         └─ <- は保持されている
```

**ステップ3**: 変換ルールが適用可能

```k
rule <k> X:Id, Y:Id := <-Ch:ChanVal
      => (X, Y) := recvWithOk(Ch) ... </k>

// パターンマッチ成功:
// X = v, Y = ok, Ch = channel(0, int)
```

**ステップ4**: recvWithOk に変換

```k
(v, ok) := recvWithOk(channel(0, int))
```

**ステップ5**: recvWithOk の優先順位付きルールで処理

```k
// 例: Priority 2（バッファから取得）
rule <k> recvWithOk(channel(CId, T)) => tuple(ListItem(V) ListItem(true)) ... </k>
```

**ステップ6**: タプル代入で完了

```k
(v, ok) := tuple(ListItem(42) ListItem(true))
↓
v = 42, ok = true
```

### 3つの構文コンテキストすべてに適用

```k
// 短変数宣言
context _:Id, _:Id := <-HOLE:Exp
rule <k> X:Id, Y:Id := <-Ch:ChanVal => (X, Y) := recvWithOk(Ch) ... </k>

// 代入文
context _:Id, _:Id = <-HOLE:Exp
rule <k> X:Id, Y:Id = <-Ch:ChanVal => (X, Y) = recvWithOk(Ch) ... </k>

// 変数宣言文
context var _:Id, _:Id = <-HOLE:Exp
rule <k> var X:Id, Y:Id = <-Ch:ChanVal => (X, Y) := recvWithOk(Ch) ... </k>
```

すべてのケースで：
1. **チャネル式だけを評価**（context）
2. **`<-` を保持**
3. **変換ルールでパターンマッチ**
4. **recvWithOk に統一**

## 比較: strict(3) vs context

### 評価範囲の違い

| アプローチ | 評価される範囲 | 結果 |
|-----------|--------------|------|
| `strict(3)` | `Exp` 全体（`<-ch`） | `42`（値） |
| `context` | `HOLE` の位置だけ（`ch`） | `<-channel(0, int)`（構文保持） |

### 構文構造の保持

| アプローチ | `<-` の扱い | 変換ルールのマッチ |
|-----------|-----------|-----------------|
| `strict(3)` | 評価されて消える可能性 | マッチしない（エラー） |
| `context` | 確実に保持される | 確実にマッチする |

### パターンマッチの成否

```k
// 変換ルール
rule <k> X:Id, Y:Id := <-Ch:ChanVal => ... </k>
```

| アプローチ | 評価後の形 | マッチ結果 |
|-----------|----------|----------|
| `strict(3)` | `v, ok := 42` | ✗ マッチしない |
| `context` | `v, ok := <-channel(0, int)` | ✓ マッチする |

### 総合比較表

| 観点 | strict(2) | strict(3) | context |
|-----|----------|-----------|---------|
| **評価対象** | `ok`（誤） | `<-ch` 全体 | `ch` のみ |
| **評価範囲** | 間違った場所 | 広すぎる | 正確 |
| **`<-` の保持** | N/A | 失われる可能性 | 確実に保持 |
| **パターンマッチ** | 停止 | マッチしない | マッチする |
| **意図の明確さ** | 不明瞭 | やや不明瞭 | 非常に明確 |
| **保守性** | 低い | 中程度 | 高い |
| **デバッグ** | 困難 | やや困難 | 容易 |
| **仕様準拠** | ✗ | ✗ | ✓ |

## 実装上の詳細

### nil チャネルのサポート

nil チャネルは `FuncVal` として表現されるため、両方のケースが必要です：

```k
// 通常のチャネル
rule <k> X:Id, Y:Id := <-Ch:ChanVal
      => (X, Y) := recvWithOk(Ch) ... </k>

// nil チャネル
rule <k> X:Id, Y:Id := <-Ch:FuncVal
      => (X, Y) := recvWithOk(Ch) ... </k>
```

`context` ルールにより、どちらの場合も評価後に変換ルールが適用されます：

```go
var ch chan int  // ch = nil (FuncVal)
v, ok := <-ch
```

```k
【Step 1】context で ch を評価
v, ok := <-ch
           ↓
v, ok := <-nil  // FuncVal

【Step 2】FuncVal 用の変換ルール適用
rule <k> X:Id, Y:Id := <-Ch:FuncVal
      => (X, Y) := recvWithOk(Ch) ... </k>

【Step 3】recvWithOk で nil チャネルを処理
rule <k> recvWithOk(_FV:FuncVal) => waitingRecvOk(0) ... </k>
// 永久にブロック
```

### context と変換ルールの協調

```k
// Context ルールが先に適用
context _:Id, _:Id := <-HOLE:Exp

// ↓ チャネル式が評価される

// 変換ルールが適用可能になる
rule <k> X:Id, Y:Id := <-Ch:ChanVal => ... </k>
rule <k> X:Id, Y:Id := <-Ch:FuncVal => ... </k>
```

この2段階のアプローチにより：
1. **評価の制御**: context が評価範囲を限定
2. **型安全性**: 変換ルールで `ChanVal` または `FuncVal` を保証
3. **構文の保持**: `<-` が残るのでパターンマッチ成功

## まとめ

### strict(3) を使わなかった理由

1. **評価範囲が不正確**
   - `<-ch` 全体を評価する可能性
   - `ch` だけを評価すべき

2. **構文構造が失われる**
   - `<-` 演算子が評価されて消える
   - 変換ルールがマッチしなくなる

3. **パターンマッチの失敗**
   - `X, Y := <-Ch` という形が必要
   - `X, Y := 42` ではマッチしない

### context を採用した理由

1. **評価位置を明示的に指定**
   - `HOLE` でチャネル式だけを指定
   - 意図が明確で、誤解の余地がない

2. **構文構造を確実に保持**
   - `<-` を評価対象から除外
   - 変換ルールが確実にマッチ

3. **保守性とデバッグ性**
   - コードの意図が明確
   - 構文が変更されても影響を受けにくい
   - デバッグ時に何が評価されるか明確

4. **Go 仕様への準拠**
   - 多値受信の正確なセマンティクス
   - すべての構文コンテキストで動作

### 設計原則

この設計判断は、以下の原則に基づいています：

1. **明示性**: 暗黙的な動作より明示的な制御を優先
2. **正確性**: 評価範囲を正確に制御
3. **保守性**: 意図が明確で、将来の変更に強い
4. **仕様準拠**: Go 言語仕様に正確に対応

`context` を使うことで、K Framework の強力な評価制御機能を活用し、Go 言語のセマンティクスを正確に実装することができました。
