# mainスレッドのブロッキングとマルチスレッド実行

## 重要な理解：すべてのスレッドは平等

K Frameworkの実装では、**mainスレッド（tid=0）も他のgoroutine（tid=1, 2, ...）も完全に平等**に扱われます。

```k
<threads>
  <thread multiplicity="*" type="Set">
    <tid> ... </tid>
    <k> ... </k>
    ...
  </thread>
</threads>
```

`multiplicity="*"` により、任意の数のスレッドが存在でき、K Frameworkはそれらをすべて同じように扱います。

## mainスレッドがブロックしても実行は継続する

### 核心的な仕組み

1. **ルールマッチングはグローバル**
   - K Frameworkは、**すべてのスレッド**を対象にルールマッチングを行う
   - あるスレッドがブロックしても、他のスレッドで適用できるルールがあれば、そちらが実行される

2. **非決定的スレッド選択**
   - 複数のスレッドでルールが適用可能な場合、K Frameworkが非決定的に選択
   - mainスレッドが優先されることはない

3. **ブロック解除は他スレッドの動作による**
   - スレッドAがブロック（`waitingSend` or `waitingRecv`）
   - スレッドBが実行（チャネル操作）
   - スレッドBの操作がスレッドAにマッチするルールをトリガー
   - スレッドAのブロック解除

## 具体例1: mainスレッドがブロック、goroutineが解除

### コード

```go
func sender(ch chan int, val int) {
    ch <- val;
    print(1);
}

func main() {
    ch := make(chan int);
    go sender(ch, 42);
    result := <-ch;  // ← mainスレッドがブロック
    print(result);
}
```

### 実行トレース

#### 初期状態（簡略化）

```k
<threads>
  <thread>
    <tid> 0 </tid>  ← mainスレッド
    <k> go sender(ch, 42) ~> result := <-ch ~> print(result) ~> .K </k>
    <env> ch |-> 0 </env>
  </thread>
</threads>

<channels>
  0 |-> chanState(.List, .List, int)
</channels>
```

#### ステップ1: Goroutine生成

```k
<threads>
  <thread>
    <tid> 0 </tid>  ← mainスレッド
    <k> result := <-ch ~> print(result) ~> .K </k>
    <env> ch |-> 0 </env>
  </thread>

  <thread>
    <tid> 1 </tid>  ← 新しいgoroutine
    <k> ch <- 42 ~> print(1) ~> .K </k>
    <env> ch |-> 0, val |-> 1 </env>
  </thread>
</threads>

<store>
  0 |-> channel(0, int)
  1 |-> 42
</store>
```

**実行可能なスレッド**: 両方（スレッド0とスレッド1）

#### ステップ2: mainスレッドが受信を試みる（非決定的選択）

K Frameworkがスレッド0を選択したと仮定：

**strict評価**: `<-ch` → `chanRecv(channel(0, int))`

**適用ルール**: 受信者ブロックルール（送信者がまだいない）

```k
<threads>
  <thread>
    <tid> 0 </tid>  ← mainスレッド（★ブロック中★）
    <k> waitingRecv(0) ~> print(result) ~> .K </k>
    <env> ch |-> 0 </env>
  </thread>

  <thread>
    <tid> 1 </tid>  ← goroutine（実行可能）
    <k> ch <- 42 ~> print(1) ~> .K </k>
    <env> ch |-> 0, val |-> 1 </env>
  </thread>
</threads>

<channels>
  0 |-> chanState(.List, ListItem(0), int)
  //                     ^^^^^^^^^^^^
  //                     mainスレッドが受信待ち
</channels>
```

**重要なポイント**:
- mainスレッド（tid=0）は `waitingRecv(0)` でブロック
- しかし、goroutine（tid=1）は**実行可能**
- K Frameworkはスレッド1でルールマッチングを続ける

#### ステップ3: goroutineが送信（mainのブロックを解除）

**実行可能なスレッド**: スレッド1のみ（スレッド0はブロック中）

K Frameworkはスレッド1を選択：

**strict評価**: `ch <- 42` → `chanSend(channel(0, int), 42)`

**適用ルール**: 送信-受信マッチングルール

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
       <k> waitingRecv(CId) => V ... </k>  ← ★ここがmainスレッド！
     ...</thread>
```

**マッチング**:
- `SenderTid` = 1（goroutine）
- `RecvTid` = 0（**mainスレッド**）
- `V` = 42

**書き換え後**:

```k
<threads>
  <thread>
    <tid> 0 </tid>  ← mainスレッド（★ブロック解除！★）
    <k> 42 ~> print(result) ~> .K </k>
    <env> ch |-> 0 </env>
  </thread>

  <thread>
    <tid> 1 </tid>  ← goroutine（送信完了）
    <k> print(1) ~> .K </k>
    <env> ch |-> 0, val |-> 1 </env>
  </thread>
</threads>

<channels>
  0 |-> chanState(.List, .List, int)
</channels>
```

**重要なポイント**:
- goroutine（スレッド1）の `chanSend(...)` が実行されることで
- mainスレッド（スレッド0）の `waitingRecv(0)` が `42` に書き換わる
- これによりmainスレッドのブロックが解除され、実行が再開

#### ステップ4: 両スレッドが実行継続

**実行可能なスレッド**: 両方

非決定的に実行され、最終的に：
- mainスレッド: `result := 42` → `print(42)` → 出力 `42`
- goroutine: `print(1)` → 出力 `1`

## 具体例2: goroutineがブロック、mainが解除

### コード

```go
func receiver(ch chan int) {
    result := <-ch;  // ← goroutineがブロック
    print(result);
}

func main() {
    ch := make(chan int);
    go receiver(ch);
    ch <- 99;  // ← mainスレッドが送信してgoroutineを解除
    print(1);
}
```

### 実行トレース（簡略版）

#### ステップ1-2: Goroutine生成と受信試行

```k
<threads>
  <thread>
    <tid> 0 </tid>  ← mainスレッド（実行可能）
    <k> ch <- 99 ~> print(1) ~> .K </k>
    <env> ch |-> 0 </env>
  </thread>

  <thread>
    <tid> 1 </tid>  ← goroutine（★ブロック中★）
    <k> waitingRecv(0) ~> print(result) ~> .K </k>
    <env> ch |-> 0 </env>
  </thread>
</threads>

<channels>
  0 |-> chanState(.List, ListItem(1), int)
  //                     ^^^^^^^^^^^^
  //                     goroutineが受信待ち
</channels>
```

**実行可能なスレッド**: スレッド0（main）のみ

#### ステップ3: mainが送信（goroutineのブロックを解除）

K Frameworkはスレッド0を選択：

**strict評価**: `ch <- 99` → `chanSend(channel(0, int), 99)`

**適用ルール**: 送信-受信マッチングルール

**マッチング**:
- `SenderTid` = 0（**mainスレッド**）
- `RecvTid` = 1（goroutine）
- `V` = 99

**書き換え後**:

```k
<threads>
  <thread>
    <tid> 0 </tid>  ← mainスレッド（送信完了）
    <k> print(1) ~> .K </k>
    <env> ch |-> 0 </env>
  </thread>

  <thread>
    <tid> 1 </tid>  ← goroutine（★ブロック解除！★）
    <k> 99 ~> print(result) ~> .K </k>
    <env> ch |-> 0 </env>
  </thread>
</threads>

<channels>
  0 |-> chanState(.List, .List, int)
</channels>
```

**重要なポイント**:
- mainスレッド（スレッド0）の `chanSend(...)` が実行されることで
- goroutine（スレッド1）の `waitingRecv(0)` が `99` に書き換わる
- goroutineのブロックが解除

## ルールマッチングの仕組み

### ルールは複数スレッドにまたがる

送信-受信マッチングルールを見ると：

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

このルールは**2つの異なる`<thread>`セル**を同時にマッチング：
- 1つ目: 送信者のスレッド
- 2つ目: 受信者のスレッド（ブロック中）

**どちらがmainでどちらがgoroutineかは関係ない**：
- mainが送信、goroutineが受信 → マッチ
- goroutineが送信、mainが受信 → マッチ
- goroutine1が送信、goroutine2が受信 → マッチ

### K Frameworkのスレッド選択

K Frameworkは以下のように動作：

1. **すべてのスレッドをスキャン**
   - 各スレッドの `<k>` セルを確認
   - 適用可能なルールを探す

2. **適用可能なルールから非決定的に選択**
   - スレッド0で適用可能なルール
   - スレッド1で適用可能なルール
   - スレッド0とスレッド1にまたがるルール
   - これらすべてから1つを非決定的に選択

3. **ルールを適用**
   - 選択されたルールを実行
   - 影響を受けるすべてのセルを書き換え

4. **繰り返し**
   - ステップ1に戻る

**mainスレッドに特別な優先順位はない**。

## 実際のGoとの対応

### Go言語のランタイム

実際のGoランタイムも同様の動作をします：

```go
func main() {
    ch := make(chan int)
    go func() { ch <- 42 }()
    result := <-ch  // mainもブロック可能
    fmt.Println(result)
}
```

- mainがブロックしても、goroutineスケジューラーは他のgoroutineを実行
- goroutineが送信すると、mainがブロック解除されて再開
- mainは特別なgoroutineではなく、他のgoroutineと同じスケジューリング対象

### この実装の忠実性

K Frameworkの実装は、この動作を**正確に再現**しています：

| Go言語 | K Framework実装 |
|--------|----------------|
| goroutineスケジューラー | K Frameworkのルールマッチング |
| mainもgoroutineの1つ | tid=0のスレッドも他と平等 |
| チャネルブロッキング | `waitingSend`/`waitingRecv`でルール不適用 |
| ブロック解除 | マルチスレッドルールによる状態書き換え |
| 非決定的実行順序 | K Frameworkの非決定的選択 |

## デッドロックの例

### すべてのスレッドがブロックする場合

```go
func main() {
    ch := make(chan int)
    <-ch  // 送信者がいないので永久にブロック
}
```

**状態**:
```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k> waitingRecv(0) ~> ... </k>
  </thread>
</threads>

<channels>
  0 |-> chanState(.List, ListItem(0), int)
</channels>
```

**実行可能なルール**: なし
- スレッド0は `waitingRecv(0)` でブロック
- 他のスレッドが存在しない
- `waitingRecv(0)` に適用できるルールは、送信者が現れることを要求
- 送信者が永遠に現れない

**結果**: 実行完全停止（デッドロック）

### 複数スレッドがすべてブロック

```go
func main() {
    ch1 := make(chan int)
    ch2 := make(chan int)

    go func() { ch1 <- (<-ch2) }()  // ch2からの受信を待つ
    ch2 <- (<-ch1)                   // ch1からの受信を待つ
}
```

**状態**:
```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k> chanSend(channel(1, int), waitingRecv(0)) ... </k>  ← ch1を待つ
  </thread>
  <thread>
    <tid> 1 </tid>
    <k> chanSend(channel(0, int), waitingRecv(1)) ... </k>  ← ch2を待つ
  </thread>
</threads>
```

実際には評価の順序により異なりますが、循環待機が発生してデッドロックになります。

**Go言語**: このようなデッドロックを検出して `fatal error: all goroutines are asleep - deadlock!` を出力

**K Framework実装**: デッドロック検出は未実装のため、実行が単に停止

## まとめ

### 質問への回答

> mainスレッドとして扱っているから、そこでブロック起きても別スレッドのライティングルールが動いてブロックが解除されるということですか

**答え**: はい、その通りです！

### 重要なポイント

1. ✅ **mainスレッドは特別ではない**
   - tid=0のスレッドも他のgoroutine（tid=1, 2, ...）も完全に平等
   - K Frameworkは区別しない

2. ✅ **ルールマッチングはグローバル**
   - すべてのスレッドを対象にルールマッチング
   - あるスレッドがブロックしても、他のスレッドで実行可能

3. ✅ **マルチスレッドルール**
   - 送信-受信マッチングルールは2つのスレッドにまたがる
   - どちらがmainでどちらがgoroutineかは関係ない

4. ✅ **非決定的スケジューリング**
   - K Frameworkが実行可能なルールから非決定的に選択
   - mainスレッドに優先順位なし

5. ✅ **ブロック解除は他スレッドの動作による**
   - スレッドAがブロック → スレッドBが実行 → スレッドAのブロック解除
   - mainがブロック → goroutineが実行 → mainのブロック解除（可能）
   - goroutineがブロック → mainが実行 → goroutineのブロック解除（可能）

### 実際のGoとの対応

この実装は、実際のGoのgoroutineスケジューリングを忠実に再現しています。mainも単なるgoroutineの1つとして扱われ、他のgoroutineと同様にブロック・再開します。

**K Frameworkのルールシステム**により、明示的なスレッドスケジューラーを実装することなく、マルチスレッド実行とブロッキング同期を自然に表現できています。
