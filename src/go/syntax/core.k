/*
Semicolons¶
The formal syntax uses semicolons ";" as terminators in a number of productions. Go programs may omit most of these semicolons using the following two rules:

When the input is broken into tokens, a semicolon is automatically inserted into the token stream immediately after a line's final token if that token is
an identifier
an integer, floating-point, imaginary, rune, or string literal
one of the keywords break, continue, fallthrough, or return
one of the operators and punctuation ++, --, ), ], or }
To allow complex statements to occupy a single line, a semicolon may be omitted before a closing ")" or "}".
To reflect idiomatic use, code examples in this document elide semicolons using these rules.
*/

requires "domains.md"

module GO-SYNTAX
  imports UNSIGNED-INT-SYNTAX
  imports BOOL-SYNTAX
  imports ID-SYNTAX

  syntax TopDecl
  syntax TopDecls ::= List{TopDecl, ";"}
  syntax Program ::= "package" "main" TopDecls "func" "main" "(" ")" Block TopDecls

  syntax Block   ::= "{" StatementList ";" "}"
  syntax StatementList ::= List{Statement, ";"}

  syntax Type ::= "int" | "bool"

  syntax SimpleStmt ::= Assignment | ShortVarDecl | IncDecStmt
  syntax Assignment ::= Id "=" Exp [strict(2)]
  syntax ShortVarDecl ::= Id ":=" Exp [strict(2)]
  syntax IncDecStmt ::= Id "++" | Id "--"

  syntax Statement ::= SimpleStmt | Print | Block | IfStmt | ForStmt | BreakStmt | ContinueStmt
                     | "var" Id Type "=" Exp  [strict(3)]

  syntax Print ::= "print" "(" Exp ")" [strict]

  syntax Exp ::= Int | Bool | Id | "(" Exp ")" [bracket]
               > "!" Exp [seqstrict]
               | "-" Exp [seqstrict]
               > left:
                 Exp "*" Exp [left, seqstrict]
               | Exp "/" Exp [left, seqstrict]
               | Exp "%" Exp [left, seqstrict]
               > left:
                 Exp "+" Exp [left, seqstrict]
               | Exp "-" Exp [left, seqstrict]
               > non-assoc:
                 Exp "<"  Exp [seqstrict]
               | Exp ">"  Exp [seqstrict]
               | Exp "==" Exp [seqstrict]
               > left:
                 Exp "&&" Exp [left, seqstrict]
               | Exp "||" Exp [left, seqstrict]

  syntax IfStmt ::= "if" Exp Block                                   [strict(1)]
                  | "if" Exp Block "else" Block                       [strict(1)]
                  | "if" Exp Block "else" IfStmt                      [strict(1)]
                  | "if" SimpleStmt ";" Exp Block                     
                  | "if" SimpleStmt ";" Exp Block "else" Block        
                  | "if" SimpleStmt ";" Exp Block "else" IfStmt       

  syntax ForStmt ::= "for" ForClause Block

  syntax BreakStmt ::= "break"
  syntax ContinueStmt ::= "continue"

  syntax ForClause ::= SimpleStmt ";" Exp ";" SimpleStmt
                     | SimpleStmt ";" ";" SimpleStmt
                     | SimpleStmt ";" Exp ";"
                     | ";" Exp ";" SimpleStmt
                     | ";" ";" SimpleStmt
                     | ";" Exp ";"
                     | SimpleStmt ";" ";"
                     | ";" ";"
endmodule
