# strictとcontextの違い：なぜcontextはネストしていても機能するのか？

## 概要

K Frameworkにおいて、`strict`アノテーションはネストした構文で機能しないのに、`context`ルールはネストしていても機能します。この違いの本質を理解することが重要です。

## 根本的な違い

### strictは「属性ベース」の評価

```k
syntax RangeClause ::= IdentifierList ":=" "range" Exp [strict(2)]
                                                        ↑
                                                    属性（メタ情報）
```

- 構文定義に付随する**メタ情報**
- K Frameworkが構文を**マッチング**した時に参照される
- **直接の子要素**にのみ適用される

### contextは「パターンマッチングベース」の評価

```k
context for ((_ , .IdentifierList) := range HOLE:Exp) _
        ↑
    項全体にマッチするパターン
```

- **書き換えルール**の一種
- 項全体をスキャンして**パターンにマッチする部分**を探す
- **ネストの深さは関係ない**

## K Frameworkの内部動作

### strictの処理フロー

```
1. 構文マッチング
   ↓
2. マッチした構文の属性を確認
   ↓
3. strict属性があれば、指定された位置の引数を評価
   ↓
4. ただし、これは直接の子要素にのみ適用
```

**例：**

```k
syntax ForStmt ::= "for" RangeClause Block
syntax RangeClause ::= IdentifierList ":=" "range" Exp [strict(2)]
```

```
項: for (i := range n) { ... }
     ↓
マッチング階層:
ForStmt
├── RangeClause (値として扱われる)
└── Block

処理:
1. ForStmt にマッチ
2. ForStmt の属性を確認 → なし
3. 子要素 RangeClause は「値」
4. 値の中の属性（strict）は見られない
5. n は評価されない ❌
```

### contextの処理フロー

```
1. 項全体を走査（トップダウンまたはボトムアップ）
   ↓
2. 各contextルールのパターンとマッチングを試みる
   ↓
3. マッチしたら、HOLEの位置を評価コンテキストとして扱う
   ↓
4. ネストの深さは関係ない（パターンさえマッチすればOK）
```

**例：**

```k
context for ((_ , .IdentifierList) := range HOLE:Exp) _
```

```
項: for (i := range n) { ... }
     ↓
パターンマッチング:
context for ((_ , .IdentifierList) := range HOLE:Exp) _
              ↓                              ↓
        for ((i , .IdentifierList) := range n) { ... }
              マッチ✓                         ↑
                                          HOLEにマッチ

処理:
1. contextパターンを項全体に適用
2. パターンマッチ成功
3. n の位置がHOLE → 評価対象
4. n が評価される ✅
```

## 視覚的な比較

### strictの視界（属性の伝播範囲）

```
構文定義:
syntax A ::= Exp [strict]           ← A の直接の引数に適用
syntax B ::= A                      ← A は B の子要素（値）

項:
B
└── A ← これは「値」、属性は見えない
    └── Exp ← strict は届かない ❌
```

strictの「視界」：
```
[構文定義の直接の引数] → ✅ 見える
[ネストした構文内部]   → ❌ 見えない（値として扱われる）
```

### contextの視界（パターンマッチング範囲）

```
contextルール:
context B(A(HOLE:Exp))              ← パターン全体を指定

項:
B
└── A
    └── Exp ← パターンマッチで到達可能 ✅
```

contextの「視界」：
```
[パターンにマッチする全ての項] → ✅ 見える
[ネストの深さ]                → 関係なし
```

## なぜこのような設計なのか？

### 設計哲学

#### strictの目的

**簡潔さ**と**読みやすさ**：

```k
syntax Stmt ::= "print" Exp [strict]
```

これだけで「Expを評価してから実行」という意図が明確。

利点：
- ✅ 簡潔
- ✅ 宣言的
- ✅ 読みやすい

欠点：
- ❌ 柔軟性が低い
- ❌ ネストに対応できない
- ❌ 複雑なパターンには不十分

#### contextの目的

**柔軟性**と**表現力**：

```k
context for ((_ , .IdentifierList) := range HOLE:Exp) _
```

任意の複雑なパターンに対応可能。

利点：
- ✅ 完全な制御
- ✅ ネスト対応
- ✅ 複雑なパターン対応
- ✅ 任意の位置に適用可能

欠点：
- ❌ 冗長
- ❌ 明示的に書く必要がある

### 使い分け

| 状況 | strict | context |
|------|--------|---------|
| フラットな構文 | ✅ 推奨 | 使える |
| ネストした構文 | ❌ 不可 | ✅ 必須 |
| 複雑なパターン | ❌ 不可 | ✅ 必須 |
| 簡潔さ重視 | ✅ 適切 | 冗長 |

## 技術的な深掘り

### K Frameworkの項の表現

K Frameworkでは、全ての項は**項木（term tree）**として表現されます：

```
項: for (i := range n) { print(i); }

項木:
ForStmt(
  RangeClause(
    IdentifierList(Id("i"), .IdentifierList),
    "range",
    Id("n")
  ),
  Block(...)
)
```

### strictの適用範囲

strictは**構文定義のレベル**で動作します：

```k
syntax RangeClause ::= IdentifierList ":=" "range" Exp [strict(2)]
```

K Frameworkの内部処理：
1. `RangeClause(...)`という項を見つける
2. strict(2)属性を確認
3. 2番目の引数（Exp）を評価コンテキストに置く

**でも：**
```k
syntax ForStmt ::= "for" RangeClause Block
```

`ForStmt`をマッチングする時：
1. `ForStmt(RangeClause(...), Block(...))`にマッチ
2. `ForStmt`の属性を確認 → なし
3. 引数`RangeClause(...)`は**既に構築された項**（値）
4. その項の内部構造（strict属性）は**もう見られない**

なぜなら、K Frameworkは**構文を解析する時**にstrictを適用するからです。`ForStmt`を解析する段階では、`RangeClause`は既に解析済みの**値**として扱われます。

### contextの適用範囲

contextは**項のパターンマッチング**で動作します：

```k
context for ((_ , .IdentifierList) := range HOLE:Exp) _
```

K Frameworkの内部処理：
1. **全ての項**を走査
2. 各項に対してcontextパターンとマッチングを試みる
3. マッチしたら、`HOLE`の位置を評価コンテキストとする

**重要：** この処理は**項木全体**に対して行われます。ネストの深さは関係ありません。

```
項木全体を走査:
ForStmt(
  RangeClause(
    IdentifierList(...),
    "range",
    Id("n")  ← ここでパターンマッチ成功！
  ),
  Block(...)
)

↓

contextパターン:
for ((_ , .IdentifierList) := range HOLE:Exp) _

↓ マッチ

HOLE = Id("n") → 評価コンテキスト
```

## 実用的な例

### 例1: 単純な式評価（strictで十分）

```k
syntax Exp ::= Exp "+" Exp [strict]
```

```
項: 1 + (2 + 3)

処理:
1. Exp "+" Exp にマッチ
2. strict属性 → 両方の引数を評価
3. 1 は値
4. (2 + 3) を評価 → 5
5. 1 + 5 → 6
```

strictで十分な理由：**直接の子要素だけを評価すればいい**

### 例2: ネストした構文（contextが必要）

```k
syntax Stmt ::= "if" Exp Block
syntax Exp ::= Id | Int | Exp "+" Exp [strict]
```

```go
if x + 1 { ... }
```

```
項: Stmt("if", Exp(Id("x"), "+", Int(1)), Block(...))

strict だけだと:
1. Stmt にマッチ
2. Stmt には strict なし
3. 引数 Exp(...) は評価されない ❌

context を追加:
context if HOLE:Exp _

1. パターンマッチ成功
2. Exp(Id("x"), "+", Int(1)) が HOLE
3. Exp の strict が機能
4. x + 1 が評価される ✅
```

### 例3: 深いネスト（contextのみ可能）

```k
syntax A ::= "a" Exp [strict]
syntax B ::= "b" A
syntax C ::= "c" B
```

```
項: C("c", B("b", A("a", Id("x"))))

strict だけ:
- A の strict は A が直接マッチした時のみ機能
- C や B レベルからは見えない

context で対応:
context c(b(a(HOLE:Exp)))

- このパターンが項全体にマッチ
- Id("x") が HOLE として評価される
```

## まとめ

### 本質的な違い

| | strict | context |
|---|--------|---------|
| **性質** | 構文の属性（メタ情報） | 書き換えルール |
| **適用方法** | 構文マッチング時に自動 | パターンマッチングで明示的 |
| **適用範囲** | 直接の子要素のみ | 任意のパターン（ネストOK） |
| **処理時点** | 構文解析時 | 項の書き換え時 |

### なぜcontextはネストしていても機能するのか？

**答え：** contextはパターンマッチングベースだから。

- strictは「構文定義の属性」→ 直接の子要素にのみ適用
- contextは「項のパターン」→ 項全体をスキャンしてマッチングするため、ネストの深さは関係ない

### 実用的なガイドライン

1. **単純な構文** → strict を使う（簡潔）
2. **ネストした構文** → context を使う（必須）
3. **複雑なパターン** → context を使う（柔軟）
4. **迷ったら** → context を使う（確実）

## 参考

### K Frameworkの公式ドキュメントより

> The `strict` attribute is a syntactic sugar that generates context rules for direct children of a production.
> For nested structures, you need to write explicit context rules.

（`strict`属性は、生成規則の直接の子に対するcontextルールを生成する糖衣構文です。ネストした構造には、明示的なcontextルールを書く必要があります。）

### 関連項目

- `ex/nested-syntax-explanation.md` - ネストした構文の詳細
- `ex/range-clause-implementation.md` - RangeClauseでの実例
