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
  Stacks of the page thread, taken from another thread: SIGUSR1
  interrupts the page thread, whose handler walks its frame pointers
  (Linux x86-64; within the main thread's stack) and keeps the return
  addresses. The watchdog takes one when the page thread is stuck; the
  profiler (webbrowse --profile) takes one every millisecond and prints
  the functions most often running (self) and on the stack (total),
  symbolized from the line information (build with -gl).
}
unit WebBrowse.Sampler;

{$mode objfpc}
{$H+}

interface

const
  MaximumSampleDepth = 48;

type
  TStackSample = record
    Count: LongInt;
    Addresses: array[0..MaximumSampleDepth - 1] of CodePointer;
  end;

{ Call on the page thread first. }
procedure PrepareSampling;
{ From another thread: the page thread's stack now (False if it did not
  answer or sampling is not available here). }
function TakeSample(out Sample: TStackSample): Boolean;
function DescribeSample(constref Sample: TStackSample): string;

procedure StartProfiler(IntervalMicroseconds: Integer);
{ Stops it and prints the report (Top functions each way). }
procedure StopProfiler(Top: Integer);

implementation

uses
  SysUtils,
  Classes,
  BaseUnix,
  UnixType,
  Contnrs,
  Process,
  Web.Profiling;

function pthread_kill(Thread: TThreadID; Signal: cint): cint; cdecl; external 'c' name 'pthread_kill';

type
  TProfilerThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Interval: Integer;
  end;

var
  PageThread: TThreadID;
  StackLow, StackHigh: PtrUInt;
  Current: TStackSample;
  SampleTaken: LongInt = 0;
  SampleLock: TRTLCriticalSection;
  Profiler: TProfilerThread = nil;
  ProfileSamples: array of TStackSample;
  ProfileCount: Integer = 0;
  IdleSamples: Integer = 0;
  { The program's symbols (nm), for code without line information (the
    run-time library). }
  SymbolAddresses: array of PtrUInt;
  SymbolNames: array of string;

{$ifdef CPUX86_64}
{ Linux x86-64 ucontext_t: gregs start at 40; RBP is register 10, RIP 16. }
procedure SampleHandler(Signal: cint; Info: PSigInfo; Context: Pointer); cdecl;
var
  Frame, Previous: PtrUInt;
  Count: LongInt;
begin
  Count := 0;
  Current.Addresses[Count] := PCodePointer(PByte(Context) + 40 + 16 * 8)^;
  Inc(Count);
  Frame := PPtrUInt(PByte(Context) + 40 + 10 * 8)^;
  Previous := 0;
  while (Count < MaximumSampleDepth) and (Frame >= StackLow) and (Frame + 16 <= StackHigh) and
    (Frame > Previous) and (Frame and 7 = 0) do
  begin
    Current.Addresses[Count] := PCodePointer(Frame + 8)^;
    Inc(Count);
    Previous := Frame;
    Frame := PPtrUInt(Frame)^;
  end;
  Current.Count := Count;
  InterlockedExchange(SampleTaken, 1);
end;
{$endif}

procedure PrepareSampling;
{$ifdef CPUX86_64}
var
  Action: SigActionRec;
{$endif}
begin
  PageThread := GetCurrentThreadId;
  StackHigh := PtrUInt(StackBottom) + PtrUInt(StackLength);
  StackLow := PtrUInt(StackBottom);
  {$ifdef CPUX86_64}
  FillChar(Action, SizeOf(Action), 0);
  Action.sa_handler := SigActionHandler(@SampleHandler);
  Action.sa_flags := SA_SIGINFO or SA_RESTART;
  fpSigAction(SIGUSR1, @Action, nil);
  {$endif}
end;

function TakeSample(out Sample: TStackSample): Boolean;
var
  Waited: Integer;
begin
  Sample.Count := 0;
  Result := False;
  {$ifdef CPUX86_64}
  EnterCriticalSection(SampleLock);
  try
    InterlockedExchange(SampleTaken, 0);
    if pthread_kill(PageThread, SIGUSR1) <> 0 then
      Exit;
    Waited := 0;
    while (SampleTaken = 0) and (Waited < 2000) do
    begin
      ThreadSwitch;
      Inc(Waited);
      if Waited > 100 then
        Sleep(1);
    end;
    if SampleTaken = 0 then
      Exit;
    Sample := Current;
    Result := True;
  finally
    LeaveCriticalSection(SampleLock);
  end;
  {$endif}
end;

function DescribeSample(constref Sample: TStackSample): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to Sample.Count - 1 do
    Result := Result + '  ' + BackTraceStrFunc(Sample.Addresses[Index]) + LineEnding;
end;

procedure TProfilerThread.Execute;
var
  Sample: TStackSample;
begin
  while not Terminated do
  begin
    if CurrentPhase = PhaseIdle then
      Inc(IdleSamples)
    else if TakeSample(Sample) then
    begin
      if ProfileCount >= Length(ProfileSamples) then
        SetLength(ProfileSamples, ProfileCount * 2 + 4096);
      ProfileSamples[ProfileCount] := Sample;
      Inc(ProfileCount);
    end;
    Sleep(Interval div 1000);
  end;
end;

procedure StartProfiler(IntervalMicroseconds: Integer);
begin
  Profiler := TProfilerThread.Create(True);
  Profiler.Interval := IntervalMicroseconds;
  if Profiler.Interval < 1000 then
    Profiler.Interval := 1000;
  Profiler.Start;
end;

procedure LoadSymbols;
var
  Output: string;
  Lines: TStringList;
  Index, Count: Integer;
  Fields: TStringArray;
  Address: QWord;
begin
  SymbolAddresses := nil;
  SymbolNames := nil;
  if not RunCommand('nm', ['-n', '--defined-only', ParamStr(0)], Output) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    SetLength(SymbolAddresses, Lines.Count);
    SetLength(SymbolNames, Lines.Count);
    Count := 0;
    for Index := 0 to Lines.Count - 1 do
    begin
      Fields := Lines[Index].Split(' ');
      if (Length(Fields) < 3) or not (Fields[1][1] in ['t', 'T']) then
        Continue;
      if not TryStrToQWord('$' + Fields[0], Address) then
        Continue;
      SymbolAddresses[Count] := PtrUInt(Address);
      SymbolNames[Count] := Fields[2];
      Inc(Count);
    end;
    SetLength(SymbolAddresses, Count);
    SetLength(SymbolNames, Count);
  finally
    Lines.Free;
  end;
end;

function SymbolOf(Address: PtrUInt): string;
var
  Low, High, Middle: Integer;
begin
  Result := '';
  if (Length(SymbolAddresses) = 0) or (Address < SymbolAddresses[0]) then
    Exit;
  Low := 0;
  High := System.High(SymbolAddresses);
  while Low < High do
  begin
    Middle := (Low + High + 1) div 2;
    if SymbolAddresses[Middle] <= Address then
      Low := Middle
    else
      High := Middle - 1;
  end;
  if Address - SymbolAddresses[Low] < 1024 * 1024 then
    Result := SymbolNames[Low];
end;

{ "FUNCTION, line 12 of file.pas" without the line. }
function FunctionOf(Address: CodePointer; Names: TFPStringHashTable): string;
var
  Key, Text: string;
  Comma: Integer;
begin
  Key := HexStr(Address);
  Result := Names[Key];
  if Result <> '' then
    Exit;
  Text := Trim(BackTraceStrFunc(Address));
  Comma := Pos(',', Text);
  if Comma > 0 then
  begin
    { "$0000000000412345  NAME,  line 12 of dir/File.pas" }
    Result := Trim(Copy(Text, 1, Comma - 1));
    while Pos(' ', Result) > 0 do
      Delete(Result, 1, Pos(' ', Result));
    Text := Copy(Text, Comma + 1, MaxInt);
    Result := ExtractFileName(Trim(Copy(Text, Pos(' of ', Text) + 4, MaxInt))) + ': ' + Result;
  end
  else
  begin
    Result := SymbolOf(PtrUInt(Address));
    if Result = '' then
      Result := '(outside the program: the C library)';
  end;
  Names[Key] := Result;
end;

procedure PrintTop(const Title: string; Counts: TStringList; Total, Top: Integer);
var
  Index: Integer;
  Pairs: TStringList;
begin
  Pairs := TStringList.Create;
  try
    for Index := 0 to Counts.Count - 1 do
      Pairs.Add(Format('%.10d', [PtrInt(Counts.Objects[Index])]) + #9 + Counts[Index]);
    Pairs.Sort;
    WriteLn(Title);
    for Index := Pairs.Count - 1 downto Pairs.Count - Top do
    begin
      if Index < 0 then
        Break;
      WriteLn(Format('  %5.1f%%  %s', [StrToInt(Copy(Pairs[Index], 1, 10)) * 100 / Total,
        Copy(Pairs[Index], 12, MaxInt)]));
    end;
  finally
    Pairs.Free;
  end;
end;

procedure Count(List: TStringList; const Name: string);
var
  Index: Integer;
begin
  Index := List.IndexOf(Name);
  if Index < 0 then
    List.AddObject(Name, TObject(PtrInt(1)))
  else
    List.Objects[Index] := TObject(PtrInt(List.Objects[Index]) + 1);
end;

procedure StopProfiler(Top: Integer);
var
  Names: TFPStringHashTable;
  SelfCounts, TotalCounts, Seen: TStringList;
  Index, Frame: Integer;
  Name: string;
begin
  if Profiler = nil then
    Exit;
  Profiler.Terminate;
  Profiler.WaitFor;
  FreeAndNil(Profiler);
  if ProfileCount = 0 then
  begin
    WriteLn('profile: no samples');
    Exit;
  end;
  LoadSymbols;
  Names := TFPStringHashTable.Create;
  SelfCounts := TStringList.Create;
  TotalCounts := TStringList.Create;
  Seen := TStringList.Create;
  SelfCounts.Sorted := True;
  TotalCounts.Sorted := True;
  Seen.Sorted := True;
  try
    for Index := 0 to ProfileCount - 1 do
    begin
      if ProfileSamples[Index].Count = 0 then
        Continue;
      Count(SelfCounts, FunctionOf(ProfileSamples[Index].Addresses[0], Names));
      Seen.Clear;
      for Frame := 0 to ProfileSamples[Index].Count - 1 do
      begin
        Name := FunctionOf(ProfileSamples[Index].Addresses[Frame], Names);
        if Seen.IndexOf(Name) < 0 then
        begin
          Seen.Add(Name);
          Count(TotalCounts, Name);
        end;
      end;
    end;
    WriteLn('profile: ', ProfileCount, ' samples of work (', IdleSamples, ' idle not counted), 1 ms apart');
    PrintTop('self:', SelfCounts, ProfileCount, Top);
    PrintTop('total:', TotalCounts, ProfileCount, Top);
  finally
    Names.Free;
    SelfCounts.Free;
    TotalCounts.Free;
    Seen.Free;
  end;
end;

initialization
  InitCriticalSection(SampleLock);
finalization
  DoneCriticalSection(SampleLock);
end.
