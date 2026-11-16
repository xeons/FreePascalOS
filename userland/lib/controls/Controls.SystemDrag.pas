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
  Controls' drags going through the display server, so they reach other
  windows and programs (Windowing.DragAndDrop).

  A drag of text or of a file list becomes the server's: text as UTF-8
  text, a file list as the file list format with the plain paths as
  text beside it (so an edit box takes dropped files as their paths).
  A program's own formats stay within the window (Controls.Window).
  While this program's drag goes on, its windows see the drag's own
  TDragData (OutgoingDrag: its source control too, so a list can tell
  its own items); a drag from another program is read once, when it
  first comes over one of this program's windows, and kept as a
  TDragData with no source until another drag comes.
}
unit Controls.SystemDrag;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.DataTransfer,
  Windowing.DragAndDrop,
  Controls.DragData;

var
  { This program's drag going through the server (its window owns it),
    or nil. }
  OutgoingDrag: TDragData;

{ What the server is given for Data (nil: a format only this program
  knows, which stays within the window). }
function OfferForDragData(Data: TDragData): TDataOffer;
{ A few words for beside the pointer. }
function DescribeDragData(Data: TDragData): string;
{ The data of the drag Drag is about: this program's own, or read from
  the server (kept until another drag); nil if it carries nothing a
  control takes. Not the caller's to free. }
function IncomingDragData(const Drag: TDragEvent): TDragData;
{ The text a drop of Data puts in an edit box: its text, or the paths of
  a file list a line each; False if it carries neither. }
function DragDataAsText(Data: TDragData; out Text: string): Boolean;
{ Between the controls' effects and the protocol's (DropEffect*). }
function DropEffectBits(Effect: TDropEffect): LongWord;
function DropEffectOfBits(Bits: LongWord): TDropEffect;

implementation

uses
  SysUtils,
  Classes,
  Windowing.Protocol,
  Controls.FileLists;

const
  DescriptionLength = 32;

var
  ForeignDrag: TDragData;
  ForeignDragNumber: LongWord;

function PlainPathsOf(Paths: TStrings): string;
var
  Index: LongInt;
begin
  Result := '';
  for Index := 0 to Paths.Count - 1 do
  begin
    if Index > 0 then
      Result := Result + #10;
    Result := Result + Paths[Index];
  end;
end;

function OfferForDragData(Data: TDragData): TDataOffer;
var
  Paths: TStringList;
  Action: TFileListAction;
begin
  Result := nil;
  if Data.Format = DragFormatText then
  begin
    Result := TDataOffer.Create;
    Result.Add(DataFormatText, TextToBytes(Data.Text));
  end
  else if Data.Format = DragFormatFileList then
  begin
    Paths := TStringList.Create;
    try
      Result := TDataOffer.Create;
      Result.Add(DataFormatFileList, TextToBytes(Data.Text));
      if DecodeFileList(Data.Text, Action, Paths) then
        Result.Add(DataFormatText, TextToBytes(PlainPathsOf(Paths)));
    finally
      Paths.Free;
    end;
  end;
end;

function FirstLine(const Text: string): string;
var
  Index: LongInt;
begin
  Index := 1;
  while (Index <= Length(Text)) and (Text[Index] <> #10) and (Text[Index] <> #13) do
    Inc(Index);
  Result := Copy(Text, 1, Index - 1);
end;

function DescribeDragData(Data: TDragData): string;
var
  Paths: TStringList;
  Action: TFileListAction;
begin
  if Data.Format = DragFormatFileList then
  begin
    Paths := TStringList.Create;
    try
      if DecodeFileList(Data.Text, Action, Paths) and (Paths.Count = 1) then
        Exit(ExtractFileName(ExcludeTrailingPathDelimiter(Paths[0])));
      Exit(IntToStr(Paths.Count) + ' items');
    finally
      Paths.Free;
    end;
  end;
  Result := FirstLine(Data.Text);
  if Length(Result) > DescriptionLength then
    Result := Copy(Result, 1, DescriptionLength - 3) + '...';
end;

function ReadForeignDrag(const Drag: TDragEvent): TDragData;
var
  Data: TBytes;
begin
  Result := nil;
  if ((Drag.Formats and DataFormatBit(DataFormatFileList)) <> 0) and ReadDragData(DataFormatFileList, Data) then
    Exit(TDragData.Create(DragFormatFileList, BytesToText(Data), nil));
  if ((Drag.Formats and DataFormatBit(DataFormatText)) <> 0) and ReadDragData(DataFormatText, Data) then
    Exit(TDragData.Create(DragFormatText, BytesToText(Data), nil));
end;

function IncomingDragData(const Drag: TDragEvent): TDragData;
begin
  if OwnDragGoingOn and (OutgoingDrag <> nil) then
    Exit(OutgoingDrag);
  if (ForeignDrag = nil) or (ForeignDragNumber <> Drag.Number) then
  begin
    FreeAndNil(ForeignDrag);
    ForeignDrag := ReadForeignDrag(Drag);
    ForeignDragNumber := Drag.Number;
  end;
  Result := ForeignDrag;
end;

function DragDataAsText(Data: TDragData; out Text: string): Boolean;
var
  Paths: TStringList;
  Action: TFileListAction;
begin
  Text := '';
  Result := False;
  if Data = nil then
    Exit;
  if Data.Format = DragFormatText then
  begin
    Text := Data.Text;
    Exit(True);
  end;
  if Data.Format <> DragFormatFileList then
    Exit;
  Paths := TStringList.Create;
  try
    Result := DecodeFileList(Data.Text, Action, Paths);
    if Result then
      Text := PlainPathsOf(Paths);
  finally
    Paths.Free;
  end;
end;

function DropEffectBits(Effect: TDropEffect): LongWord;
begin
  case Effect of
    DropCopy: Result := DropEffectCopy;
    DropMove: Result := DropEffectMove;
    DropLink: Result := DropEffectLink;
  else
    Result := 0;
  end;
end;

function DropEffectOfBits(Bits: LongWord): TDropEffect;
begin
  if (Bits and DropEffectMove) <> 0 then
    Result := DropMove
  else if (Bits and DropEffectCopy) <> 0 then
    Result := DropCopy
  else if (Bits and DropEffectLink) <> 0 then
    Result := DropLink
  else
    Result := DropNone;
end;

finalization
  ForeignDrag.Free;
end.
