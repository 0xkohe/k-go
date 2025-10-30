# chanState の詳細解説

## 概要

`chanState` は、**チャネルの状態**を表すK Frameworkの構文です。各チャネルが持つ送信待ちキューと受信待ちキューを管理します。

## 定義

**ファイル**: `src/go/semantics/concurrent.k:103`

```k
syntax ChanState ::= chanState(List, List, Type)
//                             ^^^^  ^^^^  ^^^^
//                             送信  受信  要素型
//                             キュー キュー
```

### 3つのフィールド

1. **送信キュー (sendQueue)**: 送信待ちのスレッド情報のリスト
2. **受信キュー (recvQueue)**: 受信待ちのスレッドIDのリスト
3. **要素型 (elementType)**: チャネルで通信する値の型

## 各フィールドの詳細

### 1. 送信キュー (List)

送信者がブロックされたときに、**送信者の情報**を保存するキューです。

**要素型**: `sendItem(Int, K)`

```k
syntax SendItem ::= sendItem(Int, K)
//                           ^^^  ^
//                           tid  送信する値
```

**内容**:
- `tid`: 送信者のスレッドID
- `value`: 送信しようとしている値

**例**:
```k
ListItem(sendItem(1, 42))
ListItem(sendItem(3, 100))
.List
```
- スレッド1が値 `42` を送信待ち
- スレッド3が値 `100` を送信待ち

### 2. 受信キュー (List)

受信者がブロックされたときに、**受信者のスレッドID**を保存するキューです。

**要素型**: `Int` (スレッドID)

**内容**:
- 受信待ちのスレッドID

**例**:
```k
ListItem(2)
ListItem(5)
.List
```
- スレッド2が受信待ち
- スレッド5が受信待ち

### 3. 要素型 (Type)

チャネルで通信する値の型です。

**可能な値**:
- `int` - 整数型チャネル
- `bool` - ブール型チャネル
- 将来的には他の型も追加可能

**型の一致チェック**:
- 送信する値の型とチャネルの要素型が一致することを保証
- ルールマッチングで型を明示的にチェック

## chanState の状態遷移

### 初期状態

チャネルが作成されたとき：

```k
rule <k> make(chan T:Type) => channel(N, T) ... </k>
     <nextChanId> N:Int => N +Int 1 </nextChanId>
     <channels> Chans => Chans [ N <- chanState(.List, .List, T) ] </channels>
```

**初期状態**:
```k
chanState(.List, .List, T)
//        ^^^^^  ^^^^^
//        両キュー空
```

両方のキューが空（`.List`）です。

### 状態1: 送信者が待っている

受信者がいない状態で送信が実行されると：

**ルール** (concurrent.k:136-144):
```k
rule <thread>...
       <tid> Tid </tid>
       <k> chanSend(channel(CId, int), V:Int) => waitingSend(CId, V) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, .List, int)
             => chanState(SendQ ListItem(sendItem(Tid, V)), .List, int))
     ...</channels>
```

**状態遷移**:
```k
chanState(.List, .List, int)
  ↓ スレッド1が 42 を送信
chanState(ListItem(sendItem(1, 42)), .List, int)
  ↓ スレッド3が 100 を送信
chanState(ListItem(sendItem(1, 42)) ListItem(sendItem(3, 100)), .List, int)
```

### 状態2: 受信者が待っている

送信者がいない状態で受信が実行されると：

**ルール** (concurrent.k:174-181):
```k
rule <thread>...
       <tid> Tid </tid>
       <k> chanRecv(channel(CId, _T)) => waitingRecv(CId) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(.List, RecvQ, T)
             => chanState(.List, RecvQ ListItem(Tid), T))
     ...</channels>
```

**状態遷移**:
```k
chanState(.List, .List, int)
  ↓ スレッド2が受信
chanState(.List, ListItem(2), int)
  ↓ スレッド5が受信
chanState(.List, ListItem(2) ListItem(5), int)
```

### 状態3: マッチングして値を受け渡し

送信者と受信者がマッチングすると、キューから削除：

**ルール** (concurrent.k:109-120):
```k
rule <thread>...
       <k> chanSend(channel(CId, int), V:Int) => .K ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, (ListItem(RecvTid:Int) RecvRest:List), int)
             => chanState(SendQ, RecvRest, int))
     ...</channels>
     <thread>...
       <tid> RecvTid </tid>
       <k> waitingRecv(CId) => V ... </k>
     ...</thread>
```

**状態遷移**:
```k
chanState(.List, ListItem(2) ListItem(5), int)
  ↓ 送信者が 42 を送信、スレッド2とマッチング
chanState(.List, ListItem(5), int)
  ↓ 送信者が 99 を送信、スレッド5とマッチング
chanState(.List, .List, int)
```

## 具体例：状態の変化を追跡

### コード

```go
func receiver1(ch chan int) {
    result := <-ch;  // スレッド1
    print(result);
}

func receiver2(ch chan int) {
    result := <-ch;  // スレッド2
    print(result);
}

func main() {
    ch := make(chan int);
    go receiver1(ch);
    go receiver2(ch);
    ch <- 10;
    ch <- 20;
}
```

### 状態遷移

#### 初期状態

```k
<channels>
  0 |-> chanState(.List, .List, int)
</channels>
```

**可視化**:
```
chanState:
  sendQueue: []
  recvQueue: []
  type: int
```

#### ステップ1: スレッド1が受信試行

```k
<channels>
  0 |-> chanState(.List, ListItem(1), int)
</channels>
```

**可視化**:
```
chanState:
  sendQueue: []
  recvQueue: [tid:1]  ← スレッド1が待機
  type: int
```

**スレッド1の状態**:
```k
<thread>
  <tid> 1 </tid>
  <k> waitingRecv(0) ~> print(result) ~> ... </k>
</thread>
```

#### ステップ2: スレッド2が受信試行

```k
<channels>
  0 |-> chanState(.List, ListItem(1) ListItem(2), int)
</channels>
```

**可視化**:
```
chanState:
  sendQueue: []
  recvQueue: [tid:1, tid:2]  ← 2つのスレッドが待機
  type: int
```

**スレッド2の状態**:
```k
<thread>
  <tid> 2 </tid>
  <k> waitingRecv(0) ~> print(result) ~> ... </k>
</thread>
```

#### ステップ3: メインスレッド(tid=0)が 10 を送信

**適用ルール**: 送信-受信マッチング（受信者が待っている）

**マッチング**:
- 受信キューの先頭: `ListItem(1)`
- 送信値: `10`
- 受信者: スレッド1

**状態遷移**:
```k
<channels>
  0 |-> chanState(.List, ListItem(2), int)
  //                     ^^^^^^^^^^^^
  //                     スレッド1を削除
</channels>
```

**可視化**:
```
chanState:
  sendQueue: []
  recvQueue: [tid:2]  ← スレッド1が削除された
  type: int
```

**スレッド1の状態変化**:
```k
<thread>
  <tid> 1 </tid>
  <k> 10 ~> print(result) ~> ... </k>  ← ブロック解除、値を受信
</thread>
```

#### ステップ4: メインスレッド(tid=0)が 20 を送信

**適用ルール**: 送信-受信マッチング（受信者が待っている）

**マッチング**:
- 受信キューの先頭: `ListItem(2)`
- 送信値: `20`
- 受信者: スレッド2

**状態遷移**:
```k
<channels>
  0 |-> chanState(.List, .List, int)
  //              ^^^^^  ^^^^^
  //              両キューが空に
</channels>
```

**可視化**:
```
chanState:
  sendQueue: []
  recvQueue: []  ← すべてのスレッドが処理された
  type: int
```

**スレッド2の状態変化**:
```k
<thread>
  <tid> 2 </tid>
  <k> 20 ~> print(result) ~> ... </k>  ← ブロック解除、値を受信
</thread>
```

## 別の例：送信者が先に待つケース

### コード

```go
func sender1(ch chan int) {
    ch <- 100;  // スレッド1
    print(1);
}

func sender2(ch chan int) {
    ch <- 200;  // スレッド2
    print(2);
}

func main() {
    ch := make(chan int);
    go sender1(ch);
    go sender2(ch);
    result1 := <-ch;
    print(result1);
    result2 := <-ch;
    print(result2);
}
```

### 状態遷移

#### 初期状態

```k
<channels>
  0 |-> chanState(.List, .List, int)
</channels>
```

#### ステップ1: スレッド1が 100 を送信試行

```k
<channels>
  0 |-> chanState(ListItem(sendItem(1, 100)), .List, int)
</channels>
```

**可視化**:
```
chanState:
  sendQueue: [(tid:1, val:100)]  ← スレッド1が100を送信待ち
  recvQueue: []
  type: int
```

#### ステップ2: スレッド2が 200 を送信試行

```k
<channels>
  0 |-> chanState(ListItem(sendItem(1, 100)) ListItem(sendItem(2, 200)), .List, int)
</channels>
```

**可視化**:
```
chanState:
  sendQueue: [(tid:1, val:100), (tid:2, val:200)]  ← 2つの送信待ち
  recvQueue: []
  type: int
```

#### ステップ3: メインスレッド(tid=0)が受信

**適用ルール**: 受信-送信マッチング（送信者が待っている）

**マッチング**:
- 送信キューの先頭: `sendItem(1, 100)`
- 受信者: メインスレッド
- 値: `100`

**状態遷移**:
```k
<channels>
  0 |-> chanState(ListItem(sendItem(2, 200)), .List, int)
</channels>
```

**可視化**:
```
chanState:
  sendQueue: [(tid:2, val:200)]  ← スレッド1が削除された
  recvQueue: []
  type: int
```

**スレッド1の状態変化**:
```k
<thread>
  <tid> 1 </tid>
  <k> print(1) ~> ... </k>  ← ブロック解除、送信完了
</thread>
```

**メインスレッド**:
```k
<thread>
  <tid> 0 </tid>
  <k> 100 ~> print(result1) ~> result2 := <-ch ~> ... </k>
</thread>
```

#### ステップ4: メインスレッド(tid=0)が再度受信

**マッチング**:
- 送信キューの先頭: `sendItem(2, 200)`
- 受信者: メインスレッド
- 値: `200`

**状態遷移**:
```k
<channels>
  0 |-> chanState(.List, .List, int)
</channels>
```

**可視化**:
```
chanState:
  sendQueue: []  ← すべての送信者が処理された
  recvQueue: []
  type: int
```

## chanState とストアの関係

### 全体構造

```k
<T>
  <threads>
    <thread multiplicity="*">
      <tid> ... </tid>
      <k> ... </k>
      <env> ... </env>  ← チャネル変数 → location
    </thread>
  </threads>

  <store> ... </store>  ← location → channel(id, type)

  <channels> ... </channels>  ← channel_id → chanState(...)
</T>
```

### 3層構造

1. **変数からlocationへ**
   ```k
   <env> ch |-> 0 </env>
   ```

2. **locationからチャネル値へ**
   ```k
   <store> 0 |-> channel(5, int) </store>
   ```

3. **チャネルIDから状態へ**
   ```k
   <channels> 5 |-> chanState(.List, ListItem(2), int) </channels>
   ```

### なぜこの構造？

#### 変数とチャネルの分離

**変数は再代入可能**:
```go
ch := make(chan int)  // ch -> location 0 -> channel(5, int)
ch = make(chan int)   // ch -> location 0 -> channel(6, int)
```

チャネル変数を別のチャネルに再代入できますが、チャネル自体の状態は独立しています。

#### チャネル値とチャネル状態の分離

**チャネル値は複製可能**:
```go
ch1 := make(chan int)  // channel(5, int)
ch2 := ch1             // 同じ channel(5, int) を参照
```

複数の変数が同じチャネルを参照できますが、チャネルの状態（キュー）は1つだけです。

### 具体例

```go
func main() {
    ch1 := make(chan int);  // channel(0, int)
    ch2 := ch1;             // 同じ channel(0, int)
    go func() { ch1 <- 42 }();
    result := <-ch2;        // 同じチャネルなので受信できる
    print(result);
}
```

**状態**:
```k
<env>
  ch1 |-> 0
  ch2 |-> 1
</env>

<store>
  0 |-> channel(0, int)
  1 |-> channel(0, int)  ← 同じチャネルID
</store>

<channels>
  0 |-> chanState(ListItem(sendItem(1, 42)), .List, int)
  //    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  //    チャネルIDが0なので、ch1でもch2でも同じ状態にアクセス
</channels>
```

## キューのFIFO保証

K FrameworkのList型は順序を保持するため、chanStateのキューは**先入れ先出し**（FIFO）です。

### 送信キュー

```k
chanState(ListItem(sendItem(1, 10)) ListItem(sendItem(2, 20)) ListItem(sendItem(3, 30)), .List, int)
```

受信者が現れると：
1. 最初にスレッド1の値 `10` が受け渡される
2. 次にスレッド2の値 `20` が受け渡される
3. 最後にスレッド3の値 `30` が受け渡される

### 受信キュー

```k
chanState(.List, ListItem(1) ListItem(2) ListItem(3), int)
```

送信者が現れると：
1. 最初にスレッド1が値を受信
2. 次にスレッド2が値を受信
3. 最後にスレッド3が値を受信

### ルールでの先頭アクセス

```k
ListItem(RecvTid:Int) RecvRest:List
^^^^^^^^^^^^^^^^^^^^^
先頭の要素
```

パターンマッチングにより、常にリストの**先頭**を処理します。

## chanState の型による分離

現在の実装では、型ごとにルールが分かれています：

### int型チャネル

**送信ルール** (concurrent.k:109-120):
```k
rule <k> chanSend(channel(CId, int), V:Int) => .K ... </k>
     <channels>...
       CId |-> chanState(SendQ, (ListItem(RecvTid) RecvRest), int) => ...
     ...</channels>
```

**ブロックルール** (concurrent.k:136-144):
```k
rule <k> chanSend(channel(CId, int), V:Int) => waitingSend(CId, V) ... </k>
     <channels>...
       CId |-> chanState(SendQ, .List, int) => ...
     ...</channels>
```

### bool型チャネル

**送信ルール** (concurrent.k:122-134):
```k
rule <k> chanSend(channel(CId, bool), V:Bool) => .K ... </k>
     <channels>...
       CId |-> chanState(SendQ, (ListItem(RecvTid) RecvRest), bool) => ...
     ...</channels>
```

**ブロックルール** (concurrent.k:146-154):
```k
rule <k> chanSend(channel(CId, bool), V:Bool) => waitingSend(CId, V) ... </k>
     <channels>...
       CId |-> chanState(SendQ, .List, bool) => ...
     ...</channels>
```

### なぜ型ごとに分ける？

K Frameworkのパターンマッチングで型を明示的にチェックするためです。将来的にはより汎用的なルールに統合できる可能性があります。

## まとめ

### chanState とは

```k
chanState(List, List, Type)
```

チャネルの状態を表す構文で、以下を管理：
1. **送信キュー**: 送信待ちスレッドの `(tid, value)` ペア
2. **受信キュー**: 受信待ちスレッドの `tid`
3. **要素型**: チャネルで通信する値の型

### 役割

- ✅ **ブロッキング同期**: 送信者と受信者のマッチング
- ✅ **FIFO保証**: 先入れ先出しの公平性
- ✅ **型安全性**: 要素型のチェック
- ✅ **マルチスレッド通信**: 複数スレッド間の値の受け渡し

### 状態遷移

```
chanState(.List, .List, T)        // 初期状態
  ↓ 送信者がブロック
chanState([send...], .List, T)    // 送信待ち
  ↓ 受信者が現れる
chanState(.List, .List, T)        // マッチング完了

または

chanState(.List, .List, T)        // 初期状態
  ↓ 受信者がブロック
chanState(.List, [recv...], T)    // 受信待ち
  ↓ 送信者が現れる
chanState(.List, .List, T)        // マッチング完了
```

### 3層アクセス構造

```
変数 → location → channel(id, type) → chanState(sendQ, recvQ, type)
<env>   <store>                       <channels>
```

この構造により、チャネル変数の再代入とチャネル状態の独立性を両立しています。

**chanState** は、Goのチャネルブロッキングセマンティクスを実現するための中核的なデータ構造です。
