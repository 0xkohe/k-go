module BINARY-INCREMENT-TM
  imports DOMAINS-SYNTAX
  imports LIST
  imports K-EQUAL
  imports BOOL

  
  // シンタックス定義
  syntax Symbol ::= "0" | "1" | "$B"  // B はブランク記号
  syntax State ::= "q0" | "q1" | "q2" | "qf"  // 状態
  syntax Direction ::= "L" | "R" | "S"  // Left, Right, Stay
  
  //syntax Bool ::= isSymbolEqual(Symbol, Symbol) [function]
  //rule isSymbolEqual(S1:Symbol, S2:Symbol) => S1 ==K S2

  // テープの表現（リストとして）
  syntax Tape ::= List{Symbol, ""}
  
  // チューリングマシンのプログラム
  syntax Pgm ::= Tape
  
  configuration <T>
    <k> $PGM:Pgm </k>
    <tape> 
      <left> ListItem($B) .List </left>      // ヘッドの左側のテープ
      <current> $B </current>     // 現在ヘッドが指している記号
      <right> .List ListItem($B)</right>     // ヘッドの右側のテープ
    </tape>
    <state> q0 </state>
    <result> .K </result>
  </T>


////  // 初期化規則
//　実行されてない
 // rule <k> S1:Symbol Ss:Tape => Ss </k>
 //      <left> .List => .List </left>
 //      <current> B => S1 </current>
 //      <right> .List => .List </right>
 //      <state> q0 </state>
  
  // leftのテープに記号を追加する初期化規, 右端に移動もする
  rule <k> S1:Symbol Ss:Tape => Ss </k>
       <current> _Cu => S1 </current>
       <left> Ls => Ls ListItem(S1) </left>
       <state> q0 => q0 </state>
       requires S1 =/=K $B
  
  rule <k> .Tape </k> 
  <state> q0 => q1 </state>
  
  // 状態遷移規則
  
  // q1: 加算処理
  // 0を見つけたら1に変更して完了
  rule <current> 0 => 1 </current>
       <left> Ls ListItem(_L) => Ls </left>
       <right> Rs => ListItem(1) Rs </right>
       <state> q1 => q2 </state>
    requires Ls =/=K .List
//  
  // 1を見つけたら0に変更してキャリー継続
  rule <current> 1 => L2</current>
       <left> Ls ListItem(L2) ListItem(_L1) => Ls ListItem(L2)</left>
       <right> Rs => ListItem(0) Rs </right>
       <state> q1 </state>
//  
  // 左端に到達（ブランク）したら1を追加
  rule <current> $B </current>
       <right> Rs => ListItem(1) Rs </right>
       <state> q1 => q2 </state>

  rule <current> Cu => L2 </current>
       <left> Ls ListItem(L2) ListItem(L1) => Ls  ListItem(L2)</left>
       <right> Rs => ListItem(L1) Rs </right>
       <state> q2 </state>
       requires Cu ==K 0 orBool Cu ==K 1

  rule <current> $B </current>
       <state> q2 => qf </state>

   rule <current> $B </current>
        <state>  qf </state>
        <left> Ls </left>
        <right> Rs </right>
        <result> .K => buildTape(Ls, Rs) </result>

  // ヘルパー関数：テープを構築
  syntax Tape ::= buildTape(List, List) [function]
  rule buildTape(ListItem(L1) Ls,  Rs) => L1 buildTape(Ls, Rs)
  rule buildTape(.List,  ListItem(R1) Rs) => R1 buildTape(.List, Rs)
  rule buildTape(.List, .List) => .Tape

endmodule