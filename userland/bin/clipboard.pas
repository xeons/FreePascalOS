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
  clipboard - the display server's clipboard from the command line

  clipboard -c [-t FORMAT]      standard input onto the clipboard
  clipboard -p [-t FORMAT]      the clipboard onto standard output
  clipboard -l                  the formats on the clipboard, a line each
  clipboard -x                  empties the clipboard
  clipboard --copy-image FILE   an image file onto it, as PNG and raw pixels
  clipboard --paste-image FILE  its image (PNG, or -t bgra) saved as a PNG file
  clipboard --copy-files PATH...  files onto it (a file list, and their paths as text)
  clipboard -w                  waits for the clipboard to change, says what it holds

  FORMAT is text (the default), png, bgra or files. Everything put on
  the clipboard is given to the server before the program ends, so the
  clipboard keeps it. Pasting a format the clipboard does not hold ends
  with status 1.
}
program clipboard;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  Util.CommandLine,
  Util.Messages,
  Abi.SystemCalls,
  Sys.Streams,
  Image.Model,
  Image.Codecs,
  Image.Errors,
  Image.Files,
  Windowing.Protocol,
  Windowing.Connection,
  Windowing.DataTransfer,
  Windowing.Clipboard,
  Controls.FileLists,
  { Its initialization puts the display server's clipboard behind
    Controls.FileLists' file lists. }
  Controls.SystemClipboard,
  Controls.ImageClipboard;

const
  Usage = 'Usage: clipboard -c|-p [-t FORMAT] | -l | -x | -w | --copy-image FILE | --paste-image FILE [-t png|bgra]'#10 +
    '       | --copy-files PATH...'#10 +
    'The display server''s clipboard: copy standard input to it, paste it, list its formats'#10 +
    '(text, png, bgra, files), empty it, or wait for it to change.'#10;
  OptionCopy = 1;
  OptionPaste = 2;
  OptionList = 3;
  OptionClear = 4;
  OptionFormat = 5;
  OptionCopyImage = 6;
  OptionPasteImage = 7;
  OptionCopyFiles = 8;
  OptionWait = 9;
  ChangeTimeout = 60000;

function ReadStandardInput: TBytes;
var
  Buffer: array[0..65535] of Char;
  Count: QWord;
  Size: LongInt;
begin
  Result := nil;
  repeat
    Count := ReadBytes(StandardInput, @Buffer[0], SizeOf(Buffer));
    if Count = 0 then
      Break;
    Size := Length(Result);
    SetLength(Result, Size + LongInt(Count));
    Move(Buffer[0], Result[Size], Count);
  until False;
end;

procedure WriteStandardOutput(const Data: TBytes);
begin
  if Length(Data) > 0 then
    WriteBytes(StandardOutput, PChar(@Data[0]), Length(Data));
  FlushStream(StandardOutput);
end;

function FormatNamed(const Name: string): LongWord;
begin
  if Name = '' then
    Exit(DataFormatText);
  Result := DataFormatFromName(Name);
  if Result = 0 then
    FailWithUsageHint('unknown format ''' + Name + ''' (text, png, bgra or files)');
end;

procedure ListFormats;
var
  Formats: LongWord;
  Format: LongWord;
begin
  Formats := ClipboardFormats;
  for Format := 1 to DataFormatCount do
    if (Formats and DataFormatBit(Format)) <> 0 then
      PrintStringLine(DataFormatName(Format));
end;

function FormatNames(Formats: LongWord): string;
var
  Format: LongWord;
begin
  Result := '';
  for Format := 1 to DataFormatCount do
    if (Formats and DataFormatBit(Format)) <> 0 then
      Result := Result + ' ' + DataFormatName(Format);
  if Result = '' then
    Result := ' empty';
end;

procedure WaitForChange;
var
  Message: TWindowMessage;
begin
  WatchClipboard(True);
  { Answered after the watch is taken: then nothing is missed. }
  ClipboardFormats;
  PrintStringLine('watching');
  FlushStream(StandardOutput);
  if not WaitForEvent(EventClipboardChanged, ChangeTimeout, Message) then
    Fail(1, 'the clipboard did not change');
  PrintStringLine('changed' + FormatNames(Message.Flags));
end;

procedure Paste(Format: LongWord);
var
  Data: TBytes;
begin
  if not ReadClipboard(Format, Data) then
    Fail(1, 'the clipboard holds no ' + DataFormatName(Format));
  WriteStandardOutput(Data);
end;

procedure CopyImage(const FileName: string);
var
  Image: TImage;
begin
  try
    Image := LoadImage(FileName, [ImageLoadApplyOrientation]);
  except
    on Error: EImageError do
      Fail(1, FileName + ': ' + Error.Message);
  end;
  WriteClipboard(TImageOffer.Create(Image));
end;

procedure PasteImage(const FileName: string; Format: LongWord);
var
  Data: TBytes;
  Image: TImage;
begin
  if (Format <> DataFormatPng) and (Format <> DataFormatBgra) then
    FailWithUsageHint('an image is pasted from png or bgra');
  if not ReadClipboard(Format, Data) then
    Fail(1, 'the clipboard holds no ' + DataFormatName(Format));
  Image := nil;
  try
    if Format = DataFormatBgra then
      Image := BgraToImage(Data)
    else
      Image := LoadImage(Data);
    if Image = nil then
      Fail(1, 'the clipboard''s image is malformed');
    SaveImage(Image, FileName, ImageFormatPng);
  except
    on Error: EImageError do
      Fail(1, Error.Message);
  end;
  Image.Free;
end;

procedure CopyFiles(const Operands: TStringArray);
var
  Paths: TStringList;
  Operand: string;
begin
  if Length(Operands) = 0 then
    FailWithUsageHint('no files given');
  Paths := TStringList.Create;
  try
    for Operand in Operands do
      Paths.Add(ExpandFileName(Operand));
    SetClipboardFileList(FileListCopy, Paths);
  finally
    Paths.Free;
  end;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Format: LongWord;
begin
  CommandLine := TCommandLine.Create([
    CommandOption('c', 'copy', False, OptionCopy),
    CommandOption('p', 'paste', False, OptionPaste),
    CommandOption('l', 'list', False, OptionList),
    CommandOption('x', 'clear', False, OptionClear),
    CommandOption('t', 'format', True, OptionFormat),
    CommandOption('w', 'wait', False, OptionWait),
    CommandOption(#0, 'copy-image', True, OptionCopyImage),
    CommandOption(#0, 'paste-image', True, OptionPasteImage),
    CommandOption(#0, 'copy-files', False, OptionCopyFiles)], Usage);
  while CommandLine.NextOption(Code, Value) do;
  Format := FormatNamed(CommandLine.OptionValue(OptionFormat));
  if ConnectToDisplay(False) <> ErrorNone then
    Fail(1, 'no display server');
  if CommandLine.OptionGiven(OptionCopy) then
    WriteClipboardBytes(Format, ReadStandardInput)
  else if CommandLine.OptionGiven(OptionPaste) then
    Paste(Format)
  else if CommandLine.OptionGiven(OptionList) then
    ListFormats
  else if CommandLine.OptionGiven(OptionClear) then
    ClearClipboard
  else if CommandLine.OptionGiven(OptionWait) then
    WaitForChange
  else if CommandLine.OptionGiven(OptionCopyImage) then
    CopyImage(CommandLine.OptionValue(OptionCopyImage))
  else if CommandLine.OptionGiven(OptionPasteImage) then
  begin
    if not CommandLine.OptionGiven(OptionFormat) then
      Format := DataFormatPng;
    PasteImage(CommandLine.OptionValue(OptionPasteImage), Format);
  end
  else if CommandLine.OptionGiven(OptionCopyFiles) then
    CopyFiles(CommandLine.Operands)
  else
    FailWithUsageHint('say what to do (-c, -p, -l, -x, -w, --copy-image, --paste-image or --copy-files)');
  { The clipboard keeps everything once this program has gone. }
  FlushClipboard;
  DisconnectFromDisplay;
  Halt(0);
end.
