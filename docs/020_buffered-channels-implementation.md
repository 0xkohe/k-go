# Buffered Channels Implementation in K Framework

K FrameworkでのGoのバッファ付きチャネルの実装について、設計思想、実装詳細、動作例を含めて解説します。

## 目次

1. [実装の概要](#実装の概要)
2. [動機と背景](#動機と背景)
3. [設計の詳細](#設計の詳細)
4. [送信操作のロジック](#送信操作のロジック)
5. [受信操作のロジック](#受信操作のロジック)
6. [具体的な実行例](#具体的な実行例)
7. [テスト結果](#テスト結果)
8. [今後の拡張](#今後の拡張)

## 実装の概要

### 実装された機能

- **バッファ付きチャネル作成**: `make(chan Type, Size)` - 指定サイズのバッファを持つチャネル
- **ノンブロッキング送信**: バッファに空きがあれば即座に送信完了
- **ブロッキング送信**: バッファ満杯時は受信を待つ
- **FIFO保証**: バッファから順番に値を取得
- **既存互換性**: Unbuffered (バッファサイズ0) との完全互換

### ファイル構成

```
src/go/
├── syntax/
│   └── concurrent.k        # make(chan T, n) 構文追加
└── semantics/
    └── concurrent.k        # バッファロジック実装
```

## 動機と背景

### Goにおけるバッファ付きチャネル

Goでは、チャネルに2種類あります：

```go
ch1 := make(chan int)       // Unbuffered: バッファサイズ0
ch2 := make(chan int, 10)   // Buffered: バッファサイズ10
```

**Unbuffered チャネル**:
- 送信と受信が同期（rendezvous）
- 送信者は受信者が現れるまでブロック

**Buffered チャネル**:
- バッファに空きがあれば送信はブロックしない
- パフォーマンス向上とデッドロック回避
- プロデューサー・コンシューマーパターンで有用

### 実装の必要性

バッファ付きチャネルがないと：
- ❌ 送受信の厳密な同期が必須
- ❌ パフォーマンスが低下
- ❌ 実用的なGoプログラムが書けない

## 設計の詳細

### 1. 構文拡張

**変更前** (syntax/concurrent.k):
```k
syntax Exp ::= "make" "(" ChannelType ")"
```

**変更後**:
```k
syntax Exp ::= "make" "(" ChannelType ")"
             | "make" "(" ChannelType "," Exp ")" [strict(2)]
```

**説明**:
- `strict(2)` 属性により、第2引数（バッファサイズ）が評価されてから `make` が実行される

**例**:
```go
make(chan int, 5)      // バッファサイズ5
make(chan int, x+1)    // 式も可能（strict(2)により評価される）
```

---

### 2. ChanState の構造変更

チャネルの状態を表す `ChanState` を拡張しました。

**変更前**:
```k
syntax ChanState ::= chanState(List, List, Type)
// chanState(sendQueue, recvQueue, elementType)
```

**変更後**:
```k
syntax ChanState ::= chanState(List, List, List, Int, Type)
// chanState(sendQueue, recvQueue, buffer, bufferSize, elementType)
```

#### ChanState の各フィールド

| フィールド | 型 | 説明 | 例 |
|------------|-----|------|-----|
| **sendQueue** | `List` | 送信待ちスレッドのキュー | `ListItem(sendItem(1, 42))` |
| **recvQueue** | `List` | 受信待ちスレッドのキュー | `ListItem(2) ListItem(3)` |
| **buffer** | `List` | バッファ内の値 | `ListItem(10) ListItem(20)` |
| **bufferSize** | `Int` | バッファの最大容量 | `5` (0はunbuffered) |
| **elementType** | `Type` | チャネルの要素型 | `int`, `bool` |

---

### 3. チャネル作成ルール

**Unbuffered チャネル** (`make(chan int)`):
```k
rule <k> make(chan T:Type) => channel(N, T) ... </k>
     <nextChanId> N:Int => N +Int 1 </nextChanId>
     <channels> Chans => Chans [ N <- chanState(.List, .List, .List, 0, T) ] </channels>
```

**初期状態**:
```k
chanState(
  .List,     // sendQueue: 空
  .List,     // recvQueue: 空
  .List,     // buffer: 空
  0,         // bufferSize: 0 (unbuffered)
  int        // elementType
)
```

---

**Buffered チャネル** (`make(chan int, 5)`):
```k
rule <k> make(chan T:Type, Size:Int) => channel(N, T) ... </k>
     <nextChanId> N:Int => N +Int 1 </nextChanId>
     <channels> Chans => Chans [ N <- chanState(.List, .List, .List, Size, T) ] </channels>
  requires Size >=Int 0
```

**初期状態**:
```k
chanState(
  .List,     // sendQueue: 空
  .List,     // recvQueue: 空
  .List,     // buffer: 空
  5,         // bufferSize: 5
  int        // elementType
)
```

## 送信操作のロジック

送信操作 `ch <- value` は3つの優先度でルールが適用されます。

### Priority 1: 受信待ちスレッドがいる場合（即座に配信）

```k
rule <thread>...
       <tid> _Tid </tid>
       <k> chanSend(channel(CId, int), V:Int) => .K ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, (ListItem(RecvTid:Int) RecvRest:List), Buf, Size, int)
            => chanState(SendQ, RecvRest, Buf, Size, int))
     ...</channels>
     <thread>...
       <tid> RecvTid </tid>
       <k> waitingRecv(CId) => V ... </k>
     ...</thread>
```

**説明**:
- 受信待ちキューに待機中のスレッドがいる場合
- バッファを経由せず、直接値を渡す（効率的）
- 受信スレッドのブロックを解除

**例**:
```go
// Thread 0
ch := make(chan int, 3)
v := <-ch  // ブロック（受信待ち）

// Thread 1
ch <- 42   // Thread 0に直接配信、バッファを経由しない
```

---

### Priority 2: バッファに空きがある場合（ノンブロッキング）

```k
rule <thread>...
       <tid> _Tid </tid>
       <k> chanSend(channel(CId, int), V:Int) => .K ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, .List, Buf, Size, int)
            => chanState(SendQ, .List, Buf ListItem(V), Size, int))
     ...</channels>
  requires size(Buf) <Int Size
```

**説明**:
- 受信待ちキューは空（`.List`）
- バッファサイズに空きがある（`size(Buf) < Size`）
- 値をバッファに追加して即座に完了

**例**:
```go
ch := make(chan int, 3)
ch <- 1  // バッファに追加（ブロックしない）
ch <- 2  // バッファに追加（ブロックしない）
ch <- 3  // バッファに追加（ブロックしない）
// バッファ: [1, 2, 3]
```

**状態遷移**:
```
初期: chanState(.List, .List, .List, 3, int)
    ↓ ch <- 1
Step1: chanState(.List, .List, ListItem(1), 3, int)
    ↓ ch <- 2
Step2: chanState(.List, .List, ListItem(1) ListItem(2), 3, int)
    ↓ ch <- 3
Step3: chanState(.List, .List, ListItem(1) ListItem(2) ListItem(3), 3, int)
```

---

### Priority 3: バッファが満杯の場合（ブロッキング）

```k
rule <thread>...
       <tid> Tid </tid>
       <k> chanSend(channel(CId, int), V:Int) => waitingSend(CId, V) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, .List, Buf, Size, int)
            => chanState(SendQ ListItem(sendItem(Tid, V)), .List, Buf, Size, int))
     ...</channels>
  requires size(Buf) >=Int Size
```

**説明**:
- バッファが満杯（`size(Buf) >= Size`）
- 送信スレッドを送信キューに追加
- スレッドは `waitingSend` 状態でブロック

**例**:
```go
ch := make(chan int, 2)
ch <- 1  // OK
ch <- 2  // OK (バッファ満杯)
ch <- 3  // ブロック！受信を待つ
```

**状態**:
```k
chanState(
  ListItem(sendItem(Tid, 3)),  // 送信待ちキューにTidと値3を追加
  .List,
  ListItem(1) ListItem(2),     // バッファ満杯
  2,
  int
)
```

## 受信操作のロジック

受信操作 `<-ch` は4つの優先度でルールが適用されます。

### Priority 1: バッファに値があり、送信待ちもいる場合

```k
rule <thread>...
       <tid> _Tid </tid>
       <k> chanRecv(channel(CId, _T)) => V ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState((ListItem(sendItem(SendTid:Int, SV)) SendRest:List), RecvQ,
                         (ListItem(V) BufRest:List), Size, T)
            => chanState(SendRest, RecvQ, BufRest ListItem(SV), Size, T))
     ...</channels>
     <thread>...
       <tid> SendTid </tid>
       <k> waitingSend(CId, _) => .K ... </k>
     ...</thread>
```

**説明**:
1. バッファの先頭値 `V` を取得
2. 送信待ちキューから1つ取り出し、その値 `SV` をバッファに追加
3. 送信スレッドのブロックを解除

**例**:
```go
ch := make(chan int, 2)
ch <- 1
ch <- 2
go func() {
    ch <- 3  // ブロック（送信待ち）
}()
v := <-ch  // v=1, バッファに3を追加
```

**状態遷移**:
```
Before:
  Buffer: [1, 2]
  SendQueue: [sendItem(tid, 3)]
    ↓ <-ch
After:
  Buffer: [2, 3]
  SendQueue: []
  Return: 1
```

---

### Priority 2: バッファに値があり、送信待ちはいない場合

```k
rule <thread>...
       <tid> _Tid </tid>
       <k> chanRecv(channel(CId, _T)) => V ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, RecvQ, (ListItem(V) BufRest:List), Size, T)
            => chanState(SendQ, RecvQ, BufRest, Size, T))
     ...</channels>
```

**説明**:
- バッファから値を取得するだけ
- 送信待ちキューは空

**例**:
```go
ch := make(chan int, 3)
ch <- 10
ch <- 20
v1 := <-ch  // v1 = 10
v2 := <-ch  // v2 = 20
```

---

### Priority 3: バッファは空だが、送信待ちがいる場合

```k
rule <thread>...
       <tid> _Tid </tid>
       <k> chanRecv(channel(CId, _T)) => V ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState((ListItem(sendItem(SendTid:Int, V)) SendRest:List), RecvQ, .List, Size, T)
            => chanState(SendRest, RecvQ, .List, Size, T))
     ...</channels>
     <thread>...
       <tid> SendTid </tid>
       <k> waitingSend(CId, _) => .K ... </k>
     ...</thread>
```

**説明**:
- バッファは空（`.List`）
- 送信待ちキューから直接取得
- Unbufferedと同じ動作

---

### Priority 4: 何もない場合（ブロッキング）

```k
rule <thread>...
       <tid> Tid </tid>
       <k> chanRecv(channel(CId, _T)) => waitingRecv(CId) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(.List, RecvQ, .List, Size, T)
            => chanState(.List, RecvQ ListItem(Tid), .List, Size, T))
     ...</channels>
```

**説明**:
- バッファ空、送信待ちもなし
- 受信スレッドをブロック

## 具体的な実行例

### 例1: ノンブロッキング送信・受信

**コード**:
```go
package main

func main() {
    ch := make(chan int, 3)
    ch <- 1
    ch <- 2
    ch <- 3
    print(<-ch)
    print(<-ch)
    print(<-ch)
}
```

**実行ステップ**:

#### ステップ1: チャネル作成
```
<k> ch := make(chan int, 3) </k>
    ↓
<channels> 0 |-> chanState(.List, .List, .List, 3, int) </channels>
<env> ch |-> loc(0) </env>
<store> loc(0) |-> channel(0, int) </store>
```

#### ステップ2: 送信 `ch <- 1`
```
Before:
  chanState(.List, .List, .List, 3, int)
    ↓ (Priority 2: バッファに空き)
After:
  chanState(.List, .List, ListItem(1), 3, int)
```

#### ステップ3: 送信 `ch <- 2`
```
Before:
  chanState(.List, .List, ListItem(1), 3, int)
    ↓ (Priority 2: バッファに空き)
After:
  chanState(.List, .List, ListItem(1) ListItem(2), 3, int)
```

#### ステップ4: 送信 `ch <- 3`
```
Before:
  chanState(.List, .List, ListItem(1) ListItem(2), 3, int)
    ↓ (Priority 2: バッファに空き)
After:
  chanState(.List, .List, ListItem(1) ListItem(2) ListItem(3), 3, int)
```

#### ステップ5: 受信 `<-ch`
```
Before:
  chanState(.List, .List, ListItem(1) ListItem(2) ListItem(3), 3, int)
    ↓ (Priority 2: バッファから取得)
After:
  chanState(.List, .List, ListItem(2) ListItem(3), 3, int)
  Return: 1
```

#### ステップ6-7: 残りの受信
```
<-ch → 2
<-ch → 3
```

**出力**:
```
1
2
3
```

---

### 例2: バッファ満杯時のブロッキング

**コード**:
```go
package main

func main() {
    ch := make(chan int, 2)
    ch <- 1
    ch <- 2
    go func() {
        ch <- 3      // ブロック
        print(99)
    }()
    print(<-ch)
    print(<-ch)
    print(<-ch)
}
```

**実行ステップ**:

#### ステップ1-2: バッファに1, 2を追加
```
chanState(.List, .List, ListItem(1) ListItem(2), 2, int)
```

#### ステップ3: Goroutine生成
```
Thread 1が作成される
```

#### ステップ4: Thread 1で `ch <- 3` 実行
```
Before:
  Buffer: [1, 2] (満杯)
  SendQueue: []
    ↓ (Priority 3: バッファ満杯 → ブロック)
After:
  Buffer: [1, 2]
  SendQueue: [sendItem(1, 3)]
  Thread 1: waitingSend(0, 3) でブロック
```

#### ステップ5: Thread 0で `<-ch` 実行
```
Before:
  Buffer: [1, 2]
  SendQueue: [sendItem(1, 3)]
    ↓ (Priority 1: 送信待ちがいる)
After:
  Buffer: [2, 3]
  SendQueue: []
  Thread 1: waitingSend(0, 3) → .K (ブロック解除)
  Return: 1
```

**出力**: `1, 2, 99, 3`

**重要なポイント**:
- Thread 1は `ch <- 3` でブロックされる
- Thread 0が `<-ch` を実行すると、バッファから1を取得し、3をバッファに追加
- Thread 1のブロックが解除され、`print(99)` が実行される

---

### 例3: FIFO順序の保証

**コード**:
```go
package main

func main() {
    ch := make(chan int, 5)
    ch <- 10
    ch <- 20
    ch <- 30
    ch <- 40
    ch <- 50
    print(<-ch)
    print(<-ch)
    print(<-ch)
    print(<-ch)
    print(<-ch)
}
```

**バッファの状態遷移**:
```
初期: []
ch <- 10 → [10]
ch <- 20 → [10, 20]
ch <- 30 → [10, 20, 30]
ch <- 40 → [10, 20, 30, 40]
ch <- 50 → [10, 20, 30, 40, 50]

<-ch → 10, Buffer: [20, 30, 40, 50]
<-ch → 20, Buffer: [30, 40, 50]
<-ch → 30, Buffer: [40, 50]
<-ch → 40, Buffer: [50]
<-ch → 50, Buffer: []
```

**出力**: `10, 20, 30, 40, 50`

**FIFO保証**:
- K FrameworkのListは順序を保持
- `ListItem(V)` がバッファの末尾に追加される
- 先頭から取り出される

## テスト結果

### テストケース一覧

| テスト名 | 説明 | コード | 期待出力 | 実際の出力 | 状態 |
|---------|------|--------|---------|-----------|------|
| **Unbuffered互換** | 既存のunbufferedが動作 | `code-channel-basic` | `42` | `42` | ✅ |
| **Non-blocking送信** | バッファに空きがあれば即座に送信 | `code-buffered-nonblock` | `1, 2, 3` | `1, 2, 3` | ✅ |
| **Buffer満杯ブロック** | 満杯時は送信ブロック | `code-buffered-block` | `1, 2, 99, 3` | `1, 2, 99, 3` | ✅ |
| **FIFO順序** | バッファからFIFO順に取得 | `code-buffered-fifo` | `10, 20, 30, 40, 50` | `10, 20, 30, 40, 50` | ✅ |

### テストコード

#### Test 1: Unbuffered互換性
```go
// codes/code-channel-basic
package main

func main() {
    ch := make(chan int)  // unbuffered (bufferSize=0)
    go func() {
        ch <- 42
    }()
    x := <-ch
    print(x)
}
```

#### Test 2: Non-blocking送信
```go
// codes/code-buffered-nonblock
package main

func main() {
    ch := make(chan int, 3)
    ch <- 1  // 即座に完了
    ch <- 2  // 即座に完了
    ch <- 3  // 即座に完了
    print(<-ch)
    print(<-ch)
    print(<-ch)
}
```

#### Test 3: Buffer満杯でブロック
```go
// codes/code-buffered-block
package main

func main() {
    ch := make(chan int, 2)
    ch <- 1
    ch <- 2
    go func() {
        ch <- 3      // ブロック
        print(99)    // ブロック解除後に実行
    }()
    print(<-ch)
    print(<-ch)
    print(<-ch)
}
```

#### Test 4: FIFO順序
```go
// codes/code-buffered-fifo
package main

func main() {
    ch := make(chan int, 5)
    ch <- 10
    ch <- 20
    ch <- 30
    ch <- 40
    ch <- 50
    print(<-ch)
    print(<-ch)
    print(<-ch)
    print(<-ch)
    print(<-ch)
}
```

## 設計上の工夫

### 1. 優先度ベースのルール適用

K Frameworkは複数のルールがマッチする場合、非決定的に選択します。しかし、`requires` 条件により優先度を制御：

**送信の優先順位**:
1. 受信待ちがいる → 直接配信（最優先）
2. バッファに空き → バッファに追加
3. バッファ満杯 → ブロック

この順序により、最も効率的な動作を実現。

### 2. Unbufferedとの統一

`bufferSize = 0` でunbufferedを表現：
```k
make(chan int)     → chanState(.List, .List, .List, 0, int)
make(chan int, 10) → chanState(.List, .List, .List, 10, int)
```

バッファサイズが0の場合：
- `size(Buf) < Size` → `0 < 0` → false（Priority 2は適用されない）
- `size(Buf) >= Size` → `0 >= 0` → true（Priority 3が適用される）

つまり、unbufferedは常にブロッキングします（既存動作と一致）。

### 3. 型ごとのルール

現在、int型とbool型それぞれに送受信ルールを定義：

```k
// int用
rule <k> chanSend(channel(CId, int), V:Int) => ... </k>

// bool用
rule <k> chanSend(channel(CId, bool), V:Bool) => ... </k>
```

**理由**:
- K FrameworkのパターンマッチングにはValueとTypeの両方が必要
- 将来的にはポリモーフィックなルールに統一可能

## 実装の限界と今後の課題

### 現在の制限

1. **型ごとのルール重複**
   - int, boolそれぞれに送受信ルールが必要
   - 新しい型（string, struct等）を追加する度にルールを追加

2. **close(ch)未実装**
   - チャネルのクローズができない
   - `for range ch` が使えない

3. **select文未実装**
   - 複数チャネルの多重化ができない
   - タイムアウト処理が書けない

### 今後の拡張

#### Phase 2: close(ch) の実装

```go
close(ch)
v, ok := <-ch  // ok=falseでクローズを検出
for v := range ch { ... }  // クローズで自動終了
```

**設計案**:
```k
syntax ChanState ::= chanState(List, List, List, Int, Type, Bool)
                     // 最後のBoolがclosedフラグ

syntax Exp ::= close(Exp) [strict]

rule <k> close(channel(CId, T)) => .K ... </k>
     <channels>...
       CId |-> chanState(SQ, RQ, Buf, Size, T, false)
            => chanState(SQ, RQ, Buf, Size, T, true)
     ...</channels>
```

#### Phase 3: select文の実装

```go
select {
case v := <-ch1:
    print(v)
case ch2 <- 42:
    print("sent")
default:
    print("no comm")
}
```

**設計案**:
- 各caseの準備状態を非決定的にチェック
- 準備できているcaseを選択
- defaultはフォールバック

## まとめ

### 実装のハイライト

✅ **完全な後方互換性**: Unbuffered (bufferSize=0) との互換性
✅ **効率的な動作**: 受信待ちがいる場合はバッファを経由しない
✅ **FIFO保証**: バッファから順序通りに取得
✅ **正確なブロッキング**: バッファ満杯時のみブロック

### 実装の成果

- **構文拡張**: `make(chan T, n)` をサポート
- **データ構造**: `ChanState` にバッファを追加
- **送受信ロジック**: 優先度ベースの複雑なルール
- **テスト**: 4つのテストケースすべて成功

### 学んだこと

1. **K Frameworkの柔軟性**: `requires` 条件でルールの適用順序を制御
2. **非決定性の活用**: 複数の準備できている操作から選択
3. **段階的実装**: Unbuffered → Buffered → close → select

---

**作成日**: 2025-01-30
**K Framework バージョン**: 最新版
**実装者**: Claude Code
**関連ドキュメント**:
- [goroutine-channel-implementation.md](./goroutine-channel-implementation.md)
- [symbol-and-pattern-matching.md](./symbol-and-pattern-matching.md)
