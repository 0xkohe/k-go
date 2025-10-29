# チャネルのブロッキング実装詳細

## 概要

Go言語のチャネルは、送信者と受信者が揃うまで**ブロッキング**します：
- 送信者が `ch <- value` を実行したが受信者がいない → 送信者がブロック
- 受信者が `<-ch` を実行したが送信者がいない → 受信者がブロック
- 相手が現れたら、値を受け渡してブロック解除

この実装では、K Frameworkのルールシステムを使ってブロッキングを実現しています。

## 実装の核心：待機状態

### 待機状態の定義

**ファイル**: `src/go/syntax/concurrent.k`

```k
syntax KItem ::= waitingSend(Int)  // 送信待ち（チャネルID）
syntax KItem ::= waitingRecv(Int)  // 受信待ち（チャネルID）
```

これらは、スレッドが**ブロックされている状態**を表す特別な構文です。

### チャネル状態の構造

**ファイル**: `src/go/semantics/concurrent.k`

```k
syntax ChanState ::= chanState(List, List, Type)
//                             ^^^^  ^^^^  ^^^^
//                             送信  受信  要素型
//                             キュー キュー
```

- **送信キュー**: 送信待ちのスレッド情報のリスト
- **受信キュー**: 受信待ちのスレッドIDのリスト
- **要素型**: チャネルで通信する値の型

### 送信キューの要素

```k
syntax SendItem ::= sendItem(Int, Val)
//                           ^^^  ^^^
//                           送信者 送信
//                           スレッド値
//                           ID
```

送信者がブロックされると、`sendItem(スレッドID, 値)` がキューに追加されます。

## ブロッキングのメカニズム

### 仕組み

1. **ルールマッチング失敗 = ブロック**
   - K Frameworkでは、適用できるルールがないと実行が停止
   - `waitingSend(CId)` や `waitingRecv(CId)` を `<k>` セルに置くことで、他のルールとマッチしなくなる

2. **キューに情報を保存**
   - ブロックする際、チャネル状態のキューにスレッド情報を追加
   - 他のスレッドがこの情報を使って値を受け渡す

3. **マッチング時に再開**
   - 相手が現れたら、待機状態を値や完了状態に書き換える
   - これによりスレッドの実行が再開

## 具体例1: 送信者がブロックするケース

### コード

```go
func main() {
    ch := make(chan int);
    ch <- 100;  // ← 受信者がいないのでブロック
    print(1);
}
```

### 実行トレース

#### 初期状態

```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k>
      var ch chan int = nil
      ~> ch = channel(0, int)
      ~> ch <- 100
      ~> print(1)
      ~> .K
    </k>
    <env> .Map </env>
  </thread>
</threads>

<channels>
  0 |-> chanState(.List, .List, int)
</channels>

<nextLoc> 0 </nextLoc>
<store> .Map </store>
```

#### ステップ1: チャネル変数宣言

**適用ルール**: `var X:Id chan T:Type = CV:ChanVal => .K`

```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k>
      ch = channel(0, int)
      ~> ch <- 100
      ~> print(1)
      ~> .K
    </k>
    <env> ch |-> 0 </env>
  </thread>
</threads>

<store> 0 |-> nil </store>
<nextLoc> 1 </nextLoc>
```

#### ステップ2: チャネル代入

**適用ルール**: `X:Id = CV:ChanVal => .K`

```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k>
      ch <- 100
      ~> print(1)
      ~> .K
    </k>
    <env> ch |-> 0 </env>
  </thread>
</threads>

<store> 0 |-> channel(0, int) </store>
```

#### ステップ3: 送信文の評価（strict属性）

**strict評価**: `ch <- 100` → `channel(0, int) <- 100` → `chanSend(channel(0, int), 100)`

```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k>
      chanSend(channel(0, int), 100)
      ~> print(1)
      ~> .K
    </k>
    <env> ch |-> 0 </env>
  </thread>
</threads>
```

#### ステップ4: 送信ルールの確認

**可能性1**: 受信者が待っているルール
```k
rule <thread>...
       <k> chanSend(channel(CId:Int, T:Type), V:Val) => .K ... </k>
     ...</thread>
     <channels>...
       CId |-> chanState(_SendQ, (ListItem(RecvTid) RecvRest:List), T) => ...
     ...</channels>
     <thread>...
       <tid> RecvTid </tid>
       <k> waitingRecv(CId) => V ... </k>
     ...</thread>
```

**マッチするか？** ❌ No
- チャネル状態: `chanState(.List, .List, int)`
- 受信キューが**空**（`.List`）なのでマッチしない

**可能性2**: 送信者がブロックするルール
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

**マッチするか？** ✅ Yes
- 受信キューが `.List`（空）
- 他の条件も満たす

**適用！**

#### ステップ5: ブロック状態に遷移

**変数バインディング**:
```
SenderTid = 0
CId = 0
T = int
V = 100
SendQ = .List
```

**書き換え後**:
```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k>
      waitingSend(0)   ← ★ ブロック中！
      ~> print(1)
      ~> .K
    </k>
    <env> ch |-> 0 </env>
  </thread>
</threads>

<channels>
  0 |-> chanState(ListItem(sendItem(0, 100)), .List, int)
  //              ^^^^^^^^^^^^^^^^^^^^^^^^
  //              送信キューに追加！
</channels>
```

#### ステップ6: 実行停止

**重要**: `waitingSend(0)` に適用できるルールが存在しない！

利用可能なルール（抜粋）:
```k
// このルールは受信者が現れたときだけマッチ
rule <thread>...
       <tid> SenderTid </tid>
       <k> waitingSend(CId) => .K ... </k>
     ...</thread>
     <channels>...
       CId |-> chanState((ListItem(sendItem(SenderTid, V)) SendRest:List), .List, T)
            => chanState(SendRest, .List, T)
     ...</channels>
     <thread>...
       <tid> RecvTid </tid>
       <k> chanRecv(channel(CId, T)) => V ... </k>
     ...</thread>
```

**現状**: 受信者のスレッドが存在しないので、このルールもマッチしない。

**結果**: スレッド0は `waitingSend(0)` の状態で**永久にブロック**され、`print(1)` は実行されない。

### ブロッキングのまとめ（この例）

1. ✅ `ch <- 100` が `chanSend(channel(0, int), 100)` に評価
2. ✅ 受信者がいないことを確認
3. ✅ 送信者ブロックルールが適用
4. ✅ `<k>` セルが `waitingSend(0)` に書き換え
5. ✅ 送信キューに `sendItem(0, 100)` を追加
6. ✅ 適用できるルールがなくなり実行停止 = **ブロック**

## 具体例2: 受信者がブロック後、送信者が現れて再開

### コード

```go
func receiver(ch chan int) {
    result := <-ch;  // ← 送信者がいないのでブロック
    print(result);
}

func main() {
    ch := make(chan int);
    go receiver(ch);
    ch <- 42;  // ← ここで送信して受信者を再開
}
```

### 実行トレース

#### 初期状態（簡略化）

```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k>
      go receiver(ch)
      ~> ch <- 42
      ~> .K
    </k>
    <env> ch |-> 0 </env>
  </thread>
</threads>

<channels>
  0 |-> chanState(.List, .List, int)
</channels>

<store> 0 |-> channel(0, int) </store>
<nextTid> 1 </nextTid>
```

#### ステップ1: Goroutine生成

**適用ルール**: `go FCall:Exp => .K` （goroutine作成）

```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k>
      ch <- 42
      ~> .K
    </k>
    <env> ch |-> 0 </env>
  </thread>

  <thread>  ← ★ 新しいスレッド！
    <tid> 1 </tid>
    <k>
      receiver(ch)
      ~> .K
    </k>
    <env> ch |-> 0 </env>
  </thread>
</threads>

<nextTid> 2 </nextTid>
```

#### ステップ2: スレッド1で関数呼び出し

**適用ルール**: 関数呼び出しルール

スレッド1の `<k>` セルが関数本体に展開されます：

```k
<thread>
  <tid> 1 </tid>
  <k>
    enterScope(var ch chan int = channel(0, int))
    ~> result := <-ch
    ~> print(result)
    ~> exitScope
    ~> .K
  </k>
  <env> .Map </env>
</thread>
```

スコープ処理後、簡略化すると：

```k
<thread>
  <tid> 1 </tid>
  <k>
    result := <-ch
    ~> print(result)
    ~> exitScope
    ~> .K
  </k>
  <env> ch |-> 0 </env>
</thread>
```

#### ステップ3: 受信式の評価（strict属性）

**strict評価**: `<-ch` → `<-channel(0, int)` → `chanRecv(channel(0, int))`

```k
<thread>
  <tid> 1 </tid>
  <k>
    result := chanRecv(channel(0, int))
    ~> print(result)
    ~> exitScope
    ~> .K
  </k>
  <env> ch |-> 0 </env>
</thread>
```

#### ステップ4: 受信ルールの確認

**可能性1**: 送信者が待っているルール
```k
rule <thread>...
       <k> chanRecv(channel(CId:Int, T:Type)) => V ... </k>
     ...</thread>
     <channels>...
       CId |-> chanState((ListItem(sendItem(SenderTid, V)) SendRest:List), _RecvQ, T)
            => chanState(SendRest, _RecvQ, T)
     ...</channels>
     <thread>...
       <tid> SenderTid </tid>
       <k> waitingSend(CId) => .K ... </k>
     ...</thread>
```

**マッチするか？** ❌ No
- チャネル状態: `chanState(.List, .List, int)`
- 送信キューが**空**（`.List`）なのでマッチしない

**可能性2**: 受信者がブロックするルール
```k
rule <thread>...
       <tid> RecvTid </tid>
       <k> chanRecv(channel(CId:Int, T:Type)) => waitingRecv(CId) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(.List, RecvQ:List, T)
             => chanState(.List, (RecvQ ListItem(RecvTid)), T))
     ...</channels>
```

**マッチするか？** ✅ Yes
- 送信キューが `.List`（空）
- 他の条件も満たす

**適用！**

#### ステップ5: 受信者がブロック

**変数バインディング**:
```
RecvTid = 1
CId = 0
T = int
RecvQ = .List
```

**書き換え後**:
```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k>
      ch <- 42
      ~> .K
    </k>
    <env> ch |-> 0 </env>
  </thread>

  <thread>
    <tid> 1 </tid>
    <k>
      waitingRecv(0)   ← ★ ブロック中！
      ~> print(result)
      ~> exitScope
      ~> .K
    </k>
    <env> ch |-> 0 </env>
  </thread>
</threads>

<channels>
  0 |-> chanState(.List, ListItem(1), int)
  //                     ^^^^^^^^^^^^
  //                     受信キューに追加！
</channels>
```

**現状**: スレッド1は `waitingRecv(0)` でブロック中。スレッド0は実行可能。

#### ステップ6: スレッド0で送信（strict評価）

K Frameworkは非決定的にスレッド0を選択して実行します。

**strict評価**: `ch <- 42` → `chanSend(channel(0, int), 42)`

```k
<thread>
  <tid> 0 </tid>
  <k>
    chanSend(channel(0, int), 42)
    ~> .K
  </k>
  <env> ch |-> 0 </env>
</thread>
```

#### ステップ7: 送信-受信マッチング

**適用ルール**: 受信者が待っているルール
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

**マッチするか？** ✅ Yes!
- チャネル状態の受信キュー: `ListItem(1)`（空でない！）
- スレッド1が `waitingRecv(0)` で待機中

**変数バインディング**:
```
SenderTid = 0
CId = 0
T = int
V = 42
RecvTid = 1
RecvRest = .List
```

#### ステップ8: 値の受け渡しとブロック解除

**書き換え後**:
```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k> .K </k>  ← ★ 送信完了！
    <env> ch |-> 0 </env>
  </thread>

  <thread>
    <tid> 1 </tid>
    <k>
      42   ← ★ ブロック解除！値を受け取った
      ~> print(result)
      ~> exitScope
      ~> .K
    </k>
    <env> ch |-> 0 </env>
  </thread>
</threads>

<channels>
  0 |-> chanState(.List, .List, int)
  //              ^^^^^  ^^^^^
  //              両キュー空に！
</channels>
```

**重要なポイント**:
- 送信者: `chanSend(...) => .K` - 送信完了
- 受信者: `waitingRecv(0) => 42` - ブロック解除、値を受信
- チャネル: 受信キューから `ListItem(1)` が削除

#### ステップ9: 短変数代入の完了

スレッド1で `result := 42` が完了：

```k
<thread>
  <tid> 1 </tid>
  <k>
    print(result)
    ~> exitScope
    ~> .K
  </k>
  <env>
    ch |-> 0
    result |-> 1
  </env>
</thread>

<store>
  0 |-> channel(0, int)
  1 |-> 42
</store>
```

#### ステップ10: print実行

**出力**: `42`

### ブロッキング解除のまとめ（この例）

1. ✅ スレッド1が `chanRecv(channel(0, int))` を実行
2. ✅ 送信者がいないことを確認
3. ✅ 受信者ブロックルールが適用
4. ✅ スレッド1が `waitingRecv(0)` でブロック
5. ✅ 受信キューに `ListItem(1)` を追加
6. ✅ スレッド0が `chanSend(channel(0, int), 42)` を実行
7. ✅ 受信者がいることを確認（受信キューに `ListItem(1)`）
8. ✅ 送信-受信マッチングルールが適用
9. ✅ スレッド1の `waitingRecv(0)` が `42` に書き換え = **ブロック解除**
10. ✅ スレッド1が実行再開し `print(42)` を実行

## 具体例3: 送信者がブロック後、受信者が現れて再開

### コード

```go
func sender(ch chan int, val int) {
    ch <- val;  // ← 受信者がいないのでブロック
    print(1);
}

func main() {
    ch := make(chan int);
    go sender(ch, 99);
    result := <-ch;  // ← ここで受信して送信者を再開
    print(result);
}
```

### 実行トレース（簡略版）

#### ステップ1-3: 初期設定とGoroutine生成

```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k> result := <-ch ~> print(result) ~> .K </k>
    <env> ch |-> 0 </env>
  </thread>

  <thread>
    <tid> 1 </tid>
    <k> ch <- 99 ~> print(1) ~> .K </k>
    <env> ch |-> 0, val |-> 1 </env>
  </thread>
</threads>

<channels>
  0 |-> chanState(.List, .List, int)
</channels>

<store>
  0 |-> channel(0, int)
  1 |-> 99
</store>
```

#### ステップ4: スレッド1で送信（非決定的選択）

スレッド1が先に実行されると仮定：

**strict評価**: `ch <- 99` → `chanSend(channel(0, int), 99)`

**適用ルール**: 送信者ブロックルール（受信者がいない）

```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k> result := <-ch ~> print(result) ~> .K </k>
    <env> ch |-> 0 </env>
  </thread>

  <thread>
    <tid> 1 </tid>
    <k> waitingSend(0) ~> print(1) ~> .K </k>  ← ★ ブロック！
    <env> ch |-> 0, val |-> 1 </env>
  </thread>
</threads>

<channels>
  0 |-> chanState(ListItem(sendItem(1, 99)), .List, int)
  //              ^^^^^^^^^^^^^^^^^^^^^^^^
  //              送信キューに追加！
</channels>
```

#### ステップ5: スレッド0で受信

**strict評価**: `<-ch` → `chanRecv(channel(0, int))`

**適用ルール**: 送信者が待っているルール
```k
rule <thread>...
       <k> chanRecv(channel(CId:Int, T:Type)) => V ... </k>
     ...</thread>
     <channels>...
       CId |-> chanState((ListItem(sendItem(SenderTid, V)) SendRest:List), _RecvQ, T)
            => chanState(SendRest, _RecvQ, T)
     ...</channels>
     <thread>...
       <tid> SenderTid </tid>
       <k> waitingSend(CId) => .K ... </k>
     ...</thread>
```

**マッチするか？** ✅ Yes!
- 送信キュー: `ListItem(sendItem(1, 99))`（空でない！）
- スレッド1が `waitingSend(0)` で待機中

**変数バインディング**:
```
CId = 0
T = int
V = 99
SenderTid = 1
SendRest = .List
```

#### ステップ6: 値の受け渡しとブロック解除

```k
<threads>
  <thread>
    <tid> 0 </tid>
    <k> 99 ~> print(result) ~> .K </k>  ← ★ 値を受信！
    <env> ch |-> 0 </env>
  </thread>

  <thread>
    <tid> 1 </tid>
    <k> print(1) ~> .K </k>  ← ★ ブロック解除！送信完了
    <env> ch |-> 0, val |-> 1 </env>
  </thread>
</threads>

<channels>
  0 |-> chanState(.List, .List, int)
  //              両キュー空に！
</channels>
```

**重要なポイント**:
- 受信者: `chanRecv(...) => 99` - 値を受信
- 送信者: `waitingSend(0) => .K` - ブロック解除、送信完了
- チャネル: 送信キューから `sendItem(1, 99)` が削除

#### ステップ7: 両スレッドが実行継続

スレッド0: `result := 99` → `print(result)` → 出力 `99`
スレッド1: `print(1)` → 出力 `1`

**最終出力** (非決定的): `99` と `1` （順序は実行による）

## ブロッキングの全ルール一覧

### 送信側のルール

#### ルール1: 受信者が待っている → 即座に送信

**ファイル**: `src/go/semantics/concurrent.k`

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

**条件**:
- ✅ 受信キューに少なくとも1つのスレッドID
- ✅ そのスレッドが `waitingRecv(CId)` で待機中

**動作**:
- 送信者: 即座に完了（`.K`）
- 受信者: ブロック解除、値を受信（`V`）
- チャネル: 受信キューから先頭を削除

**ブロックするか？** ❌ No（即座に完了）

#### ルール2: 受信者がいない → 送信者ブロック

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

**条件**:
- ✅ 受信キューが空（`.List`）

**動作**:
- 送信者: `waitingSend(CId)` に遷移 = **ブロック**
- チャネル: 送信キューに `sendItem(SenderTid, V)` を追加

**ブロックするか？** ✅ Yes（`waitingSend`で待機）

### 受信側のルール

#### ルール3: 送信者が待っている → 即座に受信

```k
rule <thread>...
       <k> chanRecv(channel(CId:Int, T:Type)) => V ... </k>
     ...</thread>
     <channels>...
       CId |-> chanState((ListItem(sendItem(SenderTid, V)) SendRest:List), _RecvQ, T)
            => chanState(SendRest, _RecvQ, T)
     ...</channels>
     <thread>...
       <tid> SenderTid </tid>
       <k> waitingSend(CId) => .K ... </k>
     ...</thread>
```

**条件**:
- ✅ 送信キューに少なくとも1つの `sendItem`
- ✅ そのスレッドが `waitingSend(CId)` で待機中

**動作**:
- 受信者: 即座に値を受信（`V`）
- 送信者: ブロック解除、送信完了（`.K`）
- チャネル: 送信キューから先頭を削除

**ブロックするか？** ❌ No（即座に完了）

#### ルール4: 送信者がいない → 受信者ブロック

```k
rule <thread>...
       <tid> RecvTid </tid>
       <k> chanRecv(channel(CId:Int, T:Type)) => waitingRecv(CId) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(.List, RecvQ:List, T)
             => chanState(.List, (RecvQ ListItem(RecvTid)), T))
     ...</channels>
```

**条件**:
- ✅ 送信キューが空（`.List`）

**動作**:
- 受信者: `waitingRecv(CId)` に遷移 = **ブロック**
- チャネル: 受信キューに `RecvTid` を追加

**ブロックするか？** ✅ Yes（`waitingRecv`で待機）

## ブロッキングの特徴

### 1. FIFOキュー保証

チャネルのキューは**先入れ先出し**（FIFO）です：

```k
chanState(SendQ:List, RecvQ:List, T)
```

K FrameworkのList型は順序を保持するため：
- 最初に待機したスレッドが最初に再開される
- `ListItem(id)` が先頭から順に処理される

### 2. 対称性

送信と受信は対称的な構造：

| 操作 | ブロック状態 | キュー | 保存内容 |
|------|------------|--------|---------|
| 送信 | `waitingSend(CId)` | 送信キュー | `sendItem(tid, value)` |
| 受信 | `waitingRecv(CId)` | 受信キュー | `ListItem(tid)` |

### 3. ルールマッチング失敗 = ブロック

K Frameworkの特性を活用：
- `waitingSend(CId)` や `waitingRecv(CId)` に適用できるルールが（相手が現れるまで）ない
- ルールマッチング失敗 = 実行停止 = ブロック
- 明示的なスレッドスケジューラー不要

### 4. 非決定的スケジューリング

複数のスレッドが実行可能な場合、K Frameworkが非決定的に選択：
- スレッド1がブロック中、スレッド0が実行可能 → スレッド0が実行
- 両方実行可能 → どちらが先に実行されるかは非決定的

### 5. デッドロック検出なし

現在の実装では、デッドロック（すべてのスレッドがブロック）は検出されません：
```go
func main() {
    ch := make(chan int);
    <-ch;  // 永久にブロック
}
```

これは実行が単に停止します。実際のGoランタイムはデッドロックを検出してpanicしますが、この実装では未対応です。

## まとめ

### ブロッキングの実装方法

1. **待機状態**: `waitingSend(CId)` と `waitingRecv(CId)` を定義
2. **キュー**: `chanState(sendQueue, recvQueue, type)` で待機中のスレッド情報を保存
3. **ルール分岐**:
   - 相手がいる → 即座に値を受け渡し
   - 相手がいない → 待機状態に遷移してキューに追加
   - 相手が現れる → 待機状態を解除してキューから削除
4. **K Frameworkの特性**: ルールマッチング失敗 = 実行停止 = ブロック

### ブロッキングの保証

- ✅ **FIFO順序**: キューにより先入れ先出し保証
- ✅ **対称性**: 送信と受信が対称的に実装
- ✅ **非決定的スケジューリング**: 実際のGoと同様
- ✅ **値の受け渡し**: ブロック解除時に正確に値を転送
- ❌ **デッドロック検出**: 未実装

この実装により、Goのチャネルの本質的な動作であるブロッキング同期を、K Frameworkのルールシステムで忠実に再現しています。
