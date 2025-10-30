# symbol属性とパターンマッチングの詳細解説

## symbol属性の役割

K Frameworkでは、`symbol()` 属性は構文プロダクションに**明示的な名前**を付けるために使用します。

## なぜsymbol(chanSend)を付けるのか

### 理由1: 曖昧性の回避

`<-` 演算子は**2つの異なる構文**で使われています：

```k
// 送信: Exp <- Exp
syntax SendStmt ::= Exp "<-" Exp [strict, symbol(chanSend)]

// 受信: <- Exp
syntax Exp ::= "<-" Exp [strict(1), symbol(chanRecv)]
```

**ファイル**: `src/go/syntax/concurrent.k`

`symbol()` を指定することで、パーサーとルールマッチングで両者を区別できます。

### 理由2: ルールでの明示的マッチング

セマンティクスルールで特定の構文を参照するときに使います：

```k
// concurrent.k の送信ルール
rule <thread>...
       <tid> SenderTid </tid>
       <k> chanSend(channel(CId:Int, T:Type), V:Val) => .K ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(_SendQ, (ListItem(RecvTid) RecvRest:List), T)
             => chanState(_SendQ, RecvRest, T))
     ...</channels>
     <thread>...
       <tid> RecvTid </tid>
       <k> waitingRecv(CId) => V ... </k>
     ...</thread>
```

**重要**: `chanSend(...)` という形式で直接参照できます。

### 理由3: 構文糖衣の展開

もし `symbol()` を指定しない場合、K Frameworkは自動的に名前を生成しますが、その名前は：
- 読みにくい（例: `_<-_`）
- 予測しにくい
- ルールで参照しにくい

### 実際の使用例

**構文定義**:
```k
syntax SendStmt ::= Exp "<-" Exp [strict, symbol(chanSend)]
```

**strict属性の効果**:
```
ch <- 100
  ↓ (evaluate ch)
channel(0, int) <- 100
  ↓ (evaluate 100)
chanSend(channel(0, int), 100)  // symbolの名前で呼ばれる！
```

`strict` 属性が引数を評価した後、最終的に `chanSend(...)` という**関数的な形式**に変換されます。

### chanRecv との比較

```k
// 受信
syntax Exp ::= "<-" Exp [strict(1), symbol(chanRecv)]

// 使用例
result := <-ch
  ↓
result := chanRecv(channel(0, int))
```

ルールで `chanRecv(...)` として明確にマッチできます。

## パターンマッチング: chanSend(channel(...), ...)

### マッチング構造の分解

```k
<k> chanSend(channel(CId:Int, T:Type), V:Val) => .K ... </k>
```

このパターンは**3層の構造**をマッチングしています：

### 層1: chanSend(...) の形式

```k
chanSend(引数1, 引数2)
```

これは `symbol(chanSend)` で定義された構文プロダクション：
```k
syntax SendStmt ::= Exp "<-" Exp [strict, symbol(chanSend)]
```

`strict` 属性により、両方の引数が評価された後、この形式になります。

### 層2: 第1引数のマッチング

```k
channel(CId:Int, T:Type)
```

これは**具体的なチャネル値**を期待しています：

```k
// concurrent.k の定義
syntax ChanVal ::= channel(Int, Type)
```

**マッチング詳細**:
- `channel(...)` - チャネル値のコンストラクタ
- `CId:Int` - チャネルID（整数）を変数 `CId` にバインド
- `T:Type` - 要素型（int, bool等）を変数 `T` にバインド

### 層3: 第2引数のマッチング

```k
V:Val
```

**マッチング詳細**:
- `Val` - 任意の値型（Int, Bool, ChanVal, FuncVal等）
- `V` - その値を変数 `V` にバインド

## 具体的なマッチング例

### 例1: `ch <- 100`

**初期状態**:
```k
<k> ch <- 100 ... </k>
<env> ... ch |-> 0 ... </env>
<store> ... 0 |-> channel(5, int) ... </store>
```

**strict評価の過程**:

#### ステップ1: ch を評価

```k
<k> ch <- 100 ... </k>
```

**適用ルール**: 変数ルックアップルール（`semantics/core.k`）

```k
rule <k> X:Id => V ... </k>
     <env> ... X |-> L:Int ... </env>
     <store> ... L |-> V:Val ... </store>
```

**マッチング**:
- `X` = `ch`
- `L` = 0
- `V` = `channel(5, int)`

**結果**:
```k
<k> channel(5, int) <- 100 ... </k>
```

#### ステップ2: 100 を評価（既に値）

```k
<k> channel(5, int) <- 100 ... </k>
```

**strict完了**: 両引数が値になったので、`chanSend` に変換

```k
<k> chanSend(channel(5, int), 100) ... </k>
```

#### ステップ3: 送信ルールマッチング

**パターン**:
```k
chanSend(channel(CId:Int, T:Type), V:Val)
```

**実際の値**:
```k
chanSend(channel(5, int), 100)
```

**変数バインディング**:
```
CId = 5
T = int
V = 100
```

### 例2: `ch <- result`（resultは変数）

**初期状態**:
```k
<k> ch <- result ... </k>
<env>
  ch |-> 0
  result |-> 1
</env>
<store>
  0 |-> channel(3, bool)
  1 |-> true
</store>
```

**strict評価の過程**:

#### ステップ1: ch を評価

```k
<k> ch <- result ... </k>
  ↓ (変数ルックアップ)
<k> channel(3, bool) <- result ... </k>
```

#### ステップ2: result を評価

```k
<k> channel(3, bool) <- result ... </k>
  ↓ (変数ルックアップ)
<k> channel(3, bool) <- true ... </k>
  ↓ (strict完了)
<k> chanSend(channel(3, bool), true) ... </k>
```

**変数バインディング**:
```
CId = 3
T = bool
V = true
```

### 例3: 関数呼び出しから返された値

**コード**:
```go
ch <- getValue()
```

**初期状態**:
```k
<k> ch <- getValue() ... </k>
<env> ... ch |-> 0 ... </env>
<store> ... 0 |-> channel(2, int) ... </store>
<fenv> ... getValue |-> fun(.ParamIds, .ParamTypes, int, return 42;) ... </fenv>
```

**strict評価の過程**:

#### ステップ1: ch を評価
```k
<k> channel(2, int) <- getValue() ... </k>
```

#### ステップ2: getValue() を評価
```k
<k> channel(2, int) <- getValue() ... </k>
  ↓ (関数呼び出し)
<k> channel(2, int) <- 42 ... </k>
  ↓ (strict完了)
<k> chanSend(channel(2, int), 42) ... </k>
```

**変数バインディング**:
```
CId = 2
T = int
V = 42
```

## マッチングしない例

### ❌ 例1: チャネルがnil

```k
<k> chanSend(nil, 100) ... </k>
```

**マッチしない理由**:
- `nil` は `channel(CId:Int, T:Type)` のパターンにマッチしない
- `nil` は `FuncVal` 型であり、`channel(...)` コンストラクタではない

**実際のエラー**: このルールはマッチせず、実行がスタックします。

### ❌ 例2: 第1引数が評価されていない

```k
<k> chanSend(ch, 100) ... </k>
```

**マッチしない理由**:
- `ch` は識別子（`Id`型）
- `channel(CId:Int, T:Type)` パターンは具体的な `channel(...)` 値を期待

**注意**: これは実際には起こりません。なぜなら `strict` 属性が評価を強制するからです。

### ❌ 例3: 第2引数が評価されていない

```k
<k> chanSend(channel(5, int), x) ... </k>
```

**マッチしない理由**:
- `x` は識別子（`Id`型）
- `V:Val` パターンは評価済みの値を期待

**注意**: これも `strict` 属性により起こりません。

## なぜこのパターンが重要か

### 1. 型安全性

```k
channel(CId:Int, T:Type)
```

このパターンにより：
- ✅ **評価済み**のチャネル値のみマッチ
- ✅ チャネルIDと型情報を抽出できる
- ✅ `nil` や未評価の変数を排除

### 2. チャネルIDの取得

```k
rule <thread>...
       <k> chanSend(channel(CId:Int, T:Type), V:Val) => .K ... </k>
     ...</thread>
     <channels>...
       CId |-> chanState(...)  // CIdを使ってチャネル状態にアクセス
     ...</channels>
```

`CId` 変数により、`<channels>` マップで対応するチャネル状態を探せます。

**例**:
```k
// チャネルID = 5 の場合
<channels>
  0 |-> chanState(...)  // マッチしない
  3 |-> chanState(...)  // マッチしない
  5 |-> chanState(...)  // マッチ！
  7 |-> chanState(...)  // マッチしない
</channels>
```

### 3. 型チェック

```k
<channels>...
  CId |-> chanState(_SendQ, _RecvQ, T)  // 同じ型Tをマッチング
...</channels>
```

送信される値の型とチャネルの要素型が一致することを確認できます。

**例: 型の一致**:
```k
// ルールパターン
chanSend(channel(CId:Int, T:Type), V:Val)
         ↓
chanSend(channel(5, int), 100)

// チャネル状態
<channels>
  5 |-> chanState(.List, .List, int)  // ✅ 型が一致（int）
</channels>
```

**例: 型の不一致**:
```k
chanSend(channel(5, bool), 100)

<channels>
  5 |-> chanState(.List, .List, int)  // ❌ 型が不一致（bool vs int）
</channels>
```

この場合、ルールはマッチしません（実際の実装では型システムが事前にこれを防ぎます）。

## 完全なルール例

### ルール1: 受信者が待っている場合

```k
rule <thread>...
       <tid> SenderTid </tid>
       <k> chanSend(channel(CId:Int, T:Type), V:Val) => .K ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(_SendQ, (ListItem(RecvTid) RecvRest:List), T)
             => chanState(_SendQ, RecvRest, T))
     ...</channels>
     <thread>...
       <tid> RecvTid </tid>
       <k> waitingRecv(CId) => V ... </k>
     ...</thread>
```

**ファイル**: `src/go/semantics/concurrent.k` (送信-受信マッチング)

**このルールのマッチング条件**:
1. ✅ 送信者のスレッドが `chanSend(channel(...), value)` を実行
2. ✅ チャネルID `CId` が `<channels>` に存在
3. ✅ 受信待ちキューに少なくとも1つのスレッドID
4. ✅ 受信者スレッドが `waitingRecv(CId)` で待機中
5. ✅ チャネルの型 `T` が一致

**動作**:
- 送信者: `chanSend(...) => .K` (完了)
- チャネル: 受信者を受信待ちキューから削除
- 受信者: `waitingRecv(CId) => V` (値を受信)

**具体例**:

**初期状態**:
```k
<threads>
  <thread>  // 送信者
    <tid> 1 </tid>
    <k> chanSend(channel(5, int), 100) ~> ... </k>
  </thread>

  <thread>  // 受信者
    <tid> 2 </tid>
    <k> waitingRecv(5) ~> ... </k>
  </thread>
</threads>

<channels>
  5 |-> chanState(.List, ListItem(2), int)
</channels>
```

**変数バインディング**:
```
SenderTid = 1
CId = 5
T = int
V = 100
RecvTid = 2
RecvRest = .List
```

**書き換え後**:
```k
<threads>
  <thread>  // 送信者（完了）
    <tid> 1 </tid>
    <k> ... </k>
  </thread>

  <thread>  // 受信者（値を受け取った）
    <tid> 2 </tid>
    <k> 100 ~> ... </k>
  </thread>
</threads>

<channels>
  5 |-> chanState(.List, .List, int)  // 受信キューが空に
</channels>
```

### ルール2: 受信者がいない場合（送信者がブロック）

```k
rule <thread>...
       <tid> SenderTid </tid>
       <k> chanSend(channel(CId:Int, T:Type), V:Val) => waitingSend(CId) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ:List, .List, T)
             => chanState((SendQ ListItem(sendItem(SenderTid, V))), .List, T))
     ...</channels>
```

**ファイル**: `src/go/semantics/concurrent.k` (送信者ブロック)

**このルールのマッチング条件**:
1. ✅ 送信者のスレッドが `chanSend(channel(...), value)` を実行
2. ✅ チャネルID `CId` が `<channels>` に存在
3. ✅ 受信待ちキューが**空**（`.List`）
4. ✅ チャネルの型 `T` が一致

**動作**:
- 送信者: `chanSend(...) => waitingSend(CId)` (ブロック)
- チャネル: 送信キューに `sendItem(SenderTid, V)` を追加

**具体例**:

**初期状態**:
```k
<threads>
  <thread>  // 送信者
    <tid> 3 </tid>
    <k> chanSend(channel(7, bool), true) ~> ... </k>
  </thread>
</threads>

<channels>
  7 |-> chanState(.List, .List, bool)  // 両キュー空
</channels>
```

**変数バインディング**:
```
SenderTid = 3
CId = 7
T = bool
V = true
SendQ = .List
```

**書き換え後**:
```k
<threads>
  <thread>  // 送信者（ブロック中）
    <tid> 3 </tid>
    <k> waitingSend(7) ~> ... </k>
  </thread>
</threads>

<channels>
  7 |-> chanState(ListItem(sendItem(3, true)), .List, bool)
</channels>
```

この後、受信者が現れると、別のルールが適用されて送信者が再開します。

## パターンマッチングの階層構造まとめ

```
chanSend(channel(CId:Int, T:Type), V:Val)
│
├─ chanSend(...)          ← symbol で定義された構文名
│   │
│   ├─ 引数1: channel(CId:Int, T:Type)
│   │   │
│   │   ├─ channel(...)  ← ChanVal のコンストラクタ
│   │   ├─ CId:Int       ← チャネルIDを変数にバインド
│   │   └─ T:Type        ← 要素型を変数にバインド
│   │
│   └─ 引数2: V:Val
│       │
│       ├─ V             ← 値を変数にバインド
│       └─ Val           ← 値型の制約（Int, Bool, ChanVal等）
```

## まとめ

### symbol(chanSend) の役割

1. ✅ **曖昧性回避**: 送信と受信の `<-` を区別
2. ✅ **明示的参照**: ルールで `chanSend(...)` として参照可能
3. ✅ **可読性**: 自動生成名（`_<-_`）より読みやすい
4. ✅ **strict連携**: 評価後の形式が予測可能

### パターンマッチング chanSend(channel(...), ...)

**期待される形式**:
```k
chanSend(channel(CId:Int, T:Type), V:Val)
```

**マッチング条件**:
1. **chanSend**: `symbol(chanSend)` で定義された構文
2. **channel(CId, T)**: 評価済みのチャネル値（IDと型を含む）
3. **V**: 評価済みの送信する値

**抽出される情報**:
- `CId` - チャネルID（`<channels>` マップの検索に使用）
- `T` - 要素型（型チェックに使用）
- `V` - 送信する値（受信者に渡される）

このパターンにより、K Frameworkは：
- ✅ 評価済みの具体的な値のみマッチ
- ✅ チャネルIDと型情報を変数に抽出
- ✅ ルール内で `CId`, `T`, `V` を使用可能
- ✅ 型安全な送信操作を保証

**結論**: `symbol()` 属性と構造化パターンマッチングの組み合わせにより、K Frameworkは複雑なチャネル通信のセマンティクスを型安全かつ明確に表現できます。

## Go仕様の型制約とK実装の関係

### Go仕様における構文と型の分離

Go言語仕様では、SendStmtは以下のように定義されています：

```
SendStmt = Channel "<-" Expression .
Channel  = Expression .
```

**重要な制約**（Go仕様書より）:
> "The channel expression **must be of channel type**, the channel direction must permit send operations, and the type of the value to be sent must be assignable to the channel's element type."

つまり、Go仕様では：
- **構文レベル**: 任意の式 `<-` 任意の式（パーサーが受け入れる）
- **型レベル**: 左辺はチャネル型でなければならない（型チェッカーが検証）

### K実装での同様のアプローチ

K Frameworkの実装も同じアプローチを採用しています：

```k
// syntax/concurrent.k
// Go specification: SendStmt = Channel "<-" Expression .
// Go specification: Channel  = Expression .
// Note: We use Exp directly instead of defining a Channel alias, as it would add no semantic value.
syntax SendStmt ::= Exp "<-" Exp [strict, symbol(chanSend)]
```

**構文レベル**: 任意の式を左右に許可

```k
// semantics/concurrent.k
rule <k> chanSend(channel(CId, int), V:Int) => .K ... </k>
     ...
```

**セマンティクスレベル**: `channel(...)` 構造のみマッチ

### なぜ `1 <- 10` は構文的に許可されるのか？

**Go言語の場合:**
```
1. 構文解析: 1 <- 10
   → パース成功（任意の式が許可されているため）

2. 型チェック: 1 の型は int
   → エラー: "invalid operation: 1 <- 10 (send to non-channel type int)"
```

**K Framework実装の場合:**
```
1. 構文解析: 1 <- 10
   → パース成功
   → chanSend(1, 10)

2. strict評価:
   → chanSend(1, 10)  // 両辺とも既に値

3. セマンティクスルール適用試行:
   ルール: chanSend(channel(CId, int), V:Int)
   実際: chanSend(1, 10)
   → マッチ失敗: 1 ≠ channel(...)

4. 実行がstuckになる（適用できるルールなし）
```

### チャネル変数が正しくマッチする仕組み

#### ケース: `ch <- 10` （チャネル変数）

**初期状態:**
```k
<k> ch <- 10 ... </k>
<env> ch |-> loc(0) </env>
<store> loc(0) |-> channel(0, int) </store>
```

**評価の流れ:**

##### ステップ1: 構文解析
```k
ch <- 10
  ↓ (パース)
chanSend(ch, 10)  // [strict] 属性により両辺を評価
```

##### ステップ2: 左辺の評価（chの評価）
```k
chanSend(ch, 10)
  ↓ (変数lookupルール適用)
<k> ch ... </k>
<env> ch |-> loc(0) </env>
<store> loc(0) |-> channel(0, int) </store>
  ↓
ch => channel(0, int)
  ↓
chanSend(channel(0, int), 10)
```

**重要**: チャネル変数は評価されると `channel(id, type)` という**構造化された値**になる

##### ステップ3: 右辺の評価
```k
chanSend(channel(0, int), 10)
  ↓ (10は既に値)
chanSend(channel(0, int), 10)  // strict評価完了
```

##### ステップ4: セマンティクスルール適用
```k
実際の値: chanSend(channel(0, int), 10)
ルール:   chanSend(channel(CId, int), V:Int)

パターンマッチング:
  channel(0, int) = channel(CId, int)  ✅ CId=0にバインド
  10 = V:Int                           ✅ V=10にバインド

→ マッチ成功！セマンティクスルールが適用される
```

### なぜ整数リテラルはマッチしないのか

#### ケース: `1 <- 10` （整数リテラル）

**評価の流れ:**

##### ステップ1: 構文解析
```k
1 <- 10
  ↓ (パース)
chanSend(1, 10)  // [strict] 属性により両辺を評価
```

##### ステップ2: 左辺の評価
```k
chanSend(1, 10)
  ↓
1  // 既に値（KResult）なので評価不要
```

##### ステップ3: 右辺の評価
```k
chanSend(1, 10)
  ↓
10  // 既に値（KResult）なので評価不要
```

##### ステップ4: セマンティクスルール適用試行
```k
実際の値: chanSend(1, 10)
ルール:   chanSend(channel(CId, int), V:Int)

パターンマッチング:
  1 = channel(CId, int)  ❌ マッチ失敗

理由: 1 はただの整数値（Int型）であり、
     channel(...)という構造を持たない

→ マッチ失敗！実行がstuck
```

### 構造の違い：値の表現

**整数リテラル:**
```k
1  // ただの整数値（Int型）
   // 構造: なし
```

**チャネル変数の評価結果:**
```k
channel(0, int)  // 構造化された値（ChanVal型）
                 // 構造: channel(チャネルID, 要素型)
```

**パターンマッチングの要求:**
```k
channel(CId:Int, T:Type)
// この形式の構造を持つ値のみマッチ
```

### チャネル値の生成元

チャネル値 `channel(id, type)` は以下のルールで生成されます：

```k
// make(chan T) でチャネル作成
rule <k> make(chan T:Type) => channel(N, T) ... </k>
     <nextChanId> N:Int => N +Int 1 </nextChanId>
     <channels> Chans => Chans [ N <- chanState(.List, .List, T) ] </channels>
```

**例:**
```go
ch := make(chan int)
```

**評価の流れ:**
```k
1. make(chan int)
   → channel(0, int)  // 新しいチャネル値を生成

2. ch := channel(0, int)
   → <env> ch |-> loc(0) </env>
      <store> loc(0) |-> channel(0, int) </store>
```

その後、`ch` を参照すると：
```k
ch
  ↓ (env lookup)
loc(0)
  ↓ (store lookup)
channel(0, int)  // この値がパターンマッチング可能
```

### まとめ：型安全性の実現方法

| レベル | Go言語 | K Framework実装 |
|--------|--------|----------------|
| **構文** | `Channel "<-" Expression`<br>`Channel = Expression` | `Exp "<-" Exp` |
| **型制約** | 型チェッカーが検証<br>"channel expressionはチャネル型でなければならない" | パターンマッチングで検証<br>`chanSend(channel(...), ...)` のみマッチ |
| **エラー** | コンパイルエラー<br>"send to non-channel type" | 実行がstuck<br>（マッチするルールなし） |
| **実装の場** | 型チェックフェーズ | セマンティクス評価フェーズ |

**重要な洞察:**
- K実装は構文で自由度を保ち、セマンティクスで制約を課す
- チャネル変数は評価により `channel(id, type)` という特別な構造を持つ
- この構造がパターンマッチングの鍵となり、型安全性を保証する
- 整数リテラルなど他の値はこの構造を持たないため、自然に排除される

**Go仕様とK実装の整合性:**
Go言語仕様の「構文は柔軟、型チェックで制約」というアプローチをK Frameworkでも忠実に再現しており、構文とセマンティクスの分離という設計原則を体現しています。
