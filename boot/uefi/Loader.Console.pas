{
  Text output for the loader through the firmware console.

  Firmware text output expects UTF-16 strings. The loader works with plain
  ASCII PChar strings and converts them here in small chunks.
}
unit Loader.Console;

{$mode objfpc}
{$pointermath on}

interface

uses
  Uefi.Base;

procedure PrintText(Text: PChar);
procedure PrintLine(Text: PChar);
procedure PrintHexadecimal(Value: QWord);
procedure PrintDecimal(Value: QWord);
procedure PrintStatus(Status: TEfiStatus);

procedure PrintErrorAndStatus(Message: PChar; Status: TEfiStatus);

procedure SetConsoleColor(Attribute: QWord);
procedure ClearConsole;

{ Converts ASCII text into a null-terminated UTF-16 string. Returns False
  when the destination is too small. }
function ConvertAsciiToUtf16(Source: PChar; Destination: PWideChar;
  DestinationCapacity: PtrUInt): Boolean;

implementation

uses
  Runtime.Text,
  Uefi.TextOutput,
  Loader.Firmware;

const
  ConversionChunkLength = 126;

procedure OutputWideText(Text: PWideChar);
var
  ConsoleOut: PEfiSimpleTextOutputProtocol;
begin
  if BootServicesHaveExited then
    Exit;
  ConsoleOut := FirmwareSystemTable^.ConsoleOut;
  ConsoleOut^.OutputString(ConsoleOut, Text);
end;

procedure PrintText(Text: PChar);
var
  WideBuffer: array[0..ConversionChunkLength + 2] of WideChar;
  BufferLength: PtrUInt;
  TextIndex: PtrUInt;
  Character: Char;
begin
  BufferLength := 0;
  TextIndex := 0;

  while Text[TextIndex] <> #0 do
  begin
    Character := Text[TextIndex];

    { The firmware console needs an explicit carriage return. }
    if Character = #10 then
    begin
      WideBuffer[BufferLength] := WideChar(13);
      Inc(BufferLength);
    end;

    WideBuffer[BufferLength] := WideChar(Ord(Character));
    Inc(BufferLength);
    Inc(TextIndex);

    if BufferLength >= ConversionChunkLength then
    begin
      WideBuffer[BufferLength] := WideChar(0);
      OutputWideText(@WideBuffer[0]);
      BufferLength := 0;
    end;
  end;

  if BufferLength > 0 then
  begin
    WideBuffer[BufferLength] := WideChar(0);
    OutputWideText(@WideBuffer[0]);
  end;
end;

procedure PrintLine(Text: PChar);
begin
  PrintText(Text);
  PrintText(#10);
end;

procedure PrintHexadecimal(Value: QWord);
var
  NumberText: TNumberText;
begin
  PrintText('0x');
  PrintText(FormatHexadecimal(Value, 1, NumberText));
end;

procedure PrintDecimal(Value: QWord);
var
  NumberText: TNumberText;
begin
  PrintText(FormatDecimal(Value, NumberText));
end;

procedure PrintStatus(Status: TEfiStatus);
begin
  case Status of
    EfiSuccess: PrintText('success');
    EfiLoadError: PrintText('load error');
    EfiInvalidParameter: PrintText('invalid parameter');
    EfiUnsupported: PrintText('unsupported');
    EfiBufferTooSmall: PrintText('buffer too small');
    EfiOutOfResources: PrintText('out of resources');
    EfiNotFound: PrintText('not found');
  else
    PrintHexadecimal(Status);
  end;
end;

procedure PrintErrorAndStatus(Message: PChar; Status: TEfiStatus);
begin
  SetConsoleColor(EfiTextColorLightRed);
  PrintText('Error: ');
  PrintText(Message);
  PrintText(' (');
  PrintStatus(Status);
  PrintLine(')');
  SetConsoleColor(EfiTextColorLightGray);
end;

procedure SetConsoleColor(Attribute: QWord);
var
  ConsoleOut: PEfiSimpleTextOutputProtocol;
begin
  if BootServicesHaveExited then
    Exit;
  ConsoleOut := FirmwareSystemTable^.ConsoleOut;
  ConsoleOut^.SetAttribute(ConsoleOut, Attribute);
end;

procedure ClearConsole;
var
  ConsoleOut: PEfiSimpleTextOutputProtocol;
begin
  if BootServicesHaveExited then
    Exit;
  ConsoleOut := FirmwareSystemTable^.ConsoleOut;
  ConsoleOut^.ClearScreen(ConsoleOut);
end;

function ConvertAsciiToUtf16(Source: PChar; Destination: PWideChar;
  DestinationCapacity: PtrUInt): Boolean;
var
  Index: PtrUInt;
begin
  Index := 0;
  while Source[Index] <> #0 do
  begin
    if Index + 1 >= DestinationCapacity then
      Exit(False);
    Destination[Index] := WideChar(Ord(Source[Index]));
    Inc(Index);
  end;
  Destination[Index] := WideChar(0);
  Result := True;
end;

end.
