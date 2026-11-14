{
  coretest - tests for user mode, the shell and the core utilities

  Run by "make test" as the first user process (kernel option
  init=/bin/coretest). It works in /tmp/coretest and checks:

    * run time loading of libplugin.so (LoadLibrary / FindSymbol),
    * the program heap,
    * a list of shell command lines: each runs through "sh -c" with its
      standard output captured through a pipe, and both the output and
      the exit status must match,
    * threads, thread-local storage and initialization order (threadtest),
    * that a crashing program (coretest --crash-on-purpose) only ends
      itself.

  Exits with status 0 when every test passed, 1 otherwise.
}
program coretest;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Libraries,
  Sys.Memory,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Util.FileTree;

type
  TCommandTest = record
    Command: PChar;
    ExpectedOutput: PChar;
    ExpectedStatus: LongInt;
  end;

const
  WorkDirectory = '/tmp/coretest';

  { Commands run in order in WorkDirectory; later ones may rely on files
    made by earlier ones. }
  CommandTests: array[0..241] of TCommandTest = (
    { --- the shell -------------------------------------------------- }
    (Command: 'echo hello world'; ExpectedOutput: 'hello world'#10; ExpectedStatus: 0),
    (Command: 'echo -n no line end'; ExpectedOutput: 'no line end'; ExpectedStatus: 0),
    (Command: 'echo -e ''a\tb\nc'''; ExpectedOutput: 'a'#9'b'#10'c'#10; ExpectedStatus: 0),
    (Command: 'X=5; echo $X $((X * 2 + 1))'; ExpectedOutput: '5 11'#10; ExpectedStatus: 0),
    (Command: 'echo "double $HOME" ''single $HOME'' \$escaped'; ExpectedOutput: 'double / single $HOME $escaped'#10; ExpectedStatus: 0),
    (Command: 'A="one  two"; for w in $A; do echo "[$w]"; done'; ExpectedOutput: '[one]'#10'[two]'#10; ExpectedStatus: 0),
    (Command: 'A="one  two"; for w in "$A"; do echo "[$w]"; done'; ExpectedOutput: '[one  two]'#10; ExpectedStatus: 0),
    (Command: 'true && echo yes || echo no'; ExpectedOutput: 'yes'#10; ExpectedStatus: 0),
    (Command: 'false && echo yes || echo no'; ExpectedOutput: 'no'#10; ExpectedStatus: 0),
    (Command: 'false; echo $?'; ExpectedOutput: '1'#10; ExpectedStatus: 0),
    (Command: '! false'; ExpectedOutput: ''; ExpectedStatus: 0),
    (Command: 'exit 7'; ExpectedOutput: ''; ExpectedStatus: 7),
    (Command: 'if test 2 -gt 1; then echo bigger; else echo smaller; fi'; ExpectedOutput: 'bigger'#10; ExpectedStatus: 0),
    (Command: 'i=0; while [ $i -lt 3 ]; do echo $i; i=$((i+1)); done'; ExpectedOutput: '0'#10'1'#10'2'#10; ExpectedStatus: 0),
    (Command: 'i=0; until [ $i -ge 2 ]; do i=$((i+1)); done; echo $i'; ExpectedOutput: '2'#10; ExpectedStatus: 0),
    (Command: 'for i in 1 2 3 4 5; do if [ $i = 2 ]; then continue; fi; if [ $i = 4 ]; then break; fi; echo $i; done'; ExpectedOutput: '1'#10'3'#10; ExpectedStatus: 0),
    (Command: 'echo "$(echo inner) and $(echo $(echo deeper))"'; ExpectedOutput: 'inner and deeper'#10; ExpectedStatus: 0),
    (Command: 'echo ${UNSET:-fallback} ${HOME:-none}'; ExpectedOutput: 'fallback /'#10; ExpectedStatus: 0),
    (Command: 'set -- a b c; echo $# $2; shift; echo $1'; ExpectedOutput: '3 b'#10'b'#10; ExpectedStatus: 0),
    (Command: 'nosuchcommand 2>/dev/null; echo $?'; ExpectedOutput: '127'#10; ExpectedStatus: 0),
    (Command: 'echo first > out.txt; echo second >> out.txt; cat < out.txt'; ExpectedOutput: 'first'#10'second'#10; ExpectedStatus: 0),
    (Command: 'ls missing-file > err.txt 2>&1; cat err.txt'; ExpectedOutput: 'ls: cannot access ''missing-file'': No such file or directory'#10; ExpectedStatus: 0),
    (Command: 'echo one two three | tr " " "\n" | sort -r | head -n 2'; ExpectedOutput: 'two'#10'three'#10; ExpectedStatus: 0),
    (Command: 'printf "b\na\nc\n" | sort | tr a-z A-Z'; ExpectedOutput: 'A'#10'B'#10'C'#10; ExpectedStatus: 0),
    (Command: 'echo piped | while read line; do echo "got $line"; done'; ExpectedOutput: 'got piped'#10; ExpectedStatus: 0),
    (Command: '{ echo a; echo b; } | wc -l'; ExpectedOutput: '2'#10; ExpectedStatus: 0),
    (Command: 'export EXPORTED=visible; sh -c ''echo $EXPORTED'''; ExpectedOutput: 'visible'#10; ExpectedStatus: 0),
    (Command: 'LOCAL=hidden; sh -c ''echo "[$LOCAL]"'''; ExpectedOutput: '[]'#10; ExpectedStatus: 0),
    (Command: 'PREFIXED=yes sh -c ''echo $PREFIXED''; echo "[$PREFIXED]"'; ExpectedOutput: 'yes'#10'[]'#10; ExpectedStatus: 0),
    (Command: 'mkdir -p sub/dir && cd sub/dir && pwd && cd .. && pwd'; ExpectedOutput: '/tmp/coretest/sub/dir'#10'/tmp/coretest/sub'#10; ExpectedStatus: 0),
    (Command: 'echo "line one" > script.sh; echo ''echo "args: $1 $2 ($#)"'' >> script.sh; sh script.sh x y 2>&1 | tail -n 1'; ExpectedOutput: 'args: x y (2)'#10; ExpectedStatus: 0),
    (Command: 'touch g1.dat g2.dat g3.txt; echo g*.dat'; ExpectedOutput: 'g1.dat g2.dat'#10; ExpectedStatus: 0),
    (Command: 'echo g?.txt "g*.dat" nomatch*'; ExpectedOutput: 'g3.txt g*.dat nomatch*'#10; ExpectedStatus: 0),
    (Command: 'echo # a comment'; ExpectedOutput: #10; ExpectedStatus: 0),
    (Command: 'echo multi \'#10'line'; ExpectedOutput: 'multi line'#10; ExpectedStatus: 0),

    { --- text output ------------------------------------------------ }
    (Command: 'printf "%s=%d|%5s|%-5s|%05d|%x\n" age 42 r l 7 255'; ExpectedOutput: 'age=42|    r|l    |00007|ff'#10; ExpectedStatus: 0),
    (Command: 'printf "%s\n" a b c'; ExpectedOutput: 'a'#10'b'#10'c'#10; ExpectedStatus: 0),
    (Command: 'seq 3'; ExpectedOutput: '1'#10'2'#10'3'#10; ExpectedStatus: 0),
    (Command: 'seq -s , 2 2 8'; ExpectedOutput: '2,4,6,8'#10; ExpectedStatus: 0),
    (Command: 'seq -w 8 10'; ExpectedOutput: '08'#10'09'#10'10'#10; ExpectedStatus: 0),
    (Command: 'seq 3 -1 1'; ExpectedOutput: '3'#10'2'#10'1'#10; ExpectedStatus: 0),
    (Command: 'yes | head -n 3'; ExpectedOutput: 'y'#10'y'#10'y'#10; ExpectedStatus: 0),
    (Command: 'yes abc def | head -n 2'; ExpectedOutput: 'abc def'#10'abc def'#10; ExpectedStatus: 0),
    (Command: 'true; echo $?; false; echo $?'; ExpectedOutput: '0'#10'1'#10; ExpectedStatus: 0),
    (Command: '/bin/true; echo $?; /bin/false; echo $?'; ExpectedOutput: '0'#10'1'#10; ExpectedStatus: 0),
    (Command: 'basename /usr/lib/libfoo.so .so; basename -a a/b c/d/'; ExpectedOutput: 'libfoo'#10'b'#10'd'#10; ExpectedStatus: 0),
    (Command: 'dirname /usr/lib/x dir/file file /'; ExpectedOutput: '/usr/lib'#10'dir'#10'.'#10'/'#10; ExpectedStatus: 0),
    (Command: 'uname; uname -m'; ExpectedOutput: 'FreePascalOS'#10'x86_64'#10; ExpectedStatus: 0),
    (Command: 'date -d @0 +%Y-%m-%d_%H:%M:%S_%a_%j'; ExpectedOutput: '1970-01-01_00:00:00_Thu_001'#10; ExpectedStatus: 0),
    (Command: 'date -d @1700000000'; ExpectedOutput: 'Tue Nov 14 22:13:20 UTC 2023'#10; ExpectedStatus: 0),
    (Command: 'env -i A=1 B=2 /bin/env'; ExpectedOutput: 'A=1'#10'B=2'#10; ExpectedStatus: 0),
    (Command: 'env -u HOME sh -c ''echo "[${HOME}]"'''; ExpectedOutput: '[]'#10; ExpectedStatus: 0),
    (Command: 'sleep 0.05 && echo slept'; ExpectedOutput: 'slept'#10; ExpectedStatus: 0),

    { --- test and expr ---------------------------------------------- }
    (Command: 'test abc = abc; echo $?; test abc = abd; echo $?'; ExpectedOutput: '0'#10'1'#10; ExpectedStatus: 0),
    (Command: '[ -z "" ] && [ -n x ] && [ 3 -le 3 ] && echo ok'; ExpectedOutput: 'ok'#10; ExpectedStatus: 0),
    (Command: '[ -d /bin ] && [ -f /bin/sh ] && [ ! -e /nonexistent ] && echo ok'; ExpectedOutput: 'ok'#10; ExpectedStatus: 0),
    (Command: '[ 1 -eq 2 -o \( a = a -a b != c \) ]; echo $?'; ExpectedOutput: '0'#10; ExpectedStatus: 0),
    (Command: '[ 1 = 1'; ExpectedOutput: ''; ExpectedStatus: 2),
    (Command: 'expr 2 + 3 \* 4; expr 17 / 5; expr 17 % 5'; ExpectedOutput: '14'#10'3'#10'2'#10; ExpectedStatus: 0),
    (Command: 'expr length hello; expr substr hello 2 3; expr index hello l'; ExpectedOutput: '5'#10'ell'#10'3'#10; ExpectedStatus: 0),
    (Command: 'expr abc123 : ''[a-z]*''; expr file.txt : ''\(.*\)\.txt'''; ExpectedOutput: '3'#10'file'#10; ExpectedStatus: 0),
    (Command: 'expr 3 \< 10; expr 0'; ExpectedOutput: '1'#10'0'#10; ExpectedStatus: 1),

    { --- files ------------------------------------------------------ }
    (Command: 'printf "one\ntwo\nthree\nfour\nfive\n" > lines.txt; cat lines.txt | wc -l'; ExpectedOutput: '5'#10; ExpectedStatus: 0),
    (Command: 'head -n 2 lines.txt; head -2 lines.txt'; ExpectedOutput: 'one'#10'two'#10'one'#10'two'#10; ExpectedStatus: 0),
    (Command: 'head -n -3 lines.txt; head -c 5 lines.txt; echo'; ExpectedOutput: 'one'#10'two'#10'one'#10't'#10; ExpectedStatus: 0),
    (Command: 'tail -n 2 lines.txt; tail -n +4 lines.txt'; ExpectedOutput: 'four'#10'five'#10'four'#10'five'#10; ExpectedStatus: 0),
    (Command: 'tail -c 5 lines.txt'; ExpectedOutput: 'five'#10; ExpectedStatus: 0),
    (Command: 'cat -n lines.txt | head -n 2'; ExpectedOutput: '     1'#9'one'#10'     2'#9'two'#10; ExpectedStatus: 0),
    (Command: 'printf "a\n\n\nb\n" | cat -s'; ExpectedOutput: 'a'#10#10'b'#10; ExpectedStatus: 0),
    (Command: 'printf "a\tb\n" | cat -A'; ExpectedOutput: 'a^Ib$'#10; ExpectedStatus: 0),
    (Command: 'wc lines.txt; wc -w < lines.txt; wc -c lines.txt'; ExpectedOutput: ' 5  5 24 lines.txt'#10'5'#10'24 lines.txt'#10; ExpectedStatus: 0),
    (Command: 'tac lines.txt | head -n 2'; ExpectedOutput: 'five'#10'four'#10; ExpectedStatus: 0),
    (Command: 'printf "x\n\ny\n" | nl'; ExpectedOutput: '     1'#9'x'#10'       '#10'     2'#9'y'#10; ExpectedStatus: 0),
    (Command: 'printf "1\n2\n" > p1; printf "a\nb\n" > p2; paste p1 p2; paste -s -d, p1'; ExpectedOutput: '1'#9'a'#10'2'#9'b'#10'1,2'#10; ExpectedStatus: 0),
    (Command: 'echo abcdefghij | fold -w 4'; ExpectedOutput: 'abcd'#10'efgh'#10'ij'#10; ExpectedStatus: 0),
    (Command: 'echo hello | tee t1.txt t2.txt > /dev/null; cat t1.txt t2.txt'; ExpectedOutput: 'hello'#10'hello'#10; ExpectedStatus: 0),
    (Command: 'echo more | tee -a t1.txt > /dev/null; cat t1.txt'; ExpectedOutput: 'hello'#10'more'#10; ExpectedStatus: 0),
    (Command: 'cp lines.txt copy.txt && cat copy.txt | head -n 1'; ExpectedOutput: 'one'#10; ExpectedStatus: 0),
    (Command: 'mkdir dest && cp lines.txt copy.txt dest && ls dest'; ExpectedOutput: 'copy.txt'#10'lines.txt'#10; ExpectedStatus: 0),
    (Command: 'mkdir -p tree/a/b && echo deep > tree/a/b/f && cp -r tree tree2 && cat tree2/a/b/f'; ExpectedOutput: 'deep'#10; ExpectedStatus: 0),
    (Command: 'cp tree t3 2>&1; echo $?'; ExpectedOutput: 'cp: -r not specified; omitting directory ''tree'''#10'1'#10; ExpectedStatus: 0),
    (Command: 'mv copy.txt moved.txt && ls copy.txt moved.txt 2>/dev/null'; ExpectedOutput: 'moved.txt'#10; ExpectedStatus: 2),
    (Command: 'mv moved.txt dest/ && ls dest'; ExpectedOutput: 'copy.txt'#10'lines.txt'#10'moved.txt'#10; ExpectedStatus: 0),
    (Command: 'mv tree2 tree3 && cat tree3/a/b/f'; ExpectedOutput: 'deep'#10; ExpectedStatus: 0),
    (Command: 'rm dest/moved.txt && ls dest'; ExpectedOutput: 'copy.txt'#10'lines.txt'#10; ExpectedStatus: 0),
    (Command: 'rm dest 2>&1; echo $?'; ExpectedOutput: 'rm: cannot remove ''dest'': Is a directory'#10'1'#10; ExpectedStatus: 0),
    (Command: 'rm -r tree3 && ls -d tree3 2>/dev/null; echo $?'; ExpectedOutput: '2'#10; ExpectedStatus: 0),
    (Command: 'rm -f does-not-exist; echo $?'; ExpectedOutput: '0'#10; ExpectedStatus: 0),
    (Command: 'mkdir empty && rmdir empty && [ ! -e empty ] && echo gone'; ExpectedOutput: 'gone'#10; ExpectedStatus: 0),
    (Command: 'rmdir dest 2>&1; echo $?'; ExpectedOutput: 'rmdir: failed to remove ''dest'': Directory not empty'#10'1'#10; ExpectedStatus: 0),
    (Command: 'mkdir -p r1/r2/r3 && rmdir -p r1/r2/r3 && [ ! -e r1 ] && echo gone'; ExpectedOutput: 'gone'#10; ExpectedStatus: 0),
    (Command: 'ln -s lines.txt link && readlink link && head -n 1 link'; ExpectedOutput: 'lines.txt'#10'one'#10; ExpectedStatus: 0),
    (Command: 'ln -s sub/dir dirlink && readlink -f dirlink'; ExpectedOutput: '/tmp/coretest/sub/dir'#10; ExpectedStatus: 0),
    (Command: '[ -h link ] && [ -f link ] && echo link-to-file'; ExpectedOutput: 'link-to-file'#10; ExpectedStatus: 0),
    (Command: 'stat -c "%n %s %F" lines.txt link; stat -c "%n %F" sub'; ExpectedOutput: 'lines.txt 24 regular file'#10'link 9 symbolic link'#10'sub directory'#10; ExpectedStatus: 0),
    (Command: 'touch newfile && stat -c %s newfile && touch -c nothere && [ ! -e nothere ] && echo ok'; ExpectedOutput: '0'#10'ok'#10; ExpectedStatus: 0),
    (Command: 'truncate -s 10K big && stat -c %s big && truncate -s -4K big && stat -c %s big'; ExpectedOutput: '10240'#10'6144'#10; ExpectedStatus: 0),
    (Command: 'ls -d g*; ls -F sub'; ExpectedOutput: 'g1.dat'#10'g2.dat'#10'g3.txt'#10'dir/'#10; ExpectedStatus: 0),
    (Command: 'ls -a sub'; ExpectedOutput: '.'#10'..'#10'dir'#10; ExpectedStatus: 0),
    (Command: 'ls -S -r big lines.txt newfile'; ExpectedOutput: 'newfile'#10'lines.txt'#10'big'#10; ExpectedStatus: 0),
    (Command: 'ls -l lines.txt | cut -d " " -f 1,5'; ExpectedOutput: '-rw-r--r-- 24'#10; ExpectedStatus: 0),
    (Command: 'ls -R tree | head -n 4'; ExpectedOutput: 'tree:'#10'a'#10#10'tree/a:'#10; ExpectedStatus: 0),
    (Command: 'cd /; ls | head -n 3'; ExpectedOutput: 'bin'#10'etc'#10'home'#10; ExpectedStatus: 0),
    (Command: 'df | head -n 1 | cut -c 1-10'; ExpectedOutput: 'Filesystem'#10; ExpectedStatus: 0),
    (Command: 'ls /volumes > /dev/null && echo volumes-listed'; ExpectedOutput: 'volumes-listed'#10; ExpectedStatus: 0),
    (Command: 'sync && echo synced'; ExpectedOutput: 'synced'#10; ExpectedStatus: 0),

    { --- text processing -------------------------------------------- }
    (Command: 'printf "10\n9\n100\n-1\n" | sort -n'; ExpectedOutput: '-1'#10'9'#10'10'#10'100'#10; ExpectedStatus: 0),
    (Command: 'printf "b\nA\na\nB\n" | sort -f'; ExpectedOutput: 'A'#10'a'#10'B'#10'b'#10; ExpectedStatus: 0),
    (Command: 'printf "x 3\ny 1\nz 2\n" | sort -k 2 -n'; ExpectedOutput: 'y 1'#10'z 2'#10'x 3'#10; ExpectedStatus: 0),
    (Command: 'printf "a:3\nb:1\n" | sort -t : -k 2'; ExpectedOutput: 'b:1'#10'a:3'#10; ExpectedStatus: 0),
    (Command: 'printf "b\na\nb\na\n" | sort -u'; ExpectedOutput: 'a'#10'b'#10; ExpectedStatus: 0),
    (Command: 'printf "c\nb\na\n" > unsorted; sort -o unsorted unsorted; cat unsorted'; ExpectedOutput: 'a'#10'b'#10'c'#10; ExpectedStatus: 0),
    (Command: 'printf "a\na\nb\nc\nc\nc\n" | uniq -c'; ExpectedOutput: '      2 a'#10'      1 b'#10'      3 c'#10; ExpectedStatus: 0),
    (Command: 'printf "a\na\nb\nc\nc\n" | uniq -d; printf "a\na\nb\n" | uniq -u'; ExpectedOutput: 'a'#10'c'#10'b'#10; ExpectedStatus: 0),
    (Command: 'echo "a:b:c:d" | cut -d : -f 2,4; echo abcdef | cut -c 2-4'; ExpectedOutput: 'b:d'#10'bcd'#10; ExpectedStatus: 0),
    (Command: 'echo "a b c" | cut -d " " -f 2-; echo abcdef | cut -b -2,5-'; ExpectedOutput: 'b c'#10'abef'#10; ExpectedStatus: 0),
    (Command: 'echo hello | tr a-y b-z; echo hello | tr -d l; echo aaabbb | tr -s ab'; ExpectedOutput: 'ifmmp'#10'heo'#10'ab'#10; ExpectedStatus: 0),
    (Command: 'echo "Mixed Case 123" | tr "[:lower:]" "[:upper:]"; echo "a1b2" | tr -cd "[:digit:]"; echo'; ExpectedOutput: 'MIXED CASE 123'#10'12'#10; ExpectedStatus: 0),

    { --- errors and options ----------------------------------------- }
    (Command: 'cat nothere 2>&1; echo $?'; ExpectedOutput: 'cat: nothere: No such file or directory'#10'1'#10; ExpectedStatus: 0),
    (Command: 'ls --bogus 2>&1 | head -n 1'; ExpectedOutput: 'ls: unrecognized option ''--bogus'''#10; ExpectedStatus: 0),
    (Command: 'head -x 2>&1 | head -n 1'; ExpectedOutput: 'head: invalid option -- ''x'''#10; ExpectedStatus: 0),
    (Command: 'wc --version'; ExpectedOutput: 'wc (FreePascalOS coreutils) 0.2'#10; ExpectedStatus: 0),
    (Command: 'sort --rev < lines.txt | head -n 1'; ExpectedOutput: 'two'#10; ExpectedStatus: 0),
    (Command: 'mkdir /bin 2>&1; echo $?'; ExpectedOutput: 'mkdir: cannot create directory ''/bin'': File exists'#10'1'#10; ExpectedStatus: 0),

    { --- digests, checksums and encodings ---------------------------- }
    (Command: 'printf abc | md5sum; printf abc | sha1sum'; ExpectedOutput: '900150983cd24fb0d6963f7d28e17f72  -'#10'a9993e364706816aba3e25717850c26c9cd0d89d  -'#10; ExpectedStatus: 0),
    (Command: 'printf abc | sha256sum; printf abc | sha224sum'; ExpectedOutput: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  -'#10'23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7  -'#10; ExpectedStatus: 0),
    (Command: 'printf abc | sha384sum | cut -c 1-16; printf abc | sha512sum | cut -c 1-16; printf abc | b2sum | cut -c 1-16'; ExpectedOutput: 'cb00753f45a35e8b'#10'ddaf35a193617aba'#10'ba80a53f981c4d0d'#10; ExpectedStatus: 0),
    (Command: 'printf abc | sha1sum --tag'; ExpectedOutput: 'SHA1 (-) = a9993e364706816aba3e25717850c26c9cd0d89d'#10; ExpectedStatus: 0),
    (Command: 'printf abc > d.txt; sha256sum d.txt > sums; sha256sum -c sums; echo x > d.txt; sha256sum -c sums 2>/dev/null; echo $?'; ExpectedOutput: 'd.txt: OK'#10'd.txt: FAILED'#10'1'#10; ExpectedStatus: 0),
    (Command: 'printf 123456789 | cksum; printf 123456789 | cksum -a crc32b'; ExpectedOutput: '930766865 9'#10'3421780262 9'#10; ExpectedStatus: 0),
    (Command: 'printf abc > d.txt; cksum -a md5 d.txt'; ExpectedOutput: 'MD5 (d.txt) = 900150983cd24fb0d6963f7d28e17f72'#10; ExpectedStatus: 0),
    (Command: 'printf 123456789 | sum; printf 123456789 | sum -s'; ExpectedOutput: '53615     1'#10'477 1'#10; ExpectedStatus: 0),
    (Command: 'printf hello | base64; echo aGVsbG8= | base64 -d; echo'; ExpectedOutput: 'aGVsbG8='#10'hello'#10; ExpectedStatus: 0),
    (Command: 'printf hello | base32; printf hi | basenc --base16; printf hi | basenc --base2msbf'; ExpectedOutput: 'NBSWY3DP'#10'6869'#10'0110100001101001'#10; ExpectedStatus: 0),
    (Command: 'printf "\206\117\322\157\265\131\367\133" | basenc --z85'; ExpectedOutput: 'HelloWorld'#10; ExpectedStatus: 0),
    (Command: 'seq 100 | base64 -w 0 | base64 -d | tail -n 1'; ExpectedOutput: '100'#10; ExpectedStatus: 0),
    (Command: 'echo "a!b" | base64 -d 2>&1; echo $?'; ExpectedOutput: 'base64: invalid input'#10'1'#10; ExpectedStatus: 0),

    { --- users and the system ---------------------------------------- }
    (Command: 'id; id -un; id -g; whoami; groups'; ExpectedOutput: 'uid=0(root) gid=0(root) groups=0(root),10(wheel)'#10'root'#10'0'#10'root'#10'root wheel'#10; ExpectedStatus: 0),
    (Command: 'id nobody; logname; users'; ExpectedOutput: 'uid=65534(nobody) gid=65534(nobody) groups=65534(nobody)'#10'root'#10'root'#10; ExpectedStatus: 0),
    (Command: 'who | cut -c 1-16; who -q'; ExpectedOutput: 'root     console'#10'root'#10'# users=1'#10; ExpectedStatus: 0),
    (Command: 'nproc; arch; hostid | wc -c; uptime -p | cut -c 1-3'; ExpectedOutput: '1'#10'x86_64'#10'9'#10'up '#10; ExpectedStatus: 0),
    (Command: 'printenv HOME; printenv NOPE; echo $?'; ExpectedOutput: '/'#10'1'#10; ExpectedStatus: 0),
    (Command: 'tty; tty < /dev/null; echo $?'; ExpectedOutput: '/dev/console'#10'not a tty'#10'1'#10; ExpectedStatus: 0),
    (Command: 'stty | tail -n 1; stty -echo; stty | tail -n 1; stty sane; stty | tail -n 1'; ExpectedOutput: 'isig icanon echo'#10'isig icanon -echo'#10'isig icanon echo'#10; ExpectedStatus: 0),

    { --- running and ending programs --------------------------------- }
    (Command: 'timeout 5 true; echo $?; timeout 0.2 sleep 5; echo $?'; ExpectedOutput: '0'#10'124'#10; ExpectedStatus: 0),
    (Command: 'timeout 0.1 yes > /dev/null; echo $?'; ExpectedOutput: '124'#10; ExpectedStatus: 0),
    (Command: 'timeout 0.2 sh -c ''while true; do :; done''; echo $?'; ExpectedOutput: '124'#10; ExpectedStatus: 0),
    (Command: 'timeout --preserve-status 0.1 sleep 3; echo $?; timeout -s KILL --preserve-status 0.1 sleep 3; echo $?'; ExpectedOutput: '143'#10'137'#10; ExpectedStatus: 0),
    (Command: 'yes | timeout 0.2 cat > /dev/null; echo $?'; ExpectedOutput: '124'#10; ExpectedStatus: 0),
    (Command: 'kill -l 15; kill -l TERM; kill 99999 2>/dev/null; echo $?'; ExpectedOutput: 'TERM'#10'15'#10'1'#10; ExpectedStatus: 0),
    (Command: 'nice; nice -n 5 echo hi 2>/dev/null; nohup echo hi; stdbuf -oL echo hi'; ExpectedOutput: '0'#10'hi'#10'hi'#10'hi'#10; ExpectedStatus: 0),
    (Command: 'mkdir -p jail/bin && cp /bin/echo jail/bin/ && chroot jail /bin/echo inside'; ExpectedOutput: 'inside'#10; ExpectedStatus: 0),
    (Command: 'chroot jail /bin/ls 2>/dev/null; echo $?'; ExpectedOutput: '127'#10; ExpectedStatus: 0),

    { --- attributes and links ---------------------------------------- }
    (Command: 'touch -d "2020-01-02 03:04:05" t; stat -c %y t; touch -t 202101020304.05 t; stat -c %Y t'; ExpectedOutput: '2020-01-02 03:04:05 +0000'#10'1609556645'#10; ExpectedStatus: 0),
    (Command: 'touch -m -d @1000 t; touch -a -d @2000 t; stat -c "%X %Y" t; touch -r t u; stat -c "%X %Y" u'; ExpectedOutput: '2000 1000'#10'2000 1000'#10; ExpectedStatus: 0),
    (Command: 'date -d "2000-02-29 12:00" +%F_%T; date -r t +%s'; ExpectedOutput: '2000-02-29_12:00:00'#10'1000'#10; ExpectedStatus: 0),
    (Command: 'touch m; chmod 640 m; stat -c %a m; chmod u+x,g-r m; stat -c %A m; chmod a=r m; stat -c %a m'; ExpectedOutput: '640'#10'-rwx------'#10'444'#10; ExpectedStatus: 0),
    (Command: 'mkdir -p ct/d && touch ct/d/f && chmod -R go-rwx ct && stat -c "%a %n" ct ct/d/f'; ExpectedOutput: '700 ct'#10'600 ct/d/f'#10; ExpectedStatus: 0),
    (Command: 'chmod 999 m 2>&1'; ExpectedOutput: 'chmod: invalid mode: ''999'''#10; ExpectedStatus: 1),
    (Command: 'chown nobody:nobody m; stat -c "%U %G %u" m; chgrp wheel m; stat -c %G m; chown root: m; stat -c %U:%G m'; ExpectedOutput: 'nobody nobody 65534'#10'wheel'#10'root:root'#10; ExpectedStatus: 0),
    (Command: 'chown bogus m 2>&1'; ExpectedOutput: 'chown: invalid user: ''bogus'''#10; ExpectedStatus: 1),
    (Command: 'ls -l m | cut -d " " -f 3,4; ls -n m | cut -d " " -f 3,4'; ExpectedOutput: 'root root'#10'0 0'#10; ExpectedStatus: 0),
    (Command: 'echo data > h1; link h1 h2; stat -c %h h1; cat h2; ln h1 h3; stat -c %h h1; rm h2 h3; stat -c %h h1'; ExpectedOutput: '2'#10'data'#10'3'#10'1'#10; ExpectedStatus: 0),
    (Command: 'unlink h1; [ ! -e h1 ] && echo gone; unlink sub 2>&1'; ExpectedOutput: 'gone'#10'unlink: cannot unlink ''sub'': Is a directory'#10; ExpectedStatus: 1),
    (Command: 'echo k > keep; cp -p keep keep2; touch -d @5000 keep; cp -p keep keep3; stat -c %Y keep3'; ExpectedOutput: '5000'#10; ExpectedStatus: 0),
    (Command: 'install -m 640 lines.txt inst.txt; stat -c %a inst.txt; install -d -m 700 ia/b/c; stat -c %a ia/b/c'; ExpectedOutput: '640'#10'700'#10; ExpectedStatus: 0),
    (Command: 'install -D lines.txt deep/x/y.txt && head -n 1 deep/x/y.txt; mkdir -m 711 mm; stat -c %a mm'; ExpectedOutput: 'one'#10'711'#10; ExpectedStatus: 0),
    (Command: 'f=$(mktemp); [ -f "$f" ] && echo file; d=$(mktemp -d); [ -d "$d" ] && echo dir; mktemp -p . demo.XXXX | cut -c 1-7'; ExpectedOutput: 'file'#10'dir'#10'./demo.'#10; ExpectedStatus: 0),
    (Command: 'echo secret > s; shred -u s; [ ! -e s ] && echo shredded; printf 0123456789 > s2; shred -n 0 -z -x s2; od -A n -t x1 s2'; ExpectedOutput: 'shredded'#10' 00 00 00 00 00 00 00 00 00 00'#10; ExpectedStatus: 0),
    (Command: 'realpath sub/dir/..; realpath -s dirlink; realpath --relative-to=sub/dir lines.txt'; ExpectedOutput: '/tmp/coretest/sub'#10'/tmp/coretest/dirlink'#10'../../lines.txt'#10; ExpectedStatus: 0),
    (Command: 'pathchk -p "a b" 2>/dev/null; echo $?; pathchk -p ok_name; echo $?'; ExpectedOutput: '1'#10'0'#10; ExpectedStatus: 0),
    (Command: 'mkdir dutest; printf 12345 > dutest/a; du -ab dutest'; ExpectedOutput: '5'#9'dutest/a'#10'1029'#9'dutest'#10; ExpectedStatus: 0),
    (Command: 'df / | tail -n 1 | cut -d " " -f 1'; ExpectedOutput: 'disk2p1'#10; ExpectedStatus: 0),

    { --- more text tools --------------------------------------------- }
    (Command: 'printf "a\nb\nc\n" > c1; printf "b\nc\nd\n" > c2; comm c1 c2; comm -12 c1 c2'; ExpectedOutput: 'a'#10#9#9'b'#10#9#9'c'#10#9'd'#10'b'#10'c'#10; ExpectedStatus: 0),
    (Command: 'printf "1 a\n2 b\n" > j1; printf "1 x\n3 y\n" > j2; join j1 j2; join -a1 j1 j2; join -v2 j1 j2'; ExpectedOutput: '1 a x'#10'1 a x'#10'2 b'#10'3 y'#10; ExpectedStatus: 0),
    (Command: 'printf "a\tb\n" | expand; printf "a\tb\n" | expand -t 4; printf "        x\n" | unexpand | od -A n -c'; ExpectedOutput: 'a       b'#10'a   b'#10'  \t   x  \n'#10; ExpectedStatus: 0),
    (Command: 'printf "one two\nthree four five\n" | fmt -w 10'; ExpectedOutput: 'one two'#10'three four'#10'five'#10; ExpectedStatus: 0),
    (Command: 'shuf -i 1-5 | sort -n | tr "\n" " "; echo; shuf -n 2 -e a b c | wc -l; shuf -r -n 3 -e x'; ExpectedOutput: '1 2 3 4 5 '#10'2'#10'x'#10'x'#10'x'#10; ExpectedStatus: 0),
    (Command: 'printf "a b\nb c\nx a\n" | tsort'; ExpectedOutput: 'x'#10'a'#10'b'#10'c'#10; ExpectedStatus: 0),
    (Command: 'factor 12 97 1001; echo 18446744073709551615 | factor'; ExpectedOutput: '12: 2 2 3'#10'97: 97'#10'1001: 7 11 13'#10'18446744073709551615: 3 5 17 257 641 65537 6700417'#10; ExpectedStatus: 0),
    (Command: 'seq 5 > sp; split -l 2 sp part; cat partaa partac; split -b 4 -d sp p_; ls p_*'; ExpectedOutput: '1'#10'2'#10'5'#10'p_00'#10'p_01'#10'p_02'#10; ExpectedStatus: 0),
    (Command: 'seq 10 > cs; csplit cs /5/; head -n 1 xx01'; ExpectedOutput: '8'#10'13'#10'5'#10; ExpectedStatus: 0),
    (Command: 'printf "a\n--\nb\n--\nc\n" > cs2; csplit -s -f q cs2 "/--/" "{*}"; cat q00 q02'; ExpectedOutput: 'a'#10'--'#10'c'#10; ExpectedStatus: 0),
    (Command: 'numfmt --to=si 1500000; numfmt --to=iec 1048576; numfmt --from=iec 4K; numfmt --from=auto 1Ki'; ExpectedOutput: '1.5M'#10'1.0M'#10'4096'#10'1024'#10; ExpectedStatus: 0),
    (Command: 'printf AB | od -A x -t x1; printf abc | od -c'; ExpectedOutput: '000000 41 42'#10'000002'#10'0000000   a   b   c'#10'0000003'#10; ExpectedStatus: 0),
    (Command: 'printf 0123456789 | dd bs=4 count=2 2>/dev/null; echo; printf abc | dd conv=ucase 2>/dev/null; echo'; ExpectedOutput: '01234567'#10'ABC'#10; ExpectedStatus: 0),
    (Command: 'dd if=lines.txt of=dd.out bs=1 skip=4 count=3 2>&1 | head -n 2; cat dd.out; echo'; ExpectedOutput: '3+0 records in'#10'3+0 records out'#10'two'#10; ExpectedStatus: 0),
    (Command: 'seq 3 | pr -t; seq 4 | pr -2 -t -l 2 -w 20'; ExpectedOutput: '1'#10'2'#10'3'#10'1         3'#10'2         4'#10; ExpectedStatus: 0),
    (Command: 'echo "hello big world" | ptx -w 30'; ExpectedOutput: '       hello   big world'#10'               hello big world'#10'   hello big   world'#10; ExpectedStatus: 0),
    (Command: 'expr abc : ''a\(.*\)c''; expr aaa : ''a*''; expr x : ''\(y\)'''; ExpectedOutput: 'b'#10'3'#10#10; ExpectedStatus: 1),
    (Command: 'ls /bin/dir /bin/vdir /bin/chgrp /bin/unexpand'; ExpectedOutput: '/bin/chgrp'#10'/bin/dir'#10'/bin/unexpand'#10'/bin/vdir'#10; ExpectedStatus: 0),

    { --- everyday programs ------------------------------------------- }
    (Command: 'grep -n t lines.txt; grep -c o lines.txt; grep -vi O lines.txt'; ExpectedOutput: '2:two'#10'3:three'#10'3'#10'three'#10'five'#10; ExpectedStatus: 0),
    (Command: 'grep -q zzz lines.txt; echo $?; grep -s x nofile; echo $?; grep -H one lines.txt'; ExpectedOutput: '1'#10'2'#10'lines.txt:one'#10; ExpectedStatus: 0),
    (Command: 'grep -E ''^(t|f)[a-z]{3}$'' lines.txt; grep -x -F two lines.txt; grep -w -o "f[a-z]*" lines.txt'; ExpectedOutput: 'four'#10'five'#10'two'#10'four'#10'five'#10; ExpectedStatus: 0),
    (Command: 'echo "a+b" | fgrep "+"; echo aab | egrep "a+b"; echo "a+b" | grep "a+b"; echo xyz | grep -e q -e y'; ExpectedOutput: 'a+b'#10'aab'#10'a+b'#10'xyz'#10; ExpectedStatus: 0),
    (Command: 'mkdir -p gr/x; echo needle > gr/x/f; echo hay > gr/g; grep -r needle gr; grep -rl hay gr; grep -L needle gr/g; grep -c e lines.txt gr/g'; ExpectedOutput: 'gr/x/f:needle'#10'gr/g'#10'gr/g'#10'lines.txt:3'#10'gr/g:0'#10; ExpectedStatus: 0),
    (Command: 'sed -n 2,3p lines.txt; sed 3q lines.txt | sed -n ''$p''; sed -e /two/,/four/d lines.txt'; ExpectedOutput: 'two'#10'three'#10'three'#10'one'#10'five'#10; ExpectedStatus: 0),
    (Command: 'echo hello world | sed s/o/0/g; echo hello world | sed s/o/0/2; echo abc | sed -E ''s/(a)(b)/\2\1&/''; echo aaa | sed s/a/b/2g'; ExpectedOutput: 'hell0 w0rld'#10'hello w0rld'#10'baabc'#10'abb'#10; ExpectedStatus: 0),
    (Command: 'sed ''1!G;h;$!d'' lines.txt | head -n 2; seq 2 | sed ''1i top''; seq 2 | sed ''$a end''; seq 3 | sed ''2c mid'''; ExpectedOutput: 'five'#10'four'#10'top'#10'1'#10'2'#10'1'#10'2'#10'end'#10'1'#10'mid'#10'3'#10; ExpectedStatus: 0),
    (Command: 'echo hello | sed y/abcdefghij/ABCDEFGHIJ/; seq 3 | sed -n ''$=''; seq 4 | sed ''N;s/\n/-/''; echo "a b c" | sed '':x;s/ /_/;tx'''; ExpectedOutput: 'HEllo'#10'3'#10'1-2'#10'3-4'#10'a_b_c'#10; ExpectedStatus: 0),
    (Command: 'seq 6 | sed -n 0~3p; seq 5 | sed -n ''n;p''; printf "a\n\n\nb\n" | sed ''/^$/N;/\n$/D'''; ExpectedOutput: '3'#10'6'#10'2'#10'4'#10'a'#10#10'b'#10; ExpectedStatus: 0),
    (Command: 'printf "x\ny\n" > si; sed -i.bak s/x/z/ si; cat si si.bak; printf "a\tb\n" | sed -n l; seq 3 | sed -n "/2/w sw"; cat sw'; ExpectedOutput: 'z'#10'y'#10'x'#10'y'#10'a\tb$'#10'2'#10; ExpectedStatus: 0),
    (Command: 'seq 5 | sed 2Q; seq 5 | sed 3q5; echo $?; echo AbC | sed s/b/x/I'; ExpectedOutput: '1'#10'1'#10'2'#10'3'#10'5'#10'AxC'#10; ExpectedStatus: 0),
    (Command: 'mkdir -p ft/a/b; touch ft/a/x.txt ft/a/b/y.txt ft/z.log; find ft -name "*.txt" | sort; find ft -type d | sort'; ExpectedOutput: 'ft/a/b/y.txt'#10'ft/a/x.txt'#10'ft'#10'ft/a'#10'ft/a/b'#10; ExpectedStatus: 0),
    (Command: 'find ft -maxdepth 1 | sort; find ft -mindepth 2 -type f -name "y*"; find ft \( -name "*.log" -o -iname "X*" \) -print | sort'; ExpectedOutput: 'ft'#10'ft/a'#10'ft/z.log'#10'ft/a/b/y.txt'#10'ft/a/x.txt'#10'ft/z.log'#10; ExpectedStatus: 0),
    (Command: 'find ft ! -type d -path "*b*"; printf 12345 > ft/s5; find ft -size +3c -size -10c; find ft -empty -name "z*"'; ExpectedOutput: 'ft/a/b/y.txt'#10'ft/s5'#10'ft/z.log'#10; ExpectedStatus: 0),
    (Command: 'touch -d @1000 ft/z.log; find ft -mtime +1; find ft -name s5 -newer ft/z.log; find ft -name a -prune -o -type f -print | sort'; ExpectedOutput: 'ft/z.log'#10'ft/s5'#10'ft/s5'#10'ft/z.log'#10; ExpectedStatus: 0),
    (Command: 'find ft -name "*.log" -exec echo got {} \;; find ft -name "*.txt" -exec echo {} + | wc -w; find ft -type f -print -quit | wc -l'; ExpectedOutput: 'got ft/z.log'#10'2'#10'1'#10; ExpectedStatus: 0),
    (Command: 'find ft/a -name x.txt -delete; ls ft/a; find ft -name s5 -print0 | xargs -0 cat; echo; find nowhere 2>/dev/null; echo $?'; ExpectedOutput: 'b'#10'12345'#10'1'#10; ExpectedStatus: 0),
    (Command: 'echo a b c | xargs; echo a b c | xargs -n 2 echo x; printf "1\n2\n" | xargs -I {} echo "[{}]"; printf "a b\nc\n" | xargs -L 1 echo -'; ExpectedOutput: 'a b c'#10'x a b'#10'x c'#10'[1]'#10'[2]'#10'- a b'#10'- c'#10; ExpectedStatus: 0),
    (Command: 'printf "a:b" | xargs -d : echo; echo "\"x y\" z" | xargs -n 1 echo; echo aaa bbb ccc | xargs -s 12 echo; echo q | xargs -P 1 echo'; ExpectedOutput: 'a b'#10'x y'#10'z'#10'aaa'#10'bbb'#10'ccc'#10'q'#10; ExpectedStatus: 0),
    (Command: 'true | xargs -r echo none; true | xargs echo empty; echo x | xargs false; echo $?; echo x | xargs nosuchcmd 2>/dev/null; echo $?; echo a | xargs -t echo 2>&1'; ExpectedOutput: 'empty'#10'123'#10'127'#10'echo a'#10'a'#10; ExpectedStatus: 0),
    (Command: 'printf "a\nb\nc\n" > d1; printf "a\nB\nc\nd\n" > d2; diff d1 d2; echo $?; diff -u d1 d2 | tail -n +3'; ExpectedOutput: '2c2'#10'< b'#10'---'#10'> B'#10'3a4'#10'> d'#10'1'#10'@@ -1,3 +1,4 @@'#10' a'#10'-b'#10'+B'#10' c'#10'+d'#10; ExpectedStatus: 0),
    (Command: 'diff -i d1 d2; diff -q d1 d2; diff d1 d1; echo $?; diff - d1 < d2 | head -n 1; diff d1 nonexist 2>/dev/null; echo $?'; ExpectedOutput: '3a4'#10'> d'#10'Files d1 and d2 differ'#10'0'#10'2c2'#10'2'#10; ExpectedStatus: 0),
    (Command: 'printf "a  b\n" > w1; printf "a b \n" > w2; diff -b w1 w2 && echo same; printf "ab\n" > w3; diff -w w1 w3 && echo same2; diff w1 w3 > /dev/null; echo $?'; ExpectedOutput: 'same'#10'same2'#10'1'#10; ExpectedStatus: 0),
    (Command: 'diff -c d1 d2 | tail -n +3'; ExpectedOutput: '***************'#10'*** 1,3 ****'#10'  a'#10'! b'#10'  c'#10'--- 1,4 ----'#10'  a'#10'! B'#10'  c'#10'+ d'#10; ExpectedStatus: 0),
    (Command: 'mkdir -p da db; echo 1 > da/f; echo 2 > db/f; echo only > da/g; diff -r da db; echo $?; diff -rN da db | tail -n 2'; ExpectedOutput: 'diff -r da/f db/f'#10'1c1'#10'< 1'#10'---'#10'> 2'#10'Only in da: g'#10'1'#10'1d0'#10'< only'#10; ExpectedStatus: 0),
    (Command: 'less lines.txt | head -n 2; seq 3 | more; seq 2 | less -F; more nofile 2>/dev/null; echo $?'; ExpectedOutput: 'one'#10'two'#10'1'#10'2'#10'3'#10'1'#10'2'#10'1'#10; ExpectedStatus: 0),
    (Command: 'ls /bin/egrep /bin/fgrep /bin/more'; ExpectedOutput: '/bin/egrep'#10'/bin/fgrep'#10'/bin/more'#10; ExpectedStatus: 0),
    { --- shell language --------------------------------------------- }
    (Command: 'for w in apple bob x.txt; do case $w in a*) echo A;; b*|c*) echo B;; *.txt) echo T;; esac; done'; ExpectedOutput: 'A'#10'B'#10'T'#10; ExpectedStatus: 0),
    (Command: 'X=''*''; case abc in "$X") echo literal;; $X) echo pattern;; esac; case x in (y) ;; esac'; ExpectedOutput: 'pattern'#10; ExpectedStatus: 0),
    (Command: 'greet() { echo "hi $1 ($#)"; }; greet bob x; greet'; ExpectedOutput: 'hi bob (2)'#10'hi  (0)'#10; ExpectedStatus: 0),
    (Command: 'f() { local v=inner; X=changed; return 3; echo never; }; v=outer; f; echo $? $v $X'; ExpectedOutput: '3 outer changed'#10; ExpectedStatus: 0),
    (Command: 'set -- a b; f() { echo $1 $#; }; f z; echo $1 $#'; ExpectedOutput: 'z 1'#10'a 2'#10; ExpectedStatus: 0),
    (Command: 'function fact { if [ $1 -le 1 ]; then echo 1; else r=$(fact $(($1 - 1))); echo $(($1 * r)); fi; }; fact 5'; ExpectedOutput: '120'#10; ExpectedStatus: 0),
    (Command: 'f() { echo in-f; }; f > f.out; cat f.out; f | tr a-z A-Z'; ExpectedOutput: 'in-f'#10'IN-F'#10; ExpectedStatus: 0),
    (Command: 'X=world; cat <<EOF'#10'hello $X'#10'EOF'#10'echo after'; ExpectedOutput: 'hello world'#10'after'#10; ExpectedStatus: 0),
    (Command: 'cat <<''EOF'''#10'$X'#10'EOF'#10'cat <<-END'#10#9'tabbed'#10#9'END'#10; ExpectedOutput: '$X'#10'tabbed'#10; ExpectedStatus: 0),
    (Command: 'while read l; do echo "<$l>"; done <<EOF'#10'a'#10'b'#10'EOF'#10; ExpectedOutput: '<a>'#10'<b>'#10; ExpectedStatus: 0),
    (Command: 'seq 2000 > big.txt; cat <<EOF | tail -n 1'#10'$(cat big.txt)'#10'EOF'#10; ExpectedOutput: '2000'#10; ExpectedStatus: 0),
    (Command: 'P=/usr/lib/file.tar.gz; echo ${#P} ${P#*/} ${P##*/} ${P%.*} ${P%%.*}'; ExpectedOutput: '20 usr/lib/file.tar.gz file.tar.gz /usr/lib/file.tar /usr/lib/file'#10; ExpectedStatus: 0),
    (Command: 'echo ${N:=set} $N ${N:+alt} ${E:+alt}.; sh -c ''echo ${E:?gone}; echo never'' 2>/dev/null; echo $?'; ExpectedOutput: 'set set alt .'#10'1'#10; ExpectedStatus: 0),
    (Command: 'i=1; : $((i += 4)); echo $i $((i == 5)) $((i < 3)) $((j = 2 * 3)) $j'; ExpectedOutput: '5 1 0 6 6'#10; ExpectedStatus: 0),
    (Command: 'cmd="echo evaluated"; eval $cmd; eval "X=7; echo \$X"'; ExpectedOutput: 'evaluated'#10'7'#10; ExpectedStatus: 0),
    (Command: 'sh -c ''exec >exec.out; echo into file''; cat exec.out; exec echo replaced; echo not reached'; ExpectedOutput: 'into file'#10'replaced'#10; ExpectedStatus: 0),
    (Command: 'f() { :; }; type f cd if cat; command -v cat; command echo plain; wait'; ExpectedOutput: 'f is a shell function'#10'cd is a shell builtin'#10'if is a shell keyword'#10'cat is /bin/cat'#10'/bin/cat'#10'plain'#10; ExpectedStatus: 0),
    (Command: 'f() { echo f; }; unset -f f; f 2>/dev/null; echo $?'; ExpectedOutput: '127'#10; ExpectedStatus: 0),
    { --- threads --- }
    (Command: '/bin/threadtest'; ExpectedOutput:
      'ok units initialized in dependency order'#10 +
      'ok library initializer ran before the units'#10 +
      'ok threads start'#10 +
      'ok thread exit codes'#10 +
      'ok shared counter under a lock'#10 +
      'ok thread ids'#10 +
      'ok waiting for a thread times out'#10 +
      'ok a thread waiting on a lock continues'#10 +
      'ok threadvars are per thread'#10 +
      'ok library TLS starts from its image in every thread'#10 +
      'ok library TLS is per thread'#10 +
      'ok library TLS blocks are distinct'#10 +
      'ok many short-lived threads'#10 +
      'threadtest: unit finalization ran'#10 +
      'tlstest: library finalizer ran'#10; ExpectedStatus: 0),
    (Command: '/bin/threadtest --exit-with-threads-running; echo $?'; ExpectedOutput: 'tlstest: library finalizer ran'#10'7'#10; ExpectedStatus: 0),
    (Command: '/bin/threadtest --last-thread-exits; echo $?'; ExpectedOutput: '5'#10; ExpectedStatus: 0),
    (Command: '/bin/threadtest --crash-in-thread; echo $?; echo still running'; ExpectedOutput: '139'#10'still running'#10; ExpectedStatus: 0),

    { --- a crashing program ends alone, with status 139 --------------- }
    (Command: '/bin/coretest --crash-on-purpose; echo $?; echo still running'; ExpectedOutput: '139'#10'still running'#10; ExpectedStatus: 0)
  );

var
  PassedCount: Integer;
  FailedCount: Integer;

procedure Check(Condition: Boolean; Name: PChar);
begin
  if Condition then
  begin
    Inc(PassedCount);
    WriteFormatted(StandardOutput, '[coretest] pass: %s'#10, [ArgumentText(Name)]);
  end
  else
  begin
    Inc(FailedCount);
    WriteFormatted(StandardOutput, '[coretest] FAIL: %s'#10, [ArgumentText(Name)]);
  end;
end;

{ Writes Text with control characters made visible, for failure reports. }
procedure WriteVisible(Text: PChar);
var
  Index: Integer;
begin
  Index := 0;
  while Text[Index] <> #0 do
  begin
    case Text[Index] of
      #10: WriteText(StandardOutput, '\n');
      #9: WriteText(StandardOutput, '\t');
    else
      WriteCharacter(StandardOutput, Text[Index]);
    end;
    Inc(Index);
  end;
end;

{ Runs Command through the shell; returns its exit status and output. }
function RunShellCommand(Command: PChar; out Output: PChar): LongInt;
var
  ReadHandle: Int64;
  WriteHandle: Int64;
  Arguments: array[0..3] of PChar;
  Options: TProcessOptions;
  Process: Int64;
  Builder: TTextBuilder;
  Buffer: array[0..1023] of Char;
  Count: Int64;
begin
  BeginText(Builder);
  Output := nil;
  if CreatePipe(ReadHandle, WriteHandle) <> ErrorNone then
  begin
    Output := FinishText(Builder);
    Exit(-1);
  end;
  Arguments[0] := 'sh';
  Arguments[1] := '-c';
  Arguments[2] := Command;
  Arguments[3] := nil;
  DefaultProcessOptions(Options);
  Options.OutputHandle := WriteHandle;
  Process := StartProgram('/bin/sh', @Arguments[0], Options);
  CloseFile(WriteHandle);
  if Process < 0 then
  begin
    CloseFile(ReadHandle);
    Output := FinishText(Builder);
    Exit(LongInt(Process));
  end;
  repeat
    Count := ReadFile(ReadHandle, @Buffer[0], SizeOf(Buffer));
    if Count > 0 then
      AppendBytes(Builder, @Buffer[0], Count);
  until Count <= 0;
  CloseFile(ReadHandle);
  Result := WaitForProgram(Process);
  Output := FinishText(Builder);
end;

procedure RunCommandTest(const Test: TCommandTest);
var
  Output: PChar;
  Status: LongInt;
  Passed: Boolean;
begin
  { Every command starts in the work directory. }
  ChangeDirectory(WorkDirectory);
  Status := RunShellCommand(Test.Command, Output);
  Passed := (Status = Test.ExpectedStatus) and TextIsEqual(Output, Test.ExpectedOutput);
  Check(Passed, Test.Command);
  if not Passed then
  begin
    WriteFormatted(StandardOutput, '[coretest]   expected status %d, output "', [ArgumentNumber(Test.ExpectedStatus)]);
    WriteVisible(Test.ExpectedOutput);
    WriteLine(StandardOutput, '"');
    WriteFormatted(StandardOutput, '[coretest]   got      status %d, output "', [ArgumentNumber(Status)]);
    WriteVisible(Output);
    WriteLine(StandardOutput, '"');
  end;
  FreeMemory(Output);
end;

type
  TAddFunction = function(First, Second: Int64): Int64;
  TGreetingFunction = function: PChar;

procedure TestRunTimeLoading;
var
  LibraryHandle: Int64;
  Add: TAddFunction;
  Greeting: TGreetingFunction;
begin
  LibraryHandle := LoadLibrary('libplugin.so');
  Check(LibraryHandle >= 0, 'LoadLibrary libplugin.so');
  if LibraryHandle < 0 then
    Exit;
  Add := TAddFunction(FindSymbol(LibraryHandle, 'plugin_add'));
  Check((Pointer(Add) <> nil) and (Add(40, 2) = 42), 'call plugin_add through FindSymbol');
  Greeting := TGreetingFunction(FindSymbol(LibraryHandle, 'plugin_greeting'));
  Check((Pointer(Greeting) <> nil) and TextIsEqual(Greeting(), 'hello from libplugin'), 'call plugin_greeting');
  Check(FindSymbol(LibraryHandle, 'no_such_symbol') = nil, 'FindSymbol of a missing symbol');
  Check(LoadLibrary('libplugin.so') >= 0, 'LoadLibrary of an already loaded library');
  Check(LoadLibrary('libmissing.so') < 0, 'LoadLibrary of a missing library fails');
end;

procedure TestHeap;
var
  Blocks: array[0..99] of PByte;
  Index: Integer;
  Large: PByte;
  AllIntact: Boolean;
  Grown: PChar;
begin
  for Index := 0 to High(Blocks) do
  begin
    Blocks[Index] := PByte(AllocateMemory(QWord(Index) * 37 + 1));
    FillMemory(Blocks[Index], QWord(Index) * 37 + 1, Byte(Index));
  end;
  AllIntact := True;
  for Index := 0 to High(Blocks) do
  begin
    if Blocks[Index][QWord(Index) * 37] <> Byte(Index) then
      AllIntact := False;
    FreeMemory(Blocks[Index]);
  end;
  Check(AllIntact, 'heap: 100 blocks of different sizes');

  Large := PByte(AllocateMemory(16 * 1024 * 1024));
  if Large <> nil then
  begin
    Large[0] := 1;
    Large[16 * 1024 * 1024 - 1] := 2;
  end;
  Check((Large <> nil) and (Large[0] = 1) and (Large[16 * 1024 * 1024 - 1] = 2), 'heap: 16 MiB block');
  FreeMemory(Large);

  Grown := DuplicateText('start');
  Grown := PChar(ReallocateMemory(Grown, 10000));
  Check(TextIsEqual(Grown, 'start'), 'heap: reallocation keeps contents');
  FreeMemory(Grown);
end;

procedure PrepareWorkDirectory;
begin
  if PathExists(WorkDirectory) then
    RemoveTree(WorkDirectory);
  if not IsDirectory('/tmp') then
    CreateDirectory('/tmp');
  CreateDirectory(WorkDirectory);
  ChangeDirectory(WorkDirectory);
  SetVariable('PATH', '/bin');
  SetVariable('HOME', '/');
end;

procedure CrashOnPurpose;
var
  Address: PByte;
begin
  { Writes to address zero, which is never mapped: the kernel must end
    this process (status 139) and nothing else. }
  Address := nil;
  Address^ := 1;
end;

var
  Index: Integer;
begin
  if TextIsEqual(Argument(1), '--crash-on-purpose') then
    CrashOnPurpose;
  PassedCount := 0;
  FailedCount := 0;
  WriteLine(StandardOutput, '[coretest] user mode tests starting');
  PrepareWorkDirectory;
  TestRunTimeLoading;
  TestHeap;
  for Index := 0 to High(CommandTests) do
    RunCommandTest(CommandTests[Index]);

  ChangeDirectory('/');
  RemoveTree(WorkDirectory);
  SyncFileSystems;
  WriteFormatted(StandardOutput, '[coretest] %d passed, %d failed'#10, [ArgumentNumber(PassedCount),
    ArgumentNumber(FailedCount)]);
  if FailedCount > 0 then
    Halt(1);
  Halt(0);
end.
