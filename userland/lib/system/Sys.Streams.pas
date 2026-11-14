{
  Buffered input and output.

  Writing one character at a time through system calls would be slow, so
  output goes through a buffer that is written out when full, at a line
  end when the stream is the console, on Flush, and when the program
  ends. Input is read a block at a time and handed out as lines or
  characters.

  StandardOutput, StandardError and StandardInput are created on first
  use; the first use of an output stream also registers the flush that
  runs when the program exits.

  The environment variables _STDBUF_O and _STDBUF_E (set by stdbuf)
  choose the buffering of standard output and error: "0" writes at once,
  "L" at every line end, anything else when the buffer is full.
}
unit Sys.Streams;

{$mode objfpc}
{$pointermath on}

interface

const
  StreamBufferSize = 4096;

type
  POutputStream = ^TOutputStream;
  TOutputStream = record
    Handle: Int64;
    Buffer: array[0..StreamBufferSize - 1] of Char;
    Count: LongWord;
    FlushAtLineEnd: Boolean;
    { Written out after every write call. }
    Unbuffered: Boolean;
    HadError: Boolean;
  end;

  PInputStream = ^TInputStream;
  TInputStream = record
    Handle: Int64;
    Buffer: array[0..StreamBufferSize - 1] of Char;
    Position: LongWord;
    Count: LongWord;
    ReachedEnd: Boolean;
    HadError: Boolean;
  end;

function StandardOutput: POutputStream;
function StandardError: POutputStream;
function StandardInput: PInputStream;

{ Streams over other handles (the handle stays owned by the caller). }
function CreateOutputStream(Handle: Int64): POutputStream;
function CreateInputStream(Handle: Int64): PInputStream;
procedure DestroyOutputStream(Stream: POutputStream);
procedure DestroyInputStream(Stream: PInputStream);

procedure WriteBytes(Stream: POutputStream; Bytes: PChar; Count: QWord);
procedure WriteText(Stream: POutputStream; Text: PChar);
procedure WriteLine(Stream: POutputStream; Text: PChar);
procedure WriteCharacter(Stream: POutputStream; Character: Char);
procedure WriteDecimal(Stream: POutputStream; Value: Int64);
procedure WriteUnsigned(Stream: POutputStream; Value: QWord);
procedure FlushStream(Stream: POutputStream);

{ Shorthands for standard output and standard error. }
procedure Print(Text: PChar);
procedure PrintLine(Text: PChar);
procedure PrintError(Text: PChar);
procedure PrintErrorLine(Text: PChar);

{ Reads the next line into a new heap string without its line end.
  Returns False at end of input with nothing read. HadLineEnd tells
  whether the line was terminated (the last line may not be). }
function ReadLine(Stream: PInputStream; out Line: PChar; out HadLineEnd: Boolean): Boolean;
function ReadCharacter(Stream: PInputStream; out Character: Char): Boolean;
{ Reads up to Count bytes; returns the number read (0 at end). }
function ReadBytes(Stream: PInputStream; Bytes: PChar; Count: QWord): QWord;

procedure FlushStandardStreams;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Memory,
  Sys.Text;

var
  OutputStream: POutputStream = nil;
  ErrorStream: POutputStream = nil;
  InputStream: PInputStream = nil;

procedure FlushStandardStreams;
begin
  if OutputStream <> nil then
    FlushStream(OutputStream);
  if ErrorStream <> nil then
    FlushStream(ErrorStream);
end;

function CreateOutputStream(Handle: Int64): POutputStream;
begin
  Result := POutputStream(AllocateZeroedMemory(SizeOf(TOutputStream)));
  if Result = nil then
    Exit;
  Result^.Handle := Handle;
  Result^.FlushAtLineEnd := KernelGetHandleKind(Handle) = HandleKindConsole;
end;

function CreateInputStream(Handle: Int64): PInputStream;
begin
  Result := PInputStream(AllocateZeroedMemory(SizeOf(TInputStream)));
  if Result <> nil then
    Result^.Handle := Handle;
end;

procedure DestroyOutputStream(Stream: POutputStream);
begin
  if Stream = nil then
    Exit;
  FlushStream(Stream);
  FreeMemory(Stream);
end;

procedure DestroyInputStream(Stream: PInputStream);
begin
  FreeMemory(Stream);
end;

{ Looks for Name=value in the program's original environment (this unit
  sits below Sys.Environment). }
function FindStartupVariable(Name: PChar): PChar;
var
  Index: Integer;
  NameLength: PtrUInt;
begin
  NameLength := TextLength(Name);
  Index := 0;
  while EnvironmentValues[Index] <> nil do
  begin
    if TextStartsWith(EnvironmentValues[Index], Name) and (EnvironmentValues[Index][NameLength] = '=') then
      Exit(EnvironmentValues[Index] + NameLength + 1);
    Inc(Index);
  end;
  Result := nil;
end;

procedure ApplyBufferingRequest(Stream: POutputStream; VariableName: PChar);
var
  Mode: PChar;
begin
  Mode := FindStartupVariable(VariableName);
  if Mode = nil then
    Exit;
  Stream^.FlushAtLineEnd := (Mode^ = 'L') or (Mode^ = '0');
  Stream^.Unbuffered := Mode^ = '0';
end;

function StandardOutput: POutputStream;
begin
  if OutputStream = nil then
  begin
    OutputStream := CreateOutputStream(StandardOutputHandle);
    ApplyBufferingRequest(OutputStream, '_STDBUF_O');
    ExitProcedure := @FlushStandardStreams;
  end;
  Result := OutputStream;
end;

function StandardError: POutputStream;
begin
  if ErrorStream = nil then
  begin
    ErrorStream := CreateOutputStream(StandardErrorHandle);
    { Errors should appear immediately. }
    ErrorStream^.FlushAtLineEnd := True;
    ApplyBufferingRequest(ErrorStream, '_STDBUF_E');
    ExitProcedure := @FlushStandardStreams;
  end;
  Result := ErrorStream;
end;

function StandardInput: PInputStream;
begin
  if InputStream = nil then
    InputStream := CreateInputStream(StandardInputHandle);
  Result := InputStream;
end;

{ --- Output ---------------------------------------------------------- }

procedure FlushStream(Stream: POutputStream);
var
  Written: QWord;
  WriteResult: Int64;
begin
  if (Stream = nil) or (Stream^.Count = 0) then
    Exit;
  Written := 0;
  while Written < Stream^.Count do
  begin
    WriteResult := KernelWrite(Stream^.Handle, @Stream^.Buffer[Written], Stream^.Count - Written);
    if WriteResult <= 0 then
    begin
      Stream^.HadError := True;
      Break;
    end;
    Written := Written + QWord(WriteResult);
  end;
  Stream^.Count := 0;
end;

procedure WriteBytes(Stream: POutputStream; Bytes: PChar; Count: QWord);
var
  Index: QWord;
  SawLineEnd: Boolean;
begin
  if Stream = nil then
    Exit;
  SawLineEnd := False;
  Index := 0;
  while Index < Count do
  begin
    if Stream^.Count = StreamBufferSize then
      FlushStream(Stream);
    Stream^.Buffer[Stream^.Count] := Bytes[Index];
    Inc(Stream^.Count);
    if Bytes[Index] = #10 then
      SawLineEnd := True;
    Inc(Index);
  end;
  if (SawLineEnd and Stream^.FlushAtLineEnd) or Stream^.Unbuffered then
    FlushStream(Stream);
end;

procedure WriteText(Stream: POutputStream; Text: PChar);
begin
  if Text <> nil then
    WriteBytes(Stream, Text, TextLength(Text));
end;

procedure WriteLine(Stream: POutputStream; Text: PChar);
begin
  WriteText(Stream, Text);
  WriteCharacter(Stream, #10);
end;

procedure WriteCharacter(Stream: POutputStream; Character: Char);
begin
  WriteBytes(Stream, @Character, 1);
end;

procedure WriteDecimal(Stream: POutputStream; Value: Int64);
var
  NumberText: TNumberText;
begin
  WriteText(Stream, FormatSignedDecimal(Value, NumberText));
end;

procedure WriteUnsigned(Stream: POutputStream; Value: QWord);
var
  NumberText: TNumberText;
begin
  WriteText(Stream, FormatDecimal(Value, NumberText));
end;

procedure Print(Text: PChar);
begin
  WriteText(StandardOutput, Text);
end;

procedure PrintLine(Text: PChar);
begin
  WriteLine(StandardOutput, Text);
end;

procedure PrintError(Text: PChar);
begin
  WriteText(StandardError, Text);
end;

procedure PrintErrorLine(Text: PChar);
begin
  WriteLine(StandardError, Text);
end;

{ --- Input ----------------------------------------------------------- }

function RefillInput(Stream: PInputStream): Boolean;
var
  BytesRead: Int64;
begin
  if Stream^.ReachedEnd then
    Exit(False);
  { Output written before a read (such as a prompt) must be visible. }
  FlushStandardStreams;
  BytesRead := KernelRead(Stream^.Handle, @Stream^.Buffer[0], StreamBufferSize);
  if BytesRead <= 0 then
  begin
    Stream^.ReachedEnd := True;
    Stream^.HadError := BytesRead < 0;
    Exit(False);
  end;
  Stream^.Position := 0;
  Stream^.Count := LongWord(BytesRead);
  Result := True;
end;

function ReadCharacter(Stream: PInputStream; out Character: Char): Boolean;
begin
  Character := #0;
  if (Stream^.Position >= Stream^.Count) and not RefillInput(Stream) then
    Exit(False);
  Character := Stream^.Buffer[Stream^.Position];
  Inc(Stream^.Position);
  Result := True;
end;

function ReadLine(Stream: PInputStream; out Line: PChar; out HadLineEnd: Boolean): Boolean;
var
  Builder: TTextBuilder;
  Character: Char;
  ReadAnything: Boolean;
begin
  Line := nil;
  HadLineEnd := False;
  ReadAnything := False;
  BeginText(Builder);
  while ReadCharacter(Stream, Character) do
  begin
    ReadAnything := True;
    if Character = #10 then
    begin
      HadLineEnd := True;
      Break;
    end;
    AppendCharacter(Builder, Character);
  end;

  if not ReadAnything then
  begin
    DiscardText(Builder);
    Exit(False);
  end;
  Line := FinishText(Builder);
  Result := True;
end;

function ReadBytes(Stream: PInputStream; Bytes: PChar; Count: QWord): QWord;
var
  Available: QWord;
begin
  Result := 0;
  while Result < Count do
  begin
    if (Stream^.Position >= Stream^.Count) and not RefillInput(Stream) then
      Break;
    Available := Stream^.Count - Stream^.Position;
    if Available > Count - Result then
      Available := Count - Result;
    CopyMemory(Bytes + Result, @Stream^.Buffer[Stream^.Position], Available);
    Stream^.Position := Stream^.Position + LongWord(Available);
    Result := Result + Available;
  end;
end;

end.
