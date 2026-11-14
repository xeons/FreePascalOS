{
  coretest - tests for user mode, the shell and the core utilities

  Run by "make test" as the first user process (kernel option
  init=/bin/coretest). It works in /tmp/coretest and checks:

    * run time loading of libplugin.so (LoadLibrary / FindSymbol),
    * the program heap,
    * a list of shell command lines: each runs through "sh -c" with its
      standard output captured through a pipe, and both the output and
      the exit status must match,
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
  CommandTests: array[0..124] of TCommandTest = (
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
