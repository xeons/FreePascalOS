{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  coretest - tests for user mode, the shell and the core utilities

  Run by "make test" as the first user process (kernel option
  init=/bin/coretest). It works in /tmp/coretest and checks:

    * run time loading of libplugin.so (LoadLibrary / FindSymbol),
    * the program heap,
    * a list of shell command lines: each runs through "sh -c" with its
      standard output captured through a pipe, and both the output and
      the exit status must match (those using su run commands as the
      ordinary user "user", to check permissions),
    * threads, thread-local storage and initialization order (threadtest),
    * events, timers, waiting on several handles, channels, ports and a
      section shared between two processes (ipctest),
    * watching files and folders for changes made by other processes,
      on several file system types (watchtest), and the permission a
      watch needs,
    * pseudo-terminals: a shell on one, typed into through the master
      side, Ctrl-C, Ctrl-D, the window size and the hang-up (ptytest),
    * notifications and requests to end: taken or left to the system,
      groups, sessions, a handler thread, permissions, Ctrl-C taken by a
      program and a terminal's new size (notifytest),
    * settings: file locks and the settings files, several programs
      writing at once (settingstest), the settings tool, who may change
      which settings and the modes of their files,
    * the service manager: definitions, the start order, readiness,
      restarts, logs, the service command (servicetest), and login with
      a right and a wrong password,
    * the Control Panel's subsystems: time zones and local times (date,
      timezone), the system settings service (the zone, the clock, the
      volumes and default output kept, refusals), accounts (useradd,
      usermod, userdel) and the keyboards' layouts (keyboardsettings),
    * networking (networktest): loopback ping, UDP and TCP echo over
      loopback (a megabyte through many windows), refused connections,
      waiting on sockets, the network service (DHCP from QEMU on eth0,
      its state file, a settings change applied live, the lease given
      back when it stops), ping and ARP for QEMU's gateway and a TCP
      echo through it, and what an ordinary user may not do; the
      resolver (dnstest: /etc/hosts and a DNS server of its own on
      127.0.0.1); ifconfig, route, arp, ping, host, nslookup and
      hostname, netstat and nc,
    * wget over HTTP and HTTPS against test servers on the host
      (wgettest): contents, cipher suites, redirects, chunked bodies,
      continuing, timeouts and each certificate failure,
    * heap checking (heaptest): its promises, and that a use after free,
      a write after free, a double free and a write past the end each end
      the program that makes them,
    * that a crashing program (coretest --crash-on-purpose) only ends
      itself, with an unhandled EAccessViolation (EStackOverflow for a
      stack overflow) and status 217, and that
      one without an exception dispatcher is ended by the kernel (139).

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
  SysUtils,
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
  CommandTests: array[0..368] of TCommandTest = (
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
    (Command: 'sysinfo -l | grep -c -e ''^OS: FreePascalOS x86_64$'' -e ''^Kernel: FreePascalOS '' -e ''^CPU: .* ([0-9]*)$'' -e ''^Memory: .* MiB'' -e ''^Disk (/): ''; sysinfo -C | grep -c ''|__|''; sysinfo -c | grep -c 107m; sysinfo extra 2>/dev/null; echo $?'; ExpectedOutput: '5'#10'1'#10'1'#10'1'#10; ExpectedStatus: 0),
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
    (Command: 'cd /; ls | head -n 3'; ExpectedOutput: 'bin'#10'dev'#10'etc'#10; ExpectedStatus: 0),
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
    (Command: 'printf hello | gzip | gzip -d; echo; seq 2000 | gzip -9 | gzip -dc | tail -n 1'; ExpectedOutput: 'hello'#10'2000'#10; ExpectedStatus: 0),
    (Command: 'seq 500 > z.txt; gzip z.txt; ls z.txt*; gzip -dk z.txt.gz; ls z.txt*; tail -n 1 z.txt'; ExpectedOutput: 'z.txt.gz'#10'z.txt'#10'z.txt.gz'#10'500'#10; ExpectedStatus: 0),
    (Command: '{ printf one | gzip -1; printf two | gzip; } | gzip -d; echo; gzip -c z.txt | gzip -d | wc -l'; ExpectedOutput: 'onetwo'#10'500'#10; ExpectedStatus: 0),
    (Command: 'echo junk | gzip -d 2>&1; echo $?; gzip -d z.txt 2>&1; echo $?'; ExpectedOutput: 'gzip: stdin: not in gzip format'#10'1'#10'gzip: z.txt: unknown suffix -- ignored'#10'1'#10; ExpectedStatus: 0),

    { --- users and the system ---------------------------------------- }
    (Command: 'id; id -un; id -g; whoami; groups; groups root'; ExpectedOutput: 'uid=0(root) gid=0(root) groups=0(root)'#10'root'#10'0'#10'root'#10'root'#10'root : root wheel'#10; ExpectedStatus: 0),
    (Command: 'id nobody; logname; users'; ExpectedOutput: 'uid=65534(nobody) gid=65534(nobody) groups=65534(nobody)'#10'root'#10'root'#10; ExpectedStatus: 0),
    (Command: 'who | cut -c 1-16; who -q'; ExpectedOutput: 'root     console'#10'root'#10'# users=1'#10; ExpectedStatus: 0),
    (Command: 'test "$(nproc)" -ge 1 && test "$(nproc --ignore=99)" = 1 && echo processors; arch; hostid | wc -c; uptime -p | cut -c 1-3'; ExpectedOutput: 'processors'#10'x86_64'#10'9'#10'up '#10; ExpectedStatus: 0),
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
    (Command: 'df | grep " /$" | cut -d " " -f 1'; ExpectedOutput: 'disk2p1'#10; ExpectedStatus: 0),

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
      'ok floating point registers are per thread'#10 +
      'ok memory freed during a system call'#10 +
      'threadtest: unit finalization ran'#10 +
      'tlstest: library finalizer ran'#10; ExpectedStatus: 0),
    (Command: '/bin/threadtest --exit-with-threads-running; echo $?'; ExpectedOutput: 'tlstest: library finalizer ran'#10'7'#10; ExpectedStatus: 0),
    (Command: '/bin/threadtest --last-thread-exits; echo $?'; ExpectedOutput: '5'#10; ExpectedStatus: 0),
    { threadtest has SysUtils (through libcoreutils), so the crash ends
      as an unhandled exception: status 217. }
    (Command: '/bin/threadtest --crash-in-thread 2>/dev/null; echo $?; echo still running'; ExpectedOutput: 'tlstest: library finalizer ran'#10'217'#10'still running'#10; ExpectedStatus: 0),
    { --- users and processes ----------------------------------------- }
    (Command: 'umask; umask 077; touch um1; mkdir um2; stat -c %a um1 um2; umask -S; umask 022'; ExpectedOutput: '0022'#10'600'#10'700'#10'u=rwx,g=,o='#10; ExpectedStatus: 0),
    (Command: 'su user -c "id; whoami; logname; cd; pwd; echo \$HOME"'; ExpectedOutput: 'uid=1000(user) gid=1000(user) groups=1000(user)'#10'user'#10'user'#10'/home/user'#10'/home/user'#10; ExpectedStatus: 0),
    (Command: 'su user -c "touch /etc/x" 2>&1; echo $?; [ -e /etc/x ] || echo absent'; ExpectedOutput: 'touch: cannot touch ''/etc/x'': Permission denied'#10'1'#10'absent'#10; ExpectedStatus: 0),
    { /tmp is sticky: only the owner of a name may remove or replace it. }
    (Command: 'echo root > /tmp/root-owned; su user -c "rm /tmp/root-owned; echo x > /tmp/mine; mv /tmp/mine /tmp/root-owned; mv /tmp/mine /tmp/mine2; rm /tmp/mine2" 2>&1; cat /tmp/root-owned; ls /tmp/mine* 2>&1; rm /tmp/root-owned'; ExpectedOutput: 'rm: cannot remove ''/tmp/root-owned'': Permission denied'#10'mv: cannot move ''/tmp/mine'' to ''/tmp/root-owned'': Permission denied'#10'root'#10'ls: cannot access ''/tmp/mine*'': No such file or directory'#10; ExpectedStatus: 0),
    { A file removed while open stays readable; renaming replaces. }
    (Command: 'echo kept > f; { rm f; [ -e f ] || echo removed; cat; } < f; echo a > x; echo b > y; mv y x; cat x; [ -e y ] || echo moved'; ExpectedOutput: 'removed'#10'kept'#10'b'#10'moved'#10; ExpectedStatus: 0),
    (Command: 'su user -c "cat /etc/shadow" >/dev/null 2>&1 || echo denied; su user -c "rm lines.txt" 2>/dev/null || echo kept'; ExpectedOutput: 'denied'#10'kept'#10; ExpectedStatus: 0),
    (Command: 'mkdir -m 700 priv && touch priv/f && su user -c "ls priv/f" >/dev/null 2>&1 || echo nosearch'; ExpectedOutput: 'nosearch'#10; ExpectedStatus: 0),
    (Command: 'su user -c "cd && echo hi > mine && ls -n mine | cut -d \" \" -f 3,4 && stat -c %a mine && rm mine"'; ExpectedOutput: '1000 1000'#10'644'#10; ExpectedStatus: 0),
    (Command: 'touch own; chown user own; su user -c "chown root own" 2>/dev/null || echo no1; su user -c "chgrp wheel own" 2>/dev/null || echo no2; su user -c "chmod 600 own && stat -c %a own"; su user -c "chmod 600 lines.txt" 2>/dev/null || echo no3'; ExpectedOutput: 'no1'#10'no2'#10'600'#10'no3'#10; ExpectedStatus: 0),
    (Command: 'touch shared; chmod 666 shared; su user -c "touch shared" && echo now; su user -c "touch -d @5 shared" 2>/dev/null || echo notowner'; ExpectedOutput: 'now'#10'notowner'#10; ExpectedStatus: 0),
    (Command: 'cp /bin/echo myecho; chmod 644 myecho; ./myecho hi 2>/dev/null; echo $?; chmod 755 myecho; ./myecho hi'; ExpectedOutput: '126'#10'hi'#10; ExpectedStatus: 0),
    (Command: 'su user -c "echo root | su -c whoami" 2>/dev/null; su user -c "echo wrong | su -c whoami" 2>/dev/null; echo $?'; ExpectedOutput: 'root'#10'1'#10; ExpectedStatus: 0),
    (Command: 'su user -c "printf ''user\nnew1\nnew1\n'' | passwd" 2>/dev/null; su user -c "echo new1 | su user -c whoami" 2>/dev/null; printf ''user\nuser\n'' | passwd user 2>/dev/null | tail -n 1'; ExpectedOutput: 'Changing password for user.'#10'passwd: password updated successfully'#10'user'#10'passwd: password updated successfully'#10; ExpectedStatus: 0),
    (Command: 'ps | head -n 1; ps -f | head -n 1; ps -e -o comm= > ps.out; sort ps.out | tr "\n" " "; echo'; ExpectedOutput: '    PID TTY          TIME CMD'#10'UID          PID    PPID  C STIME TTY          TIME CMD'#10'coretest ps sh '#10; ExpectedStatus: 0),
    (Command: 'ps aux | head -n 1; ps -o user= -o comm= -p $(pgrep -x coretest); su user -c "ps -o user= -u user" | sort -u'; ExpectedOutput: 'USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START     TIME COMMAND'#10'root     coretest'#10'user'#10; ExpectedStatus: 0),
    { Processor time and memory: the kernel's accounting (usagetest), the
      columns ps shows from it, and whose command lines may be seen. }
    (Command: 'usagetest --own-details > usage.log; echo $?; grep -E ''FAIL|='' usage.log; tail -n 1 usage.log | cut -d " " -f 5-'; ExpectedOutput: '0'#10'checks passed'#10; ExpectedStatus: 0),
    (Command: 'ps -o pid,user,pcpu,rss,time,comm | head -n 1; ps -o tty= -p $$; burn -s 3 -m 8 > /dev/null & p=$!; sleep 1.5; c=$(ps -o pcpu= -p $p | cut -d . -f 1 | tr -d " "); r=$(ps -o rss= -p $p | tr -d " "); wait; test $c -ge 10 && echo busy; test $r -ge 8192 && echo resident'; ExpectedOutput: '    PID USER     %CPU   RSS     TIME COMMAND'#10'console'#10'busy'#10'resident'#10; ExpectedStatus: 0),
    (Command: 'top -b -n 1 -d 0.2 > top.out; head -n 1 top.out | cut -c 1-8; sed -n 5p top.out; grep -c " top$" top.out'; ExpectedOutput: 'top - up'#10'    PID USER      NI    RES S  %CPU     TIME COMMAND'#10'1'#10; ExpectedStatus: 0),
    (Command: 'sleep 5 & ps -o args= -p $!; su user -c "ps -o args= -p $!; sleep 5 & ps -o args= -p \$!; kill \$!"; kill $!'; ExpectedOutput: 'sleep 5'#10'[sleep]'#10'sleep 5'#10; ExpectedStatus: 0),
    (Command: 'nice; nice -n 5 nice; nice -n 5 nice -n 3 nice; nice -n -5 nice; su user -c "nice -n 5 nice -n -2 nice" 2>/dev/null'; ExpectedOutput: '0'#10'5'#10'8'#10'-5'#10'5'#10; ExpectedStatus: 0),
    (Command: 'renice 3 -p $(pgrep -x coretest) | cut -d " " -f 2-; ps -o ni= -p $(pgrep -x coretest); su user -c "renice 0 -p $(pgrep -x coretest)" 2>/dev/null || echo denied; renice 0 -p $(pgrep -x coretest) > /dev/null'; ExpectedOutput: '(process ID) old priority 0, new priority 3'#10'  3'#10'denied'#10; ExpectedStatus: 0),
    (Command: 'pgrep -x coretest | wc -l; pgrep -c nosuchprogram; echo $?; sleep 30 & pkill -x sleep; echo $?'; ExpectedOutput: '1'#10'0'#10'1'#10'0'#10; ExpectedStatus: 0),
    (Command: 'expr "$(uptime)" : ''.*up .*load average: [0-9]*\.[0-9][0-9], [0-9]*\.[0-9][0-9], [0-9]*\.[0-9][0-9]$'' > /dev/null && echo ok'; ExpectedOutput: 'ok'#10; ExpectedStatus: 0),
    (Command: 'mkfifo ff && ls -l ff | cut -c 1 && stat -c %F ff && test -p ff && echo isfifo; head -n 2 lines.txt | tee ff > /dev/null & cat ff; rm ff'; ExpectedOutput: 'p'#10'fifo'#10'isfifo'#10'one'#10'two'#10; ExpectedStatus: 0),
    (Command: 'rm -f /tmp/fifo-check; mknod /tmp/fifo-check p && stat -c %F /tmp/fifo-check; mknod nb b 1 2 2>/dev/null || echo noblock'; ExpectedOutput: 'fifo'#10'noblock'#10; ExpectedStatus: 0),
    (Command: 'printf 12345 > a5; seq 3000 > s3k; du a5 s3k; ls -s a5 s3k; stat -c "%b %B" a5; du -s dutest'; ExpectedOutput: '1'#9'a5'#10'14'#9's3k'#10' 1 a5'#10'14 s3k'#10'2 512'#10'2'#9'dutest'#10; ExpectedStatus: 0),

    { --- job control ------------------------------------------------- }
    (Command: 'sleep 5 & jobs; kill %1; wait %1; echo $?'; ExpectedOutput: '[1]+  Running                 sleep 5 &'#10'143'#10; ExpectedStatus: 0),
    (Command: 'sleep 1 & jobs -p > jp; read p < jp; test "$p" = "$!" && echo same; wait; echo $?'; ExpectedOutput: 'same'#10'0'#10; ExpectedStatus: 0),
    (Command: 'sh -c "exit 3" & wait $!; echo $?; wait 99999 2>/dev/null; echo $?; wait; echo $?'; ExpectedOutput: '3'#10'127'#10'0'#10; ExpectedStatus: 0),
    { kill: TERM, HUP and INT ask a program to end (one that takes the
      request ends as it chooses, one that does not with 128 + the
      signal), KILL ends it whatever it takes. }
    (Command: 'sleep 5 & kill -9 $!; wait $!; echo $?; sleep 5 & kill -INT $!; wait $!; echo $?; sleep 5 & kill -HUP $!; wait $!; echo $?'; ExpectedOutput: '137'#10'130'#10'129'#10; ExpectedStatus: 0),
    (Command: 'notifytest --take 2 42 > t.out & until grep -q ready t.out 2>/dev/null; do sleep 0.1; done; kill $!; wait $!; echo $?; cut -d " " -f 1-2 t.out; notifytest --take 2 42 > t.out & until grep -q ready t.out 2>/dev/null; do sleep 0.1; done; kill -9 $!; wait $!; echo $?'; ExpectedOutput: '42'#10'ready'#10'got asked'#10'137'#10; ExpectedStatus: 0),
    (Command: 'sleep 1 & kill -STOP $!; sleep 1; jobs; ps -o s= -p $!; kill -CONT %1; wait; echo done $?'; ExpectedOutput: '[1]+  Stopped                 sleep 1'#10'T'#10'done 0'#10; ExpectedStatus: 0),
    (Command: 'sleep 1 & kill -s STOP %1; sleep 1; bg; wait; echo $?'; ExpectedOutput: '[1]+ sleep 1 &'#10'0'#10; ExpectedStatus: 0),
    (Command: 'sleep 1 | cat & sleep 0 & jobs; fg %1; echo fg $?; jobs %2 2>&1; fg 2>&1; echo $?'; ExpectedOutput: '[1]-  Running                 sleep 1 | cat &'#10'[2]+  Running                 sleep 0 &'#10'sleep 1 | cat'#10'fg 0'#10'[2]+  Done                    sleep 0'#10'sh: fg: current: no such job'#10'1'#10; ExpectedStatus: 0),

    { --- devices ----------------------------------------------------- }
    (Command: 'ls -l /dev/null | cut -c 1-10; stat -c "%F %a" /dev/zero; ls -ld /dev | cut -c 1; test -c /dev/console && echo console'; ExpectedOutput: 'crw-rw-rw-'#10'character special file 666'#10'd'#10'console'#10; ExpectedStatus: 0),
    (Command: 'head -c 5 /dev/zero | od -An -tx1; head -c 4096 /dev/urandom | wc -c; cat /dev/null | wc -c; echo gone > /dev/null; echo $?'; ExpectedOutput: ' 00 00 00 00 00'#10'4096'#10'0'#10'0'#10; ExpectedStatus: 0),
    (Command: 'dd if=/dev/zero of=/dev/full count=1 2>/dev/null; echo $?; test "$(ls /dev | grep -c "^disk")" -gt 0 && echo disks; ls /dev | grep -x -e null -e tty -e random'; ExpectedOutput: '1'#10'disks'#10'null'#10'random'#10'tty'#10; ExpectedStatus: 0),
    (Command: 'test -b /dev/disk1p1 && stat -c "%F %a" /dev/disk1p1; dd if=/dev/disk1p1 bs=512 count=1 2>/dev/null | wc -c; dd if=/dev/disk1p1 bs=1 skip=54 count=5 2>/dev/null'; ExpectedOutput: 'block special file 600'#10'512'#10'FAT12'; ExpectedStatus: 0),
    (Command: 'dd if=/dev/zero of=/dev/disk1p1 count=1 2>/dev/null; echo $?; su user -c "head -c 1 /dev/disk1p1" 2>/dev/null; echo $?; find /dev -type b -name "disk1p1"'; ExpectedOutput: '1'#10'1'#10'/dev/disk1p1'#10; ExpectedStatus: 0),
    (Command: 'ls /dev | grep -x -e keyboard -e serial0; stat -c "%F %a" /dev/keyboard; cat /dev/keyboard 2>/dev/null; echo $?; ls /dev | grep ahci || echo hidden'; ExpectedOutput: 'keyboard'#10'serial0'#10'character special file 600'#10'1'#10'hidden'#10; ExpectedStatus: 0),
    (Command: 'dd if=/dev/disk3 bs=512 skip=100 count=1 2>/dev/null; echo $?; dd if=/dev/disk3 bs=512 count=1 2>/dev/null | wc -c; dd if=/dev/disk3 bs=512 skip=100 count=1 2>/dev/null; dd if=/dev/disk3 bs=512 skip=99 count=1 2>/dev/null | wc -c'; ExpectedOutput: '1'#10'512'#10'512'#10; ExpectedStatus: 0),
    { Sound (HD Audio, recorded by QEMU and checked by the host): the
      mixer, a tone, and a WAV file written by tone and played by play. }
    (Command: 'voicetest'; ExpectedOutput: 'voicetest: 44 checks passed'#10; ExpectedStatus: 0),
    (Command: 'effecttest'; ExpectedOutput: 'effecttest: 41 checks passed'#10; ExpectedStatus: 0),
    (Command: 'record -r 16000 -c 1 i.wav 0.5 && soundinfo i.wav; tone -o s.wav -r 22050 -c 1 -f u8 440 0.25 && soundinfo s.wav'; ExpectedOutput: 'i.wav: 16000 Hz, 1 channel, s16, 0.50 s, peak 0%, silent'#10's.wav: 22050 Hz, 1 channel, u8, 0.25 s, peak 49%, 440 Hz'#10; ExpectedStatus: 0),
    (Command: 'printf "BM\076\000\000\000\000\000\000\000\066\000\000\000\050\000\000\000\002\000\000\000\001\000\000\000\001\000\030\000\000\000\000\000\010\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\377\000\000\000\377\000\000\000" > t.bmp; imageinfo t.bmp; imageinfo /etc/passwd 2>&1; echo $?; rm t.bmp'; ExpectedOutput: 't.bmp: BMP, 2 x 1, 24 bits per pixel'#10'imageinfo: /etc/passwd: not an image format known'#10'1'#10; ExpectedStatus: 0),
    (Command: 'su user -c "poweroff; reboot; halt; suspend" 2>&1; poweroff now 2>&1 | head -n 1'; ExpectedOutput: 'poweroff: cannot shut down: Operation not permitted'#10'reboot: cannot shut down: Operation not permitted'#10'halt: cannot shut down: Operation not permitted'#10'suspend: cannot suspend: Operation not permitted'#10'poweroff: no arguments are taken'#10; ExpectedStatus: 0),
    (Command: 'mixer; mixer 90; mixer; mixer 80'; ExpectedOutput: 'volume 80%'#10'volume 90%'#10; ExpectedStatus: 0),
    { The order and lengths are what check-audio.py expects: a tone, a WAV
      file, two programs at once (mixed), then other rates, sample
      formats and channel counts (converted). }
    (Command: 'tone 1000 1 && tone -o t.wav -r 44100 440 0.5 && wc -c < t.wav && play t.wav; echo $?; play /etc/passwd 2>&1; tone 600 1 & tone 1500 1; wait; tone -r 22050 -f u8 800 0.5; tone -r 96000 -f float -c 1 2000 0.5; tone -r 11025 -f s24 -c 6 300 0.5; voicetest play; record -d /dev/audiomonitor -r 16000 -c 1 m.wav 0.5 & record -d /dev/audiomonitor -r 96000 -c 6 -f float n.wav 0.5 & tone 900 1; wait; soundinfo m.wav n.wav; tone -d /dev/audio1 700 0.5; tone -d /dev/audio2 500 0.5'; ExpectedOutput: '88244'#10'0'#10'play: /etc/passwd: not a WAV file'#10'm.wav: 16000 Hz, 1 channel, s16, 0.50 s, peak 50%, 900 Hz'#10'n.wav: 96000 Hz, 6 channels, float, 0.50 s, peak 50%, 900 Hz'#10; ExpectedStatus: 0),
    { The optical drive (ATAPI) on the fifth AHCI port: 2048-byte blocks,
      read only. }
    (Command: 'dd if=/dev/disk4 bs=2048 skip=37 count=1 2>/dev/null | head -c 26; echo; dd if=/dev/disk4 bs=2048 skip=10 count=3 2>/dev/null | tail -c 2048 | head -c 26; echo; echo x | dd of=/dev/disk4 2>&1 | head -n 1'; ExpectedOutput: 'FreePascalOS CD block 0037'#10'FreePascalOS CD block 0012'#10'dd: error writing ''/dev/disk4'': Read-only file system'#10; ExpectedStatus: 0),
    (Command: 'echo x > /dev/full; echo $?; echo x 2>&1 > /dev/full | cat; seq 1000 | head -n 1; echo ok > /dev/null; echo $?'; ExpectedOutput: '1'#10'echo: write error: No space left on device'#10'1'#10'0'#10; ExpectedStatus: 0),
    (Command: 'taskset 1 nproc; taskset -c 0 sh -c nproc; sh -c ''taskset -pc 0 $$ | tail -n 1 | cut -d: -f2''; taskset 0x10000000 true 2>/dev/null; echo $?'; ExpectedOutput: '1'#10'1'#10' 0'#10'1'#10; ExpectedStatus: 0),
    (Command: 'rtltest > rt.log; echo $?; grep FAIL rt.log; tail -n 1 rt.log | cut -d " " -f 3-'; ExpectedOutput: '0'#10'passed, 0 failed'#10; ExpectedStatus: 0),
    { Heap checking (HEAP_CHECKS): what it promises, and each mistake
      ends the program - a use after free with runtime error 216, the
      others with the report and status 204. }
    (Command: 'HEAP_CHECKS=all heaptest > heap.log; echo $?; grep FAIL heap.log; tail -n 1 heap.log | cut -d " " -f 3-'; ExpectedOutput: '0'#10'passed, 0 failed'#10; ExpectedStatus: 0),
    (Command: 'HEAP_CHECKS=all heaptest --use-after-free 2>&1 | head -n 1 | cut -c 1-17; HEAP_CHECKS=all heaptest --use-after-free 2>/dev/null; echo $?'; ExpectedOutput: 'Runtime error 216'#10'216'#10; ExpectedStatus: 0),
    (Command: 'HEAP_CHECKS=all heaptest --write-after-free 2> heap.err; echo $?; grep "heap check in" heap.err | cut -d: -f2; grep "offset:" heap.err; grep "freed at:" heap.err | cut -c 1-14'; ExpectedOutput: '204'#10' memory was written after it was freed'#10'  offset:    10 holds $00 instead of $DF'#10'  freed at: $0'#10; ExpectedStatus: 0),
    (Command: 'HEAP_CHECKS=all heaptest --double-free 2> heap.err; echo $?; grep "heap check in" heap.err | cut -d: -f2; grep "freed before at:" heap.err | cut -c 1-21'; ExpectedOutput: '204'#10' a block was freed twice'#10'  freed before at: $0'#10; ExpectedStatus: 0),
    { make test boots with the option heapchecks, which programs follow
      when HEAP_CHECKS is not set. }
    (Command: 'heaptest --use-after-free 2>/dev/null; echo $?'; ExpectedOutput: '216'#10; ExpectedStatus: 0),
    (Command: 'HEAP_CHECKS=fill heaptest --write-past-end 2> heap.err; echo $?; grep "heap check in" heap.err | cut -d: -f2; grep "offset:" heap.err'; ExpectedOutput: '204'#10' memory was written past the end of a block'#10'  offset:    20 holds $00 instead of $FD'#10; ExpectedStatus: 0),
    (Command: '/bin/coretest --error-order 2>&1 | cat'; ExpectedOutput: 'error first'#10'output second'#10; ExpectedStatus: 0),
    (Command: 'ipctest > ipc.log; echo $?; grep FAIL ipc.log; tail -n 1 ipc.log | cut -d " " -f 5-'; ExpectedOutput: '0'#10'checks passed'#10; ExpectedStatus: 0),
    { --- networking (networktest, ifconfig, route, arp, ping) ----------- }
    (Command: 'networktest > net.log; echo $?; grep FAIL net.log; tail -n 1 net.log | cut -d " " -f 5-'; ExpectedOutput: '0'#10'checks passed'#10; ExpectedStatus: 0),
    (Command: 'su user -c "networktest --unprivileged" > netu.log; echo $?; grep FAIL netu.log; tail -n 1 netu.log | cut -d " " -f 5-'; ExpectedOutput: '0'#10'checks passed'#10; ExpectedStatus: 0),
    { wget and libtls against the test web servers on the host. }
    (Command: 'wgettest > wget.log; echo $?; grep FAIL wget.log; tail -n 1 wget.log | cut -d " " -f 5-'; ExpectedOutput: '0'#10'checks passed'#10; ExpectedStatus: 0),
    (Command: 'ifconfig lo | head -n 4'; ExpectedOutput: 'lo: flags=<UP,LOOPBACK,RUNNING>  mtu 1500'#10'        inet 127.0.0.1  netmask 255.0.0.0'#10'        inet6 ::1  prefixlen 128  scopeid 0x10<host>'#10'        loop'#10; ExpectedStatus: 0),
    (Command: 'ifconfig eth0 | grep inet6'; ExpectedOutput: '        inet6 fe80::5054:ff:fe12:3456  prefixlen 64  scopeid 0x20<link>'#10'        inet6 fec0::5054:ff:fe12:3456  prefixlen 64  scopeid 0x40<site>'#10; ExpectedStatus: 0),
    (Command: 'ifconfig eth0 | head -n 2'; ExpectedOutput: 'eth0: flags=<UP,BROADCAST,RUNNING>  mtu 1500'#10'        inet 10.0.2.15  netmask 255.255.255.0  broadcast 10.0.2.255'#10; ExpectedStatus: 0),
    (Command: 'ifconfig nosuch 2>&1; echo $?'; ExpectedOutput: 'ifconfig: nosuch: error fetching interface information: Device not found'#10'1'#10; ExpectedStatus: 0),
    (Command: 'route'; ExpectedOutput: 'Kernel IP routing table'#10'Destination     Gateway         Genmask         Flags Metric Iface'#10'0.0.0.0         10.0.2.2        0.0.0.0         UG    0      eth0'#10'10.0.2.0        0.0.0.0         255.255.255.0   U     0      eth0'#10'127.0.0.0       0.0.0.0         255.0.0.0       U     0      lo'#10; ExpectedStatus: 0),
    (Command: 'ping -c 1 -q 10.0.2.2 > /dev/null; arp 10.0.2.2 | tail -n 1 | cut -c 1-22'; ExpectedOutput: '10.0.2.2         ether'#10; ExpectedStatus: 0),
    (Command: 'su user -c "ifconfig eth0 down" 2>&1; echo $?; su user -c "route add default gw 10.0.2.9" 2>&1; echo $?; ifconfig eth0 | head -n 1 | cut -d " " -f 2'; ExpectedOutput: 'ifconfig: eth0: Operation not permitted'#10'1'#10'route: cannot add the route: Operation not permitted'#10'1'#10'flags=<UP,BROADCAST,RUNNING>'#10; ExpectedStatus: 0),
    (Command: 'route add -net 10.9.0.0/16 gw 10.0.2.2 && route | grep 10.9.0.0 | cut -c 1-47; route del -net 10.9.0.0/16 && route | grep 10.9.0.0 | wc -l'; ExpectedOutput: '10.9.0.0        10.0.2.2        255.255.0.0    '#10'0'#10; ExpectedStatus: 0),
    (Command: 'ping -c 2 -i 0.2 127.0.0.1 | sed -e "s/time=.*/time/" -e "s/time [0-9]*ms/time/" -e "s/= .*/= X/"'; ExpectedOutput: 'PING 127.0.0.1 (127.0.0.1) 56(84) bytes of data.'#10'64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time'#10'64 bytes from 127.0.0.1: icmp_seq=2 ttl=64 time'#10#10'--- 127.0.0.1 ping statistics ---'#10'2 packets transmitted, 2 received, 0% packet loss, time'#10'rtt min/avg/max/mdev = X'#10; ExpectedStatus: 0),
    { A name nobody has: what the message says depends on whether QEMU's
      DNS can reach the internet, the status does not. }
    (Command: 'su user -c "ping -c 1 -q -s 1000 10.0.2.2" | tail -n 2 | head -n 1 | cut -d , -f 1-3; ping -c 1 nosuchhost.invalid > p.out 2>&1; echo $?; cut -d : -f 1-2 p.out'; ExpectedOutput: '1 packets transmitted, 1 received, 0% packet loss'#10'2'#10'ping: nosuchhost.invalid'#10; ExpectedStatus: 0),
    { IPv6: localhost is ::1 first (it can always be reached), -4 asks
      for IPv4; ping, route, ndp and netstat over QEMU's IPv6 network. }
    (Command: 'ping -c 1 localhost | head -n 1; ping -4 -c 1 localhost | head -n 1'; ExpectedOutput: 'PING localhost (::1) 56(104) bytes of data.'#10'PING localhost (127.0.0.1) 56(84) bytes of data.'#10; ExpectedStatus: 0),
    (Command: 'ping -c 2 -i 0.2 ::1 | sed -e "s/time=.*/time/" -e "s/time [0-9]*ms/time/" -e "s/= .*/= X/"'; ExpectedOutput: 'PING ::1 (::1) 56(104) bytes of data.'#10'64 bytes from ::1: icmp_seq=1 ttl=64 time'#10'64 bytes from ::1: icmp_seq=2 ttl=64 time'#10#10'--- ::1 ping statistics ---'#10'2 packets transmitted, 2 received, 0% packet loss, time'#10'rtt min/avg/max/mdev = X'#10; ExpectedStatus: 0),
    (Command: 'su user -c "ping -6 -c 1 -q fec0::2" | tail -n 2 | head -n 1 | cut -d , -f 1-3; ndp fec0::2 | tail -n 1 | tr -s " " | cut -d " " -f 1,3'; ExpectedOutput: '1 packets transmitted, 1 received, 0% packet loss'#10'fec0::2 eth0'#10; ExpectedStatus: 0),
    (Command: 'route -6 | grep "^::/0 .* eth0$" | tr -s " "; netstat -rn6 | grep "^fec0::/64 .* eth0$" | tr -s " "'; ExpectedOutput: '::/0 fe80::2 UGA 2 eth0'#10'fec0::/64 :: UA 2 eth0'#10; ExpectedStatus: 0),
    (Command: 'ifconfig eth1 inet6 add fd00:9::1/64 && ifconfig eth1 | grep -c "inet6 fd00:9::1 "; ifconfig eth1 inet6 del fd00:9::1 && ifconfig eth1 | grep -c "inet6 fd00:9::1 "; su user -c "ifconfig eth1 inet6 off" 2>&1; echo $?'; ExpectedOutput: '1'#10'0'#10'ifconfig: eth1: Operation not permitted'#10'1'#10; ExpectedStatus: 0),
    { The network service (left running by networktest): eth0's state. }
    (Command: 'grep -E "^(Method|State|Address|Gateway|DhcpServer) " /var/lib/network/eth0.state'; ExpectedOutput: 'Method = "dhcp"'#10'State = "configured"'#10'Address = "10.0.2.15/24"'#10'Gateway = "10.0.2.2"'#10'DhcpServer = "10.0.2.2"'#10; ExpectedStatus: 0),
    { The resolver against a DNS server of dnstest's own (nothing here
      needs the internet). }
    (Command: 'dnstest > dns.log; echo $?; grep FAIL dns.log; tail -n 1 dns.log | cut -d " " -f 5-'; ExpectedOutput: '0'#10'checks passed'#10; ExpectedStatus: 0),
    (Command: 'dnstest --serve & p=$!; dnstest --wait; host www.test.example 127.0.0.1; host alias.test.example 127.0.0.1 | tail -n 4; host -t SOA test.example 127.0.0.1 | tail -n 1; host -t TXT www.test.example 127.0.0.1 | tail -n 1; host 192.0.2.10 127.0.0.1 | tail -n 1; host nosuch.test.example 127.0.0.1 > h.out; echo $?; tail -n 1 h.out; kill $p; wait $p'; ExpectedOutput: 'Using domain server:'#10'Name: 127.0.0.1'#10'Address: 127.0.0.1#53'#10'Aliases: '#10#10'www.test.example has address 192.0.2.10'#10'www.test.example has IPv6 address 2001:db8::10'#10'www.test.example mail is handled by 10 mail.test.example.'#10'alias.test.example is an alias for www.test.example.'#10'www.test.example has address 192.0.2.10'#10'www.test.example has IPv6 address 2001:db8::10'#10'www.test.example mail is handled by 10 mail.test.example.'#10'test.example has SOA record ns.test.example. hostmaster.test.example. 2026111601 3600 600 86400 300'#10'www.test.example descriptive text "hello world"'#10'10.2.0.192.in-addr.arpa domain name pointer www.test.example.'#10'1'#10'Host nosuch.test.example not found: 3(NXDOMAIN)'#10; ExpectedStatus: 0),
    (Command: 'dnstest --serve & p=$!; dnstest --wait; nslookup www.test.example 127.0.0.1; nslookup -type=MX www.test.example 127.0.0.1 | tail -n 2; nslookup 192.0.2.10 127.0.0.1 | tail -n 2; nslookup nosuch.test.example 127.0.0.1 > n.out; echo $?; grep "can.t find" n.out; kill $p; wait $p'; ExpectedOutput: 'Server:'#9#9'127.0.0.1'#10'Address:'#9'127.0.0.1#53'#10#10'Name:'#9'www.test.example'#10'Address: 192.0.2.10'#10'Name:'#9'www.test.example'#10'Address: 2001:db8::10'#10#10'www.test.example'#9'mail exchanger = 10 mail.test.example.'#10#10'10.2.0.192.in-addr.arpa'#9'name = www.test.example.'#10#10'1'#10'** server can''t find nosuch.test.example: NXDOMAIN'#10; ExpectedStatus: 0),
    (Command: 'hostname; uname -n; su user -c "hostname other" 2>&1; echo $?; hostname "bad name" 2>&1; hostname test-box.example && hostname && hostname -s && uname -n; hostname freepascalos; hostname -I | cut -d " " -f 1-2'; ExpectedOutput: 'freepascalos'#10'freepascalos'#10'hostname: you must be root to change the host name'#10'1'#10'hostname: the specified hostname is invalid'#10'test-box.example'#10'test-box'#10'test-box.example'#10'10.0.2.15 fec0::5054:ff:fe12:3456'#10; ExpectedStatus: 0),
    (Command: 'dnstest --serve & p=$!; dnstest --wait; host -t AAAA www.test.example ::1 | head -n 3; host -t AAAA www.test.example ::1 | tail -n 1; kill $p; wait $p'; ExpectedOutput: 'Using domain server:'#10'Name: ::1'#10'Address: ::1#53'#10'www.test.example has IPv6 address 2001:db8::10'#10; ExpectedStatus: 0),
    { netstat and nc: a listener seen by netstat (with its program),
      files both ways checked by their sums, a UDP round trip, port
      scans, a connection established, the routes, the interfaces and
      the counters. }
    (Command: 'nc -l 7101 < /dev/null > /dev/null & for i in $(seq 50); do netstat -tln | grep -q ":7101 " && break; sleep 0.1; done; netstat -tln | grep ":7101 " | tr -s " "; netstat -tlnp | grep ":7101 " | tr -s " " | cut -d " " -f 7 | cut -d / -f 2; nc -z 127.0.0.1 7101; echo $?; wait'; ExpectedOutput: 'tcp 0 0 0.0.0.0:7101 0.0.0.0:* LISTEN'#10'nc'#10'0'#10; ExpectedStatus: 0),
    (Command: 'seq 1 5000 > na; seq 5001 9000 > nb; nc -l 7102 < nb > na.got & for i in $(seq 50); do netstat -tln | grep -q ":7102 " && break; sleep 0.1; done; nc -N 127.0.0.1 7102 < na > nb.got; echo $?; wait; test "$(sha256sum < na)" = "$(sha256sum < na.got)" && echo sent; test "$(sha256sum < nb)" = "$(sha256sum < nb.got)" && echo received; rm na nb na.got nb.got'; ExpectedOutput: '0'#10'sent'#10'received'#10; ExpectedStatus: 0),
    (Command: 'echo request > ur; echo reply > up; nc -u -l -w 2 7103 < up > ur.got & for i in $(seq 50); do netstat -uln | grep -q ":7103 " && break; sleep 0.1; done; netstat -uln | grep ":7103 " | tr -s " "; nc -u -w 2 127.0.0.1 7103 < ur; wait; cat ur.got; rm ur up ur.got'; ExpectedOutput: 'udp 0 0 0.0.0.0:7103 0.0.0.0:*'#10'reply'#10'request'#10; ExpectedStatus: 0),
    (Command: 'nc -l 7104 < /dev/null > /dev/null & for i in $(seq 50); do netstat -tln | grep -q ":7104 " && break; sleep 0.1; done; nc -zv 127.0.0.1 7104 2>&1; echo $?; wait; nc -zv 127.0.0.1 7105 2>&1; echo $?; nc -z 127.0.0.1 7105-7107; echo $?'; ExpectedOutput: 'Connection to 127.0.0.1 7104 port [tcp/*] succeeded!'#10'0'#10'nc: connect to 127.0.0.1 port 7105 (tcp) failed: Connection refused'#10'1'#10'1'#10; ExpectedStatus: 0),
    (Command: 'nc -l 7106 < /dev/null > /dev/null & for i in $(seq 50); do netstat -tln | grep -q ":7106 " && break; sleep 0.1; done; sleep 2 | nc -N 127.0.0.1 7106 > /dev/null & for i in $(seq 50); do test $(netstat -tn | grep -c ":7106 .*ESTABLISHED") -ge 2 && break; sleep 0.1; done; netstat -tn | grep ":7106 " | tr -s " " | cut -d " " -f 6; netstat -tn | head -n 1; wait'; ExpectedOutput: 'ESTABLISHED'#10'ESTABLISHED'#10'Active Internet connections (w/o servers)'#10; ExpectedStatus: 0),
    (Command: 'netstat -rn | head -n 3; netstat -i | tail -n +3 | grep -E "^(lo|eth0) " | tr -s " " | cut -d " " -f 1,2,11'; ExpectedOutput: 'Kernel IP routing table'#10'Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface'#10'0.0.0.0         10.0.2.2        0.0.0.0         UG        0 0          0 eth0'#10'lo 1500 LRU'#10'eth0 1500 BRU'#10; ExpectedStatus: 0),
    (Command: 'b=$(netstat -s | grep "ICMP messages received" | tr -s " " | cut -d " " -f 2); ping -c 2 -i 0.2 127.0.0.1 > /dev/null; a=$(netstat -s | grep "ICMP messages received" | tr -s " " | cut -d " " -f 2); test $a -ge $((b + 4)) && echo counted; netstat -s | grep -c "echo replies:"; netstat -st | head -n 1; netstat -su | grep -c "packets sent"'; ExpectedOutput: 'counted'#10'2'#10'Tcp:'#10'1'#10; ExpectedStatus: 0),
    { nc and wget over IPv6: a listener on :: seen by netstat as tcp6, a
      stream to ::1, and wget fetching http://[::1]:7110/ from nc acting
      as a server; ICMPv6 counted by netstat -s. }
    (Command: 'nc -6 -l 7108 < /dev/null > n6.got & for i in $(seq 50); do netstat -tln | grep -q ":7108 " && break; sleep 0.1; done; netstat -tln | grep ":7108 " | tr -s " "; echo over6 | nc -N ::1 7108; wait; cat n6.got; rm n6.got'; ExpectedOutput: 'tcp6 0 0 :::7108 :::* LISTEN'#10'over6'#10; ExpectedStatus: 0),
    (Command: 'printf "HTTP/1.0 200 OK\r\nContent-Length: 6\r\n\r\nhello\n" | nc -6 -l 7110 > /dev/null & for i in $(seq 50); do netstat -tln | grep -q ":7110 " && break; sleep 0.1; done; wget -q -O - "http://[::1]:7110/"; echo $?; wait'; ExpectedOutput: 'hello'#10'0'#10; ExpectedStatus: 0),
    (Command: 'b=$(netstat -s6 | grep "ICMPv6 messages received" | tr -s " " | cut -d " " -f 2); ping -c 2 -i 0.2 ::1 > /dev/null; a=$(netstat -s6 | grep "ICMPv6 messages received" | tr -s " " | cut -d " " -f 2); test $a -ge $((b + 4)) && echo counted; netstat -s6 | grep -c -E "^Ip6?:"'; ExpectedOutput: 'counted'#10'1'#10; ExpectedStatus: 0),
    { Watching files and folders: changes another process makes, on
      several file system types, and a folder the user may not read. }
    (Command: 'watchtest > watch.log; echo $?; grep -E ''FAIL|expected:|got:'' watch.log; tail -n 1 watch.log | cut -d " " -f 5-'; ExpectedOutput: '0'#10'checks passed'#10; ExpectedStatus: 0),
    (Command: 'mkdir -m 700 unreadable; su user -c "watch -t 100 unreadable" 2>&1; echo $?; su user -c "watch -t 100 ."; echo $?; rmdir unreadable'; ExpectedOutput: 'watch: unreadable: Permission denied'#10'1'#10'2'#10; ExpectedStatus: 0),
    (Command: 'ptytest > pty.log; echo $?; grep -E ''FAIL|received'' pty.log; tail -n 1 pty.log | cut -d " " -f 5-'; ExpectedOutput: '0'#10'checks passed'#10; ExpectedStatus: 0),
    { Notifications: end requests taken or not, groups, sessions, a
      handler thread, permissions, Ctrl-C and a new size on a terminal. }
    (Command: 'notifytest > notify.log; echo $?; grep -E ''FAIL|received'' notify.log; tail -n 1 notify.log | cut -d " " -f 3-'; ExpectedOutput: '0'#10'checks, 0 failed'#10; ExpectedStatus: 0),
    { Settings (libconfiguration): file locks, the files, several
      writers at once (settingstest); the settings tool in both scopes,
      the user's over the system's, fixed values, who may write what and
      the modes of what is made, damaged files. }
    (Command: 'settingstest > st.log; echo $?; grep FAIL st.log; tail -n 1 st.log | cut -d " " -f 5-; rm -r /tmp/settingstest'; ExpectedOutput: '0'#10'checks passed'#10; ExpectedStatus: 0),
    (Command: 'settings set Test/Name "two words"; settings set Test/Count 7; settings set -t list Test/List a "b c"; settings get Test/Name; settings get Test/Count; settings get Test/List; settings list Test'; ExpectedOutput: 'two words'#10'7'#10'a'#10'b c'#10'Name = "two words"'#10'Count = 7'#10'List = ["a", "b c"]'#10; ExpectedStatus: 0),
    (Command: 'settings set -s Test/Count 3; settings set -s -f Test/Fixed true; settings set Test/Fixed false; settings get Test/Count; settings get Test/Fixed; settings get -s Test/Count; settings list -s Test; stat -c %a /etc/settings /etc/settings/Test.settings /.settings /.settings/Test.settings'; ExpectedOutput: '7'#10'true'#10'3'#10'Count = 3'#10'fixed Fixed = true'#10'755'#10'644'#10'700'#10'600'#10; ExpectedStatus: 0),
    (Command: 'su user -c "settings set -s Test/Count 1" 2>&1; echo $?; su user -c "settings get Test/Count; settings set Test/Count 9; settings get Test/Count; stat -c %a /home/user/.settings /home/user/.settings/Test.settings; settings delete Test"; su user -c "cat /.settings/Test.settings" > /dev/null 2>&1; echo $?'; ExpectedOutput: 'settings: /etc/settings: Permission denied'#10'1'#10'3'#10'9'#10'700'#10'600'#10'1'#10; ExpectedStatus: 0),
    (Command: 'settings delete Test/Count; settings get Test/Count; settings delete -s Test; settings get Test/Count 2>&1; echo $?; ls /etc/settings; settings get Bad 2>&1; echo $?'; ExpectedOutput: '3'#10'settings: Test/Count is not set'#10'1'#10'Network.settings'#10'settings: Bad: not the path of a setting (GROUP/KEY)'#10'2'#10; ExpectedStatus: 0),
    (Command: 'printf ''Good = 1\nbroken line\n'' > /.settings/Damaged.settings; settings get Damaged/Good; settings check Damaged; echo $?; settings set Damaged/More 2; cat /.settings/Damaged.settings; settings delete Damaged; settings delete Test; ls /.settings | wc -l'; ExpectedOutput: '1'#10'line 2: broken line'#10'1'#10'Good = 1'#10'More = 2'#10'broken line'#10'0'#10; ExpectedStatus: 0),
    { The service manager and the service command (a second manager). }
    (Command: 'servicetest > svc.log; echo $?; grep -E ''FAIL|received'' svc.log; tail -n 1 svc.log | cut -d " " -f 3-'; ExpectedOutput: '0'#10'checks, 0 failed'#10; ExpectedStatus: 0),
    { login: a right and a wrong password (read from a pipe), root only,
      the user's groups (supplementary ones from /etc/group), home and
      environment. }
    (Command: 'printf ''user\nuser\n'' | login -e /bin/id 2>/dev/null; printf ''user\nwrong\n'' | login -e /bin/id 2>/dev/null; echo $?'; ExpectedOutput: 'fpos login: uid=1000(user) gid=1000(user) groups=1000(user)'#10'fpos login: Login incorrect'#10'fpos login: 1'#10; ExpectedStatus: 0),
    (Command: 'login -f root -e /bin/id; login -f user -e /bin/pwd; login -f user -e /bin/printenv; su user -c "login -f root -e /bin/id" 2>&1; echo $?'; ExpectedOutput: 'uid=0(root) gid=0(root) groups=0(root),10(wheel)'#10'/home/user'#10'HOME=/home/user'#10'SHELL=/bin/sh'#10'USER=user'#10'LOGNAME=user'#10'PATH=/bin'#10'TERM=console'#10'login: only root may log users in'#10'1'#10; ExpectedStatus: 0),

    { --- the Control Panel's subsystems ------------------------------- }
    { Time zones (Sys.TimeZones): offsets and abbreviations on both sides
      of daylight saving's changes, north and south, half and quarter
      hours; local times read back; an unknown TZ is UTC. }
    (Command: 'for t in 1774745999 1774746000 1792889999 1792890000; do TZ=Europe/Berlin date -d @$t "+%F %T %Z %z"; done'; ExpectedOutput: '2026-03-29 01:59:59 CET +0100'#10'2026-03-29 03:00:00 CEST +0200'#10'2026-10-25 02:59:59 CEST +0200'#10'2026-10-25 02:00:00 CET +0100'#10; ExpectedStatus: 0),
    (Command: 'for t in 1772953199 1772953200 1793512799 1793512800; do TZ=America/New_York date -d @$t "+%F %T %Z %z"; done'; ExpectedOutput: '2026-03-08 01:59:59 EST -0500'#10'2026-03-08 03:00:00 EDT -0400'#10'2026-11-01 01:59:59 EDT -0400'#10'2026-11-01 01:00:00 EST -0500'#10; ExpectedStatus: 0),
    (Command: 'for t in 1775318399 1775318400 1791043199 1791043200; do TZ=Australia/Sydney date -d @$t "+%F %T %Z %z"; done'; ExpectedOutput: '2026-04-05 02:59:59 AEDT +1100'#10'2026-04-05 02:00:00 AEST +1000'#10'2026-10-04 01:59:59 AEST +1000'#10'2026-10-04 03:00:00 AEDT +1100'#10; ExpectedStatus: 0),
    (Command: 'TZ=Pacific/Auckland date -d @1790431200 "+%F %T %Z %z"; TZ=Europe/London date -d @1782907200 "+%T %Z"; TZ=Asia/Kolkata date -d @1767225600 "+%T %z"; TZ=Asia/Kathmandu date -d @1767225600 "+%T %z"; TZ=America/St_Johns date -d @1782907200 "+%T %Z %z"'; ExpectedOutput: '2026-09-27 03:00:00 NZDT +1300'#10'13:00:00 BST'#10'05:30:00 +0530'#10'05:45:00 +0545'#10'09:30:00 NDT -0230'#10; ExpectedStatus: 0),
    (Command: 'TZ=America/New_York date -d "2026-07-04 12:00" +%s; date -u -d "2026-07-04 12:00" +%s; TZ=Nowhere/City date -d @0 "+%F %T %Z"; timezone -l | wc -l; timezone -l | grep -c "^Europe/"; timezone; timezone Mars/Base 2>&1; echo $?'; ExpectedOutput: '1783180800'#10'1783166400'#10'1970-01-01 00:00:00 UTC'#10'66'#10'23'#10'UTC +0000 UTC'#10'timezone: unknown time zone ''Mars/Base'' (timezone -l lists them)'#10'1'#10; ExpectedStatus: 0),
    { The system settings service, started here (there is no service
      manager under coretest): the system's zone (kept, used by date,
      touch and ls), refused to a user with a wrong password and done
      with root's; the clock; the sound outputs' volumes, mute and the
      default output, kept in the system's settings. }
    (Command: 'systemsettings > /tmp/systemsettings.log 2>&1 & until grep -q ready /tmp/systemsettings.log 2>/dev/null; do sleep 0.1; done; timezone Europe/Paris | cut -d " " -f 1; settings get -s Time/Zone; date -d @1782907200 "+%H:%M %Z"; touch -d "2026-07-01 14:00" tf; stat -c %y tf; ls -l tf | cut -d " " -f 6-8; rm tf'; ExpectedOutput: 'Europe/Paris'#10'Europe/Paris'#10'14:00 CEST'#10'2026-07-01 14:00:00 +0200'#10'Jul  1'#10; ExpectedStatus: 0),
    (Command: 'su user -c "echo wrong | timezone Asia/Tokyo" > /dev/null 2>&1 || echo refused; su user -c "echo root | timezone Asia/Tokyo" 2>/dev/null; timezone UTC; settings get -s Time/Zone'; ExpectedOutput: 'refused'#10'Asia/Tokyo +0900 JST'#10'UTC +0000 UTC'#10'UTC'#10; ExpectedStatus: 0),
    (Command: 'date -s @$(date +%s) > /dev/null; echo $?; su user -c "echo wrong | date -s @1800000000" > /dev/null 2>&1 || echo refused; grep -c "wrong password" /tmp/systemsettings.log'; ExpectedOutput: '0'#10'refused'#10'2'#10; ExpectedStatus: 0),
    (Command: 'mixer -r 70; mixer; settings get -s Sound/0/Volume; mixer -m on; mixer; mixer -m off; mixer -r 80; mixer -l | head -n 2; mixer -D 1; mixer -l | grep default; mixer -D 0'; ExpectedOutput: 'volume 70%'#10'70'#10'volume 70%, muted'#10'0 /dev/audio HD Audio: volume 80%, default'#10'1 /dev/audio1 AC''97: volume 80%'#10'1 /dev/audio1 AC''97: volume 80%, default'#10; ExpectedStatus: 0),
    { Accounts (Util.AccountChanges): useradd, usermod and userdel, the
      home's owner and mode, logging in as the new user, what is
      refused; the files keep their modes. }
    (Command: 'printf "pw1\npw1\n" | useradd -c "Test Person" tester 2>/dev/null; grep "^tester:" /etc/passwd /etc/group; stat -c "%U %G %a" /home/tester; printf "tester\npw1\n" | login -e /bin/id 2>/dev/null'; ExpectedOutput: '/etc/passwd:tester:x:1001:1001:Test Person:/home/tester:/bin/sh'#10'/etc/group:tester:x:1001:'#10'tester tester 755'#10'fpos login: uid=1001(tester) gid=1001(tester) groups=1001(tester)'#10; ExpectedStatus: 0),
    (Command: 'usermod -c "Tess Ter" -G wheel tester; grep "^tester:" /etc/passwd | cut -d: -f5; id tester; usermod -a -G user tester; groups tester; usermod -G "" tester; id tester'; ExpectedOutput: 'Tess Ter'#10'uid=1001(tester) gid=1001(tester) groups=1001(tester),10(wheel)'#10'tester : tester wheel user'#10'uid=1001(tester) gid=1001(tester) groups=1001(tester)'#10; ExpectedStatus: 0),
    (Command: 'su user -c "useradd x" 2>&1; userdel nosuch 2>&1; userdel root 2>&1; printf "a\nb\n" | useradd y 2>&1 | tail -c 23; useradd -c "a:b" z < /dev/null 2>&1; printf "a\na\n" | useradd tester 2>&1 | tail -c 29; useradd Bad < /dev/null 2>&1; echo $?'; ExpectedOutput: 'useradd: only root may add users'#10'userdel: user ''nosuch'' does not exist'#10'userdel: the account ''root'' cannot be removed'#10'Passwords do not match'#10'useradd: a full name may not hold a colon'#10'user ''tester'' already exists'#10'useradd: invalid user name ''Bad'''#10'1'#10; ExpectedStatus: 0),
    (Command: 'userdel -r tester; grep -c "^tester:" /etc/passwd /etc/group /etc/shadow; test -e /home/tester || echo gone; stat -c %a /etc/shadow /etc/passwd /etc/group'; ExpectedOutput: '/etc/passwd:0'#10'/etc/group:0'#10'/etc/shadow:0'#10'gone'#10'600'#10'644'#10'644'#10; ExpectedStatus: 0),
    { The keyboards' layout and repeat (the kernel's tables; with no
      display server only root changes them); then the service ends. }
    (Command: 'keyboardsettings; keyboardsettings -l; keyboardsettings -d 250 -s 30 de; su user -c "keyboardsettings fr" 2>&1; keyboardsettings xx 2>&1; keyboardsettings -d 500 -s 11 us; pkill -x systemsettings; echo $?'; ExpectedOutput: 'layout us, repeat delay 500, rate 11'#10'us English (US)'#10'uk English (UK)'#10'de German (QWERTZ)'#10'fr French (AZERTY)'#10'layout de, repeat delay 250, rate 30'#10'keyboardsettings: cannot change the keyboard settings: Operation not permitted'#10'keyboardsettings: there is no keyboard layout ''xx'' (keyboardsettings -l lists them)'#10'layout us, repeat delay 500, rate 11'#10'0'#10; ExpectedStatus: 0),

    { --- a crashing program ends alone: with an unhandled exception
      (coretest has SysUtils, through libcoreutils, so the fault becomes
      an exception: status 217), or with status 139 when the kernel must
      end it (no dispatcher) ------------------------------------------- }
    (Command: '/bin/coretest --crash-on-purpose 2>&1 | sed -n 2p; /bin/coretest --crash-on-purpose 2>/dev/null; echo $?; echo still running'; ExpectedOutput: 'EAccessViolation: Access violation'#10'217'#10'still running'#10; ExpectedStatus: 0),
    (Command: '/bin/coretest --overflow-stack 2>&1 | sed -n 2p; /bin/coretest --crash-without-dispatcher; echo $?'; ExpectedOutput: 'EStackOverflow: Stack overflow'#10'139'#10; ExpectedStatus: 0)
  );

var
  PassedCount: Integer;
  FailedCount: Integer;

procedure Check(Condition: Boolean; Name: PChar);
begin
  if Condition then
  begin
    Inc(PassedCount);
    WriteString(StandardOutput, Format('[coretest] pass: %s'#10, [Name]));
  end
  else
  begin
    Inc(FailedCount);
    WriteString(StandardOutput, Format('[coretest] FAIL: %s'#10, [Name]));
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
      #10: WriteString(StandardOutput, '\n');
      #9: WriteString(StandardOutput, '\t');
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
    WriteString(StandardOutput, Format('[coretest]   expected status %d, output "', [Test.ExpectedStatus]));
    WriteVisible(Test.ExpectedOutput);
    WriteStringLine(StandardOutput, '"');
    WriteString(StandardOutput, Format('[coretest]   got      status %d, output "', [Status]));
    WriteVisible(Output);
    WriteStringLine(StandardOutput, '"');
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

{ Recurses until the stack runs out; the sum keeps the calls from being
  turned into a loop. }
function RecurseWithoutEnd(Depth: LongInt): LongInt;
var
  Padding: array[0..255] of Byte;
begin
  Padding[Depth and 255] := Byte(Depth);
  Result := RecurseWithoutEnd(Depth + 1) + Padding[(Depth + 1) and 255];
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
  if TextIsEqual(Argument(1), '--overflow-stack') then
    Halt(RecurseWithoutEnd(1));
  if TextIsEqual(Argument(1), '--error-order') then
  begin
    { Through a pipe: error output goes at once, standard output when
      the program ends. }
    WriteLn(StdErr, 'error first');
    WriteLn('output second');
    Halt(0);
  end;
  if TextIsEqual(Argument(1), '--crash-without-dispatcher') then
  begin
    { Nobody to pass the exception to: the kernel ends the process. }
    SystemCall(CallSetExceptionDispatcher, 0, 0, 0, 0, 0, 0);
    CrashOnPurpose;
  end;
  PassedCount := 0;
  FailedCount := 0;
  WriteStringLine(StandardOutput, '[coretest] user mode tests starting');
  PrepareWorkDirectory;
  TestRunTimeLoading;
  TestHeap;
  for Index := 0 to High(CommandTests) do
    RunCommandTest(CommandTests[Index]);

  ChangeDirectory('/');
  RemoveTree(WorkDirectory);
  SyncFileSystems;
  WriteString(StandardOutput, Format('[coretest] %d passed, %d failed'#10, [PassedCount,
    FailedCount]));
  if FailedCount > 0 then
    Halt(1);
  Halt(0);
end.
