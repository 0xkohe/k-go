# Go並行処理機能の実装（Goroutines & Channels）

本ドキュメントでは、K Frameworkを使用したGoの並行処理機能の実装について説明します。

## 目次

1. [概要](#概要)
2. [Goroutinesの実装](#goroutinesの実装)
3. [Channelsの実装](#channelsの実装)
4. [close(ch)の実装](#closechの実装)
5. [実装の技術詳細](#実装の技術詳細)
6. [制限事項と今後の拡張](#制限事項と今後の拡張)

---

## 概要

### 実装済みの機能

| 機能 | 状態 | 説明 |
|------|------|------|
| `go f()` | ✅ 完全実装 | 新しいgoroutineを起動 |
| `make(chan T)` | ✅ 完全実装 | アンバッファードチャネル作成 |
| `make(chan T, n)` | ✅ 完全実装 | バッファ付きチャネル作成 |
| `ch <- v` | ✅ 完全実装 | チャネルへの送信 |
| `v := <-ch` | ✅ 完全実装 | チャネルからの受信 |
| `close(ch)` | ✅ 完全実装 | チャネルのクローズ |
| `for v := range ch` | ✅ 完全実装 | チャネルのイテレーション |
| `v, ok := <-ch` | ⚠️ 部分実装 | クローズ検出（構文は定義済み） |

### サポートするチャネル型

- `chan int` - 整数型チャネル
- `chan bool` - 真偽値型チャネル

---

## Goroutinesの実装

### 基本的な使い方

```go
package main

func worker(id int) {
    print(id)
}

func main() {
    go worker(1);
    go worker(2);
    go worker(3)
}
```

**実行結果の例:**
```
1
2
3
```
（実行順序は非決定的）

#### 適用されるルール

**ルール定義 (semantics/concurrent.k:38-57):**
```k
rule <thread>...
       <tid> ParentTid </tid>
       <k> go FCall:Exp => .K ... </k>
       <tenv> TEnv </tenv>
       <env> Env </env>
       <constEnv> CEnv </constEnv>
     ...</thread>
     (.Bag =>
       <thread>...
         <tid> N </tid>
         <k> FCall </k>
         <tenv> TEnv </tenv>
         <env> Env </env>
         <envStack> .List </envStack>
         <tenvStack> .List </tenvStack>
         <constEnv> CEnv </constEnv>
         <constEnvStack> .List </constEnvStack>
         <scopeDecls> .List </scopeDecls>
       ...</thread>)
     <nextTid> N:Int => N +Int 1 </nextTid>
```

#### 実行トレース

**ステップ1: `go worker(1)` の実行**
```
初期状態:
<thread>
  <tid> 0 </tid>
  <k> go worker(1) ~> go worker(2) ~> go worker(3) ~> .K </k>
  <tenv> worker |-> func(int) </tenv>
  <env> .Map </env>
</thread>
<nextTid> 1 </nextTid>

適用ルール: go statement (goroutine作成)
- FCall = worker(1)
- TEnv = worker |-> func(int)
- N = 1

実行後:
<thread>  // メインスレッド
  <tid> 0 </tid>
  <k> go worker(2) ~> go worker(3) ~> .K </k>
</thread>
<thread>  // 新しいスレッド
  <tid> 1 </tid>
  <k> worker(1) </k>
  <tenv> worker |-> func(int) </tenv>
</thread>
<nextTid> 2 </nextTid>
```

**ステップ2: `go worker(2)` の実行**
```
同様に <tid> 2 のスレッドが作成される
<nextTid> 3 </nextTid>
```

**ステップ3: `go worker(3)` の実行**
```
同様に <tid> 3 のスレッドが作成される
<nextTid> 4 </nextTid>
```

**ステップ4: 各スレッドが並行実行**
```
Thread 1: worker(1) → print(1) → 出力: 1
Thread 2: worker(2) → print(2) → 出力: 2
Thread 3: worker(3) → print(3) → 出力: 3
```

**重要なポイント:**
- 親スレッドの環境（TEnv, Env, CEnv）が子スレッドに**コピー**される
- `go` 文自体は即座に `.K` に書き換わり、メインスレッドは続行
- 新しいスレッドは独立して実行される
- 実行順序は K Framework のルール適用順に依存（非決定的）

### 複数のgoroutineでの計算

```go
package main

func compute(x int, y int) {
    result := x + y;
    print(result)
}

func main() {
    go compute(10, 20);
    go compute(5, 15);
    go compute(1, 1)
}
```

**実行結果の例:**
```
30
20
2
```

### 技術的な詳細

- 各goroutineは独立した`<thread>`セルで表現
- スレッドIDは`<nextTid>`で管理
- 環境（`<tenv>`, `<env>`, `<constEnv>`）は親スレッドから継承
- グローバルストア（`<store>`）は全スレッドで共有

---

## Channelsの実装

### アンバッファードチャネル

同期通信を実現します。送信者は受信者が現れるまでブロックされます。

```go
package main

func sender(ch chan int) {
    print(100);
    ch <- 42;
    print(200)
}

func receiver(ch chan int) {
    print(300);
    v := <-ch;
    print(v)
}

func main() {
    ch := make(chan int);
    go sender(ch);
    go receiver(ch)
}
```

**実行結果の例:**
```
100
300
42
200
```

**動作説明:**
1. `sender` が `print(100)` を実行
2. `sender` が `ch <- 42` でブロック（受信者待ち）
3. `receiver` が `print(300)` を実行
4. `receiver` が `<-ch` で受信し、`sender` のブロック解除
5. 両方が続行

#### 適用されるルール

**1. チャネル作成 (semantics/concurrent.k:98-100):**
```k
rule <k> make(chan T:Type) => channel(N, T) ... </k>
     <nextChanId> N:Int => N +Int 1 </nextChanId>
     <channels> Chans => Chans [ N <- chanState(.List, .List, .List, 0, T, false) ] </channels>
```

**2. 送信（受信者がいない場合） - Priority 3 (semantics/concurrent.k:156-164):**
```k
rule <thread>...
       <tid> Tid </tid>
       <k> chanSend(channel(CId, int), V:Int) => waitingSend(CId, V) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, .List, Buf, Size, int, false)
            => chanState(SendQ ListItem(sendItem(Tid, V)), .List, Buf, Size, int, false))
     ...</channels>
  requires size(Buf) >=Int Size
```

**3. 受信（送信者待ち） - Priority 3 (semantics/concurrent.k:241-253):**
```k
rule <thread>...
       <tid> RecvTid </tid>
       <k> chanRecv(channel(CId, T)) => V ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState((ListItem(sendItem(SendTid:Int, V)) SendRest:List), RecvQ, .List, Size, T, Closed)
            => chanState(SendRest, RecvQ, .List, Size, T, Closed))
     ...</channels>
     <thread>...
       <tid> SendTid </tid>
       <k> waitingSend(CId, _) => .K ... </k>
     ...</thread>
```

#### 実行トレース

**ステップ1: `make(chan int)` の実行**
```
<k> make(chan int) ~> ... </k>
<channels> .Map </channels>
<nextChanId> 0 </nextChanId>

↓ make ルール適用

<k> channel(0, int) ~> ... </k>
<channels> 0 |-> chanState(.List, .List, .List, 0, int, false) </channels>
<nextChanId> 1 </nextChanId>

説明: bufferSize=0 のアンバッファードチャネルが作成される
```

**ステップ2: Sender と Receiver の goroutine 作成**
```
Thread 1 (sender):
  <k> print(100) ~> ch <- 42 ~> print(200) </k>

Thread 2 (receiver):
  <k> print(300) ~> v := <-ch ~> print(v) </k>
```

**ステップ3: Sender が `print(100)` を実行**
```
<out> ListItem(100) </out>

Thread 1: <k> ch <- 42 ~> print(200) </k>
```

**ステップ4: Sender が `ch <- 42` でブロック**
```
適用ルール: 送信（受信者なし、バッファなし）

初期状態:
<channels>
  0 |-> chanState(.List, .List, .List, 0, int, false)
           // sendQ  recvQ  buffer  size
</channels>
Thread 1: <k> chanSend(channel(0, int), 42) ~> print(200) </k>

↓ Priority 3 ルール適用（バッファフル: size(Buf)=0 >=Int Size=0）

実行後:
<channels>
  0 |-> chanState(ListItem(sendItem(1, 42)), .List, .List, 0, int, false)
           // Sender Tid=1 が値 42 を持って待機
</channels>
Thread 1: <k> waitingSend(0, 42) ~> print(200) </k>  // ブロック状態
```

**ステップ5: Receiver が `print(300)` を実行**
```
<out> ListItem(100) ListItem(300) </out>

Thread 2: <k> v := <-ch ~> print(v) </k>
```

**ステップ6: Receiver が `<-ch` で受信 → Sender のブロック解除**
```
適用ルール: 受信（送信者待ち、バッファ空）

初期状態:
<channels>
  0 |-> chanState(ListItem(sendItem(1, 42)), .List, .List, 0, int, false)
</channels>
Thread 1: <k> waitingSend(0, 42) ~> print(200) </k>
Thread 2: <k> chanRecv(channel(0, int)) ~> print(v) </k>

↓ Priority 3 ルール適用（送信待ちがいる、バッファ空）

実行後:
<channels>
  0 |-> chanState(.List, .List, .List, 0, int, false)
           // sendQ が空になる
</channels>
Thread 1: <k> .K ~> print(200) </k>  // ブロック解除！
Thread 2: <k> 42 ~> print(v) </k>    // 42 を受信
```

**ステップ7: 両スレッドが続行**
```
Thread 1: print(200) → 出力: 200
Thread 2: v := 42, print(42) → 出力: 42

最終出力:
100
300
42
200
```

**重要なポイント:**
- **同期通信**: 送信者と受信者が揃うまでブロック（ランデブー）
- **sendQueue**: 送信待ちスレッドの ID と値を記録
- **ブロック解除**: 受信時に送信者の `waitingSend` が `.K` に書き換わる

### バッファ付きチャネル

非同期通信を実現します。バッファに空きがあれば送信者はブロックされません。

```go
package main

func main() {
    ch := make(chan int, 3);

    // ノンブロッキング送信（バッファに空きあり）
    ch <- 1;
    ch <- 2;
    ch <- 3;

    // 受信
    v1 := <-ch;
    print(v1);

    v2 := <-ch;
    print(v2);

    v3 := <-ch;
    print(v3)
}
```

**実行結果:**
```
1
2
3
```

#### 適用されるルール

**1. バッファ付きチャネル作成 (semantics/concurrent.k:103-106):**
```k
rule <k> make(chan T:Type, Size:Int) => channel(N, T) ... </k>
     <nextChanId> N:Int => N +Int 1 </nextChanId>
     <channels> Chans => Chans [ N <- chanState(.List, .List, .List, Size, T, false) ] </channels>
  requires Size >=Int 0
```

**2. 送信（バッファに空きあり） - Priority 2 (semantics/concurrent.k:145-153):**
```k
rule <thread>...
       <tid> Tid </tid>
       <k> chanSend(channel(CId, int), V:Int) => .K ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, .List, Buf, Size, int, false)
            => chanState(SendQ, .List, Buf ListItem(V), Size, int, false))
     ...</channels>
  requires size(Buf) <Int Size
```

**3. 受信（バッファから取り出し） - Priority 2 (semantics/concurrent.k:231-239):**
```k
rule <thread>...
       <tid> Tid </tid>
       <k> chanRecv(channel(CId, T)) => V ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, RecvQ, (ListItem(V) BufRest:List), Size, T, Closed)
            => chanState(SendQ, RecvQ, BufRest, Size, T, Closed))
     ...</channels>
```

#### 実行トレース

**ステップ1: `make(chan int, 3)` の実行**
```
<k> make(chan int, 3) ~> ... </k>
<channels> .Map </channels>
<nextChanId> 0 </nextChanId>

↓ make (バッファ付き) ルール適用

<k> channel(0, int) ~> ... </k>
<channels> 0 |-> chanState(.List, .List, .List, 3, int, false) </channels>
                         // sendQ  recvQ  buffer  bufSize=3
<nextChanId> 1 </nextChanId>
```

**ステップ2: `ch <- 1` の実行**
```
適用ルール: 送信（バッファに空きあり）

初期状態:
<channels>
  0 |-> chanState(.List, .List, .List, 3, int, false)
</channels>
<k> chanSend(channel(0, int), 1) ~> ch <- 2 ~> ... </k>

条件チェック: size(Buf)=0 <Int Size=3 ✓

↓ Priority 2 ルール適用（即座に完了、ノンブロッキング）

実行後:
<channels>
  0 |-> chanState(.List, .List, ListItem(1), 3, int, false)
                         //     buffer=[1]
</channels>
<k> .K ~> ch <- 2 ~> ... </k>
```

**ステップ3: `ch <- 2` と `ch <- 3` の実行**
```
同様に Priority 2 ルールが適用される

ch <- 2 後:
<channels>
  0 |-> chanState(.List, .List, ListItem(1) ListItem(2), 3, int, false)
                         //     buffer=[1, 2]
</channels>

ch <- 3 後:
<channels>
  0 |-> chanState(.List, .List, ListItem(1) ListItem(2) ListItem(3), 3, int, false)
                         //     buffer=[1, 2, 3]  ← フル
</channels>
```

**ステップ4: `v1 := <-ch` の実行**
```
適用ルール: 受信（バッファから取り出し）

初期状態:
<channels>
  0 |-> chanState(.List, .List, ListItem(1) ListItem(2) ListItem(3), 3, int, false)
</channels>
<k> chanRecv(channel(0, int)) ~> ... </k>

↓ Priority 2 ルール適用（先頭から取り出し - FIFO）

実行後:
<channels>
  0 |-> chanState(.List, .List, ListItem(2) ListItem(3), 3, int, false)
                         //     buffer=[2, 3]
</channels>
<k> 1 ~> ... </k>  // 値 1 を返す
```

**ステップ5: `v2 := <-ch` と `v3 := <-ch` の実行**
```
v2 := <-ch:
  buffer=[2, 3] → buffer=[3]
  return 2

v3 := <-ch:
  buffer=[3] → buffer=[]
  return 3

最終状態:
<channels>
  0 |-> chanState(.List, .List, .List, 3, int, false)
                         //     buffer=[] (空)
</channels>
<out> ListItem(1) ListItem(2) ListItem(3) </out>
```

**重要なポイント:**
- **非同期通信**: バッファに空きがあれば送信は即座に完了
- **FIFO順序**: 送信順と受信順が保証される（ListItem の順序）
- **条件チェック**: `size(Buf) <Int Size` でバッファの空き確認

### バッファがフルになった場合

```go
package main

func producer(ch chan int) {
    ch <- 1;
    print(10);
    ch <- 2;
    print(20);
    ch <- 3;
    print(30);
    ch <- 4;  // バッファフル、受信者を待つ
    print(40)
}

func consumer(ch chan int) {
    v := <-ch;
    print(v)
}

func main() {
    ch := make(chan int, 3);
    go producer(ch);
    go consumer(ch)
}
```

**実行結果の例:**
```
10
20
30
1
40
```

**動作説明:**
1. Producer が 1, 2, 3 を送信（バッファに空きあり）
2. Producer が 4 を送信しようとしてブロック（バッファフル）
3. Consumer が 1 を受信、バッファに空きができる
4. Producer のブロック解除、40 を出力

### FIFO順序の保証

```go
package main

func main() {
    ch := make(chan int, 5);

    ch <- 10;
    ch <- 20;
    ch <- 30;
    ch <- 40;
    ch <- 50;

    print(<-ch);
    print(<-ch);
    print(<-ch);
    print(<-ch);
    print(<-ch)
}
```

**実行結果:**
```
10
20
30
40
50
```
（送信順と受信順が一致）

---

## close(ch)の実装

### 基本的な使い方

```go
package main

func main() {
    ch := make(chan int, 3);
    ch <- 1;
    ch <- 2;
    ch <- 3;
    close(ch);

    v1 := <-ch;
    print(v1);

    v2 := <-ch;
    print(v2);

    v3 := <-ch;
    print(v3);

    v4 := <-ch;  // クローズ済み、ゼロ値を返す
    print(v4)
}
```

**実行結果:**
```
1
2
3
0
```

**動作説明:**
- バッファの値（1, 2, 3）を受信
- バッファが空になった後は、ゼロ値（int の場合は 0）を返す

#### 適用されるルール

**1. close 構文定義 (syntax/concurrent.k:49-50):**
```k
syntax CloseStmt ::= "close" "(" Exp ")" [strict(1)]
syntax Statement ::= CloseStmt
```

**2. close 実行 (semantics/concurrent.k:294-302):**
```k
rule <thread>...
       <tid> Tid </tid>
       <k> close(channel(CId, int)) => wakeReceivers(RecvQ, CId, 0) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, RecvQ, Buf, Size, int, false)
            => chanState(SendQ, .List, Buf, Size, int, true))
     ...</channels>
```

**3. クローズ済みチャネルからの受信 - Priority 4 (semantics/concurrent.k:257-264):**
```k
rule <thread>...
       <tid> Tid </tid>
       <k> chanRecv(channel(CIdClosed, int)) => 0 ... </k>
     ...</thread>
     <channels>...
       CIdClosed |-> chanState(.List, _RecvQ, .List, _Size, int, true)
     ...</channels>
```

**4. クローズ済みチャネルへの送信 - Priority 0 (semantics/concurrent.k:122-129):**
```k
rule <thread>...
       <tid> Tid </tid>
       <k> chanSend(channel(CId, int), V:Int) => SendClosedPanic ... </k>
     ...</thread>
     <channels>...
       CId |-> chanState(_SendQ, _RecvQ, _Buf, _Size, int, true)
     ...</channels>
```

#### 実行トレース

**ステップ1-3: バッファに値を送信**
```
ch <- 1, ch <- 2, ch <- 3 の実行（前述と同様）

結果:
<channels>
  0 |-> chanState(.List, .List,
                  ListItem(1) ListItem(2) ListItem(3),
                  3, int, false)
                  //     buffer=[1,2,3]  closed=false
</channels>
```

**ステップ4: `close(ch)` の実行**
```
適用ルール: close 実行

初期状態:
<channels>
  0 |-> chanState(.List, .List,
                  ListItem(1) ListItem(2) ListItem(3),
                  3, int, false)
</channels>
<k> close(channel(0, int)) ~> ... </k>

↓ close ルール適用

実行後:
<channels>
  0 |-> chanState(.List, .List,
                  ListItem(1) ListItem(2) ListItem(3),
                  3, int, true)
                  //     closed=true に変更
                  //     recvQ=.List（待機受信者をクリア）
</channels>
<k> wakeReceivers(.List, 0, 0) ~> ... </k>
// RecvQが空なので、wakeReceiversは何もせずに完了
```

**ステップ5: `v1 := <-ch` の実行**
```
適用ルール: 受信（バッファから取り出し） - Priority 2

<channels>
  0 |-> chanState(.List, .List,
                  ListItem(1) ListItem(2) ListItem(3),
                  3, int, true)
</channels>

↓ Priority 2 ルール適用（バッファに値あり）

<channels>
  0 |-> chanState(.List, .List,
                  ListItem(2) ListItem(3),
                  3, int, true)
</channels>
<k> 1 ~> ... </k>

注意: closed=true でもバッファに値がある間は通常受信
```

**ステップ6-7: `v2 := <-ch`, `v3 := <-ch` の実行**
```
同様にバッファから取り出し

v2 受信後:
  buffer=[3], return 2

v3 受信後:
  buffer=[], return 3
```

**ステップ8: `v4 := <-ch` の実行（バッファ空、クローズ済み）**
```
適用ルール: クローズ済みチャネルからの受信 - Priority 4

初期状態:
<channels>
  0 |-> chanState(.List, .List, .List, 3, int, true)
                  //     buffer=[]  closed=true
</channels>
<k> chanRecv(channel(0, int)) ~> ... </k>

条件チェック:
- buffer = .List ✓
- closed = true ✓

↓ Priority 4 ルール適用（ゼロ値を返す）

実行後:
<k> 0 ~> ... </k>  // int のゼロ値 0 を返す

最終出力:
<out> ListItem(1) ListItem(2) ListItem(3) ListItem(0) </out>
```

**重要なポイント:**
- **closed フラグ**: ChanState に Bool 型の closed フラグを追加
- **バッファ優先**: クローズ後もバッファの値は受信可能
- **ゼロ値**: バッファが空でクローズ済みならゼロ値を返す
- **panic**: クローズ済みチャネルへの送信は Priority 0 で panic

### for range によるイテレーション

```go
package main

func main() {
    ch := make(chan int, 3);
    ch <- 1;
    ch <- 2;
    ch <- 3;
    close(ch);

    for v := range ch {
        print(v);
    };

    print(999)
}
```

**実行結果:**
```
1
2
3
999
```

**動作説明:**
- `for range` はチャネルから値を受信し続ける
- チャネルがクローズされてバッファが空になると自動的にループ終了
- ループ後の処理（`print(999)`）が実行される

#### 適用されるルール

**1. for range 構文の脱糖 (semantics/concurrent.k:383-384):**
```k
rule <k> for ((X:Id , .IdentifierList) := range Ch:ChanVal) B:Block
      => enterScope(X := 0 ~> rangeChannelLoop(X, Ch, B)) ... </k>
```

**2. ループ継続（バッファに値あり） (semantics/concurrent.k:393-400):**
```k
rule <thread>...
       <tid> Tid </tid>
       <k> rangeChannelLoop(X, channel(CId, T), B)
        => X = <-channel(CId, T) ~> B ~> rangeChannelLoop(X, channel(CId, T), B) ... </k>
     ...</thread>
     <channels>...
       CId |-> chanState(_SendQ, _RecvQ, (ListItem(_V) _BufRest:List), _Size, T, _Closed)
     ...</channels>
```

**3. ループ終了（クローズ済み、バッファ空） (semantics/concurrent.k:412-419):**
```k
rule <thread>...
       <tid> Tid </tid>
       <k> rangeChannelLoop(_X, channel(CId, TRange), _B) => exitScope ... </k>
     ...</thread>
     <channels>...
       CId |-> chanState(.List, _RecvQ, .List, _Size, TRange, true)
     ...</channels>
```

#### 実行トレース

**ステップ1: `for v := range ch` の脱糖**
```
初期状態:
<k> for ((v, .IdentifierList) := range channel(0, int)) {print(v);} ~> print(999) </k>

↓ for range 脱糖ルール適用

実行後:
<k> enterScope(v := 0 ~> rangeChannelLoop(v, channel(0, int), {print(v);})) ~> print(999) </k>

説明: ループ変数 v を初期化し、rangeChannelLoop を開始
```

**ステップ2: rangeChannelLoop の1回目（buffer=[1,2,3]）**
```
適用ルール: ループ継続（バッファに値あり）

初期状態:
<channels>
  0 |-> chanState(.List, .List,
                  ListItem(1) ListItem(2) ListItem(3),
                  3, int, true)
</channels>
<k> rangeChannelLoop(v, channel(0, int), {print(v);}) ~> exitScope ~> print(999) </k>

条件チェック: buffer に ListItem(1) が存在 ✓

↓ ループ継続ルール適用

実行後:
<k> v = <-channel(0, int) ~> {print(v);} ~> rangeChannelLoop(v, channel(0, int), {print(v);}) ~> exitScope ~> print(999) </k>

処理:
1. v = <-channel(0, int) → v = 1 (buffer=[2,3])
2. print(v) → 出力: 1
3. 次のループへ
```

**ステップ3: rangeChannelLoop の2回目（buffer=[2,3]）**
```
同様にループ継続

処理:
1. v = <-channel(0, int) → v = 2 (buffer=[3])
2. print(v) → 出力: 2
3. 次のループへ
```

**ステップ4: rangeChannelLoop の3回目（buffer=[3]）**
```
同様にループ継続

処理:
1. v = <-channel(0, int) → v = 3 (buffer=[])
2. print(v) → 出力: 3
3. 次のループへ
```

**ステップ5: rangeChannelLoop の終了判定（buffer=[], closed=true）**
```
適用ルール: ループ終了（クローズ済み、バッファ空）

初期状態:
<channels>
  0 |-> chanState(.List, .List, .List, 3, int, true)
                  //     buffer=[]  closed=true
</channels>
<k> rangeChannelLoop(v, channel(0, int), {print(v);}) ~> exitScope ~> print(999) </k>

条件チェック:
- buffer = .List ✓
- closed = true ✓

↓ ループ終了ルール適用

実行後:
<k> exitScope ~> print(999) </k>

説明: rangeChannelLoop が exitScope に置き換わり、ループ終了
```

**ステップ6: exitScope と print(999) の実行**
```
<k> exitScope ~> print(999) </k>

↓ exitScope 実行（スコープから抜ける）

<k> print(999) </k>

↓ print 実行

<out> ListItem(1) ListItem(2) ListItem(3) ListItem(999) </out>

最終出力:
1
2
3
999
```

**重要なポイント:**
- **自動終了**: `closed=true && buffer=[]` でループ自動終了
- **脱糖化**: `for range` は `rangeChannelLoop` に変換される
- **ループ変数**: 初回に `v := 0` で初期化、各イテレーションで代入
- **exitScope**: ループ終了時にスコープを抜ける（ループ変数を破棄）

### Producer-Consumer パターン

```go
package main

func producer(ch chan int) {
    ch <- 10;
    ch <- 20;
    ch <- 30;
    close(ch)
}

func consumer(ch chan int) {
    for v := range ch {
        print(v);
    };
    print(999)
}

func main() {
    ch := make(chan int, 3);
    go producer(ch);
    go consumer(ch)
}
```

**実行結果の例:**
```
10
20
30
999
```

### close の安全性

#### クローズ済みチャネルへの送信（panic）

```go
package main

func main() {
    ch := make(chan int, 1);
    close(ch);
    ch <- 42  // panic: send on closed channel
}
```

**実行結果:**
プログラムが停止（panic）

#### 重複 close（panic）

```go
package main

func main() {
    ch := make(chan int);
    close(ch);
    close(ch)  // panic: close of closed channel
}
```

**実行結果:**
プログラムが停止（panic）

---

## 実装の技術詳細

### アーキテクチャ概要

#### ファイル構造

```
src/go/
├── concurrent.k               # メインの集約ファイル
├── syntax/
│   └── concurrent.k          # 並行処理の構文定義
└── semantics/
    └── concurrent.k          # 並行処理のセマンティクス
```

### K Configuration 構造

```k
<T>
  <threads>
    <thread multiplicity="*">
      <tid> 0 </tid>                    // スレッドID
      <k> $PGM:Program </k>             // 実行中のプログラム
      <tenv> .Map </tenv>               // 型環境
      <env> .Map </env>                 // 変数環境
      <envStack> .List </envStack>      // 環境スタック
      <tenvStack> .List </tenvStack>    // 型環境スタック
      <constEnv> .Map </constEnv>       // 定数環境
      <constEnvStack> .List </constEnvStack>
      <scopeDecls> .List </scopeDecls>  // スコープ宣言
    </thread>
  </threads>
  <nextTid> 1 </nextTid>                // 次のスレッドID
  <out> .List </out>                    // 出力
  <store> .Map </store>                 // 共有メモリストア
  <nextLoc> 0 </nextLoc>                // 次のロケーション
  <fenv> .Map </fenv>                   // 関数環境
  <channels> .Map </channels>           // チャネル状態
  <nextChanId> 0 </nextChanId>          // 次のチャネルID
</T>
```

### チャネルの状態表現

```k
syntax ChanState ::= chanState(
  List,    // sendQueue: 送信待ちスレッドのリスト
  List,    // recvQueue: 受信待ちスレッドのリスト
  List,    // buffer: バッファの値
  Int,     // bufferSize: バッファサイズ
  Type,    // elementType: 要素の型
  Bool     // closed: クローズ済みフラグ
)
```

### チャネル送信の優先順位

```k
// Priority 0: クローズ済みチャネルへの送信 → panic
// Priority 1: 待機中の受信者がいる → 直接渡す（ランデブー）
// Priority 2: バッファに空きがある → バッファに追加
// Priority 3: バッファがフル → 送信キューに追加してブロック
```

### チャネル受信の優先順位

```k
// Priority 1: バッファに値がある → 取り出す（送信キューから補充）
// Priority 2: バッファに値がある（送信待ちなし） → 取り出す
// Priority 3: 送信待ちがいる（バッファ空） → 直接受け取る
// Priority 4: クローズ済み（バッファ空） → ゼロ値を返す
// Priority 5: 何もない（非クローズ） → 受信キューに追加してブロック
```

### Goroutine の実行

```k
rule <thread>...
       <tid> ParentTid </tid>
       <k> go FCall:Exp => .K ... </k>
       <tenv> TEnv </tenv>
       <env> Env </env>
       <constEnv> CEnv </constEnv>
     ...</thread>
     (.Bag =>
       <thread>...
         <tid> N </tid>
         <k> FCall </k>
         <tenv> TEnv </tenv>
         <env> Env </env>
         <envStack> .List </envStack>
         <tenvStack> .List </tenvStack>
         <constEnv> CEnv </constEnv>
         <constEnvStack> .List </constEnvStack>
         <scopeDecls> .List </scopeDecls>
       ...</thread>)
     <nextTid> N:Int => N +Int 1 </nextTid>
```

### close の実装

```k
// close() で待機中の受信者全員を起こす
rule <thread>...
       <tid> Tid </tid>
       <k> close(channel(CId, int)) => wakeReceivers(RecvQ, CId, 0) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, RecvQ, Buf, Size, int, false)
            => chanState(SendQ, .List, Buf, Size, int, true))
     ...</channels>

// 待機中の受信者に順次ゼロ値を配る
rule <k> wakeReceivers((ListItem(RecvTid:Int) Rest:List), CId, ZeroVal)
      => wakeReceivers(Rest, CId, ZeroVal) ... </k>
     <thread>...
       <tid> RecvTid </tid>
       <k> waitingRecv(CId) => ZeroVal ... </k>
     ...</thread>
```

---

## 制限事項と今後の拡張

### 現在の制限事項

1. **v, ok := <-ch の未完成**
   - 構文とセマンティクスは定義済み
   - K Framework でのルールマッチングに課題あり
   - 回避策: `for range ch` でクローズ検出可能

2. **サポートするチャネル型**
   - 現在: `chan int`, `chan bool` のみ
   - 今後: 構造体、スライス、ポインタなどへの拡張

3. **単方向チャネル未サポート**
   - `chan<- T` (送信専用) と `<-chan T` (受信専用) は未実装
   - 現在は双方向チャネル（`chan T`）のみ

4. **select 文未実装**
   - 複数チャネルからの選択的な送受信は未サポート

5. **チャネルの nil チェック**
   - nil チャネルへの操作は未実装

### 今後の拡張候補

1. **v, ok := <-ch の完全実装**
   - より高度なクローズ検出

2. **select 文**
   ```go
   select {
   case v := <-ch1:
       // ...
   case ch2 <- v:
       // ...
   default:
       // ...
   }
   ```

3. **単方向チャネル**
   ```go
   func send(ch chan<- int) { ch <- 42 }
   func recv(ch <-chan int) { v := <-ch }
   ```

4. **追加のチャネル型**
   - `chan string`
   - `chan struct`
   - `chan chan T` (チャネルのチャネル)

5. **WaitGroup や Mutex などの同期プリミティブ**

---

## テストファイル

実装の動作確認用テストファイルは `src/go/codes/` 配下にあります：

- `code-goroutine-*`: Goroutine の基本動作
- `code-unbuffered-*`: アンバッファードチャネル
- `code-buffered-*`: バッファ付きチャネル
- `code-close-*`: close 機能

### テストの実行方法

```bash
# Docker コンテナに入る
docker compose exec k bash

# K 定義をコンパイル
cd go
kompile main.k

# テストを実行
krun codes/code-close-simple --definition main-kompiled/
```

---

## 参考文献

- [Go Language Specification - Go Statements](https://go.dev/ref/spec#Go_statements)
- [Go Language Specification - Channel Types](https://go.dev/ref/spec#Channel_types)
- [K Framework Documentation](https://kframework.org/)
- プロジェクトの `K_framework_documentation.md`
- プロジェクトの `go_language_specification.txt`

---

**作成日**: 2025年10月
**バージョン**: Phase 2 完了時点
