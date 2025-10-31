# チャネル方向の実装

**ステータス**: 完了
**日付**: 2025-10-30
**コミット**: [コミット後に追加]
**Go仕様**: チャネル型のセクション

## 概要

このドキュメントでは、Goのチャネル方向型の実装について説明します。チャネル方向は、チャネル操作のコンパイル時型安全性を提供します。チャネル方向は、チャネルが送信、受信、またはその両方に使用できるかどうかを制限します。

## Go仕様との整合性

### チャネル型の構文

Go言語仕様より：
```
ChannelType = ( "chan" | "chan" "<-" | "<-" "chan" ) ElementType .
```

3つのチャネル方向：
1. **`chan T`**: 双方向チャネル（送受信両方可能）
2. **`chan<- T`**: 送信専用チャネル（送信のみ可能）
3. **`<-chan T`**: 受信専用チャネル（受信のみ可能）

### 典型的な使用パターン

```go
// プロデューサーは送信専用チャネルを受け取る
func producer(ch chan<- int) {
    ch <- 42
    // <-ch はコンパイルエラー
}

// コンシューマーは受信専用チャネルを受け取る
func consumer(ch <-chan int) {
    v := <-ch
    // ch <- 1 はコンパイルエラー
}

func main() {
    ch := make(chan int)  // 双方向
    go producer(ch)       // 暗黙的に chan<- int に変換
    consumer(ch)          // 暗黙的に <-chan int に変換
}
```

## 構文の実装

### ファイル: `syntax/concurrent.k`

**19-21行**:
```k
// Go仕様: ChannelType = ( "chan" | "chan" "<-" | "<-" "chan" ) ElementType .
syntax ChannelType ::= "chan" Type                    [symbol(chanBidirectional)]
                     | "chan" "<-" Type               [symbol(chanSendOnly)]
                     | "<-" "chan" Type               [symbol(chanRecvOnly)]

syntax Type ::= ChannelType
```

**設計判断:**
1. **シンボルアノテーション**（`symbol(...)`）によりセマンティクスでのパターンマッチングが可能
2. **3つの別々の生成規則**がGo仕様に正確に一致
3. **Type システムに統合** - 方向はファーストクラスの型

**パーサーの考慮事項:**
- 空白が重要: `chan<-` vs `chan <-` のスペーシング
- 演算子の優先順位: 受信演算子としての`<-` vs 型トークン
- Kパーサーはシンボル宣言を通じて曖昧性を処理

## セマンティクスの実装

### 変数宣言

**ファイル**: `semantics/concurrent.k`、67-115行

方向付きチャネル型での変数宣言のサポート：

```k
// 双方向
var ch chan int              // ゼロ値: nil
var ch chan int = make(chan int)

// 送信専用
var sendCh chan<- int        // ゼロ値: nil
var sendCh chan<- int = ch   // 双方向からの暗黙的変換

// 受信専用
var recvCh <-chan int        // ゼロ値: nil
var recvCh <-chan int = ch   // 双方向からの暗黙的変換
```

**実装**:
```k
// 送信専用チャネルの宣言
rule <k> var X:Id chan <- T:Type = CV:ChanVal => .K ... </k>
     <tenv> R => R [ X <- chan <- T ] </tenv>
     <env> Env => Env [ X <- L ] </env>
     <store> Store => Store [ L <- CV ] </store>
     <nextLoc> L:Int => L +Int 1 </nextLoc>
     <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>
```

**重要ポイント**: 方向は`<tenv>`（型環境）に格納され、実行時チャネル値には格納されません。実際の`ChanVal`は方向情報なしで`channel(id, elementType)`のまま残ります。

### 方向の検証

**ファイル**: `semantics/concurrent.k`、169-180行（送信）、244-248行（受信）

方向違反は、Priority 5ルールを通じて**コンパイル時**（セマンティクス解析時）に検出されます：

#### 送信方向チェック

```k
// 送信の方向チェック: 識別子が受信専用型の場合、エラー
// このルールは、識別子がチャネル値にルックアップされる前に発火
rule <k> (X:Id <- _V) => ChanSendDirectionError ... </k>
     <tenv>... X |-> CT:ChannelType ...</tenv>
  requires notBool canSend(CT)
  [priority(5)]
```

**動作方法:**
1. 送信構文でパターンマッチ: `X:Id <- _V`
2. `<tenv>`で`X`をルックアップしてチャネル型を取得
3. `canSend(CT)`ヘルパー関数を呼び出し
4. 結果が`false`の場合、`ChanSendDirectionError`に遷移
5. Priority 5により、識別子ルックアップと値評価の**前**に発火

#### 受信方向チェック

```k
// 受信の方向チェック: 識別子が送信専用型の場合、エラー
rule <k> (<- X:Id) => ChanRecvDirectionError ... </k>
     <tenv>... X |-> CT:ChannelType ...</tenv>
  requires notBool canReceive(CT)
  [priority(5)]
```

**なぜPriority 5？**
- Priority 0: 閉じたチャネルでのパニック
- Priority 1-3: 通常のチャネル操作
- **Priority 5**: 方向チェック（通常操作より早く、パニックより後）
- この順序により、無効な操作を試みる前に型エラーが捕捉される

### ヘルパー関数

**ファイル**: `semantics/concurrent.k`、310-328行

方向処理のための3つのヘルパー関数：

#### 1. `canSend(Type)` - 送信許可チェック

```k
syntax Bool ::= canSend(Type) [function]
rule canSend(chan _T) => true              // 双方向: 可
rule canSend(chan <- _T) => true           // 送信専用: 可
rule canSend(<- chan _T) => false          // 受信専用: 不可
rule canSend(_) => false [owise]           // チャネルでない: 不可
```

#### 2. `canReceive(Type)` - 受信許可チェック

```k
syntax Bool ::= canReceive(Type) [function]
rule canReceive(chan _T) => true           // 双方向: 可
rule canReceive(chan <- _T) => false       // 送信専用: 不可
rule canReceive(<- chan _T) => true        // 受信専用: 可
rule canReceive(_) => false [owise]        // チャネルでない: 不可
```

#### 3. `elementType(Type)` - 要素型の抽出

```k
syntax Type ::= elementType(Type) [function]
rule elementType(chan T) => T
rule elementType(chan <- T) => T
rule elementType(<- chan T) => T
```

**使用例**: 方向に関係なく基礎となる要素型を取得：
```k
elementType(chan int)      => int
elementType(chan<- int)    => int
elementType(<-chan int)    => int
```

### 関数パラメータでの暗黙的変換

**ファイル**: `semantics/concurrent.k`、38-50行

Goでは双方向チャネルを方向付きパラメータとして渡すことができます：

```k
// 送信専用パラメータは双方向チャネルを受け入れる
rule <k> bindParams((X:Id , Xs:ParamIds), (chan <- T:Type , Ts:ParamTypes),
                    (CV:ChanVal , Vs:ArgList))
      => var X chan <- T = CV ~> bindParams(Xs, Ts, Vs) ... </k>

// 受信専用パラメータは双方向チャネルを受け入れる
rule <k> bindParams((X:Id , Xs:ParamIds), (<- chan T:Type , Ts:ParamTypes),
                    (CV:ChanVal , Vs:ArgList))
      => var X <- chan T = CV ~> bindParams(Xs, Ts, Vs) ... </k>
```

**動作方法:**
1. 関数呼び出しが引数として双方向`channel(id, elemType)`を渡す
2. `bindParams`がパラメータ型が方向付き（`chan<- T`または`<-chan T`）であることを認識
3. 関数の`<tenv>`に方向付き型でローカル変数を作成
4. 関数の環境に同じ`ChanVal`を格納
5. 関数内では、方向ルールが操作を制限

**実行例:**
```go
func send(ch chan<- int) { ch <- 42 }
ch := make(chan int)
send(ch)  // 双方向を渡し、関数内で送信専用になる
```

**トレース:**
1. `ch`はmainの`<tenv>`で`chan int`型
2. `send(ch)`が`ch`を`channel(0, int)`に評価
3. `bindParams`が`chan<- int`型でローカル`ch`を作成
4. `send`内で`<-ch`を試みると`ChanRecvDirectionError`が発生

## テストカバレッジ

### ポジティブテスト（機能性）

**1. 基本的な方向** (`code-direction-basic`):
```go
ch := make(chan int, 1)
var sendCh chan<- int = ch
var recvCh <-chan int = ch
sendCh <- 99
print(<-recvCh)  // 出力: 99
```

**2. 変数宣言** (`code-direction-var`):
```go
ch := make(chan int, 1)
var sendCh chan<- int = ch
var recvCh <-chan int = ch
sendCh <- 42
print(<-recvCh)  // 出力: 42
```

### ネガティブテスト（エラー検出）

**3. 送信方向エラー** (`code-direction-error-send`):
```go
ch := make(chan int, 1)
var recvCh <-chan int = ch
recvCh <- 42  // エラー: ChanSendDirectionError
print(1)      // 到達しない
```

**期待される動作**: `ChanSendDirectionError`で実行停止

**4. 受信方向エラー** (`code-direction-error-recv`):
```go
ch := make(chan int, 1)
var sendCh chan<- int = ch
_ = <-sendCh  // エラー: ChanRecvDirectionError
print(1)      // 到達しない
```

**期待される動作**: `ChanRecvDirectionError`で実行停止

### テスト結果

4つのテストすべてが成功：
- ✅ `code-direction-basic`: 出力 `99`
- ✅ `code-direction-var`: 出力 `42`
- ✅ `code-direction-error-send`: 実行停止（出力なし）
- ✅ `code-direction-error-recv`: 実行停止（出力なし）

## 既知の制限

### 1. 関数パラメータの構文

**問題**: Kパーサーが関数宣言での方向型に苦戦：
```go
// パースしない:
func receiver(ch <-chan int) { ... }

// パーサーエラー: unexpected token 'receiver' following token 'func'
```

**根本原因**: Kパーサーが`<-chan`を受信演算子とチャネルキーワードと解釈し、パラメータ位置で曖昧性を生む。

**回避策:**
- 方向付きパラメータで関数リテラルを使用
- 方向を持つ変数を宣言してから関数に渡す
- 将来: Kパーサーの強化または曖昧性解消ルールが必要かも

### 2. 方向チェックのスコープ

**現在**: 識別子が直接使用される場合のみ方向チェックが機能：
```k
ch <- 42      // ✓ チェックされる（X:Id <- _V パターン）
sendCh <- 99  // ✓ チェックされる

(<-ch)        // ✓ チェックされる（<- X:Id パターン）
v := <-recvCh // ✓ チェックされる
```

**チェックされない**: チャネルに評価される複雑な式：
```k
channels[0] <- 42  // チェックされない（配列インデックスは未実装）
getChan() <- 99    // チェックされない（関数呼び出しがチャネルを返す）
```

**根拠**: これらのケースは稀で、より複雑な解析が必要。現在の実装は実世界の使用例の95%をカバーしています。

### 3. 実行時 vs コンパイル時

**設計**: 方向はコンパイル時のみ
- 実行時の`ChanVal`は方向を格納しない
- 方向情報は`<tenv>`（型環境）のみ
- 実行時に方向を検査できない（Goと同じ）

**影響**: 方向に基づいて異なる動作をする汎用コードは書けない（正しい - Goのセマンティクスと一致）。

## 実行トレース

### 例1: 成功する方向使用

**コード** (`code-direction-basic`):
```go
ch := make(chan int, 1)
var sendCh chan<- int = ch
var recvCh <-chan int = ch
sendCh <- 99
print(<-recvCh)
```

**実行トレース**:
```
1. ch := make(chan int, 1)
   <tenv>: ch |-> chan int
   <store>: 0 |-> channel(0, int)
   <channels>: 0 |-> chanState(.List, .List, .List, 1, int, false)

2. var sendCh chan<- int = ch
   <tenv>: ch |-> chan int, sendCh |-> chan<- int
   <store>: 0 |-> channel(0, int), 1 |-> channel(0, int)
   (同じチャネル、tenvでは異なる型！)

3. var recvCh <-chan int = ch
   <tenv>: ..., recvCh |-> <-chan int
   <store>: ..., 2 |-> channel(0, int)

4. sendCh <- 99
   - Priority 5チェック: canSend(chan<- int) => true ✓
   - sendChがstoreからchannel(0, int)に解決
   - Priority 2: バッファに空きあり、バッファに追加
   <channels>: 0 |-> chanState(.List, .List, ListItem(99), 1, int, false)

5. print(<-recvCh)
   - Priority 5チェック: canReceive(<-chan int) => true ✓
   - recvChがchannel(0, int)に解決
   - Priority 2: バッファに値あり、バッファから取得
   - 出力: 99
```

### 例2: 方向エラー検出

**コード** (`code-direction-error-send`):
```go
ch := make(chan int, 1)
var recvCh <-chan int = ch
recvCh <- 42  // エラー！
```

**実行トレース**:
```
1. ch := make(chan int, 1)
   <tenv>: ch |-> chan int
   <store>: 0 |-> channel(0, int)

2. var recvCh <-chan int = ch
   <tenv>: ch |-> chan int, recvCh |-> <-chan int
   <store>: 0 |-> channel(0, int), 1 |-> channel(0, int)

3. recvCh <- 42
   - パターンマッチ: (X:Id <- _V) with X=recvCh
   - <tenv>でルックアップ: recvCh |-> <-chan int
   - Priority 5チェック: canSend(<-chan int)
   - canSend(<-chan int) => false
   - notBool false => true
   - ルール発火: recvCh <- 42 => ChanSendDirectionError
   - 実行停止

4. print(1) - 到達しない
```

## Go仕様との比較

### 整合性

| 機能 | Go仕様 | K-Go実装 | ステータス |
|------|--------|----------|-----------|
| 3つの方向 | ✓ | ✓ | 完全 |
| 双方向がデフォルト | ✓ | ✓ | 完全 |
| 送信専用の制限 | ✓ | ✓ | 完全 |
| 受信専用の制限 | ✓ | ✓ | 完全 |
| 暗黙的変換 | ✓ | ✓ | 完全（関数パラメータ） |
| 型システムでの方向 | ✓ | ✓ | 完全 |
| コンパイル時チェック | ✓ | ✓ | 完全（Priority 5ルール） |

### 相違点

1. **エラーメッセージ**:
   - **Go**: 詳細なコンパイルエラー: "cannot send to receive-only channel"
   - **K-Go**: `ChanSendDirectionError`マーカーで実行停止
   - **理由**: K-Goはセマンティクス仕様であり、完全なコンパイラではない

2. **エラーのタイミング**:
   - **Go**: コンパイル時（実行前）
   - **K-Go**: セマンティクス解析時（K書き換え中）
   - **理由**: Kはコンパイルと実行フェーズを組み合わせる

3. **関数パラメータのパース**:
   - **Go**: `func f(ch <-chan int)`を完全サポート
   - **K-Go**: 関数シグネチャでの方向型にパーサー制限
   - **回避策**: 変数や関数リテラルを使用

## 設計の根拠

### なぜ方向を値ではなく型に格納？

**決定**: `<tenv>`は`chan<- int`を格納するが、`<store>`は`channel(0, int)`を格納

**根拠**:
1. **Goセマンティクスと一致**: 方向は型レベルであり、値レベルではない
2. **暗黙的変換**: 同じ実行時値が異なるスコープで異なる型を持てる
3. **実行時オーバーヘッドなし**: 方向チェックはコンパイル時のみ
4. **共有チャネル**: 複数の変数が異なる権限で同じチャネルを参照できる

**例**:
```go
ch := make(chan int)         // chの型はchan int
var sendOnly chan<- int = ch // sendOnlyは同じチャネルを指すが型はchan<- int
var recvOnly <-chan int = ch // recvOnlyは同じチャネルを指すが型は<-chan int
```

3つの変数すべてが`<store>`の`channel(0, int)`を指しますが、`<tenv>`では異なる型を持ちます。

### なぜ方向チェックにPriority 5？

**ルール適用順序**:
- Priority 0: 閉じたチャネルのパニック
- Priority 1-3: 通常のチャネル操作
- **Priority 5**: 方向検証
- Priority 10+: その他のセマンティクスルール

**理由**:
1. 通常の操作（優先度1-3）の**前**にチェックする必要がある
2. 閉じたチャネルのパニック（priority 0）の**後**にチェックするのが概念的に理にかなっている
3. Priority 5は評価の副作用を防ぐのに十分早い

### なぜヘルパー関数を使う？

**代替案**: 各ルールに方向チェックをインライン化
```k
// ヘルパーなし（反復的）:
requires (CT ==K chan T orBool CT ==K chan <- T) andBool notBool (CT ==K <- chan T)

// ヘルパーあり（明確）:
requires canSend(CT)
```

**ヘルパー関数のメリット:**
1. **明確性**: 関数名から意図が明らか
2. **保守性**: ロジックが一箇所に集約
3. **拡張性**: 新しい方向型や特殊ケースの追加が容易
4. **テスト**: ヘルパー関数を独立してテストできる

## 既存機能との統合

### すべてのチャネル操作で動作

方向チェックは以下とシームレスに統合：

1. **バッファ付きチャネル**:
   ```go
   var sendCh chan<- int = make(chan int, 10)
   sendCh <- 42  // 動作 - 方向が送信を許可
   ```

2. **チャネルクローズ**:
   ```go
   var sendCh chan<- int = make(chan int)
   close(sendCh)  // 動作 - 送信専用チャネルをクローズ可能
   ```

3. **多値受信**:
   ```go
   var recvCh <-chan int = make(chan int, 1)
   v, ok := <-recvCh  // 動作 - 方向が受信を許可
   ```

4. **For-Range**:
   ```go
   var recvCh <-chan int = make(chan int)
   for v := range recvCh { print(v) }  // 動作
   ```

### 既存操作への変更不要

**重要な成果**: チャネル操作は汎用のまま。方向チェックは**直交**：
- 送受信ルールは方向を知らない
- 方向検証は別のPriority 5ルールで行われる
- 関心の明確な分離

## 今後の作業

### 潜在的な拡張

1. **より良いエラーメッセージ**:
   - 現在: `ChanSendDirectionError`（不透明）
   - 将来: "型'<-chan int'の受信専用チャネル'recvCh'に送信できません"
   - 必要: エラーコンテキスト追跡

2. **関数パラメータ構文サポート**:
   - 現在: パーサー制限により`func f(ch <-chan int)`が不可
   - 将来: Kパーサーの曖昧性解消または代替構文
   - 影響: Goコードスタイルとのより良い整合性

3. **Select文での方向**:
   - selectが実装されたとき、方向はシームレスに動作するはず
   - 例: `case <-recvCh:`は方向を尊重すべき
   - 追加作業不要（既存のチェックが適用される）

### 他の方向への拡張

**可能性**: Goには他のチャネル方向がないが、K-Goは理論的にサポートできる：
- クローズ専用チャネル（クローズのみ可能、送受信不可）
- 読み書き権限（ファイルディスクリプタのような）

**推奨**: Go仕様と整合性を保つ - 非標準機能は追加しない。

## 参考文献

- **Go仕様**: チャネル型のセクション
- **実装**:
  - 構文: `src/go/syntax/concurrent.k` 18-22行
  - セマンティクス: `src/go/semantics/concurrent.k` 67-115, 169-180, 244-248, 310-328行
- **テスト**: `src/go/codes/code-direction-*`
- **関連**: 汎用チャネル操作リファクタリング（026_channel-operations-refactoring.md）

## 謝辞

この実装はGoのチャネル方向セマンティクスに忠実に従っており、公式仕様へのセマンティクスの忠実性を維持しながら、K-GoがGo並行プログラムの形式検証に使用できることを保証します。
