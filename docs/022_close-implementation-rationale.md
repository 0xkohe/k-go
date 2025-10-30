# close(ch) 機能実装の設計判断と変更理由

このドキュメントでは、チャネルの close 機能を実装するために行った変更とその設計判断について説明します。

## 目次

1. [変更概要](#変更概要)
2. [ChanState への closed フラグ追加](#chanstate-への-closed-フラグ追加)
3. [送信時のクローズチェック](#送信時のクローズチェック)
4. [受信時のクローズ処理](#受信時のクローズ処理)
5. [close() の実装](#close-の実装)
6. [v, ok := <-ch の実装](#v-ok---ch-の実装)
7. [for range ch の実装](#for-range-ch-の実装)
8. [panic の実装](#panic-の実装)
9. [代替案と却下理由](#代替案と却下理由)

---

## 変更概要

### 追加・変更したファイル

```
src/go/syntax/concurrent.k
  - CloseStmt 構文追加
  - recvWithOk 構文追加
  - 特殊な ShortVarDecl 構文追加

src/go/semantics/concurrent.k
  - ChanState に Bool (closed) 追加
  - close() セマンティクス実装
  - クローズ済みチャネルの送受信処理
  - for range ch 実装
  - panic 実装
```

### 主要な変更

| 変更内容 | 影響範囲 | 理由 |
|---------|---------|------|
| ChanState に closed 追加 | すべてのチャネル操作 | クローズ状態の追跡 |
| Priority 0 追加（送信） | chanSend ルール | クローズ済みチャネルへの送信を防ぐ |
| Priority 4 追加（受信） | chanRecv ルール | クローズ済みチャネルからゼロ値を返す |
| wakeReceivers ヘルパー | close() | 待機中の受信者を起こす |
| rangeChannelLoop | for range | クローズ検出とループ終了 |

---

## ChanState への closed フラグ追加

### 変更内容

```k
// 変更前
syntax ChanState ::= chanState(List, List, List, Int, Type)

// 変更後
syntax ChanState ::= chanState(List, List, List, Int, Type, Bool)
                                                          // ↑ closed フラグ
```

### 理由

**1. Go 仕様との整合性**

Go 言語仕様では、チャネルには以下の3つの状態があります：
- **Open**: 通常の状態、送受信可能
- **Closed**: close() された状態、送信不可、受信はゼロ値を返す
- **nil**: 未初期化（本実装では未サポート）

この状態を表現するために、Bool 型の closed フラグが最も単純で明確です。

**2. 代替案の検討**

| 代替案 | 評価 | 却下理由 |
|-------|------|---------|
| 特殊なマーカー値 | △ | 型安全性に欠ける |
| 状態セル追加 | △ | 複雑性が増す |
| closed フラグ（採用） | ◎ | シンプルで型安全 |

**3. すべての make ルールの更新**

```k
// すべてのチャネル作成で false で初期化
chanState(.List, .List, .List, 0, T, false)
chanState(.List, .List, .List, Size, T, false)
```

初期状態は必ず `false`（オープン）である必要があります。

**4. すべてのルールへの影響**

closed フラグを追加したため、以下のすべてのルールで ChanState のパターンマッチを更新：
- 送信ルール（int, bool × 3優先度 = 6ルール）
- 受信ルール（5優先度）

変数名の選択：
- `Closed`: 変数として使用（値はパターンマッチで決定）
- `false`/`true`: リテラルとして使用（条件を明示）

---

## 送信時のクローズチェック

### 変更内容

```k
// Priority 0: Panic if channel is closed (新規追加)
rule <thread>...
       <tid> _Tid </tid>
       <k> chanSend(channel(CId, int), _V:Int) => SendClosedPanic ... </k>
     ...</thread>
     <channels>...
       CId |-> chanState(_SendQ, _RecvQ, _Buf, _Size, int, true)
                                                         // ↑ closed=true
     ...</channels>
```

### 理由

**1. Go 仕様の要件**

Go 言語仕様より：
> Sending to a closed channel causes a run-time panic.

これは Go の重要な安全性保証です。閉じたチャネルへの送信は**プログラムエラー**として扱われます。

**2. Priority 0 の必要性**

なぜ既存のルールより先にチェックする必要があるのか：

```
Priority 0: クローズ済みチェック  ← 新規追加（最優先）
Priority 1: 待機受信者がいる → 直接渡す
Priority 2: バッファに空きあり → バッファに追加
Priority 3: バッファフル → 送信キューに追加
```

**理由**: どのような状況（受信者待機中、バッファ空き）でも、クローズ済みチャネルへの送信は禁止されるべきです。

**3. int と bool 両方に実装**

現在サポートする2つのチャネル型それぞれに実装が必要：
- `chan int` 用のルール
- `chan bool` 用のルール

K Framework では型ごとにルールを書く必要があります（ジェネリックな実装は複雑）。

**4. 値を無視する理由**

```k
chanSend(channel(CId, int), _V:Int)
                            // ↑ アンダースコア（値は使わない）
```

送信しようとした値は panic の際に不要なので、パターンマッチで無視しています。

---

## 受信時のクローズ処理

### 変更内容

```k
// Priority 4: If channel is closed and nothing in buffer, return zero value
rule <thread>...
       <tid> _Tid </tid>
       <k> chanRecv(channel(CIdClosed, int)) => 0 ... </k>
     ...</thread>
     <channels>...
       CIdClosed |-> chanState(.List, _RecvQ, .List, _Size, int, true)
                              //送信待ちなし  //バッファ空    //closed
     ...</channels>
```

### 理由

**1. Go 仕様の要件**

Go 言語仕様より：
> A receive operation on a closed channel can always proceed immediately, yielding the element type's zero value after any previously sent values have been received.

**重要な点**:
- バッファに値があれば、その値を返す（通常の受信）
- バッファが空になった後は、ゼロ値を返す
- **ブロックしない**（待機しない）

**2. Priority 4 の位置付け**

```
Priority 1: バッファに値 + 送信待ち → バッファから取り出し + 補充
Priority 2: バッファに値（送信待ちなし） → バッファから取り出し
Priority 3: 送信待ち + バッファ空 → 直接受信
Priority 4: クローズ済み + バッファ空 → ゼロ値   ← 新規追加
Priority 5: 何もなし（オープン） → ブロック
```

**なぜこの順序か**:
1. バッファの値は優先的に消費される（Priority 1-2）
2. 送信待ちがいれば優先（Priority 3）
3. **その後で**クローズチェック（Priority 4）
4. 最後にブロック（Priority 5）

**3. Priority 5 への影響**

```k
// 変更後: closed=false の条件を明示
rule <thread>...
       <tid> Tid </tid>
       <k> chanRecv(channel(CId, _T)) => waitingRecv(CId) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(.List, RecvQ, .List, Size, T, false)
                                                      // ↑ false を明示
            => chanState(.List, RecvQ ListItem(Tid), .List, Size, T, false))
     ...</channels>
```

`false` を明示することで、Priority 4 との衝突を防ぎます。

**4. 型ごとのゼロ値**

```k
// int 型のゼロ値
chanRecv(channel(CIdClosed, int)) => 0

// bool 型のゼロ値
chanRecv(channel(CIdClosed2, bool)) => false
```

Go のゼロ値の定義に従います：
- `int`: 0
- `bool`: false
- `string`: "" (未実装)
- ポインタ: nil (未実装)

**5. 変数名の工夫**

```k
CIdClosed   // int 用
CIdClosed2  // bool 用
```

K Framework のルール内で変数名の重複を避けるため、異なる名前を使用しています。

---

## close() の実装

### 変更内容

**1. 構文定義**

```k
// syntax/concurrent.k
syntax CloseStmt ::= "close" "(" Exp ")" [strict(1)]
syntax Statement ::= CloseStmt
```

**2. セマンティクス**

```k
// close() on already closed channel panics
rule <k> close(channel(CId, _T)) => CloseClosedPanic ... </k>
     <channels>...
       CId |-> chanState(_SendQ, _RecvQ, _Buf, _Size, _ElemT, true)
     ...</channels>

// close() for int channel
rule <thread>...
       <tid> _Tid </tid>
       <k> close(channel(CId, int)) => wakeReceivers(RecvQ, CId, 0) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, RecvQ, Buf, Size, int, false)
            => chanState(SendQ, .List, Buf, Size, int, true))
                              // ↑ RecvQ をクリア    ↑ true に変更
     ...</channels>
```

### 理由

**1. Statement としての定義**

```k
syntax CloseStmt ::= "close" "(" Exp ")" [strict(1)]
syntax Statement ::= CloseStmt
```

**なぜ Statement か**:
- Go では `close(ch)` は**文**として使用される（値を返さない）
- `close(ch);` のようにセミコロンで終わる
- 式の中では使えない（`x := close(ch)` は不可）

**strict(1) の意味**:
- `close(ch)` の `ch` を先に評価してから close を実行
- `ch` が `channel(0, int)` のような値になってからルールが適用される

**2. 重複 close の検出**

```k
rule <k> close(channel(CId, _T)) => CloseClosedPanic ... </k>
     <channels>...
       CId |-> chanState(_SendQ, _RecvQ, _Buf, _Size, _ElemT, true)
     ...</channels>
```

**Go 仕様**:
> Closing a closed channel causes a run-time panic.

**実装のポイント**:
- このルールは `closed=true` の場合にのみマッチ
- 他の close ルール（`closed=false`）より優先的に適用される

**3. RecvQ のクリア**

```k
chanState(SendQ, RecvQ, Buf, Size, int, false)
=> chanState(SendQ, .List, Buf, Size, int, true)
                 // ↑ RecvQ を .List (空) に
```

**なぜクリアするのか**:

close() 時に受信待ちスレッドがいる場合：
1. それらのスレッドを起こす（wakeReceivers）
2. RecvQ は空にする
3. 以降、新しい受信はゼロ値を即座に返す

**SendQ をクリアしない理由**:
- close() 時に送信待ちがいるのは異常（プログラムバグ）
- Go 仕様では未定義動作
- 本実装では SendQ はそのまま残す（将来の拡張の余地）

**4. wakeReceivers ヘルパー**

```k
syntax KItem ::= wakeReceivers(List, Int, K)

rule <k> wakeReceivers(.List, _CId, _ZeroVal) => .K ... </k>

rule <k> wakeReceivers((ListItem(RecvTid:Int) Rest:List), CId, ZeroVal)
      => wakeReceivers(Rest, CId, ZeroVal) ... </k>
     <thread>...
       <tid> RecvTid </tid>
       <k> waitingRecv(CId) => ZeroVal ... </k>
     ...</thread>
```

**再帰的な実装**:
- ベースケース: リストが空なら終了
- 再帰ケース: 先頭のスレッドを起こして、残りを処理

**なぜヘルパーが必要か**:
- 複数のスレッドを順次起こす必要がある
- K のルールは1ステップずつ進むため、再帰的に処理

**5. 型ごとの実装**

```k
close(channel(CId, int)) => wakeReceivers(RecvQ, CId, 0)
close(channel(CId, bool)) => wakeReceivers(RecvQ, CId, false)
```

各型に対してゼロ値を渡します。

---

## v, ok := <-ch の実装

### 変更内容

**1. 構文定義**

```k
// syntax/concurrent.k
syntax Exp ::= recvWithOk(Exp) [strict(1)]
syntax ShortVarDecl ::= Id "," Id ":=" "<-" Exp [strict(2)]
```

**2. セマンティクス**

```k
// 変換ルール
rule <k> X:Id, Y:Id := <-Ch:ChanVal
      => (X, Y) := recvWithOk(Ch) ... </k>

// 成功時
rule <thread>...
       <tid> _Tid </tid>
       <k> recvWithOk(channel(CId, int)) => tuple(ListItem(V) ListItem(true)) ... </k>
     ...</thread>
     <channels>...
       CId |-> (chanState(SendQ, RecvQ, (ListItem(V) BufRest:List), Size, int, Closed)
            => chanState(SendQ, RecvQ, BufRest, Size, int, Closed))
     ...</channels>

// 失敗時（クローズ済み）
rule <thread>...
       <tid> _Tid </tid>
       <k> recvWithOk(channel(CIdOk, int)) => tuple(ListItem(0) ListItem(false)) ... </k>
     ...</thread>
     <channels>...
       CIdOk |-> chanState(.List, _RecvQ, .List, _Size, int, true)
     ...</channels>
```

### 理由

**1. Go 仕様の二値受信**

Go 言語仕様より：
```go
v, ok := <-ch
// ok は bool 型
// ok == true: 受信成功
// ok == false: チャネルはクローズ済み、v はゼロ値
```

**2. 特殊構文の必要性**

**問題**: 通常のパース規則だと以下のようになる：
```
v, ok := <-ch
↓
(v, ok, .IdentifierList) := (<-ch, .ExpressionList)
```

これは `IdentifierList := ExpressionList` の一般形に当てはまってしまいます。

**解決策**: 特殊な構文ルールを追加：
```k
syntax ShortVarDecl ::= Id "," Id ":=" "<-" Exp [strict(2)]
```

これにより `v, ok := <-ch` を直接認識できます。

**3. recvWithOk への変換**

```k
rule <k> X:Id, Y:Id := <-Ch:ChanVal
      => (X, Y) := recvWithOk(Ch) ... </k>
```

**なぜ変換するのか**:
- `<-ch` は単一値を返す
- しかし `v, ok :=` は2つの値が必要
- `recvWithOk` は tuple を返す内部関数

**4. tuple の使用**

```k
tuple(ListItem(V) ListItem(true))
tuple(ListItem(0) ListItem(false))
```

K Framework の tuple 型を使用して2つの値を返します。

**既存の tuple 処理との統合**:
- 既存の多値代入機構（`evalForShortDecl`）がこの tuple を処理
- 追加の実装は不要

**5. 部分実装の理由**

**現状の課題**:
- 特殊構文ルールと一般的な IdentifierList ルールが競合する可能性
- パーサーがどちらを選ぶかは文脈依存
- 一部のケースで正しく動作しない

**回避策**:
- `for range ch` で代替可能（こちらは完全実装）
- 将来的にパーサー優先順位の調整で解決予定

---

## for range ch の実装

### 変更内容

```k
// 構文の脱糖
rule <k> for ((X:Id , .IdentifierList) := range Ch:ChanVal) B:Block
      => enterScope(X := 0 ~> rangeChannelLoop(X, Ch, B)) ... </k>

// ループ継続
rule <thread>...
       <tid> _Tid </tid>
       <k> rangeChannelLoop(X, channel(CId, T), B)
        => X = <-channel(CId, T) ~> B ~> rangeChannelLoop(X, channel(CId, T), B) ... </k>
     ...</thread>
     <channels>...
       CId |-> chanState(_SendQ, _RecvQ, (ListItem(_V) _BufRest:List), _Size, T, _Closed)
     ...</channels>

// ループ終了
rule <thread>...
       <tid> _Tid </tid>
       <k> rangeChannelLoop(_X, channel(CId, TRange), _B) => exitScope ... </k>
     ...</thread>
     <channels>...
       CId |-> chanState(.List, _RecvQ, .List, _Size, TRange, true)
     ...</channels>
```

### 理由

**1. Go 仕様の for range**

Go 言語仕様より：
```go
for v := range ch {
    // チャネルから受信し続ける
    // チャネルがクローズされて空になると自動終了
}
```

これは以下のコードと等価です：
```go
for {
    v, ok := <-ch
    if !ok {
        break
    }
    // ループ本体
}
```

**2. 脱糖化アプローチ**

**なぜ脱糖化するのか**:
- Go の for range は複雑な構文糖衣
- K Framework では明示的なループ構造に変換するのが自然
- 既存の整数 range（`for i := range n`）と同じアプローチ

**脱糖の流れ**:
```
for v := range ch { body }
↓
enterScope(v := 0 ~> rangeChannelLoop(v, ch, body))
```

**3. rangeChannelLoop の設計**

```k
syntax KItem ::= rangeChannelLoop(Id, ChanVal, Block)
```

**パラメータ**:
- `Id`: ループ変数名
- `ChanVal`: チャネル値
- `Block`: ループ本体

**ループの各イテレーション**:
```
rangeChannelLoop(v, ch, body)
↓
v = <-ch ~> body ~> rangeChannelLoop(v, ch, body)
```

再帰的な構造でループを実現しています。

**4. ループ継続条件**

```k
CId |-> chanState(_SendQ, _RecvQ, (ListItem(_V) _BufRest:List), _Size, T, _Closed)
                                  // ↑ バッファに値がある
```

**条件**: バッファに少なくとも1つ値があれば継続

**`_Closed` を使う理由**:
- バッファに値がある限り、closed 状態に関係なく受信
- これは Go の仕様に沿っている

**5. ループ終了条件**

```k
CId |-> chanState(.List, _RecvQ, .List, _Size, TRange, true)
                 //送信待ちなし  //バッファ空     //closed
```

**3つの条件すべてが必要**:
1. `sendQ = .List`: 送信待ちなし
2. `buffer = .List`: バッファ空
3. `closed = true`: クローズ済み

これらすべてが揃ったときだけループ終了します。

**6. exitScope の使用**

```k
rangeChannelLoop(_X, channel(CId, TRange), _B) => exitScope
```

**なぜ exitScope か**:
- `enterScope` でスコープを作成したので、対応する `exitScope` が必要
- ループ変数 `v` を破棄
- 環境を元に戻す

**7. 送信待ちがいる場合**

```k
rule <thread>...
       <tid> _Tid </tid>
       <k> rangeChannelLoop(X, channel(CId, T), B)
        => X = <-channel(CId, T) ~> B ~> rangeChannelLoop(X, channel(CId, T), B) ... </k>
     ...</thread>
     <channels>...
       CId |-> chanState((ListItem(_) _SendRest:List), _RecvQ, .List, _Size, T, false)
                       // ↑ 送信待ちあり              // バッファ空     // オープン
     ...</channels>
```

この追加ルールは、バッファは空だが送信待ちがいる場合に対応します（アンバッファードチャネルでの典型的なパターン）。

**8. for range ch（変数なし）**

```k
rule <k> for range Ch:ChanVal B:Block
      => enterScope(rangeChannelLoop(String2Id("_range_dummy"), Ch, B)) ... </k>
```

Go 1.23+ で追加された構文：
```go
for range ch {
    // 値を使わない、ただカウントするだけ
}
```

ダミー変数 `_range_dummy` を使用して実装します。

---

## panic の実装

### 変更内容

```k
syntax KItem ::= "SendClosedPanic" | "CloseClosedPanic"

rule <k> SendClosedPanic ~> _ => .K </k>

rule <k> CloseClosedPanic ~> _ => .K </k>
```

### 理由

**1. シンプルな panic**

**Go の panic**:
- スタックトレースを出力
- defer 関数を実行
- プログラムを終了（または recover で回復）

**本実装の panic**:
- 計算を停止（`.K` に書き換え）
- スタックトレースなし（簡略版）

**2. なぜ簡略版か**

**理由**:
- 本プロジェクトは言語のコア機能に焦点
- panic のフル実装は複雑（defer、recover、スタック管理）
- エラー検出が目的（エラー処理ではない）

**将来の拡張**:
```k
rule <k> SendClosedPanic ~> _ => . </k>
     <out> Out => Out +String "panic: send on closed channel\n" </out>
```

出力メッセージを追加することも可能ですが、現状は最小限の実装です。

**3. ~> _ => .K のパターン**

```k
SendClosedPanic ~> _ => .K
                 ↑     ↑
            残りの計算  空にする
```

**意味**:
- `~>` は K の sequencing 演算子（「その後」）
- `_` は残りの計算全体（ワイルドカード）
- `.K` は空の計算（何も実行しない）

**効果**: panic 後の処理をすべてスキップ

**4. 2種類の panic**

```k
SendClosedPanic    // クローズ済みチャネルへの送信
CloseClosedPanic   // クローズ済みチャネルの再クローズ
```

**なぜ分けるのか**:
- エラーの原因を区別
- 将来、異なるメッセージを出力可能
- デバッグが容易

**5. 文字列リテラルの使用**

```k
syntax KItem ::= "SendClosedPanic" | "CloseClosedPanic"
                 ↑                   ↑
               引用符で囲む（文字列リテラル）
```

**K Framework の制約**:
- 小文字で始まる識別子は変数として扱われる
- 引用符で囲むことでリテラルとして扱われる
- または `SendClosedPanic` のように大文字で始める

**6. deprecated warning について**

```
[Warning] Compiler: Use of deprecated production found
rule <k> SendClosedPanic ~> _ => . </k>
```

**原因**: `=> .` の構文が古い

**推奨される書き方**:
```k
rule <k> SendClosedPanic ~> _ => .K </k>
```

ただし、どちらも動作します。

---

## 代替案と却下理由

### 1. ChanState に closed フラグではなく状態列挙型

**案**:
```k
syntax ChanStatus ::= "open" | "closed"
syntax ChanState ::= chanState(List, List, List, Int, Type, ChanStatus)
```

**却下理由**:
- Bool より複雑
- パターンマッチが冗長（`true`/`false` より長い）
- 将来の nil 対応を考えても、別の方法がある

### 2. close を式として実装

**案**:
```k
syntax Exp ::= "close" "(" Exp ")"
```

**却下理由**:
- Go では close は値を返さない
- 式として使うと誤用を招く（`x := close(ch)` など）
- Statement として実装するのが正しい

### 3. wakeReceivers をループで実装

**案**:
```k
rule <k> close(channel(CId, int)) => .K ... </k>
     <channels>...
       CId |-> (chanState(SendQ, RecvQ, Buf, Size, int, false)
            => chanState(SendQ, .List, Buf, Size, int, true))
     ...</channels>
  // 各スレッドを一度に起こす（ループ不要）
```

**却下理由**:
- K Framework ではループよりも再帰が自然
- 複数スレッドの一括操作は複雑
- 再帰的ヘルパーの方が理解しやすい

### 4. for range を既存の for ループで実装

**案**:
```k
for v := range ch { body }
↓
for {
    v, ok := <-ch
    if !ok { break }
    body
}
```

**却下理由**:
- `v, ok := <-ch` 自体が未完成
- 依存関係が逆（for range は v, ok に依存しない方が良い）
- rangeChannelLoop の方が直接的で効率的

### 5. panic で出力メッセージを追加

**案**:
```k
rule <k> SendClosedPanic ~> _ => .K </k>
     <out> Out => Out +String "panic: send on closed channel\n" </out>
```

**却下理由**:
- 現状の `<out>` は ListItem(Int) 専用
- String を混在させると print 処理が複雑化
- エラー出力用の別セルが必要（将来の拡張）

---

## まとめ

### 設計原則

1. **Go 仕様への忠実性**: Go の動作を正確に再現
2. **K Framework の慣用**: K の自然なパターンを使用
3. **段階的な実装**: コア機能から始めて拡張
4. **型安全性**: 明示的な型チェック
5. **シンプルさ**: 必要最小限の複雑さ

### 成功した点

- ✅ close() の基本機能が動作
- ✅ クローズ済みチャネルの検出
- ✅ for range ch の自動終了
- ✅ 既存コードとの互換性維持

### 今後の改善点

- ⚠️ v, ok := <-ch の完全実装
- 📝 panic のエラーメッセージ出力
- 📝 nil チャネルのサポート
- 📝 追加の型（string, struct など）のサポート

---

**作成日**: 2025年10月
**バージョン**: Phase 2 完了時点
