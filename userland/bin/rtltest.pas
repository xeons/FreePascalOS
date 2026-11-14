{
  rtltest - checks the Free Pascal runtime library on FreePascalOS

  rtltest

  Exercises what the runtime library brings to programs: reference
  counted strings, dynamic arrays, exceptions, classes and interfaces,
  generics, SysUtils (formatting, conversions, files, directories,
  searching, environment, processes), Classes (string lists, streams,
  threads) and text files. Prints one line per check and "rtltest: N
  passed, M failed"; exits with 1 if anything failed.
}
program rtltest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  StrUtils,
  Math,
  DateUtils,
  Contnrs,
  SyncObjs,
  fgl,
  Abi.SystemCalls,
  Sys.Exceptions;

type
  TIntegerList = specialize TFPGList<Integer>;

  IGreeter = interface
    ['{6B0E0F6C-1D3A-4B7E-9A51-3F2C8E1D0A11}']
    function Greet(const Name: string): string;
  end;

  TGreeter = class(TInterfacedObject, IGreeter)
  public
    function Greet(const Name: string): string;
  end;

  ECustomError = class(Exception);

  TCountingThread = class(TThread)
  private
    FCount: Integer;
  protected
    procedure Execute; override;
  public
    property Count: Integer read FCount;
  end;

var
  Passed: Integer = 0;
  Failed: Integer = 0;
  SharedTotal: Integer = 0;
  SharedLock: TCriticalSection;
  WorkDirectory: string;

procedure Check(Condition: Boolean; const Description: string);
begin
  if Condition then
  begin
    Inc(Passed);
    WriteLn('pass: ', Description);
  end
  else
  begin
    Inc(Failed);
    WriteLn('FAIL: ', Description);
  end;
end;

function TGreeter.Greet(const Name: string): string;
begin
  Result := 'hello, ' + Name;
end;

procedure TCountingThread.Execute;
var
  Index: Integer;
begin
  for Index := 1 to 1000 do
  begin
    Inc(FCount);
    SharedLock.Enter;
    try
      Inc(SharedTotal);
    finally
      SharedLock.Leave;
    end;
  end;
end;

procedure TestStrings;
var
  Text, Copy: string;
  Wide: UnicodeString;
  Parts: TStringArray;
begin
  Text := 'Free';
  Copy := Text;
  Text := Text + ' Pascal';
  Check((Text = 'Free Pascal') and (Copy = 'Free'), 'strings are copied on write');
  Check(UpperCase(Text) = 'FREE PASCAL', 'UpperCase');
  Check(Pos('Pascal', Text) = 6, 'Pos');
  Check(StringReplace(Text, 'Free', 'Object', []) = 'Object Pascal', 'StringReplace');
  Parts := 'a,b,,c'.Split([',']);
  Check((Length(Parts) = 4) and (Parts[3] = 'c'), 'string helpers: Split');
  Check(ReverseString('abc') = 'cba', 'StrUtils.ReverseString');
  Wide := UTF8Decode('Grüße');
  Check((Length(Wide) = 5) and (UTF8Encode(Wide) = 'Grüße'), 'UTF-8 to UTF-16 and back');
end;

procedure TestNumbersAndFormatting;
var
  Value: Integer;
begin
  Check(IntToStr(-42) = '-42', 'IntToStr');
  Check(StrToInt('1234') = 1234, 'StrToInt');
  Check(not TryStrToInt('12x', Value), 'TryStrToInt refuses junk');
  Check(Format('%d-%s-%.2f-%x', [7, 'x', 3.14159, 255]) = '7-x-3.14-FF', 'Format');
  Check(FloatToStr(2.5) = '2.5', 'FloatToStr');
  Check(Max(3, 9) = 9, 'Math.Max');
  Check(SameValue(Power(2, 10), 1024), 'Math.Power');
  Check(IntToHex(48879, 4) = 'BEEF', 'IntToHex');
end;

function CompareIntegers(const Left, Right: Integer): Integer;
begin
  Result := Left - Right;
end;

procedure TestDynamicArrays;
var
  Numbers, Alias: array of Integer;
  Index: Integer;
  List: TIntegerList;
begin
  SetLength(Numbers, 10);
  for Index := 0 to High(Numbers) do
    Numbers[Index] := Index * Index;
  Alias := Numbers;
  SetLength(Numbers, 20);
  Check((Length(Numbers) = 20) and (Numbers[9] = 81) and (Length(Alias) = 10), 'dynamic arrays grow and share');
  List := TIntegerList.Create;
  try
    List.Add(3);
    List.Add(1);
    List.Add(2);
    List.Sort(@CompareIntegers);
    Check((List[0] = 1) and (List[2] = 3), 'generic list (fgl)');
  finally
    List.Free;
  end;
end;

procedure RaiseCustom;
begin
  raise ECustomError.CreateFmt('code %d', [17]);
end;

procedure TestExceptions;
var
  Caught: string;
  FinallyRan: Boolean;
begin
  Caught := '';
  try
    StrToInt('nope');
  except
    on E: EConvertError do
      Caught := E.ClassName;
  end;
  Check(Caught = 'EConvertError', 'EConvertError from StrToInt');

  FinallyRan := False;
  Caught := '';
  try
    try
      RaiseCustom;
    finally
      FinallyRan := True;
    end;
  except
    on E: ECustomError do
      Caught := E.Message;
  end;
  Check(FinallyRan and (Caught = 'code 17'), 'raise, finally and except');

  Caught := '';
  try
    try
      raise Exception.Create('inner');
    except
      raise EAbort.Create('outer');
    end;
  except
    on E: EAbort do
      Caught := E.Message;
  end;
  Check(Caught = 'outer', 'raising inside except');
end;

procedure TestClasses;
var
  Greeter: IGreeter;
  Objects: TObjectList;
  Strings: TStringList;
begin
  Greeter := TGreeter.Create;
  Check(Greeter.Greet('world') = 'hello, world', 'interfaces with reference counting');
  Check(Supports(Greeter, IGreeter), 'Supports');

  Objects := TObjectList.Create(True);
  try
    Objects.Add(TStringList.Create);
    Objects.Add(TStringList.Create);
    Check(Objects.Count = 2, 'Contnrs.TObjectList');
  finally
    Objects.Free;
  end;

  Strings := TStringList.Create;
  try
    Strings.CommaText := 'pear,apple,fig';
    Strings.Sort;
    Check(Strings.CommaText = 'apple,fig,pear', 'TStringList.Sort');
    Strings.Values['key'] := 'value';
    Check(Strings.Values['key'] = 'value', 'TStringList name=value pairs');
  finally
    Strings.Free;
  end;
end;

procedure TestFiles;
var
  Path, Line: string;
  TextFile: Text;
  Stream: TFileStream;
  Strings: TStringList;
  Search: TSearchRec;
  Found: Integer;
  Buffer: array[0..4] of Char;
begin
  Path := WorkDirectory + '/notes.txt';
  AssignFile(TextFile, Path);
  Rewrite(TextFile);
  WriteLn(TextFile, 'first line');
  WriteLn(TextFile, 42, ' ', 1.5:0:1);
  CloseFile(TextFile);
  Check(FileExists(Path), 'Rewrite creates a file');

  Reset(TextFile);
  ReadLn(TextFile, Line);
  Check(Line = 'first line', 'ReadLn from a text file');
  ReadLn(TextFile, Line);
  Check(Line = '42 1.5', 'formatted WriteLn');
  CloseFile(TextFile);

  Strings := TStringList.Create;
  try
    Strings.LoadFromFile(Path);
    Check((Strings.Count = 2) and (Strings[1] = '42 1.5'), 'TStringList.LoadFromFile');
  finally
    Strings.Free;
  end;

  Stream := TFileStream.Create(WorkDirectory + '/data.bin', fmCreate);
  try
    Stream.WriteBuffer('hello', 5);
  finally
    Stream.Free;
  end;
  Stream := TFileStream.Create(WorkDirectory + '/data.bin', fmOpenRead);
  try
    Stream.ReadBuffer(Buffer, 5);
    Check((Stream.Size = 5) and (Buffer = 'hello'), 'TFileStream write and read');
  finally
    Stream.Free;
  end;

  Check(CreateDir(WorkDirectory + '/sub') and DirectoryExists(WorkDirectory + '/sub'), 'CreateDir, DirectoryExists');
  Found := 0;
  if FindFirst(WorkDirectory + '/*.txt', faAnyFile, Search) = 0 then
  begin
    repeat
      Inc(Found);
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
  Check(Found = 1, 'FindFirst with a wildcard');
  Check(RenameFile(Path, WorkDirectory + '/renamed.txt') and FileExists(WorkDirectory + '/renamed.txt'),
    'RenameFile');
  Check(DeleteFile(WorkDirectory + '/renamed.txt') and not FileExists(WorkDirectory + '/renamed.txt'),
    'DeleteFile');
  Check(not DeleteFile(WorkDirectory + '/sub'), 'DeleteFile refuses a directory');
  Check(RemoveDir(WorkDirectory + '/sub'), 'RemoveDir');
  Check(ExtractFileName('/a/b/c.txt') = 'c.txt', 'ExtractFileName');
  Check(ChangeFileExt('x.pas', '.o') = 'x.o', 'ChangeFileExt');
end;

procedure TestThreads;
var
  Threads: array[0..3] of TCountingThread;
  Index: Integer;
  AllCounted: Boolean;
begin
  SharedLock := TCriticalSection.Create;
  try
    for Index := 0 to High(Threads) do
      Threads[Index] := TCountingThread.Create(False);
    AllCounted := True;
    for Index := 0 to High(Threads) do
    begin
      Threads[Index].WaitFor;
      AllCounted := AllCounted and (Threads[Index].Count = 1000);
      Threads[Index].Free;
    end;
    Check(AllCounted, 'TThread: four threads run to the end');
    Check(SharedTotal = 4000, 'TCriticalSection keeps a shared count right');
  finally
    SharedLock.Free;
  end;
end;

var
  SpinCount: LongInt = 0;

{ Counts as fast as it can, without system calls, until it is killed. }
function SpinForever(Parameter: Pointer): PtrInt;
begin
  while True do
    InterlockedIncrement(SpinCount);
  Result := 0;
end;

procedure TestThreadControl;
var
  Handle, Id: TThreadID;
  BeforeWait, AfterWait: LongInt;
begin
  Handle := BeginThread(@SpinForever, nil, Id);
  Check(Handle <> 0, 'BeginThread');
  Sleep(30);
  Check(SpinCount > 0, 'the spinning thread runs');
  Check(ThreadSetPriority(Handle, -5) and (ThreadGetPriority(Handle) = -5), 'ThreadSetPriority, ThreadGetPriority');
  Check(SuspendThread(Handle) = 0, 'SuspendThread returns the previous count');
  { It stops at its next safe point (the next clock interrupt at the latest). }
  Sleep(50);
  BeforeWait := SpinCount;
  Sleep(100);
  AfterWait := SpinCount;
  Check(BeforeWait = AfterWait, 'a suspended thread does not run');
  Check(ResumeThread(Handle) = 1, 'ResumeThread returns the previous count');
  Sleep(50);
  Check(SpinCount > AfterWait, 'a resumed thread runs again');
  Check(KillThread(Handle) = 0, 'KillThread');
  Check(WaitForThreadTerminate(Handle, 0) = 0, 'a killed thread ends');
  CloseThread(Handle);
end;

procedure TestFileControl;
var
  Path: string;
  Handle: THandle;
  Age: LongInt;
begin
  Path := WorkDirectory + '/dated.txt';
  Handle := FileCreate(Path);
  Check(Handle <> feInvalidHandle, 'FileCreate');
  Age := DateTimeToFileDate(EncodeDate(2001, 2, 3) + EncodeTime(4, 5, 6, 0));
  Check(FileSetDate(Handle, Age) = 0, 'FileSetDate through a handle');
  Check(FileGetDate(Handle) = Age, 'FileGetDate gives the date back');
  FileClose(Handle);
  Check(FileSetAttr(Path, faReadOnly) = 0, 'FileSetAttr read-only');
  Check((FileGetAttr(Path) and faReadOnly) <> 0, 'FileGetAttr shows read-only');
  Check((FileSetAttr(Path, 0) = 0) and ((FileGetAttr(Path) and faReadOnly) = 0), 'FileSetAttr clears read-only');
  DeleteFile(Path);
  Check((DiskSize(0) > 0) and (DiskFree(0) >= 0) and (DiskSize(0) >= DiskFree(0)), 'DiskSize, DiskFree');
end;

{ --- Processor exceptions ------------------------------------------------- }

type
  TFaultingThread = class(TThread)
  private
    FCaught: string;
    FCatch: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(Catch: Boolean);
    property Caught: string read FCaught;
  end;

{ Values the compiler cannot see through, so the faults happen at run time. }
function Zero: Integer;
begin
  Result := StrToInt('0');
end;

function NilPointer: PInteger;
begin
  Result := PInteger(PtrUInt(Zero));
end;

procedure TouchNil;
begin
  NilPointer^ := 1;
end;

constructor TFaultingThread.Create(Catch: Boolean);
begin
  FCatch := Catch;
  inherited Create(False);
end;

procedure TFaultingThread.Execute;
begin
  if not FCatch then
    TouchNil;
  try
    TouchNil;
  except
    on E: EAccessViolation do
      FCaught := E.ClassName;
  end;
end;

{ The class of the exception Action raises, or ''. }
function ExceptionClassOf(Action: TProcedure): string;
begin
  Result := '';
  try
    Action();
  except
    on E: Exception do
      Result := E.ClassName;
  end;
end;

procedure DivideIntegerByZero;
var
  Quotient: Integer;
begin
  Quotient := 10 div Zero;
  if Quotient = 0 then
    Exit;
end;

procedure DivideFloatByZero;
var
  Quotient: Double;
begin
  Quotient := 1.0 / Zero;
  if Quotient = 0 then
    Exit;
end;

{ Extended arithmetic is done by the x87 unit. }
procedure DivideExtendedByZero;
var
  Quotient: Extended;
begin
  Quotient := 1;
  Quotient := Quotient / Zero;
  { x87 exceptions are reported at the next waiting instruction. }
  asm
    fwait
  end;
  if Quotient = 0 then
    Exit;
end;

const
  FloatZeroDivideFlag = $04;

procedure ExecuteInvalidInstruction; assembler;
asm
  ud2
end;

{ --- Stack overflows and continuing ---------------------------------------- }

function RecurseWithoutEnd(Depth: LongInt): LongInt;
var
  Padding: array[0..255] of Byte;
begin
  Padding[Depth and 255] := Byte(Depth);
  Result := RecurseWithoutEnd(Depth + 1) + Padding[(Depth + 1) and 255];
end;

procedure OverflowStack;
begin
  RecurseWithoutEnd(1);
end;

type
  TOverflowingThread = class(TThread)
  private
    FCaught: string;
  protected
    procedure Execute; override;
  public
    property Caught: string read FCaught;
  end;

procedure TOverflowingThread.Execute;
begin
  FCaught := ExceptionClassOf(@OverflowStack);
end;

{ Clears EAX, then runs an invalid instruction (at offset 2). }
function ClearThenFault: QWord; assembler; nostackframe;
asm
  xorl %eax, %eax
  ud2
  ret
end;

const
  { Where the invalid instruction is in ClearThenFault, and its length. }
  InvalidInstructionOffset = 2;
  InvalidInstructionLength = 2;
  RepairedValue = 42;

{ Deals with the invalid instruction in ClearThenFault only: skips it and
  puts a value in RAX. }
function RepairClearThenFault(var ExceptionRecord: TAbiExceptionRecord): Boolean;
begin
  Result := (ExceptionRecord.Code = ExceptionIllegalInstruction) and
    (ExceptionRecord.Address = PtrUInt(@ClearThenFault) + InvalidInstructionOffset);
  if not Result then
    Exit;
  ExceptionRecord.Context.Rip := ExceptionRecord.Context.Rip + InvalidInstructionLength;
  ExceptionRecord.Context.Rax := RepairedValue;
end;

procedure TestStackOverflowAndContinuing;
var
  Overflowing: TOverflowingThread;
begin
  Check(ExceptionClassOf(@OverflowStack) = 'EStackOverflow', 'a stack overflow raises EStackOverflow');
  { The reserve is armed again at the next system call. }
  Sleep(1);
  Check(ExceptionClassOf(@OverflowStack) = 'EStackOverflow', 'a second stack overflow is caught too');
  Overflowing := TOverflowingThread.Create(False);
  Overflowing.WaitFor;
  Check(Overflowing.Caught = 'EStackOverflow', 'a stack overflow in a thread');
  Overflowing.Free;

  SetExceptionFilter(@RepairClearThenFault);
  Check(ClearThenFault = RepairedValue, 'an exception filter continues at a changed context');
  Check(ExceptionClassOf(@TouchNil) = 'EAccessViolation', 'exceptions a filter declines still raise');
  SetExceptionFilter(nil);
  Check(ExceptionClassOf(@ExecuteInvalidInstruction) = 'EAccessViolation', 'without the filter, exceptions raise');
end;

procedure TestProcessorExceptions;
var
  Index: Integer;
  AllCaught: Boolean;
  Faulting: TFaultingThread;
  Raised: string;
begin
  Check(ExceptionClassOf(@TouchNil) = 'EAccessViolation', 'a nil dereference raises EAccessViolation');
  Check(ExceptionClassOf(@DivideIntegerByZero) = 'EDivByZero', 'integer division by zero raises EDivByZero');
  Raised := ExceptionClassOf(@DivideFloatByZero);
  if (Raised = '') and ((GetMXCSR and FloatZeroDivideFlag) <> 0) then
  begin
    { The processor set the flag instead of trapping (QEMU's emulator
      does that); nothing the kernel could pass on. }
    SetMXCSR(GetMXCSR and not FloatZeroDivideFlag);
    Check(True, 'SSE division by zero: the processor does not trap, not checked');
  end
  else
    Check(Raised = 'EZeroDivide', 'SSE division by zero raises EZeroDivide (got ' + Raised + ')');
  Raised := ExceptionClassOf(@DivideExtendedByZero);
  Check(Raised = 'EZeroDivide', 'x87 division by zero raises EZeroDivide (got ' + Raised + ')');
  Check(Abs(1.0 / (Zero + 4) - 0.25) < 1e-12, 'floating point works after an exception');
  Check(ExceptionClassOf(@ExecuteInvalidInstruction) = 'EAccessViolation', 'an invalid instruction raises EAccessViolation');
  AllCaught := True;
  for Index := 1 to 5 do
    AllCaught := AllCaught and (ExceptionClassOf(@TouchNil) = 'EAccessViolation');
  Check(AllCaught, 'exceptions one after another, without system calls between');

  Faulting := TFaultingThread.Create(True);
  Faulting.WaitFor;
  Check(Faulting.Caught = 'EAccessViolation', 'an exception caught inside a thread');
  Faulting.Free;
  Faulting := TFaultingThread.Create(False);
  Faulting.WaitFor;
  Check(Faulting.FatalException is EAccessViolation, 'an uncaught exception ends a TThread (FatalException)');
  Faulting.Free;
end;

procedure TestSystem;
var
  Now1: TDateTime;
begin
  Check(GetEnvironmentVariable('HOME') <> '', 'GetEnvironmentVariable');
  Check(ParamStr(0) <> '', 'ParamStr(0)');
  Check(ExecuteProcess('/bin/true', '') = 0, 'ExecuteProcess of true');
  Check(ExecuteProcess('/bin/sh', '-c "exit 3"') = 3, 'ExecuteProcess passes the exit code');
  Now1 := Now;
  Check(YearOf(Now1) >= 2024, 'Now and DateUtils.YearOf');
  Check(GetTickCount64 > 0, 'GetTickCount64');
  Check(SysErrorMessage(2) = 'No such file or directory', 'SysErrorMessage');
end;

begin
  WorkDirectory := GetTempDir(False);
  if WorkDirectory = '' then
    WorkDirectory := '/tmp';
  WorkDirectory := ExcludeTrailingPathDelimiter(WorkDirectory) + '/rtltest' + IntToStr(GetProcessID);
  ForceDirectories(WorkDirectory);
  TestStrings;
  TestNumbersAndFormatting;
  TestDynamicArrays;
  TestExceptions;
  TestClasses;
  TestFiles;
  TestThreads;
  TestThreadControl;
  TestFileControl;
  TestProcessorExceptions;
  TestStackOverflowAndContinuing;
  TestSystem;
  RemoveDir(WorkDirectory);
  WriteLn('rtltest: ', Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then
    Halt(1);
end.
