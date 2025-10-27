# ネストした構文とstrictアノテーションの問題

## 概要

K Frameworkにおける「ネストした構文」とは、ある構文定義が別の構文定義の内部に含まれている状態を指します。

## 例：RangeClauseの場合

### 構文定義

```k
syntax RangeClause ::= IdentifierList ":=" "range" Exp [strict(2)]
syntax ForStmt ::= "for" RangeClause Block
```

### パース木の構造

```go
for i := range n { print(i); }
```

これは以下のようなツリー構造になります：

```
ForStmt (親)
├── RangeClause (子 - ネストしている)
│   ├── IdentifierList: (i , .IdentifierList)
│   ├── ":="
│   ├── "range"
│   └── Exp: n ← これを評価したい
└── Block: { print(i); }
```

`RangeClause`が`ForStmt`の**内部にネスト**されています。

## strictアノテーションの制限

### 問題

```k
syntax RangeClause ::= IdentifierList ":=" "range" Exp [strict(2)]
```

この`strict(2)`は、`RangeClause`が**トップレベル**で使われる場合は機能しますが、`ForStmt`の内部にネストされると自動的には機能しません。

### なぜ機能しないのか？

K Frameworkの`strict`は**直接的な子要素**にのみ適用されます：

```
ForStmt
├── RangeClause ← ForStmtの直接の子
│   └── Exp ← RangeClauseの直接の子（ForStmtから見ると孫）
└── Block
```

`ForStmt`から見ると、`Exp`は孫要素なので`strict`が自動伝播しません。

## 実験：strictだけの場合

### Contextルールなし

```k
syntax RangeClause ::= IdentifierList ":=" "range" Exp [strict(2)]
syntax ForStmt ::= "for" RangeClause Block

// Contextルールなし
```

### 実行結果

```
<k>
  for i , .IdentifierList := range n { print ( i ) ; } ~> exitScope ~> .K
</k>
```

`n`が評価されずに**そのまま残る**。

## 解決策：Contextルール

### Contextルールを追加

```k
context for ((_ , .IdentifierList) := range HOLE:Exp) _
context for range HOLE:Exp _
```

### 意味

「`ForStmt`の中でも、range式の部分に計算の穴（HOLE）を作って評価せよ」

### 実行結果

```
<k>
  .K
</k>
<out>
  ListItem(0) ListItem(1) ListItem(2)
</out>
```

`n`が正しく`3`に評価されてループが実行される。

## 他のネストの例

### 例1：If文の中の式

```k
syntax IfStmt ::= "if" Exp Block [strict(1)]
syntax Statement ::= IfStmt
```

```go
if x > 0 { ... }
```

```
Statement
└── IfStmt
    ├── Exp: x > 0 ← strict(1)で評価される
    └── Block
```

この場合は`IfStmt`が`Statement`の直接の子なので、まだ問題ない。

### 例2：深いネスト

```k
syntax A ::= "a" Exp [strict(1)]
syntax B ::= "b" A
syntax C ::= "c" B
```

```
C
└── B
    └── A
        └── Exp ← ここまで深いとstrictが届かない
```

`C`や`B`レベルでContextルールが必要になる。

## ネストのレベル

### レベル1（問題なし）

```k
syntax Stmt ::= Exp [strict]
```

```
Stmt
└── Exp ← 直接の子、strictが機能
```

### レベル2（問題が起きる可能性）

```k
syntax Inner ::= Exp [strict]
syntax Outer ::= Inner
```

```
Outer
└── Inner
    └── Exp ← Outerから見ると孫、strictが伝播しない
```

### レベル3以上（確実に問題）

```k
syntax A ::= Exp [strict]
syntax B ::= A
syntax C ::= B
```

```
C
└── B
    └── A
        └── Exp ← さらに深いネスト
```

## まとめ

### ネストした構文とは

構文定義Aが別の構文定義Bの内部に含まれている状態：

```k
syntax A ::= ... Exp [strict] ...
syntax B ::= ... A ...  ← AがBの中にネスト
```

### strictの制限

- strictは**直接的な子要素**にのみ適用
- ネストした構造では自動伝播しない
- 孫要素以降には届かない

### 解決策

Contextルールで明示的に「ここを評価せよ」と指示：

```k
context ConstructorName( ... HOLE:Type ... )
```

### 実用的な判断基準

| 状況 | strictだけでOK? | Contextルール必要? |
|------|----------------|-------------------|
| 直接の子要素 | ✅ はい | ❌ 不要 |
| ネストした構造 | ❌ いいえ | ✅ 必要 |
| 複雑な構文 | ❌ いいえ | ✅ 必要 |

### RangeClauseの場合

```k
syntax RangeClause ::= ... Exp [strict] ← strictを指定
syntax ForStmt ::= "for" RangeClause Block ← ネスト

// strictだけでは不十分
context for ... range HOLE:Exp ... ← Contextルールが必要
```

## 参考：K Frameworkのドキュメントより

> The strict attribute only applies to the immediate children of the production.
> For nested structures, you need to use context rules to explicitly specify
> where evaluation should occur.

（strictアノテーションは生成規則の直接の子にのみ適用されます。ネストした構造では、評価が行われる場所を明示的に指定するためにcontextルールを使用する必要があります。）
