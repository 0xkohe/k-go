# scopeDecls実装の解説

## 概要

このドキュメントでは、`scopeDecls`セルの導入によるGoの短い変数宣言（`:=`）の正しいエラーチェック実装について説明します。

## 背景

### 問題：`env`だけでは不十分

`env`は現在アクセス可能な全ての変数を含みますが、**どのスコープで宣言されたか**の情報は持ちません。

#### 例1: 同じスコープでの再宣言（エラーであるべき）

```go
{
    x := 1    // OK
    x := 2    // ERROR - 同じスコープで既に宣言済み
}
```

`env`だけでは：
- `x := 1`の後、`env`に`x`が存在
- `x := 2`を評価する時、`env`に`x`が存在することは分かる
- **しかし、この`x`が現在のスコープで宣言されたのか、外側のスコープから継承されたのか区別できない**

#### 例2: シャドウイング（これはOK）

```go
x := 1
{
    x := 2    // OK - 外側のxをシャドウイング
}
```

これは合法ですが、`env`には両方のケースで`x`が存在するため、例1と例2を区別できません。

### 解決策：`scopeDecls`セル

`scopeDecls`は**現在のスコープで新しく宣言された変数だけ**を追跡します。

| セル | 役割 |
|------|------|
| `env` | 現在アクセス可能なすべての変数（外側のスコープを含む） |
| `scopeDecls` | **現在のスコープで宣言された変数のみ** |

## データ構造

### `scopeDecls`の構造

```k
<scopeDecls> .List </scopeDecls>
```

- **MapのList（スタック構造）**
- 各スコープごとに独立したMapを持つ
- 最上位の要素が現在のスコープの宣言情報

### 他のセルとの比較

#### `env` / `tenv`: 作業用Mapとバックアップスタックに分離

```k
<env> .Map </env>           // 作業用（現在の環境）
<envStack> .List </envStack>  // バックアップ用スタック
```

#### `scopeDecls`: 単一のスタック

```k
<scopeDecls> .List </scopeDecls>  // スタック構造のみ
```

**なぜ分けないのか？**
- `env`は全スコープの変数にアクセスするため、平坦なMapが必要
- `scopeDecls`は**常に最上位のMapだけ**にアクセスするため、分ける必要がない

## 主な変更内容

### 1. `scopeDecls`セルの追加と管理

#### 初期化 (core.k:24)

```k
<scopeDecls> .List </scopeDecls>
```

#### スコープ管理 (core.k:49, 54)

```k
// enterScope: 新しい空のMapをスタックに追加
rule <k> enterScope(Body:K) => Body ~> exitScope ... </k>
     <scopeDecls> SD => SD ListItem(.Map) </scopeDecls>

// exitScope: スタックから削除
rule <k> exitScope => .K ... </k>
     <scopeDecls> (SD ListItem(_)) => SD </scopeDecls>
```

#### 具体例

```go
package main

func main() {
    x := 1        // scopeDecls: [{x -> true}]
    {
        y := 2    // scopeDecls: [{x -> true}, {y -> true}]
                  //                           ↑ 現在のスコープ
    }             // scopeDecls: [{x -> true}]
}
```

### 2. var宣言のゼロ値デフォルト (core.k:62-64)

#### 変更内容

```k
rule <k> var X:Id int => var X int = 0 ... </k>
rule <k> var X:Id bool => var X bool = false ... </k>
rule <k> var X:Id FT:FunctionType => var X FT = nil ... </k>
```

#### 対応する構文追加 (syntax/core.k:72)

```k
syntax Statement ::= "var" Id Type
```

#### 具体例

```go
// 以前: エラー
var x int

// 変更後: 自動的に var x int = 0 に変換される
var x int
print(x)  // 出力: 0
```

### 3. 全ての宣言で`scopeDecls`を更新

#### 変更内容

各宣言ルール（`var`宣言、`:=`宣言）に以下を追加：

```k
<scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>
```

#### パターンの意味

```k
<scopeDecls> (SD ListItem(ScopeMap)) </scopeDecls>
```

- `SD`: 以前のスコープのMapたち（古いスコープ）
- `ListItem(ScopeMap)`: スタックの最上位のMap（現在のスコープ）
- `ScopeMap`: 現在のスコープで宣言された変数のMap

視覚的には：

```
List: [Scope1, Scope2, Scope3]
                        ↑
                   最上位（現在のスコープ）
```

### 4. 短い変数宣言のエラーチェック

#### 単一変数の宣言 (core.k:95-96, 103-104)

```k
// 新規宣言の場合
rule <k> X:Id := I:Int => .K ... </k>
     <tenv> R => R [ X <- int ] </tenv>
     <env> Env => Env [ X <- L ] </env>
     <store> Store => Store [ L <- I ] </store>
     <nextLoc> L:Int => L +Int 1 </nextLoc>
     <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>
  requires notBool (X in_keys(ScopeMap))  // ← 重要: 現在のスコープに存在しない
```

#### エラールールの追加 (core.k:135-140)

```k
syntax KItem ::= "shortDeclError"

rule <k> X:Id := V => shortDeclError ... </k>
     <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
  requires X in_keys(ScopeMap) andBool isKResult(V)
```

#### 具体例

```go
// ケース1: 同じスコープでの再宣言（ERROR）
{
    x := 1    // scopeDecls: [{x -> true}]
    x := 2    // ERROR: xは既にScopeMapに存在
}

// ケース2: シャドウイング（OK）
x := 1        // scopeDecls: [{x -> true}]
{
    x := 2    // scopeDecls: [{x -> true}, {x -> true}]
              // OK: 新しいスコープのMapには存在しない
}

// ケース3: 外側のスコープの変数（OK）
x := 1        // scopeDecls: [{x -> true}]
{
    print(x)  // OK: envから取得
    y := 2    // OK: 現在のスコープでyは新規
}
```

### 5. 複数変数の短い宣言（Goの複雑な仕様）

#### Goの仕様

> 短い変数宣言では、少なくとも1つの変数が新規であれば、既存の変数も含めることができる。
> その場合、既存の変数は再代入として扱われる。

#### 実装前の問題

```k
// 変更前: 全ての変数を新規宣言として扱う
declareFromTuple(IdentifierList, List)
```

#### 実装後

```k
// 変更後: ScopeMapを引数として追加
shortDeclFromTuple(IdentifierList, List, Map)
```

#### ヘルパー関数の追加 (core.k:426-429)

```k
syntax Bool ::= hasNewIdList(IdentifierList, Map) [function]
rule hasNewIdList(.IdentifierList, _M:Map) => false
rule hasNewIdList(X:Id , IL:IdentifierList, M:Map)
  => notBool (X in_keys(M)) orBool hasNewIdList(IL, M)
rule hasNewIdList(X:Id, M:Map) => notBool (X in_keys(M))
```

識別子リストに**少なくとも1つの新規変数が含まれているか**をチェック。

#### エントリーポイント (core.k:213-221)

```k
// OK: 少なくとも1つは新規変数
rule <k> IL:IdentifierList := (E:Exp , .ExpressionList) => evalForShortDecl(IL, E, ScopeMap) ... </k>
     <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
  requires lenIdList(IL) >=Int 2
   andBool hasNewIdList(IL, ScopeMap)

// ERROR: 全て既存変数
rule <k> IL:IdentifierList := (_E:Exp , .ExpressionList) => shortDeclError ... </k>
     <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
  requires lenIdList(IL) >=Int 2
   andBool notBool hasNewIdList(IL, ScopeMap)
```

#### 新規変数と既存変数の両方に対応

各型（Int, Bool, FuncVal）に対して**2つのルール**を用意：

**新規変数の場合**:

```k
rule <k> shortDeclFromTuple((X:Id , ILRest), (ListItem(V:Int) LRest), ScopeMap)
      => shortDeclFromTuple(ILRest, LRest, ScopeMap) ... </k>
     <tenv> TEnv => TEnv [ X <- int ] </tenv>        // 新規エントリ
     <env> Env => Env [ X <- L ] </env>
     <store> Store => Store [ L <- V ] </store>
     <nextLoc> L:Int => L +Int 1 </nextLoc>          // 新しいLocationを割り当て
     <scopeDecls> (SD ListItem(CurrentMap))
       => SD ListItem(CurrentMap [ X <- true ]) </scopeDecls>
  requires notBool (X in_keys(ScopeMap))
```

**既存変数の場合**:

```k
rule <k> shortDeclFromTuple((X:Id , ILRest), (ListItem(V:Int) LRest), ScopeMap)
      => shortDeclFromTuple(ILRest, LRest, ScopeMap) ... </k>
     <tenv> ... X |-> int ... </tenv>                // 既存エントリを参照
     <env> ... X |-> L:Int ... </env>
     <store> Store => Store [ L <- V ] </store>      // 既存Locationに再代入
  requires X in_keys(ScopeMap)                       // scopeDeclsは更新しない
```

#### 具体例

```go
// ケース1: 全て新規（OK）
x, y := 1, 2
// scopeDecls: [{x -> true, y -> true}]

// ケース2: 一部が既存（OK）
x := 1
x, y := 2, 3  // xは既存だがyは新規
              // x: 再代入、y: 新規宣言
              // scopeDecls: [{x -> true, y -> true}]

// ケース3: 全て既存（ERROR）
x, y := 1, 2
x, y := 3, 4  // ERROR: 両方とも既に宣言済み

// ケース4: 複雑な例
x := 1
{
    x, y := 2, 3  // OK: yは新規（xは外側のスコープから）
                  // scopeDecls: [{x -> true}, {y -> true}]
                  //                           ↑ 現在のスコープにyを追加

    x, y := 4, 5  // ERROR: 両方とも現在のスコープで宣言済み
}
```

## 状態遷移の詳細例

### 例: ネストしたスコープ

```go
package main

func main() {
    x := 1
    {
        y := 2
        x, z := 3, 4
    }
}
```

#### 実行の流れ

1. **`x := 1`**
   ```
   env: {x -> Loc0}
   scopeDecls: [{x -> true}]
   ```

2. **ブロック開始 `{`**
   ```
   env: {x -> Loc0}
   scopeDecls: [{x -> true}, {}]  ← 新しい空のMap追加
                             ↑ 現在のスコープ
   ```

3. **`y := 2`**
   ```
   env: {x -> Loc0, y -> Loc1}
   scopeDecls: [{x -> true}, {y -> true}]
   ```

4. **`x, z := 3, 4`**
   - `hasNewIdList([x, z], {y -> true})` をチェック
   - `z`は新規 → OK
   - `x`は`ScopeMap`に存在しない → 新規宣言扱い
   - `z`は`ScopeMap`に存在しない → 新規宣言扱い

   ```
   env: {x -> Loc2, y -> Loc1, z -> Loc3}  // xは新しいLocation
   scopeDecls: [{x -> true}, {y -> true, x -> true, z -> true}]
   ```

5. **ブロック終了 `}`**
   ```
   env: {x -> Loc0}  // 復元
   scopeDecls: [{x -> true}]  // 内側のスコープを削除
   ```

### 例: エラーケース

```go
package main

func main() {
    x := 1
    x := 2  // ERROR
}
```

#### 実行の流れ

1. **`x := 1`**
   ```
   env: {x -> Loc0}
   scopeDecls: [{x -> true}]
   ```

2. **`x := 2` を評価**
   - `ScopeMap = {x -> true}`
   - `x in_keys(ScopeMap)` → `true`
   - 新規宣言のルールの `requires notBool (X in_keys(ScopeMap))` にマッチしない
   - エラールールにマッチ:

   ```k
   rule <k> X:Id := V => shortDeclError ... </k>
        <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
     requires X in_keys(ScopeMap) andBool isKResult(V)
   ```

   - 結果: `shortDeclError`

## まとめ

`scopeDecls`の導入により、以下のGoの短い変数宣言の仕様が正しく実装されました：

1. ✅ 同じスコープでの再宣言を禁止
2. ✅ 異なるスコープでのシャドウイングを許可
3. ✅ 複数変数宣言で少なくとも1つが新規なら既存変数も含められる
4. ✅ 全ての変数が既存の場合はエラー

### 設計のポイント

- `env`は**全スコープの変数にアクセス**するための平坦なMap
- `scopeDecls`は**現在のスコープでの宣言チェック**のためのスタック
- スタック構造により、親スコープの宣言と現在のスコープの宣言を明確に区別

### テストケース

実装をテストするには：

```bash
# エラーケースのテスト
docker compose exec k bash -c "cd go && krun codes/code-short-decl-error --definition main-kompiled/"

# 正常ケースのテスト（複数変数宣言など）
docker compose exec k bash -c "cd go && krun codes/code-var-zero --definition main-kompiled/"
```
