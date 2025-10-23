# k-framework
# k-framework

``` sh
ex: kompile lesson-19-a.k  --verbose --enable-llvm-debug --backend llvm
llvm-kompile /app/lesson-19-a.k/lesson-19-a-kompiled/definition.kore /app/lesson-19-a.k/lesson-19-a-kompiled/dt main -g -O1 -o /app/lesson-19-a.k/lesson-19-a-kompiled/interpreter -- -g
krun -cPGM=0 --debugger
krun code.txt --debugger
```

kompile lesson-19-a.k  && krun code.txt 


``` sh
docker compose up -d && docker compose exec k bash
docker compose exec k bash -c "cd go && kompile main.k"
docker compose exec k bash -c "cd go && krun code --definition main-kompiled/"
```


# k-go
